# # Hybrid simulation with neural network for relative permeability

# This example demonstrates how to integrate a neural network into JutulDarcy.jl for relative permeability modeling in reservoir simulations.
# It includes the following steps:
# 1. Set up a simple reference simulation with a Brooks-Corey relative permeability model
# 2. Train a neural network to approximate the Brooks-Corey relative permeability model
# 3. Incorporate the trained network into a simulation model
# 4. Compare the results of the neural network-based simulation with the reference simulation
#
# This approach showcases the flexibility of JutulDarcy.jl in incorporating machine learning models
# into conventional reservoir simulation workflows, potentially enabling more accurate and
# efficient simulations of complex fluid behavior.

# ## Preliminaries

# First, let's import the necessary packages.
# We will use Flux for the neural network model.

using JutulDarcy, Jutul, Flux, ProgressMeter, Plots

# ## Set up the simulation case
# We set up a reference simulation case following the [Your first JutulDarcy.jl simulation](https://sintefmath.github.io/JutulDarcy.jl/dev/man/first_ex) example:
# - Create a simple Cartesian Mesh
# - Convert it to a reservoir domain with permeability and porosity
# - Set up two wells: a vertical injector and a single-perforation producer

# #### Fluid system and model setup
# - Use a two-phase immiscible system (liquid and vapor)
# - Set reference densities: 1000 kg/m³ for liquid, 100 kg/m³ for vapor

# #### Timesteps and well controls
# - Set reporting timesteps: every year for 25 years
# - Producer: fixed bottom-hole pressure
# - Injector: high gas injection rate (for dramatic visualization)

# These steps create a basic simulation setup that we'll use to compare against
# the neural network-based relative permeability model.

Darcy, bar, kg, meter, day = si_units(:darcy, :bar, :kilogram, :meter, :day)

function setup_simulation_case()
    nx = ny = 25
    nz = 10
    cart_dims = (nx, ny, nz)
    physical_dims = (1000.0, 1000.0, 100.0).*meter
    g = CartesianMesh(cart_dims, physical_dims)
    domain = reservoir_domain(g, permeability = 0.3Darcy, porosity = 0.2)
    Injector = setup_vertical_well(domain, 1, 1, name = :Injector)
    Producer = setup_well(domain, (nx, ny, 1), name = :Producer)

    phases = (LiquidPhase(), VaporPhase())
    rhoLS = 1000.0kg/meter^3
    rhoGS = 100.0kg/meter^3
    reference_densities = [rhoLS, rhoGS]
    sys = ImmiscibleSystem(phases, reference_densities = reference_densities)

    nstep = 25
    dt = fill(365.0day, nstep)

    pv = pore_volume(domain)
    inj_rate = 1.5*sum(pv)/sum(dt)
    rate_target = TotalRateTarget(inj_rate)
    bhp_target = BottomHolePressureTarget(100bar)

    I_ctrl = InjectorControl(rate_target, [0.0, 1.0], density = rhoGS)
    P_ctrl = ProducerControl(bhp_target)
    controls = Dict(:Injector => I_ctrl, :Producer => P_ctrl)

    model, parameters = setup_reservoir_model(domain, sys, wells = [Injector, Producer])
    forces = setup_reservoir_forces(model, control = controls);

    return model, parameters, forces, sys, dt
end

ref_model, ref_parameters, ref_forces, ref_sys, ref_dt = setup_simulation_case();

# The simulation model has a set of default secondary variables (properties) that are used to compute the flow equations. We can have a look at the reservoir model to see what the defaults are for the Darcy flow part of the domain:

reservoir_model(ref_model)

# The secondary variables can be swapped out, replaced and new variables can be added with arbitrary functional dependencies thanks to Jutul's flexible setup for automatic differentiation. Let us adjust the defaults by replacing the relative permeabilities with Brooks-Corey functions:

# ### Brooks-Corey
# The Brooks-Corey model is a simple model that can be used to generate relative
# permeabilities. The model is defined in the mobile region as:
#
# ``k_{rw} = k_{max,w} \bar{S}_w``
#
# ``k_{rg} = k_{max,g} \bar{S}_g``
#
# where $k_{max,w}$ is the maximum relative permeability, $\bar{S}_w$
# is the normalized saturation for the water phase,
#
# `` \bar{S}_w = \frac{S_w - S_{wi}}{1 - S_{wi} - S_{rg}}``
#
# and, similarly, for the vapor phase:
#
# ``\bar{S}_g = \frac{S_g - S_{rg}}{1 - S_{wi} - S_{rg}}``
#
# We use the Brooks Corey function available in JutulDarcy to evaluate the values for a given saturation range.
# For simplicity, we use the same exponent and residual saturation for both the liquid and vapour phase, such that we only need to train a single model
exponent = 2.0
sr_g = sr_w = 0.2
r_tot = sr_g + sr_w;

kr = BrooksCoreyRelativePermeabilities(ref_sys, [exponent, exponent], [sr_w, sr_g])
replace_variables!(ref_model, RelativePermeabilities = kr);


# ### Run the reference simulation

# We then set up the initial state with constant pressure and liquid-filled reservoir.
# The inputs (pressure and saturations) must match the model's primary variables.
# We can now run the simulation.

ref_state0 = setup_reservoir_state(ref_model,
    Pressure = 120bar,
    Saturations = [1.0, 0.0]
)

ref_wd, ref_states, ref_t = simulate_reservoir(ref_state0, ref_model, ref_dt, parameters = ref_parameters, forces = ref_forces);


# ## Training a neural network to compute relative permeability
# The next step is to train a neural network to learn the Brooks-Corey relative permeability curve.
# While using a neural network to learn a simple analytical function is not typically practical, it serves as a
# good example for integrating machine learning with reservoir simulation.


# First we must generate some data for training a model to represent the Brooks Corey function.
train_samples = 1000
test_samples = 1000

training_sat = collect(range(Float64(0), stop=Float64(1), length=train_samples))
training_sat = reshape(training_sat, 1, :)

rel_perm_analytical = JutulDarcy.brooks_corey_relperm.(training_sat, n = exponent, residual = sr_g, residual_total = r_tot)
plot(vec(training_sat), vec(rel_perm_analytical), label="Brooks-Corey RelPerm", xlabel="Saturation", ylabel="Relative Permeability", title="Saturation vs. Relative Permeability")

# ### Define the neural network architecture
# Next we define the neural network architecture. The model takes in a saturation value and outputs a relative permeability value.
# For a batched input, such as the number of cells in the model, the input and output
# shapes are (1xN_cells).


# We define our neural network architecture for relative permeability prediction
# using a multi-layer perceptron (MLP) with the following characteristics:
# - Input layer: 1 neuron (saturation value)
# - Three hidden layers: 16 neurons each, with tanh activation
# - Output layer: 1 neuron with sigmoid activation (relative permeability)
#
# Key design choices:
# - Use of tanh activation in hidden layers for smooth first derivatives
# - Sigmoid in the final layer to constrain output to [0, 1] range
# - Float64 precision to match JutulDarcy's numerical precision
# - Glorot normal initialization for weights
# - Use GPU for faster training (if available)

MLP = f64(Chain(
    Dense(1 => 16, tanh; init=Flux.glorot_normal),
    Dense(16 => 16, tanh; init=Flux.glorot_normal),
    Dense(16 => 16, tanh; init=Flux.glorot_normal),
    Dense(16 => 1, sigmoid; init=Flux.glorot_normal)))

BrooksCoreyMLModel = f64(MLP)

# Define training parameters
# We train the model using the Adam optimizer with a learning rate of 0.0005. For a total of 10 epochs.
# The `optim` object will store the optimiser momentum, etc.

epochs = 20000
batchsize = 1000
lr = 0.0005
loader = Flux.DataLoader((training_sat, rel_perm_analytical), batchsize=batchsize, shuffle=true);
optim = Flux.setup(Flux.Adam(lr), BrooksCoreyMLModel);

# Training loop, using the whole data set epochs number of times:
# Evaluate model and loss inside gradient context
# logging, outside gradient context.
losses = []
@showprogress for epoch in 1:epochs
    for (x, y) in loader
        loss, grads = Flux.withgradient(BrooksCoreyMLModel) do m
            y_hat = m(x)
            Flux.mse(y_hat, y)
        end
        Flux.update!(optim, BrooksCoreyMLModel, grads[1])
        push!(losses, loss)
    end
end

# The loss function is plotted to show that the model is learning.

plot(losses; xaxis=(:log10, "iteration"),
    yaxis=(:log10, "loss"), label="per batch")
n = length(loader)
plot!(n:n:length(losses), mean.(Iterators.partition(losses, n)),
    label="epoch mean", dpi=200)


# To test the trained model , we generate some test data, different to the training set

testing_sat = sort([0.0; rand(Float64, test_samples-2); 1.0])
testing_sat = reshape(testing_sat, 1, :)

# Next, we calculate the analytical solution and predicted values with the trained model.
test_y = JutulDarcy.brooks_corey_relperm.(testing_sat, n = exponent, residual = sr_g, residual_total = r_tot)
pred_y = BrooksCoreyMLModel(testing_sat)

plot(vec(testing_sat), vec(test_y), label="Brooks-Corey RelPerm", xlabel="Saturation", ylabel="Relative Permeability", title="Saturation vs. Relative Permeability")
plot!(vec(testing_sat), vec(pred_y), label="ML model RelPerm", xlabel="Saturation", ylabel="Relative Permeability", title="Saturation vs. Relative Permeability")

# The plot demonstrates that our neural network has successfully learned to approximate the Brooks-Corey relative permeability curve.
# This close match between the analytical solution and the ML model's predictions indicates that we can use this trained neural network in our simulation model.


# ## Replacing the relative permeability function with our neural network

# Now we can replace the relative permeability function with our neural network.
# We define a new type `MLModelRelativePermeabilities` that wraps our neural network model and implements the `update_kr!` function.
# This function is called by the simulator to update the relative permeability values for the liquid and vapour phase.
# A potential benefit of using a neural network, is that we can compute all the cells in parallel, and access to highly optimised GPU acceleration is trivial.

struct MLModelRelativePermeabilities{M} <: JutulDarcy.AbstractRelativePermeabilities
    ML_model::M
    function MLModelRelativePermeabilities(input_ML_model)
        new{typeof(input_ML_model)}(input_ML_model)
    end
end

Jutul.@jutul_secondary function update_kr!(kr, kr_def::MLModelRelativePermeabilities, model, Saturations, ix)
    ML_model = kr_def.ML_model
    for ph in axes(kr, 1)
        sat_batch = reshape(Saturations[ph, :], 1, :)
        kr[ph, :] .= vec(ML_model(sat_batch))
    end
end

# Since JutulDarcy uses automatic differentiation, our new realtive permeability model needs to be differentiable.
# This is not a problem for our neural network model, since differentiatiability is a necessary condition for machine learning models.
# One thing to note, is that the machine learning library Flux uses Zygote.jl for automatic differentiation, while Jutul uses ForwardDiff.jl.
# This is not a problem, as the gradient of our simple neural network is fully compatible with ForwardDiff.jl, so no middlelayer is needed.
# We can now replace the default relative permeability model with our new model.


ml_model, ml_parameters, ml_forces, ml_sys, ml_dt = setup_simulation_case()

ml_kr = MLModelRelativePermeabilities(BrooksCoreyMLModel)
replace_variables!(ml_model, RelativePermeabilities = ml_kr);

# We can now inspect the model to see that the relative permeability model has been replaced.

reservoir_model(ml_model)


# ### Run the simulation

ml_state0 = setup_reservoir_state(ml_model,
    Pressure = 120bar,
    Saturations = [1.0, 0.0]
)

ml_wd, ml_states, ml_t = simulate_reservoir(ml_state0, ml_model, ml_dt, parameters = ml_parameters, forces = ml_forces)


# ### Compare results


# We can now compare the results of the reference simulation and the simulation with the neural network-based relative permeability model.
using GLMakie
function plot_comparison(ref_wd, ml_wd, ref_t, ml_t)
    fig = Figure(size = (1200, 800))

    ax1 = Axis(fig[1, 1], title = "Injector BHP", xlabel = "Time (days)", ylabel = "Pressure (bar)")
    lines!(ax1, ref_t/day, ref_wd[:Injector, :bhp]./bar, label = "Brooks-Corey")
    lines!(ax1, ml_t/day, ml_wd[:Injector, :bhp]./bar, label = "ML Model")
    axislegend(ax1)

    ax2 = Axis(fig[1, 2], title = "Producer BHP", xlabel = "Time (days)", ylabel = "Pressure (bar)")
    lines!(ax2, ref_t/day, ref_wd[:Producer, :bhp]./bar, label = "Brooks-Corey")
    lines!(ax2, ml_t/day, ml_wd[:Producer, :bhp]./bar, label = "ML Model")
    axislegend(ax2)

    ax3 = Axis(fig[2, 1], title = "Producer Liquid Rate", xlabel = "Time (days)", ylabel = "Rate (m³/day)")
    lines!(ax3, ref_t/day, abs.(ref_wd[:Producer, :lrat]).*day, label = "Brooks-Corey")
    lines!(ax3, ml_t/day, abs.(ml_wd[:Producer, :lrat]).*day, label = "ML Model")
    axislegend(ax3)

    ax4 = Axis(fig[2, 2], title = "Producer Gas Rate", xlabel = "Time (days)", ylabel = "Rate (m³/day)")
    lines!(ax4, ref_t/day, abs.(ref_wd[:Producer, :grat]).*day, label = "Brooks-Corey")
    lines!(ax4, ml_t/day, abs.(ml_wd[:Producer, :grat]).*day, label = "ML Model")
    axislegend(ax4)

    return fig
end

plot_comparison(ref_wd, ml_wd, ref_t, ml_t)

# From the plot, we can see that the neural network-based relative permeability model is able to match the reference simulation to an acceptable level.

# Interactive visualization of the 3D results is also possible if GLMakie is loaded:

plot_reservoir(ml_model, ml_states, key = :Saturations, step = 3)

# This example demonstrates how to integrate a neural network model for relative
# permeability into a reservoir simulation using JutulDarcy.jl. While we used a
# simple Brooks-Corey model for demonstration, this approach can be extended to
# more complex scenarios where analytical models may not be sufficient.