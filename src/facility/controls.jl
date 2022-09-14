function Jutul.initialize_extra_state_fields!(state, domain::WellGroup, model)
    # Insert structure that holds well control (limits etc) that is then updated before each step
    state[:WellGroupConfiguration] = WellGroupConfiguration(domain.well_symbols)
end

function Jutul.update_before_step_domain!(storage, model::SimulationModel, domain::WellGroup, dt, forces)
    # Set control to whatever is on the forces
    cfg = storage.state.WellGroupConfiguration
    q_t = storage.state.TotalSurfaceMassRate
    op_ctrls = cfg.operating_controls
    req_ctrls = cfg.requested_controls
    for key in keys(forces.control)
        # If the requested control in forces differ from the one we are presently using, we need to switch.
        # Otherwise, stay the course.
        newctrl = forces.control[key]
        oldctrl = req_ctrls[key]
        if newctrl != oldctrl
            # We have a new control. Any previous control change is invalid.
            # Set both operating and requested control to the new one.
            @debug "Well $key switching from $oldctrl to $newctrl"
            req_ctrls[key] = newctrl
            op_ctrls[key] = newctrl
        end
        pos = get_well_position(model.domain, key)
        q_t[pos] = valid_surface_rate_for_control(q_t[pos], newctrl)
    end
    for key in keys(forces.limits)
        cfg.limits[key] = forces.limits[key]
    end
end

function valid_surface_rate_for_control(q_t, ::InjectorControl)
    if q_t < MIN_INITIAL_WELL_RATE
        q_t = Jutul.replace_value(q_t, MIN_INITIAL_WELL_RATE)
    end
    return q_t
end

function valid_surface_rate_for_control(q_t, ::ProducerControl)
    if q_t > -MIN_INITIAL_WELL_RATE
        q_t = Jutul.replace_value(q_t, -MIN_INITIAL_WELL_RATE)
    end
    return q_t
end

function valid_surface_rate_for_control(q_t, ::DisabledControl)
    return Jutul.replace_value(q_t, 0.0)
end

function apply_well_limit!(cfg::WellGroupConfiguration, target, wmodel, wstate, well::Symbol, density_s, volume_fraction_s, total_mass_rate, current_lims = current_limits(cfg, well))
    if !isnothing(current_lims)
        ctrl = operating_control(cfg, well)
        @timeit "limits" target, changed, current_val, limit_val, lim_type = check_active_limits(ctrl, target, current_lims, wmodel, wstate, well, density_s, volume_fraction_s, total_mass_rate)
        if changed
            old = cfg.operating_controls[well].target
            next = replace_target(ctrl, target)
            cfg.operating_controls[well] = next
            @debug "$well: Switching control from $old to $target due to $(typeof(target)) limit:\nComputed value $current_val exceeds $lim_type limit $limit_val.\nNew control: $next"
        end
    end
    return target
end

function check_active_limits(control, target, limits, wmodel, wstate, well::Symbol, density_s, volume_fraction_s, total_mass_rate)
    changed = false
    cval = tval = NaN
    is_lower = false
    for (name, val) in pairs(limits)
        if isfinite(val)
            (target_limit, is_lower) = translate_limit(control, name, val)
            ok, cval, tval = check_limit(control, target_limit, target, is_lower, total_mass_rate, wmodel, wstate, density_s, volume_fraction_s)
            if !ok
                changed = true
                target = target_limit
                break
            end
        end
    end
    if is_lower
        lim_type = :lower
    else
        lim_type = :upper
    end
    return (target, changed, cval, tval, lim_type)
end

function translate_limit(control::ProducerControl, name, val)
    # Note: Negative sign convention for production.
    # A lower absolute bound on a rate
    # |q| > |lim| -> q < lim if both sides are negative
    # means that we specify is_lower for upper limits and the other
    # way around for lower limits, when dealing with rates.
    is_lower = true
    if name == :bhp
        # Upper limit, pressure
        target_limit = BottomHolePressureTarget(val)
        # Pressures are positive, this is a true lower bound
        is_lower = true
    elseif name == :orat
        # Upper limit, surface oil rate
        target_limit = SurfaceOilRateTarget(val)
    elseif name == :lrat
        # Upper limit, surface liquid (water + oil) rate
        target_limit = SurfaceLiquidRateTarget(val)
    elseif name == :grat
        # Upper limit, surface gas rate
        target_limit = SurfaceGasRateTarget(val)
    elseif name == :wrat
        # Upper limit, surface water rate
        target_limit = SurfaceWaterRateTarget(val)
    elseif name == :rate || name == :rate_upper
        # Upper limit, total volumetric surface rate
        target_limit = TotalRateTarget(val)
    elseif name == :rate_lower
        # Lower limit, total volumetric surface rate. This is useful
        # disabling producers if they would otherwise start to inject.
        target_limit = TotalRateTarget(val)
        is_lower = false
    else
        error("$name limit not supported for well acting as producer.")
    end
    return (target_limit, is_lower)
end

function translate_limit(control::InjectorControl, name, val)
    is_lower = false
    if name == :bhp
        # Upper limit, pressure
        target_limit = BottomHolePressureTarget(val)
    elseif name == :rate || name == :rate_upper
        # Upper limit, total volumetric surface rate
        target_limit = TotalRateTarget(val)
    elseif name == :rate_lower
        # Lower limit, total volumetric surface rate
        target_limit = TotalRateTarget(val)
        is_lower = true
    else
        error("$name limit not supported for well acting as producer.")
    end
    return (target_limit, is_lower)
end

function check_limit(current_control, target_limit, target, is_lower::Bool, q_t, source_model, well_state, rhoS, S)
    if typeof(target_limit) == typeof(target)
        # We are already operating at this target and there is no need to check.
        ok = true
        current_val = limit_val = NaN
    else
        current_val = value(well_target_value(q_t, current_control, target_limit, source_model, well_state, rhoS, S))
        limit_val = target_limit.value
        ϵ = 1e-6
        if is_lower
            # Limit is lower bound, check that we are above...
            ok = current_val >= (1 + ϵ)*limit_val
        else
            ok = current_val <= (1 - ϵ)*limit_val
        end
    end
    return (ok, current_val, limit_val)
end


function facility_surface_mass_rate_for_well(model::SimulationModel, wsym, fstate)
    pos = get_well_position(model.domain, wsym)
    return fstate.TotalSurfaceMassRate[pos]
end

bottom_hole_pressure(ws) = ws.Pressure[1]

"""
Well target contribution from well itself (disabled, zero value)
"""
function well_target(control, target::DisabledTarget, well_model, well_state, rhoS, S)
    return 0.0
end

"""
Well target contribution from well itself (bhp)
"""
function well_target(control, target::BottomHolePressureTarget, well_model, well_state, rhoS, S)
    return bottom_hole_pressure(well_state)
end

"""
Well target contribution from well itself (surface volume, injector)
"""
function well_target(control::InjectorControl, target::SurfaceVolumeTarget, well_model, well_state, surface_densities, surface_volume_fractions)
    t_phases = lumped_phases(target)
    w_phases = get_phases(well_model.system)
    t = 0.0
    for (ix, mix) in control.phases
        if w_phases[ix] in t_phases
            t += mix
        end
    end
    return t/control.mixture_density
end

"""
Well target contribution from well itself (surface volume, injector)
"""
function well_target(control::InjectorControl, target::TotalRateTarget, well_model, well_state, surface_densities, surface_volume_fractions)
    return 1.0/control.mixture_density
end

"""
Well target contribution from well itself (surface volume, producer)
"""
function well_target(control::ProducerControl, target::SurfaceVolumeTarget, well_model, well_state, surface_densities, surface_volume_fractions)
    phases = get_phases(well_model.system)
    Tw = eltype(surface_volume_fractions)
    # Compute total density at surface conditions by weighting phase volumes at surf
    ρ_tot = zero(Tw)
    for (ρ, V) in zip(surface_densities, surface_volume_fractions)
        ρ_tot += ρ*V
    end
    # Divide by total density to get total volume at surface, then multiply that by surface volume fraction
    w = zero(Tw)
    if isa(target, TotalRateTarget)
        for i in eachindex(phases)
            @inbounds V = surface_volume_fractions[i]
            w += V
        end
    else
        lp = lumped_phases(target)
        for (i, ph) in enumerate(phases)
            if ph in lp
                @inbounds V = surface_volume_fractions[i]
                w += V
            end
        end
    end
    w = w/ρ_tot
    return w
end

function well_target_value(q_t, control, target, source_model, well_state, rhoS, S)
    v = well_target(control, target, source_model, well_state, rhoS, S)
    if rate_weighted(target)
        v *= value(q_t)
    end
    return v
end
