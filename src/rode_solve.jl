struct NNRODE{C,W,O,P,K} <: NeuralNetDiffEqAlgorithm
    chain::C
    W::W
    opt::O
    initθ::P
    autodiff::Bool
    kwargs::K
end
function NNRODE(chain,W,opt=Optim.BFGS(),init_params = nothing;autodiff=false,kwargs...)
    if init_params === nothing
        if chain isa FastChain
            initθ = DiffEqFlux.initial_params(chain)
        else
            initθ,re  = Flux.destructure(chain)
        end
    else
        initθ = init_params
    end
    NNRODE(chain,W,opt,initθ,autodiff,kwargs)
end

function DiffEqBase.solve(
    prob::DiffEqBase.AbstractRODEProblem,
    alg::NeuralNetDiffEqAlgorithm,
    args...;
    dt,
    timeseries_errors = true,
    save_everystep=true,
    adaptive=false,
    abstol = 1f-6,
    verbose = false,
    maxiters = 100)

    DiffEqBase.isinplace(prob) && error("Only out-of-place methods are allowed!")

    u0 = prob.u0
    tspan = prob.tspan
    f = prob.f
    p = prob.p
    t0 = tspan[1]

    #hidden layer
    chain  = alg.chain
    opt    = alg.opt
    autodiff = alg.autodiff
    W = alg.W
    #train points generation
    ts = tspan[1]:dt:tspan[2]
    initθ = alg.initθ

    if chain isa FastChain
        #The phi trial solution
        if u0 isa Number
            phi = (t,W,θ) -> u0 + (t-tspan[1])*first(chain(adapt(typeof(θ),[t,W]),θ))
        else
            phi = (t,W,θ) -> u0 + (t-tspan[1])*chain(adapt(typeof(θ),[t,W]),θ)
        end
    else
        _,re  = Flux.destructure(chain)
        #The phi trial solution
        if u0 isa Number
            phi = (t,W,θ) -> u0 + (t-t0)*first(re(θ)(adapt(typeof(θ),[t,W])))
        else
            phi = (t,W,θ) -> u0 + (t-t0)*re(θ)(adapt(typeof(θ),[t,W]))
        end
    end

    if autodiff
        # dfdx = (t,W,θ) -> ForwardDiff.derivative(t->phi(t,θ),t)
    else
        dfdx = (t,W,θ) -> (phi(t+sqrt(eps(t)),W,θ) - phi(t,W,θ))/sqrt(eps(t))
    end

    function inner_loss(t,W,θ)
        sum(abs,dfdx(t,W,θ) - f(phi(t,W,θ),p,t,W))
    end
    loss(θ) = sum(abs2,inner_loss(ts[i],W.W[i],θ) for i in 1:length(ts)) # sum(abs2,phi(tspan[1],θ) - u0)

    cb = function (p,l)
        verbose && println("Current loss is: $l")
        l < abstol
    end
    res = DiffEqFlux.sciml_train(loss, initθ, opt; cb = cb, maxiters=maxiters, alg.kwargs...)

    #solutions at timepoints

    if u0 isa Number
        u = [(phi(ts[i],W.W[i],res.minimizer)) for i in 1:length(ts)]
    else
        u = [(phi(ts[i],W.W[i],res.minimizer)) for i in 1:length(ts)]
    end

    sol = DiffEqBase.build_solution(prob,alg,ts,u,W,calculate_error = false)
    DiffEqBase.has_analytic(prob.f) && DiffEqBase.calculate_solution_errors!(sol;timeseries_errors=true,dense_errors=false)
    sol
end #solve
