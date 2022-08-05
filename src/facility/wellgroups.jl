function Jutul.count_entities(wg::WellGroup, ::Wells)
    return length(wg.well_symbols)
end

function get_well_position(d, symbol)
    match = findall(d.well_symbols .== symbol)
    if length(match) == 0
        return nothing
    else
        return only(match)
    end
end

function Jutul.associated_entity(::TotalSurfaceMassRate) Wells() end

function Jutul.update_primary_variable!(state, massrate::TotalSurfaceMassRate, state_symbol, model, dx)
    v = state[state_symbol]
    symbols = model.domain.well_symbols
    cfg = state.WellGroupConfiguration
    # Injectors can only have strictly positive injection rates,
    # producers can only have strictly negative and disabled controls give zero rate.
    function do_update(v, dx, ctrl)
        return Jutul.update_value(v, dx)
    end
    function do_update(v, dx, ctrl::InjectorControl)
        return Jutul.update_value(v, dx, nothing, nothing, MIN_ACTIVE_WELL_RATE, nothing)
    end
    function do_update(v, dx, ctrl::ProducerControl)
        return Jutul.update_value(v, dx, nothing, nothing, nothing, -MIN_ACTIVE_WELL_RATE)
    end
    function do_update(v, dx, ctrl::DisabledControl)
        # Set value to zero since we know it is correct.
        return Jutul.update_value(v, -value(v))
    end
    @inbounds for i in eachindex(v)
        s = symbols[i]
        v[i] = do_update(v[i], dx[i], operating_control(cfg, s))
    end
end


rate_weighted(t) = true
rate_weighted(::BottomHolePressureTarget) = false
rate_weighted(::DisabledTarget) = false

target_scaling(::Any) = 1.0
target_scaling(::BottomHolePressureTarget) = 1e5

Jutul.associated_entity(::ControlEquationWell) = Wells()
Jutul.local_discretization(::ControlEquationWell, i) = nothing
function Jutul.update_equation_in_entity!(v, i, state, state0, eq::ControlEquationWell, model, dt, ldisc = local_discretization(eq, i))
    # Set to zero, do actual control via cross terms
    v[] = 0*state.TotalSurfaceMassRate[i]
end

# Selection of primary variables
function select_primary_variables_domain!(S, domain::WellGroup, system, formulation)
    S[:TotalSurfaceMassRate] = TotalSurfaceMassRate()
end

function select_equations_domain!(eqs, domain::WellGroup, system, arg...)
    # eqs[:potential_balance] = (PotentialDropBalanceWell, 1)
    eqs[:control_equation] = ControlEquationWell()
end

function setup_forces(model::SimulationModel{D}; control = nothing, limits = nothing, set_default_limits = true) where {D <: WellGroup}
    # error() # Fix me. Set up defaults for all wells, including rate limits if not provided.
    T = Dict{Symbol, Any}
    if isnothing(control)
        control = T()
    end
    wells = model.domain.well_symbols
    for w in wells
        if !haskey(control, w)
            control[w] = DisabledControl()
        end
    end
    # Initialize limits
    if isnothing(limits)
        limits = T()
    end
    for w in wells
        if set_default_limits
            # Set default limits with reasonable values (e.g. minimum rate limit on bhp producers)
            defaults = default_limits(control[w])
            if haskey(limits, w)
                if !isnothing(defaults)
                    if isnothing(limits[w])
                        limits[w] = defaults
                    else
                        limits[w] = merge(defaults, limits[w])
                    end
                end
            else
                limits[w] = defaults
            end
        else
            # Ensure that all limits exist, but set to nothing if not already present
            if !haskey(limits, w)
                limits[w] = nothing
            end
        end
    end
    return (control = control::AbstractDict, limits = limits::AbstractDict,)
end

function convergence_criterion(model, storage, eq::ControlEquationWell, eq_s, r; dt = 1)
    wells = model.domain.well_symbols
    cfg = storage.state.WellGroupConfiguration
    e = abs.(vec(r))
    names = map(w -> name_equation(w, cfg), wells)
    R = Dict("Abs" => (errors = e, names = names))
    return R
end

function name_equation(name, cfg::WellGroupConfiguration)
    ctrl = cfg.operating_controls[name]
    if ctrl isa InjectorControl
        cs = "I"
    elseif ctrl isa ProducerControl
        cs = "P"
    else
        cs = "X"
    end
    t = translate_target_to_symbol(ctrl.target)
    return "$name ($cs) $t"
end
