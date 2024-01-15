

"""
    ThermalSystem(num_phases = 1, formulation = :Temperature)

Geothermal system that defines heat transfer through fluid advection and through
the rock itself. Can be combined with a multiphase system using [`Jutul.CompositeSystem`](@ref).
"""
struct ThermalSystem{T} <: JutulSystem
    nph::Int64
    function ThermalSystem(; nphases = 1, formulation = :Temperature)
        @assert formulation == :Temperature
        new{formulation}(nphases)
    end
end

thermal_system(sys::ThermalSystem) = sys
thermal_system(sys::CompositeSystem) = sys.systems.thermal

const ThermalModel = SimulationModel{<:JutulDomain, <:ThermalSystem, <:Any, <:Any}

struct BulkVolume <: ScalarVariable end
function Jutul.default_values(model, ::BulkVolume)
    return 1.0
end

function Jutul.default_parameter_values(data_domain, model, param::BulkVolume, symb)
    if haskey(data_domain, :volumes)
        bv = copy(data_domain[:volumes])
    elseif model_or_domain_is_well(model)
        r = physical_representation(model.domain)
        if r isa MultiSegmentWell
            bv = copy(model.domain.representation.volumes)
        else
            r::SimpleWell
            bv = [r.volume]
        end
    end
    return bv
end

struct RockHeatCapacity <: ScalarVariable end
Jutul.default_value(model, ::RockHeatCapacity) = 1000.0
struct RockDensity <: ScalarVariable end
Jutul.default_value(model, ::RockDensity) = 2000.0

struct RockInternalEnergy <: ScalarVariable end
struct TotalThermalEnergy <: ScalarVariable end

struct FluidHeatCapacity <: PhaseVariables end
Jutul.default_value(model, ::FluidHeatCapacity) = 5000.0
struct FluidInternalEnergy <: PhaseVariables end
struct FluidEnthalpy <: PhaseVariables end

struct FluidThermalConductivities <: VectorVariables end
Jutul.variable_scale(::FluidThermalConductivities) = 1e-10
Jutul.minimum_value(::FluidThermalConductivities) = 0.0
Jutul.values_per_entity(model, ::FluidThermalConductivities) = number_of_phases(model.system)

function Jutul.default_parameter_values(data_domain, model, param::FluidThermalConductivities, symb)
    if haskey(data_domain, :fluid_thermal_conductivities, Faces())
        # This takes precedence
        T = copy(data_domain[:fluid_thermal_conductivities])
    elseif haskey(data_domain, :fluid_thermal_conductivity, Cells())
        nph = number_of_phases(model.system)
        C = data_domain[:fluid_thermal_conductivity]
        if C isa Vector
            T = compute_face_trans(data_domain, C)
            T = repeat(T', nph, 1)
        else
            @assert size(C, 1) == nph
            nf = number_of_faces(data_domain)
            T = zeros(nph, nf)
            for ph in 1:nph
                T[i, :] = compute_face_trans(data_domain, C[ph, :])
            end
        end
    else
        error(":fluid_thermal_conductivities or :fluid_thermal_conductivities symbol must be present in DataDomain to initialize parameter $symb, had keys: $(keys(data_domain))")
    end
    return T
end

Jutul.associated_entity(::FluidThermalConductivities) = Faces()

struct RockThermalConductivities <: ScalarVariable end
Jutul.variable_scale(::RockThermalConductivities) = 1e-10
Jutul.minimum_value(::RockThermalConductivities) = 0.0
Jutul.associated_entity(::RockThermalConductivities) = Faces()

function Jutul.default_parameter_values(data_domain, model, param::RockThermalConductivities, symb)
    if haskey(data_domain, :rock_thermal_conductivities, Faces())
        # This takes precedence
        T = copy(data_domain[:rock_thermal_conductivities])
    elseif haskey(data_domain, :rock_thermal_conductivity, Cells())
        nph = number_of_phases(model.system)
        C = data_domain[:rock_thermal_conductivity]
        T = compute_face_trans(data_domain, C)
    else
        error(":fluid_thermal_conductivities or :fluid_thermal_conductivities symbol must be present in DataDomain to initialize parameter $symb, had keys: $(keys(data_domain))")
    end
    return T
end

number_of_phases(t::ThermalSystem) = t.nph

function select_primary_variables!(S, system::ThermalSystem, model)
    S[:Temperature] = Temperature()
end

function select_parameters!(S, system::ThermalSystem, model)
    nph = number_of_phases(system)
    # Rock itself
    S[:RockHeatCapacity] = RockHeatCapacity()
    S[:RockDensity] = RockDensity()
    S[:BulkVolume] = BulkVolume()
    # Fluid heat related parameters
    S[:FluidHeatCapacity] = FluidHeatCapacity()
    S[:FluidVolume] = FluidVolume()
    # Fluid flow related parameters
    S[:PhaseMassDensities] = ConstantCompressibilityDensities(nph)
    S[:Pressure] = Pressure()
    S[:Saturations] = Saturations()
    S[:RelativePermeabilities] = RelativePermeabilitiesParameter()
    S[:PhaseViscosities] = PhaseViscosities()
    S[:PhaseMassMobilities] = PhaseMassMobilities()
end

function select_parameters!(prm, disc::D, model::ThermalModel) where D<:Union{TwoPointPotentialFlowHardCoded, Jutul.PotentialFlow}
    prm[:FluidThermalConductivities] = FluidThermalConductivities()
    prm[:RockThermalConductivities] = RockThermalConductivities()
    if !model_or_domain_is_well(model)
        prm[:Transmissibilities] = Transmissibilities()
        prm[:TwoPointGravityDifference] = TwoPointGravityDifference()
    end
end

function select_secondary_variables!(S, system::ThermalSystem, model)
    S[:FluidInternalEnergy] = FluidInternalEnergy()
    S[:FluidEnthalpy] = FluidEnthalpy()
    S[:RockInternalEnergy] = RockInternalEnergy()
    S[:TotalThermalEnergy] = TotalThermalEnergy()
end

function select_minimum_output_variables!(out, system::ThermalSystem, model)
    push!(out, :TotalThermalEnergy)
end

include("variables.jl")
include("equations.jl")