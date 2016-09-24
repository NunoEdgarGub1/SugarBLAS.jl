__precompile__(true)
module SugarBLAS

export  @blas!
export  @scale!, @axpy!, @copy!, @ger!, @syr!, @syrk, @syrk!,
        @her!, @herk, @herk!, @gbmv, @gbmv!, @sbmv, @sbmv!,
        @gemm, @gemm!, @gemv, @gemv!, @symm, @symm!, @symv, @symv!

include("Match/Match.jl")
using .Match

import Base: copy, -

copy(s::Symbol) = s

"""
Negate a Symbol or Expression
"""
function -(ast)
    if @match(ast, -ast) | (ast == 0)
        ast
    else
        Expr(:call, :(-), ast)
    end
end

substracts(expr) = false
substracts(expr::Expr) = (expr.head == :call) & (expr.args[1] == :-)

isempty(nl::Nullable) = nl.isnull

function kwargs_to_dict(kwargs::Tuple)
    dict = Dict()
    for kw in kwargs
        dict[kw.args[1]] = kw.args[2]
    end
    dict
end

wrap(expr::Symbol) = QuoteNode(expr)
function wrap(expr::Expr)
    head = QuoteNode(expr.head)
    func = string(expr.args[1])
    :(Expr($head, parse($func), $(expr.args[2:end]...)))
end

function expand(expr::Expr)
    @match(expr, A += B) && return :($A = $A + $B)
    @match(expr, A -= B) && return :($A = $A - $B)
    expr
end

macro call(expr::Expr)
    esc(:(esc($(wrap(expr)))))
end

macro case(expr::Expr)
    (expr.head == :block) || error("@case statement must be followed by `begin ... end`")
    lines = filter(expr::Expr -> expr.head != :line, expr.args)
    failproof(s) = s
    failproof(s::Char) = string("'",s,"'")
    line = lines[1]
    exec = "if $(line.args[1])\n$(failproof(line.args[2]))\n"
    for line in lines[2:end-1]
        (line.head == :line) && continue
        line.head == :(=>) || error("Each condition must be followed by `=>`")
        exec *= "elseif $(line.args[1])\n$(failproof(line.args[2]))\n"
    end
    line = lines[end]
    exec *= (line.args[1] == :otherwise) && ("else\n$(failproof(line.args[2]))\n")
    exec *= "end"
    esc(parse(exec))
end

#Must be ordered from most to least especific formulas
macro blas!(expr::Expr)
    expr = expand(expr)
    @case begin
        @match(expr, X *= a)        => @call scale!(a,X)
        @match(expr, X = a*X)       => @call scale!(a,X)
        @match(expr, Y = Y - a*X)   => @call Base.LinAlg.axpy!(-a,X,Y)
        @match(expr, Y = Y - X)     => @call Base.LinAlg.axpy!(-1.0,X,Y)
        @match(expr, Y = a*X + Y)   => @call Base.LinAlg.axpy!(a,X,Y)
        @match(expr, Y = X + Y)     => @call Base.LinAlg.axpy!(1.0,X,Y)
        @match(expr, X = Y)         => @call copy!(X, Y)
        otherwise                   => error("No match found")
    end
end

macro copy!(expr::Expr)
    @case begin
        @match(expr, X = Y) => @call copy!(X,Y)
        otherwise           => error("No match found")
    end
end

macro scale!(expr::Expr)
    @case begin
        @match(expr, X *= a)    => @call scale!(a,X)
        @match(expr, X = a*X)   => @call scale!(a,X)
        otherwise               => error("No match found")
    end
end

macro axpy!(expr::Expr)
    expr = expand(expr)
    @case begin
        @match(expr, Y = Y - a*X)   => @call(Base.LinAlg.axpy!(-a,X,Y))
        @match(expr, Y = Y - X)     => @call Base.LinAlg.axpy!(-1.0,X,Y)
        @match(expr, Y = a*X + Y)   => @call Base.LinAlg.axpy!(a,X,Y)
        @match(expr, Y = X + Y)     => @call Base.LinAlg.axpy!(1.0,X,Y)
        otherwise                   => error("No match found")
    end
end

macro ger!(expr::Expr)
    expr = expand(expr)
    f = @case begin
        @match(expr, A = alpha*x*y' + A)    => identity
        @match(expr, A = A - alpha*x*y')    => (-)
        otherwise                           => error("No match found")
    end
    @call Base.LinAlg.BLAS.ger!(f(alpha),x,y,A)
end

macro syr!(expr::Expr)
    expr = expand(expr)
    @match(expr, A[uplo] = right) || error("No match found")
    f = @case begin
        @match(right, alpha*x*x.' + Y)  => identity
        @match(right, Y - alpha*x*x.')  => (-)
        otherwise                       => error("No match found")
    end
    (@match(Y, Y[uplo]) && (Y == A)) || (Y == A) || error("No match found")
    @call Base.LinAlg.BLAS.syr!(uplo,f(alpha),x,A)
end

macro syrk(expr::Expr, kwargs...)
    kwargs = kwargs_to_dict(kwargs)
    uplo = kwargs[:uplo]
    f = @case begin
        @match(expr, alpha*X*Y) => identity
        otherwise               => error("No match found")
    end
    trans = @case begin
        @match(X, A.') && (Y == A)  => 'T'
        @match(Y, A.') && (X == A)  => 'N'
        otherwise                   => error("No match found")
    end
    @call Base.LinAlg.BLAS.syrk(uplo,trans,f(alpha),A)
end

macro syrk!(expr::Expr)
    expr = expand(expr)
    @match(expr, C[uplo] = right) || error("No match found")
    f = @case begin
        @match(right, alpha*X*Y + D)    => identity
        @match(right, D - alpha*X*Y)    => (-)
        otherwise                       => error("No match found")
    end
    trans = @case begin
        @match(X, A.') && (Y == A)  => 'T'
        @match(Y, A.') && (X == A)  => 'N'
        otherwise                   => error("No match found")
    end
    @match(D, beta*D) || (beta = 1.0)
    (@match(D, D[uplo]) && (C == D)) || (C == D) || error("No match found")
    @call Base.LinAlg.BLAS.syrk!(uplo,trans,f(alpha),A,beta,C)
end

macro her!(expr::Expr)
    expr = expand(expr)
    @match(expr, A[uplo] = right) || error("No match found")
    f = @case begin
        @match(right, alpha*x*x' + Y)   => identity
        @match(right, Y - alpha*x*x')   => (-)
        otherwise                       => error("No match found")
    end
    (@match(Y, Y[uplo]) && (Y == A)) || (Y == A) || error("No match found")
    @call Base.LinAlg.BLAS.her!(uplo,f(alpha),x,A)
end

macro herk(expr::Expr, kwargs...)
    kwargs = kwargs_to_dict(kwargs)
    uplo = kwargs[:uplo]
    @match(expr, alpha*X*Y) || error("No match found")
    trans = @case begin
        @match(X, A') && (Y == A)   =>  'T'
        @match(Y, A') && (X == A)   =>  'N'
        otherwise                   =>  error("No match found")
    end
    @call Base.LinAlg.BLAS.herk(uplo,trans,alpha,A)
end

macro herk!(expr::Expr)
    expr = expand(expr)
    @match(expr, C[uplo] = right) || error("No match found")
    f = @case begin
        @match(right, alpha*X*Y + D)    => identity
        @match(right, D - alpha*X*Y)    => (-)
        otherwise                       => error("No match found")
    end
    trans = @case begin
        @match(X, A') && (Y == A)   =>  'T'
        @match(Y, A') && (X == A)   =>  'N'
        otherwise                   =>  error("No match found")
    end
    @match(D, beta*D) || (beta = 1.0)
    (@match(D, D[crap]) && (C == D)) || (C == D) || error("No match found")
    @call Base.LinAlg.BLAS.herk!(uplo,trans,f(alpha),A,beta,C)
end

macro gbmv(expr::Expr)
    @match(expr, alpha*Y*x) || error("No match found")
    trans = @match(Y, Y') ? 'T' : 'N'
    @match(Y, A[kl:ku,h=m])
    @call Base.LinAlg.BLAS.gbmv(trans,m,-kl,ku,alpha,A,x)
end

macro gbmv!(expr::Expr)
    expr = expand(expr)
    @match(expr, y = right) || error("No match found")
    f = @case begin
        @match(right, alpha*Y*x + w)    => identity
        @match(right, w - alpha*Y*x)    => (-)
        otherwise                       => error("No match found")
    end
    trans = @match(Y, Y') ? 'T' : 'N'
    @match(Y, A[kl:ku,h=m])
    @match(w, beta*w) || (beta = 1.0)
    (y == w) || error("No match found")
    @call Base.LinAlg.BLAS.gbmv!(trans,m,-kl,ku,f(alpha),A,x,beta,y)
end

macro sbmv(expr::Expr)
    @case begin
        @match(expr, alpha*A[0:k,uplo]*x)   => @call Base.LinAlg.BLAS.sbmv(uplo,k,alpha,A,x)
        @match(expr, A[0:k,uplo]*x)         => @call Base.LinAlg.BLAS.sbmv(uplo,k,A,x)
        otherwise                           => error("No match found")
    end
end

macro sbmv!(expr::Expr)
    expr = expand(expr)
    @match(expr, y = right) || error("No match found")
    f = @case begin
        @match(right, alpha*A[0:k,uplo]*x + w)  => identity
        @match(right, w - alpha*A[0:k,uplo]*x)  => (-)
        otherwise                               => error("No match found")
    end
    @match(w, beta*w) || (beta = 1.0)
    (@match(w, w[crap]) && (y == w)) || (y == w) || error("No match found")
    @call Base.LinAlg.BLAS.sbmv!(uplo,k,f(alpha),A,x,beta,y)
end

macro gemm(expr::Expr)
    if @match(expr, alpha*A*B)
        tA = @match(A, A') ? 'T' : 'N'
        tB = @match(B, B') ? 'T' : 'N'
        @call Base.LinAlg.BLAS.gemm(tA,tB,alpha,A,B)
    elseif @match(expr, A*B)
        tA = @match(A, A') ? 'T' : 'N'
        tB = @match(B, B') ? 'T' : 'N'
        @call Base.LinAlg.BLAS.gemm(tA,tB,A,B)
    else
        error("No match found")
    end
end

macro gemm!(expr::Expr)
    expr = expand(expr)
    @match(expr, C = right) || error("No match found")
    f = @case begin
        @match(right, alpha*A*B + D)    => identity
        @match(right, D - alpha*A*B)    => (-)
        otherwise                       => error("No match found")
    end
    tA = @match(A, A') ? 'T' : 'N'
    tB = @match(B, B') ? 'T' : 'N'
    @match(D, beta*D) || (beta = 1.0)
    (C == D) || error("No match found")
    @call Base.LinAlg.BLAS.gemm!(tA,tB,f(alpha),A,B,beta,C)
end

macro gemv(expr::Expr)
    if @match(expr, alpha*A*x)
        tA = @match(A, A') ? 'T' : 'N'
        @call Base.LinAlg.BLAS.gemv(tA,alpha,A,x)
    elseif @match(expr, A*x)
        tA = @match(A, A') ? 'T' : 'N'
        @call Base.LinAlg.BLAS.gemv(tA,A,x)
    else
        error("No match found")
    end
end

macro gemv!(expr::Expr)
    expr = expand(expr)
    @match(expr, y = right) || error("No match found")
    f = @case begin
        @match(right, alpha*A*x + w)  => identity
        @match(right, w - alpha*A*x)  => (-)
        otherwise                         => error("No match found")
    end
    tA = @match(A, A') ? 'T' : 'N'
    @match(w, beta*w) || (beta = 1.0)
    (y == w) || error("No match found")
    @call Base.LinAlg.BLAS.gemv!(tA,f(alpha),A,x,beta,y)
end

macro symm(expr::Expr, kwargs...)
    kwargs = kwargs_to_dict(kwargs)
    uplo = kwargs[:uplo]
    if @match(expr, alpha*A*B)
        side = @case begin
            @match(A, A[symm]) && (symm.args[1] == :symm)   => 'L'
            @match(B, B[symm]) && (symm.args[1] == :symm)   => 'R'
            otherwise                                       => error("No match found")
        end
        @call Base.LinAlg.BLAS.symm(side,uplo,alpha,A,B)
    elseif @match(expr, A*B)
        side = @case begin
            @match(A, A[symm]) && (symm.args[1] == :symm)   => 'L'
            @match(B, B[symm]) && (symm.args[1] == :symm)   => 'R'
            otherwise                                       => error("No match found")
        end
        @call Base.LinAlg.BLAS.symm(side,uplo,A,B)
    else
        error("No match found")
    end
end

macro symm!(expr::Expr)
    expr = expand(expr)
    @match(expr, C[uplo] = right) || error("No match found")
    f = @case begin
        @match(right, alpha*A*B + D)    => identity
        @match(right, D - alpha*A*B)    => (-)
        otherwise                       => error("No match found")
    end
    side = @case begin
        @match(A, A[symm]) && (symm.args[1] == :symm)   => 'L'
        @match(B, B[symm]) && (symm.args[1] == :symm)   => 'R'
        otherwise                                       => error("No match found")
    end
    @match(D, beta*D) || (beta = 1.0)
    (@match(D, D[crap]) && (C == D)) || (C == D) || error("No match found")
    @call Base.LinAlg.BLAS.symm!(side,uplo,f(alpha),A,B,beta,C)
end

macro symv(expr::Expr, kwargs...)
    kwargs = kwargs_to_dict(kwargs)
    uplo = kwargs[:uplo]
    @case begin
        @match(expr, alpha*A[uplo]*x)   => @call Base.LinAlg.BLAS.symv(uplo,alpha,A,x)
        @match(expr, A[uplo]*x)         => @call Base.LinAlg.BLAS.symv(uplo,A,x)
        otherwise                       => error("No match found")
    end
end

macro symv!(expr::Expr)
    expr = expand(expr)
    @match(expr, y = right) || error("No match found")
    f = @case begin
        @match(right, alpha*A[uplo]*x + w)  => identity
        @match(right, w - alpha*A[uplo]*x)  => (-)
        otherwise                         => error("No match found")
    end
    @match(w, beta*w) || (beta = 1.0)
    (@match(w, w[crap]) && (y == w)) || (y == w) || error("No match found")
    @call Base.LinAlg.BLAS.symv!(uplo,f(alpha),A,x,beta,y)
end

end
