
# """
#     Snapshot{X}

# Container for a value of `T` together with a deepcopy of it.
# """
struct Snapshot{T}
    original::T
    copy::T
end


function Snapshot(original)
    try
        return Snapshot(original, deepcopy(original))
    catch ex
        if ex isa ErrorException
            @warn "Snapshotting object of type $(typeof(original)) failed, using original reference instead"
            # @show original
            # ex isa UndefRefError && showerror(stdout, ex, stacktrace())
            # println()
            return Snapshot(original, original)
        else
            rethrow(ex)
        end
    end
end

# modules can't be deepcopied anyway
Snapshot(m::Module) = Snapshot(m, m)

# This is a weird but necessary solution:
# Some isa UnionAll == true
# UnionAll <: DataType == false
# supertype(UnionAll) == Type{T}
Snapshot(u::UnionAll) = Snapshot{UnionAll}(u, u)
Snapshot(t::DataType) = Snapshot{DataType}(t, t)


Base.show(io::IO, s::Snapshot) = print(io, "Snapshot(", s.copy, ")")

getoriginal(s::Snapshot) = s.original
getsnapshot(s::Snapshot) = s.copy


"""
    TapeExpr{T}

Abstract supertype of representations of an expression in an IR statement when tracked in a node.
Contains a reified form of the original and the value obtained during execution (i.e., forward
mode).  `T` is the type of the value of the statement.
"""
abstract type TapeExpr{T} end


"""
    TapeValue{T}

Abstract supertype of [`TapeExpr`](@ref)s that represents a simple value (i.e., constants or
references).
"""
abstract type TapeValue{T} <: TapeExpr{T} end


"""
    TapeForm{T}

Abstract supertype of [`TapeExpr`](@ref)s that contain a non-simple value (i.e., calls or special 
calls).
"""
abstract type TapeForm{T} <: TapeExpr{T} end



const TapeCallArgs = Tuple{Vararg{TapeValue}}

@generated function argtypes(::TA,
                             ::TV
) where {TA<:TapeCallArgs, TV<:TapeCallArgs}
    argtyps = getvaluetype.(TA.parameters)
    vargtyps = getvaluetype.(TV.parameters)
    return Tuple{argtyps..., vargtyps...}
end

@generated function argtypes(::TA, ::Nothing) where {TA<:TapeCallArgs}
    argtyps = getvaluetype.(TA.parameters)
    return Tuple{argtyps...}
end




"""
    TapeReference{T} <: TapeValue{T}

Tape representation of an SSA variable reference of type `T`.  References a child node of a
`NestedCallNode`; like the indices of a Wengert list.  Behaves like `Ref` (i.e., you can get the
referenced node of `r` by `r[]`).
"""
struct TapeReference{T, TR<:DataFlowNode{T}} <: TapeValue{T}
    value::Snapshot{T}
    referenced::TR
    index::Int
end

TapeReference(value, referenced, index) =
    TapeReference{typeof(value), typeof(referenced)}(Snapshot(value), referenced, index)

Base.getindex(expr::TapeReference) = expr.referenced


"""
    TapeConstant{T} <: TapeValue{T}

Tape representation of a constant value of type `T`
"""
struct TapeConstant{T} <: TapeValue{T}
    value::Snapshot{T}
end

TapeConstant(value) = TapeConstant{typeof(value)}(Snapshot(value))



"""
    TapeCall{T, F, TArgs} <: TapeExpr{T}

Tape representation of a normal function call with result type `T`, function type `F`, and
argument tuple type `TArgs`.

The arguments of the function call are split into normal `arguments` and `varargs`, since varargs
calls need to be handled specially in the graph API.  A `varargs` value of `nothing` indicates that
the called method had not varargs, while `()` results from an empty vararg tuple.
"""
struct TapeCall{T, F, TArgs<:Tuple, TF<: TapeValue{F}, TA<:TapeCallArgs, TV<:Union{TapeCallArgs, Nothing}} <: TapeForm{T}
    value::Snapshot{T}
    f::TF
    arguments::TA
    varargs::TV
end

function TapeCall(value,
                  f::TapeValue{F},
                  arguments::TapeCallArgs,
                  varargs::Union{TapeCallArgs, Nothing}=nothing
) where {F}
    argtyps = argtypes(arguments, varargs)
    T = typeof(value)
    TF = typeof(f)
    TA = typeof(arguments)
    TV = typeof(varargs)
    return TapeCall{T, F, argtyps, TF, TA, TV}(Snapshot(value), f, arguments, varargs)
end


"""
    TapeSpecialForm{T} <: TapeExpr{T}

Tape representation of special expression (i.e., anything other than `Expr(:call, ...)`) with
result type `T`.
"""
struct TapeSpecialForm{T, TArgs<:Tuple, TA<:TapeCallArgs} <: TapeForm{T}
    value::Snapshot{T}
    head::Symbol
    arguments::TA
end

function TapeSpecialForm(value, head::Symbol, arguments::TapeCallArgs)
    argtyps = argtypes(arguments, nothing)
    T = typeof(value)
    TA = typeof(arguments)
    return TapeSpecialForm{T, argtyps, TA}(Snapshot(value), head, arguments)
end


"""
    references(expr::TapeExpr; numbered = false) -> Vector{TapeReference}

Get the list of tape references in a `TapeExpr`, i.e., the parents in the call graph.

If `numbered` is `true`, will return `Pair{Int, TapeReference}` for each reference with its
position within the expression.
"""
function references end


_contents(expr::TapeCall) = append!(append!(TapeValue[expr.f], expr.arguments),
                                    something(expr.varargs, TapeValue[]))
_contents(expr::TapeSpecialForm) = collect(expr.arguments)
_contents(expr::TapeConstant) = TapeValue[expr]
_contents(expr::TapeReference) = TapeValue[expr]

unnumbered_references(expr::TapeExpr) =
    TapeReference[e for e in _contents(expr) if e isa TapeReference]
numbered_references(expr::TapeExpr) =
    Pair{Int, TapeReference}[i => e for (i, e) in enumerate(_contents(expr)) if e isa TapeReference]
function references(expr::TapeExpr; numbered::Bool = false)
    if numbered
        return numbered_references(expr)
    else
        return unnumbered_references(expr)
    end
end


getvalue_ref(expr::TapeExpr) = getoriginal(expr.value)
getvalue(expr::TapeExpr) = getsnapshot(expr.value)


function getargument(expr::TapeCall, i)
    nargs = length(expr.arguments)
    if i ≤ nargs
        return expr.arguments[i]
    else
        return expr.varargs[i - nargs]
    end
end
getarguments(expr::TapeCall) = (expr.arguments..., something(expr.varargs, ())...)
get_args_varargs(expr::TapeCall) = expr.arguments, expr.varargs

getargument(expr::TapeSpecialForm, i) = expr.arguments[i]
getarguments(expr::TapeSpecialForm) = expr.arguments

getfunction(expr::TapeCall) = expr.f

getvaluetype(expr::TapeExpr) = getvaluetype(typeof(expr))
getvaluetype(::Type{<:TapeExpr{T}}) where {T} = T



