# main.jl

# overall notes:
#   - objective: given a vehicle state and pedestrian positions, return the actions that are guaranteed safe
#   - formulate for after-DESPOT approach
#   - don't want to change POMDP action set (for now)
#       - divert paths should be pulling from the same action parameters
#   - can approximate t_obs ~= t_k1 to simplify implementation in simulator

# integration:
#   - inputs: human observation, Dt_obs_to_k1, vehicle state

# need to collision-check for:
#   - every next state sp (~10)
#       - every divert trajectory (3)
#           - every time step (~5)
#               - every pedestrian set (~6)

# assumed parameters:
#   - vehicle top speed: 2.0 m/s (this shouldn't matter)
#   - vehicle max brake: -0.5 m/s (same as POMDP) (although would make sense to include as a harder brake?)
#   - human speed: 1 m/s

# pseudo-code:
#==
function gen_ped_bound(s0, t_h)
    return VPolygon
end

NOTE: better order to do this

for action in action_set
    propagate vehicle forward one time step from s to sp

    for path in divert_paths
        action_k = [full brake, steering]

        for k in time_steps (prefer dt=0.1 sec)
            propagate vehicle state to (t+k*dt)

            for human in near_humans
                generate F_p(t+k*dt)
                check polygon intersection between vehicle and human set (for current time step)
            end

            check HJB value to see if in static obstacle or RIC (better to convert HJB RICs to polygons over-approx to check definitively?)
        end
    end
end
==#

# TO-DO: need to fix Minkwoski sum issue
# F_cir = Ball2(human, v_human*t_hrz)
# plot!(p1, F_cir, alpha=0.0, linecolor=:blue, linestyle=:dash, linewidth=1, linealpha=1)

using LazySets
using LinearAlgebra
using StaticArrays
using Random
using Plots
using BenchmarkTools

using Pkg
Pkg.develop(PackageSpec(path = "/Users/willpope/.julia/dev/BellmanPDEs"))
using BellmanPDEs

# define environment
ws_width = 5.5
ws_length = 11.0

goal_positions = [[0.0, 0.0],
        [ws_width, 0.0],
        [ws_width, ws_length],
        [0.0, ws_length]]

# define vehicle and dynamics
wheelbase = 0.324
body_dims = [0.5207, 0.2762]
origin_to_cent = [0.1715, 0.0]
phi_max = 0.475
v_max = 2.0
discount = 1.0
veh = define_vehicle(wheelbase, body_dims, origin_to_cent, phi_max, v_max, discount)

# define action set
function get_actions(x, Dt, veh)
    # set change in velocity (Dv) limit
    Dv_lim = 0.5

    # set steering angle (phi) limit
    Dtheta_lim = deg2rad(45)

    v = x[4]
    vp = v + Dv_lim
    vn = v - Dv_lim

    phi_lim = atan(Dtheta_lim * 1/Dt * 1/abs(v) * veh.l)
    phi_lim = clamp(phi_lim, 0.0, veh.phi_max)

    phi_lim_p = atan(Dtheta_lim * 1/Dt * 1/abs(vp) * veh.l)
    phi_lim_p = clamp(phi_lim_p, 0.0, veh.phi_max)

    phi_lim_n = atan(Dtheta_lim * 1/Dt * 1/abs(vn) * veh.l)
    phi_lim_n = clamp(phi_lim_n, 0.0, veh.phi_max)

    actions = SVector{5, SVector{2, Float64}}(
        (-phi_lim, 0.0),       # Dv = 0.0
        (-1/3*phi_lim, 0.0),
        (0.0, 0.0),
        (1/3*phi_lim, 0.0),
        (phi_lim, 0.0))

    ia_set = collect(1:length(actions))

    return actions, ia_set
end

# plot environment and state x_0
p1 = plot(getindex.(goal_positions,1), getindex.(goal_positions,2), label="Goals",
    aspect_ratio=:equal, size=(500,600), linewidth=0, 
    markershape=:circle, markersize=5,
    xticks=0:1:6, yticks=0:1:10)


# TO-DO: modify to use more general set calculation
#   - shouldn't affect larger architecture
#   - may need to pass in set from previous time step in order to propagate
function generate_human_FRS(xy_human, v_human, Dt_obs_to_kd, goal_positions)
    reach_radius = v_human * Dt_obs_to_kd

    vertices = Vector{Vector{Float64}}(undef, length(goal_positions)+1)
    for ig in axes(goal_positions, 1)
        goal_vector = reach_radius * normalize(goal_positions[ig] - xy_human)
        vertices[ig] = xy_human + goal_vector
    end
    vertices[end] = xy_human

    F_human = VPolygon(vertices)

    # TO-DO: add Minkowski sum for human radius
    # human_radius = 0.2
    # C_h = VPolyCircle([0.0, 0.0], human_radius)

    # @show typeof(F_human)
    # @show typeof(C_h)

    # F_hc = LazySets.minkowski_sum(F_human, C_h)

    # @show typeof(F_hc)
    
    return F_human
end


function generate_human_FRS_sequence(nearby_human_positions, Dt_obs_to_k1, Dt_plan, Dt_divert, v_k2_max, Dv_max, v_human, goal_positions)
    # calculate steps for longest divert path
    Dv_divert = Dv_max * Dt_divert/Dt_plan
    kd_stop_max = ceil(Int, (0.0 - v_k2_max)/(-Dv_divert))

    println("\nkd_stop_max = ", kd_stop_max)

    # generate human reachable sets at each divert time step
    F_seq = []
    for kd = 0:kd_stop_max
        Dt_obs_to_kd = Dt_obs_to_k1 + Dt_plan + kd*Dt_divert
        println("kd = ", kd, ", Dt_obs_to_kd = ", Dt_obs_to_kd)

        F_all_k = []
        for xy_human in nearby_human_positions
            F_human_k = generate_human_FRS(xy_human, v_human, Dt_obs_to_kd, goal_positions)

            push!(F_all_k, F_human_k)
        end

        push!(F_seq, F_all_k)
    end

    return F_seq
end


# TO-DO: check HJB value at each step in divert path

# ISSUE: Julia crashes when trying to use minkowski_sum() within shielding function
#   - gen_FRS() function works fine with mink_sum() when used separately in command line

function shield_action_set(x_k, ia_k, nearby_human_positions, Dt_obs_to_k1, get_actions::Function, Dt_plan, Dt_divert, phi_max, Dv_max, veh)
    
    
    println("x_k = ", x_k)
    println("a_k = ", actions[ia_k])
    
    # TO-DO: need to pull divert actions from actual action set at each state
    #   - means need to call get_actions() from within divert path in order to get correct steering angles
    #   - want divert actions to match actual layers in tree, plus still can't oversteer when turning car

    # 0: define divert actions
    Dv_divert = Dv_max * Dt_divert/Dt_plan
    divert_actions = SVector{3, SVector{2, Float64}}(
        (-phi_max, -Dv_divert),
        (0.0, -Dv_divert),
        (phi_max, -Dv_divert))

    iad_set = collect(1:length(divert_actions))
    
    # 1: propagate vehicle to state x_k1 (execution time)
    a_k = actions[ia_k]
    x_k1, _ = propagate_state(x_k, a_k, Dt_plan, veh)

    println("x_k1 = ", x_k1)

    # 2: generate human FRS sequence from t_k2 to t_stop_max
    v_k2_max = x_k1[4] + maximum(getindex.(actions, 2))
    F_seq = generate_human_FRS_sequence(nearby_human_positions, Dt_obs_to_k1, Dt_plan, Dt_divert, v_k2_max, Dv_max, v_human, goal_positions)

    # TEST ONLY ---
    plot!(p1, [x_k1[1]], [x_k1[2]], markercolor=:black, markershape=:circle, markersize=3, markerstrokewidth=0, label="")
    plot!(p1, state_to_body(x_k1, veh))
    # ---

    # 3: perform set check on all actions in standard POMDP action set
    actions_k1, ia_set = get_actions(x_k1, Dt_plan, veh)

    ia_safe_set = []

    for ia_k1 in ia_set
        # propagate vehicle state to state x_k2
        a_k1 = actions_k1[ia_k1]
        x_k2, _ = propagate_state(x_k1, a_k1, Dt_plan, veh)

        ia_k1_safe = false

        # calculate time needed for divert path from new state
        Dv_divert = Dv_max * Dt_divert/Dt_plan
        kd_stop = ceil(Int, (0.0 - x_k2[4])/(-Dv_divert))

        # TEST ONLY ---
        println("\na_k1 = ", a_k1)
        println("x_k2 = ", x_k2)
        println("kd_stop = ", kd_stop)
        plot!(p1, [x_k2[1]], [x_k2[2]], markercolor=:black, markershape=:circle, markersize=3, markerstrokewidth=0, label="")
        plot!(p1, state_to_body(x_k2, veh))
        # ---

        # iterate through divert steering angles
        for iad in shuffle(iad_set)
            ad = divert_actions[iad]

            println("ad = ", ad)

            iad_safe = true

            # TEST ONLY ---
            divert_path = []
            # ---

            x_kd = x_k2
            for kd in 0:kd_stop
                # TO-DO:
                # # check if divert path is in static environment RIC
                # val_x_kd = interp_value(x_kd, value_array, sg)
                # if val_x_kd < -50.0
                #   iad_safe = false
                #   break
                # end

                # check for collisions with each human
                veh_body_kd = state_to_body(x_kd, veh)

                # TEST ONLY ---
                println("kd = ", kd, ", x_k = ", x_kd)
                push!(divert_path, x_kd)
                plot!(p1, getindex.(divert_path, 1), getindex.(divert_path, 2), label="")
                plot!(p1, veh_body_kd)
                # ---
                
                humans_safe = true
                for ih in axes(nearby_human_positions, 1)
                    
                    # TEST ONLY ---
                    plot!(p1, [nearby_human_positions[ih][1]], [nearby_human_positions[ih][2]], label="", markershape=:circle, markersize=5)
                    plot!(p1, F_seq[kd+1][ih], label="")
                    # ---

                    if isempty(intersection(veh_body_kd, F_seq[kd+1][ih])) == false || isempty(intersection(F_seq[kd+1][ih], veh_body_kd)) == false
                        # println("collision at k = ", k, ", x_k = ", x_k)
                        humans_safe = false
                        break
                    end
                end

                # TEST ONLY ---
                display(p1)
                # ---

                if humans_safe == false
                    iad_safe = false
                    break
                end

                # ISSUE: applying smaller Dv at smaller time steps will produce a different path
                #   - velocity is lower in "second half" of full size time step
                #   - velocity approaches a ramp function as Dt_divert shrinks, needs to stay same
                #   - may be easier to just use regular time step/action and return x_subpath for finer checking
                #       - would need to match up x_subpath time steps with steps used to generate F_seq
                #   - for now, just use Dt_divert=Dt_plan
                
                # propagate vehicle to next step along divert path
                x_kd1, _ = propagate_state(x_kd, ad, Dt_divert, veh)

                # pass state to next step
                x_kd = x_kd1
            end

            if iad_safe == true
                ia_k1_safe = true
                break
            end 
        end

        println("ia_k1_safe = ", ia_k1_safe)

        # action is safe
        if ia_k1_safe == true
            push!(ia_safe_set, ia_k1)
        end
    end

    return ia_safe_set
end


# define human positions and velocity
nearby_human_positions = [[2.0, 7.5],
                        [3.8, 5.2],
                        [4.3, 8.4]]
                        # ,
                        # [1.6, 3.2],
                        # [2.8, 5.1],
                        # [4.8, 4.6]]

# (?): what upper bound velocity should be used here?
v_human = 1.0


Dt_plan = 0.5
Dt_divert = 0.5

x_k = SVector(2.0, 2.0, pi*1/3, 1.5)
ia_k = 2
Dt_obs_to_k1 = 0.0
        
ia_safe_set = shield_action_set(x_k, ia_k, nearby_human_positions, Dt_obs_to_k1, get_actions, Dt_plan, Dt_divert, phi_max, Dv_max, veh)

# @btime shield_action_set($x_0, $actions, $Dt_plan, $Dt_divert, $v_max, $EoM, $veh)


# testing:
#   - do time steps line up? (check if vehicle and humans matching)
#   - is state propagated correctly?
#   - is safety logic flowing as expected?


#=
notional architecture:

while end_run == false
    publish action -> a_k

    retrieve state/observation -> obs_k
    update belief -> belief_k

    ranked actions = run_DESPOT(belief_k, predicted_x_k1)
    [... 0.4 sec ...]

    retrieve another state/observation -> obs_shield
    take current time -> Dt_obs_to_k1
    ia_safe_set = run_shield(obs_shield, Dt_obs_to_k1)

    a_k1 = best safe action
    a_k = a_k1
end

(?): can DESPOT.jl return Q-value for all actions?
=#



# performance:
#   - for 9 actions, 6 humans, no optimization
#       - 9/9 safe: 310.040 us, 4792 allocations
#       - 4/9 safe: 463.547 us, 7070 allocations
#       - 0/9 safe: 192.423 us, 3069 allocations