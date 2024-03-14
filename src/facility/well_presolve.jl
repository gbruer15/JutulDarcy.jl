function Jutul.prepare_step_storage(p::PrepareStepWellSolver, storage, model::MultiModel)
    @assert !isnothing(model.groups)
    submodels = Jutul.submodel_symbols(model)
    if false
        for (k, m) in pairs(model.models)
            if model_or_domain_is_well(m)
                ctrl_name = Symbol("$(k)_ctrl")
                ix = findfirst(isequal(ctrl_name), submodels)
                if isnothing(ix)
                    ix = findfirst(isequal(:Facility), submodels)
                end
                @assert !isnothing(ix) "No wells for well solver?"
                facility_label = submodels[ix]
                facility = model.models[facility_label]
                pos = findfirst(isequal(k), facility.domain.well_symbols)
            end
        end
    end

    targets = setdiff(submodels, (:Reservoir, ))
    groups = Int[]
    for (g, m) in zip(model.groups, submodels)
        if m in targets
            push!(groups, g)
        end
    end
    unique!(groups)
    well_solver_storage = JutulStorage()
    primary = JutulStorage()
    for target in targets
        primary[target] = deepcopy(storage[target].primary_variables)
    end
    well_solver_storage[:targets] = targets
    well_solver_storage[:well_primary_variables] = primary
    well_solver_storage[:groups_and_linear_solvers] = [(g, LUSolver()) for g in groups]
    return well_solver_storage
end

function Jutul.simulator_config!(cfg, sim, ::PrepareStepWellSolver, storage)
    add_option!(cfg, :well_iterations, 25, "Well iterations to be performed before step.", types = Int, values = 0:10000)
    add_option!(cfg, :well_acceptance_factor, 10.0, "Accept well pre-solve results at this relaxed factor.", types = Float64)
    add_option!(cfg, :well_info_level, -1, "Info level for well solver.", types = Int)
end

function Jutul.prepare_step!(wsol_storage, wsol::PrepareStepWellSolver, storage, model::MultiModel, dt, forces, config;
        executor = DefaultExecutor(),
        iteration = 0,
        relaxation = 1.0
    )
    converged = false
    num_its = -1
    max_well_iterations = config[:well_iterations]
    targets = wsol_storage.targets
    il = config[:well_info_level]

    primary = wsol_storage.well_primary_variables
    for target in targets
        for (k, v) in pairs(storage[target].primary_variables)
            primary[target][k] .= v
        end
    end
    for well_it in 1:max_well_iterations
        Jutul.update_state_dependents!(storage, model, dt, forces,
            update_secondary = well_it > 1, targets = targets)
        Jutul.update_linearized_system!(storage, model, executor, targets = targets)
        if well_it == max_well_iterations
            tol_factor = config[:well_acceptance_factor]
        else
            tol_factor = 1.0
        end
        ok = map(
            k -> check_convergence(storage[k], model[k], config[:tolerances][k],
                iteration = iteration,
                dt = dt,
                tol_factor = tol_factor
            ),
            targets
        )
        converged = all(ok)
        if il > 0
            Jutul.get_convergence_table(errors, il, well_it, config)
        end
        for (g, lsolve) in wsol_storage.groups_and_linear_solvers
            lsys = storage.LinearizedSystem[g, g]
            recorder = storage.recorder
            linear_solve!(lsys, lsolve, model, storage, dt, recorder, executor)
        end
        update = Jutul.update_primary_variables!(storage, model; targets = targets)
        if converged
            num_its = well_it
            break
        end
    end
    if il > 0
        println("Converged in $num_its")
    else
        # TODO: Should only cover non-converged wells.
        for target in targets
            for (k, v) in pairs(storage[target].primary_variables)
                v .= primary[target][k]
            end
        end
        Jutul.update_state_dependents!(storage, model, dt, forces,
            update_secondary = true, targets = targets)
        println("Did not converge in $max_well_iterations")
    end
    return (nothing, forces)
end
