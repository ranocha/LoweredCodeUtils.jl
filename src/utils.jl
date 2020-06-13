const AnySSAValue = Union{Core.Compiler.SSAValue,JuliaInterpreter.SSAValue}
const AnySlotNumber = Union{Core.Compiler.SlotNumber,JuliaInterpreter.SlotNumber}

isssa(stmt) = isa(stmt, Core.Compiler.SSAValue) | isa(stmt, JuliaInterpreter.SSAValue)
isslotnum(stmt) = isa(stmt, Core.Compiler.SlotNumber) | isa(stmt, JuliaInterpreter.SlotNumber)

"""
    iscallto(stmt, name)

Returns `true` is `stmt` is a call expression to `name`.
"""
function iscallto(@nospecialize(stmt), name)
    if isa(stmt, Expr)
        if stmt.head === :call
            a = stmt.args[1]
            a === name && return true
            is_global_ref(a, Core, :_apply) && stmt.args[2] === name && return true
            is_global_ref(a, Core, :_apply_iterate) && stmt.args[3] === name && return true
        end
    end
    return false
end

"""
    getcallee(stmt)

Returns the function (or Symbol) being called in a :call expression.
"""
function getcallee(@nospecialize(stmt))
    if isa(stmt, Expr)
        if stmt.head === :call
            a = stmt.args[1]
            is_global_ref(a, Core, :_apply) && return stmt.args[2]
            is_global_ref(a, Core, :_apply_iterate) && return stmt.args[3]
            return a
        end
    end
    error(stmt, " is not a call expression")
end

function callee_matches(f, mod, sym)
    is_global_ref(f, mod, sym) && return true
    if isdefined(mod, sym) && isa(f, QuoteNode)
        f.value === getfield(mod, sym) && return true  # a consequence of JuliaInterpreter.optimize!
    end
    return false
end

function rhs(stmt)
    isexpr(stmt, :(=)) && return (stmt::Expr).args[2]
    return stmt
end

ismethod(frame::Frame)  = ismethod(pc_expr(frame))
ismethod3(frame::Frame) = ismethod3(pc_expr(frame))

ismethod(stmt)  = isexpr(stmt, :method)
ismethod1(stmt) = isexpr(stmt, :method, 1)
ismethod3(stmt) = isexpr(stmt, :method, 3)

# anonymous function types are defined in a :thunk expr with a characteristic CodeInfo
function isanonymous_typedef(stmt)
    if isa(stmt, Expr)
        stmt.head === :thunk || return false
        stmt = stmt.args[1]
    end
    if isa(stmt, CodeInfo)
        src = stmt    # just for naming consistency
        length(src.code) >= 4 || return false
        if VERSION >= v"1.5.0-DEV.702"
            stmt = src.code[end-1]
            (isexpr(stmt, :call) && is_global_ref(stmt.args[1], Core, :_typebody!)) || return false
            name = (stmt::Expr).args[2]::Symbol
            return startswith(String(name), "#")
        else
            stmt = src.code[end-1]
            isexpr(stmt, :struct_type) || return false
            name = (stmt::Expr).args[1]::Symbol
            return startswith(String(name), "#")
        end
    end
    return false
end

function istypedef(stmt)
    isa(stmt, Expr) || return false
    stmt = rhs(stmt)
    isa(stmt, Expr) || return false
    stmt.head ∈ structheads && return true
    @static if isdefined(Core, :_structtype)
        if stmt.head === :call
            f = stmt.args[1]
            if isa(f, GlobalRef)
                f.mod === Core && f.name ∈ (:_structype, :_abstracttype, :_primitivetype) && return true
            end
            if isa(f, QuoteNode)
                (f.value === Core._structtype || f.value === Core._abstracttype ||
                 f.value === Core._primitivetype) && return true
            end
        end
    end
    isanonymous_typedef(stmt) && return true
    return false
end

# Given a typedef at `src.code[idx]`, return the range of statement indices that encompass the typedef.
# The range does not include any constructor methods.
function typedef_range(src::CodeInfo, idx)
    stmt = src.code[idx]
    istypedef(stmt) || error(stmt, " is not a typedef")
    isanonymous_typedef(stmt) && return idx:idx
    # Search backwards to the previous :global
    istart = idx
    while istart >= 1
        isexpr(src.code[istart], :global) && break
        istart -= 1
    end
    istart >= 1 || error("no initial :global found")
    iend, n = idx, length(src.code)
    while iend <= n
        stmt = src.code[iend]
        if isa(stmt, Expr)
            (stmt.head === :global || stmt.head === :return) && break
        end
        iend += 1
    end
    iend <= n || (@show src; error("no final :global found"))
    return istart:iend-1
end

"""
    nextpc = next_or_nothing(frame, pc)
    nextpc = next_or_nothing!(frame)

Advance the program counter without executing the corresponding line.
If `frame` is finished, `nextpc` will be `nothing`.
"""
next_or_nothing(frame, pc) = pc < nstatements(frame.framecode) ? pc+1 : nothing
function next_or_nothing!(frame)
    pc = frame.pc
    if pc < nstatements(frame.framecode)
        frame.pc = pc = pc + 1
        return pc
    end
    return nothing
end

"""
    nextpc = skip_until(predicate, frame, pc)
    nextpc = skip_until!(predicate, frame)

Advance the program counter until `predicate(stmt)` return `true`.
"""
function skip_until(predicate, frame, pc)
    stmt = pc_expr(frame, pc)
    while !predicate(stmt)
        pc = next_or_nothing(frame, pc)
        pc === nothing && return nothing
        stmt = pc_expr(frame, pc)
    end
    return pc
end
function skip_until!(predicate, frame)
    pc = frame.pc
    stmt = pc_expr(frame, pc)
    while !predicate(stmt)
        pc = next_or_nothing!(frame)
        pc === nothing && return nothing
        stmt = pc_expr(frame, pc)
    end
    return pc
end

function sparam_ub(meth::Method)
    typs = []
    sig = meth.sig
    while sig isa UnionAll
        push!(typs, Symbol(sig.var.ub))
        sig = sig.body
    end
    return Core.svec(typs...)
end

showempty(list) = isempty(list) ? '∅' : list

# Smooth the transition between Core.Compiler and Base
rng(bb::Core.Compiler.BasicBlock) = (r = bb.stmts; return Core.Compiler.first(r):Core.Compiler.last(r))

function pushall!(dest, src)
    for item in src
        push!(dest, item)
    end
    return dest
end
