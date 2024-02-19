# This is the main LaMEM Model struct
using GeophysicalModelGenerator.GeoParams
import LaMEM.Run: run_lamem, run_lamem_save_grid
import LaMEM: PassiveTracer_Time
using LaMEM.Run.LaMEM_jll

export Model, Write_LaMEM_InputFile, create_initialsetup, run_lamem, prepare_lamem

"""
    Model

Structure that holds all the information to create a LaMEM input file

    $(TYPEDFIELDS)
"""
mutable struct Model
    "Scaling parameters"
    Scaling::Scaling
    
    "LaMEM Grid"
    Grid::Grid
    
    "Time options"
    Time

    "Free surface options"
    FreeSurface

    "Boundary conditions"
    BoundaryConditions

    "Global solution parameters"
    SolutionParams

    "Solver options and optional PETSc options"
    Solver

    "Model setup"
    ModelSetup

    "Output options"
    Output

    "Passive tracers"
    PassiveTracers

    "Material parameters for each of the phases"
    Materials

    
end

"""
    Model(;
        Scaling=Scaling(GEO_units()),
        Grid=Grid(), 
        Time=Time(),
        FreeSurface=FreeSurface(),
        BoundaryConditions=BoundaryConditions(),
        SolutionParams=SolutionParams(),
        Solver=Solver(),
        ModelSetup=ModelSetup(),
        Output=Output(),
        PassiveTracers=PassiveTracers(),
        Materials=Materials()
        )

Creates a LaMEM Model setup.

    $(TYPEDFIELDS)

"""
function Model(;
    Scaling=Scaling(GEO_units()),
    Grid=Grid(), 
    Time=Time(),
    FreeSurface=FreeSurface(),
    BoundaryConditions=BoundaryConditions(),
    SolutionParams=SolutionParams(),
    Solver=Solver(),
    ModelSetup=ModelSetup(),
    Output=Output(),
    PassiveTracers=PassiveTracers(),
    Materials=Materials()
    )

    return Model(Scaling, Grid, Time, FreeSurface, BoundaryConditions, 
                SolutionParams, Solver, ModelSetup, Output, PassiveTracers, Materials)
end

include("DefaultParams.jl")             # main LaMEM_Model

"""
    Model(args...)

Allow to define a model setup by specifying some of the basic objects

Example
===
```julia
julia> d = Model(Grid(nel=(10,1,20)), Scaling(NO_units()))
LaMEM Model setup
|
|-- Scaling             :  GeoParams.Units.GeoUnits{GeoParams.Units.NONE}
|-- Grid                :  nel=(10, 1, 20); xϵ(-10.0, 10.0), yϵ(-10.0, 0.0), zϵ(-10.0, 0.0) 
|-- Time                :  nstep_max=50; nstep_out=1; time_end=1.0; dt=0.05
|-- Boundary conditions :  noslip=[0, 0, 0, 0, 0, 0]
|-- Solution parameters :  
|-- Solver options      :  direct solver; superlu_dist; penalty term=10000.0
|-- Model setup options :  Type=geom; 
|-- Output options      :  filename=output; pvd=1; avd=0; surf=0
|-- Materials           :  1 phases;  

```

"""
function Model(args...)
    names_str = typeof.(args);  # this may have { } in them
    names_strip = ();
    for name in names_str
        name_str = split("$name","{")[1]
        name_str = split("$name_str",".")[end]
        
        names_strip = (names_strip..., name_str)
    end 
    args_tuple = NamedTuple{Symbol.(names_strip)}(args)

    model = Model(; args_tuple...)
    model = UpdateDefaultParameters(model)

    return model
end

# Show brief overview of Model
function show(io::IO, d::Model)
    println(io,"LaMEM Model setup")
    println(io,"|")
    show_short(io, d.Scaling)   
    show_short(io, d.Grid)     
    show_short(io, d.Time)      
    show_short(io, d.FreeSurface)   
    show_short(io, d.BoundaryConditions)   
    show_short(io, d.SolutionParams)   
    show_short(io, d.Solver)   
    show_short(io, d.ModelSetup)   
    show_short(io, d.Output)   
    show_short(io, d.PassiveTracers)   
    show_short(io, d.Materials)
end

"""
    Write_LaMEM_InputFile(d::Model,fname::String; dir=pwd())

Writes a LaMEM input file based on the data stored in Model
"""
function Write_LaMEM_InputFile(d::Model, fname::String="input.dat"; dir=pwd())
    Check_LaMEM_Model(d)    # check for mistakes in input

    if d.Output.write_VTK_setup
        # If we want to write an input file 
        Write_Paraview(CartData(d.Grid.Grid, (Phases=d.Grid.Phases,Temp=d.Grid.Temp)),"Model3D")
    end
    
    if any(hasplasticity.(d.Materials.Phases))
        # We have plasticity, so we likely want to see that
        d.Output.out_plast_strain    = 1     # accumulated plastic strain
        d.Output.out_plast_dissip    = 1      # plastic dissipation
    end

    io = open(fname,"w")

    Write_LaMEM_InputFile(io, d.Scaling)
    Write_LaMEM_InputFile(io, d.Grid)
    Write_LaMEM_InputFile(io, d.Time)
    Write_LaMEM_InputFile(io, d.FreeSurface)
    Write_LaMEM_InputFile(io, d.BoundaryConditions)
    Write_LaMEM_InputFile(io, d.SolutionParams)
    Write_LaMEM_InputFile(io, d.Solver)
    Write_LaMEM_InputFile(io, d.ModelSetup)
    Write_LaMEM_InputFile(io, d.Output)
    Write_LaMEM_InputFile(io, d.PassiveTracers)
    Write_LaMEM_InputFile(io, d.Materials)
    
    Write_LaMEM_InputFile_PETSc(io, d.Solver)   # add PETSc options last

    close(io)
end


"""
    run_lamem(model::Model, cores::Int64=1, args:String=""; wait=true)

Performs a LaMEM run for the parameters that are specified in `model`
"""
function run_lamem(model::Model, cores::Int64=1, args::String=""; wait=true)

    cur_dir = pwd(); 
    
    #if !isdir(model.Output.out_dir); mkdir(model.Output.out_dir); end # create directory if needed
    create_initialsetup(model, cores, args);    
    
    if !isempty(model.Output.out_dir)
        cd(model.Output.out_dir)
    end
   
    run_lamem(model.Output.param_file_name, cores, args; wait=wait)
    
    cd(cur_dir)

    return nothing
end

"""
    prepare_lamem(model::Model, cores::Int64=1, args:String=""; verbose=false)

Prepares a LaMEM run for the parameters that are specified in `model`, without running the simulation

    1) Create the `*.dat` file
    2) Write markers to disk in case we use a "files" setup

This is useful if you want to prepare a model on one machine but run it on another one (e.g. a cluster)

Set `model.Output.write_VTK_setup` to `true` if you want to write a VTK file of the model setup

"""
function prepare_lamem(model::Model, cores::Int64=1, args::String=""; verbose=false)

    println("Creating LaMEM input files in the directory: $(model.Output.out_dir)")
    cur_dir = pwd(); 

    create_initialsetup(model, cores, args,  verbose=verbose);    
    
    cd(cur_dir)

    println("Generated output generated for $cores cores:")
    println("   Base directory       : $(pwd())")
    println("   LaMEM parameter file : $(model.Output.out_dir)/$(model.Output.param_file_name)")
    println("   Marker files         : $(model.Output.out_dir)/markers/")
    println("Copy these files over to the computer where you want to run your simulation")

    return nothing
end



"""
"""
function  PassiveTracer_Time(model::Model, cores::Int64=1, args::String=""; wait=true)

end

"""
    PT = PassiveTracer_Time(ID::Union{Vector{Int64},Int64}, model::Model)

This reads passive tracers with `ID` from a LaMEM simulation specified by `model`, and returns a named tuple with the temporal 
evolution of these passive tracers. We return `x`,`y`,`z` coordinates and all fields specified in `FileName` for particles number `ID`.

"""
function PassiveTracer_Time(ID::Union{Vector{Int64},Int64}, model::Model)
    return PassiveTracer_Time(ID, model.Output.out_file_name, model.Output.out_dir)
end

"""
    create_initialsetup(model::Model, cores::Int64=1, args::String=""; verbose=verbose)

Creates the initial model setup of LaMEM from `model`, which includes:
- Writing the LaMEM (*.dat) input file

and in case we do not employt geometric primitives to create the setup:

- Write the VTK file (if requested when `model.Output.write_VTK_setup=true`)
- Write the marker files to disk (if `model.ModelSetup.msetup="files"`)

"""
function create_initialsetup(model::Model, cores::Int64=1, args::String=""; verbose=true)
    
    # Move to the working directory
    cur_dir = pwd()
    if !isempty(model.Output.out_dir)
        if !isdir(model.Output.out_dir);  mkdir(model.Output.out_dir); end # create directory if needed
        cd(model.Output.out_dir)
    end

    Write_LaMEM_InputFile(model, model.Output.param_file_name)
    
    
    if !isnothing(model.FreeSurface.Topography)
        Save_LaMEMTopography(model.FreeSurface.Topography, model.FreeSurface.surf_topo_file)
    end

    if model.ModelSetup.msetup=="files"
        # write marker files to disk before running LaMEM
        Model3D = CartData(model.Grid.Grid, (Phases=model.Grid.Phases,Temp=model.Grid.Temp));

        if cores>1
            PartFile = run_lamem_save_grid(model.Output.param_file_name, cores)

            Save_LaMEMMarkersParallel(Model3D, PartitioningFile=PartFile, verbose=verbose)
        else
            Save_LaMEMMarkersParallel(Model3D, verbose=verbose)
        end
    end

    cd(cur_dir)
    return nothing
end

