module FlexExtract

using DataStructures
using CSV
using Dates
using FlexExtract_jll
using Pkg.Artifacts
using PyCall
import EcRequests
using EcRequests: EcRequestType
using StatsBase

export 
    FlexExtractDir,
    FeControl, 
    MarsRequest,
    set_area!,
    set_area,
    set_steps!,
    set_ensemble_rest!,
    save_request,
    csvpath,
    submit,
    prepare,
    retrieve

const PATH_CALC_ETADOT = joinpath(FlexExtract_jll.artifact_dir, "bin")
const CALC_ETADOT_PARAMETER = :EXEDIR
const CMD_CALC_ETADOT = FlexExtract_jll.calc_etadot()

const ROOT_ARTIFACT_FLEXEXTRACT = artifact"flex_extract"
const PATH_FLEXEXTRACT = joinpath(ROOT_ARTIFACT_FLEXEXTRACT, "flex_extract_v7.1.2")

const FLEX_DEFAULT_CONTROL = "CONTROL_OD.OPER.FC.eta.highres"
const FLEX_ENSEMBLE_CONTROL = "CONTROL_OD.ENFO.PF.36hours"
const PATH_FLEXEXTRACT_CONTROL_DIR = joinpath(PATH_FLEXEXTRACT, "Run", "Control")
const PATH_FLEXEXTRACT_DEFAULT_CONTROL = joinpath(PATH_FLEXEXTRACT_CONTROL_DIR, FLEX_DEFAULT_CONTROL)

const PATH_PYTHON_SCRIPTS = Dict(
    :run_local => joinpath(PATH_FLEXEXTRACT, "Run", "run_local.sh"),
    :submit => joinpath(PATH_FLEXEXTRACT, "Source", "Python", "submit.py"),
    :prepare => joinpath(PATH_FLEXEXTRACT, "Source", "Python", "Mods", "prepare_flexpart.py"),
)

const PYTHON_EXECUTABLE = PyCall.python

include("utils.jl")

_default_control(filename) = joinpath(PATH_FLEXEXTRACT_CONTROL_DIR, filename)

function __init__()
    pyimport_conda("ecmwfapi", "ecmwf-api-client", "conda-forge")
    pyimport_conda("eccodes", "python-eccodes", "conda-forge")
    pyimport_conda("genshi", "genshi", "conda-forge")
    pyimport_conda("numpy", "numpy", "conda-forge")
    pyimport_conda("cdsapi", "cdsapi", "conda-forge")
end

abstract type AbstractPathnames end

getpath(pn::AbstractPathnames) = pn.dirpath
Base.getindex(pn::AbstractPathnames, name::Symbol) = joinpath(getpath(pn), getfield(pn, name)) |> Base.abspath
function Base.setindex!(pn::AbstractPathnames, val::String, name::Symbol)
    setfield!(pn, name, val)
end
function Base.iterate(pn::AbstractPathnames, state=1)
    fn = filter(x -> x!==:dirpath, fieldnames(typeof(pn)))
    state > length(fn) ? nothing : ( (fn[state], getfield(pn, fn[state])), state + 1)
end
function Base.show(io::IO, ::MIME"text/plain", pn::AbstractPathnames)
    println(io, "pathnames:")
    for (k, v) in pn
        println(io, "\t", "$k => $v")
    end
end


abstract type AbstractFlexDir end
Base.getindex(flexdir::AbstractFlexDir, name::Symbol) = getindex(getpathnames(flexdir), name)
function Base.setindex!(flexdir::AbstractFlexDir, value::String, name::Symbol)
    getpathnames(flexdir)[name] = value
end


abstract type WrappedOrderedDict{K,V} <: AbstractDict{K,V} end
Base.parent(wrappeddict::WrappedOrderedDict) = wrappeddict.dict
Base.show(io::IO, mime::MIME"text/plain", fcontrol::WrappedOrderedDict) = show(io, mime, Base.parent(fcontrol))
Base.show(io::IO, fcontrol::WrappedOrderedDict) = show(io, Base.parent(fcontrol))
Base.length(fcontrol::WrappedOrderedDict) = length(Base.parent(fcontrol))
Base.getindex(fcontrol::WrappedOrderedDict, name) = getindex(Base.parent(fcontrol), name)
Base.setindex!(fcontrol::WrappedOrderedDict, val, name) = setindex!(Base.parent(fcontrol), val, name)
Base.iterate(fcontrol::WrappedOrderedDict) = iterate(Base.parent(fcontrol))
Base.iterate(fcontrol::WrappedOrderedDict, state) = iterate(Base.parent(fcontrol), state)

mutable struct FePathnames <: AbstractPathnames
    dirpath::AbstractString
    input::AbstractString
    output::AbstractString
    controlfile::AbstractString
end
FePathnames(dirpath; control = FLEX_DEFAULT_CONTROL) = FePathnames(dirpath, "./input", "./output", _default_control(control))
FePathnames(dirpath, controlpath::AbstractString) = FePathnames(dirpath, "./input", "./output", controlpath)


struct FlexExtractDir <: AbstractFlexDir
    path::AbstractString
    pathnames::FePathnames
end
FlexExtractDir(fepath::AbstractString, controlpath::AbstractString) = FlexExtractDir(abspath(fepath), FePathnames(fepath, "input", "output", relpath(controlpath, fepath)))

function FlexExtractDir(fepath::AbstractString)
    files = readdir(fepath)
    icontrol = findfirst(x -> occursin("CONTROL", x), files .|> basename)
    isnothing(icontrol) && error("No control file has been found in $fepath")
    FlexExtractDir(fepath, FePathnames(fepath, "input", "output", files[icontrol]))
end
FlexExtractDir(fepath::AbstractString, fcontrolpath::AbstractString, inpath::AbstractString, outpath::AbstractString) =
    FlexExtractDir(fepath, FePathnames(fepath, inpath, outpath, fcontrolpath))
function FlexExtractDir()
    dir = mktempdir()
    return FlexExtract.create(dir)
end

getpathnames(fedir::FlexExtractDir) = fedir.pathnames
function Base.show(io::IO, mime::MIME"text/plain", fedir::FlexExtractDir)
    println(io, "FlexExtractDir @ ", fedir.path)
    show(io, mime, fedir.pathnames)
end

function create(path::AbstractString; force = false, control = FLEX_DEFAULT_CONTROL)
    mkpath(path)
    default_pn = FePathnames(path; control = control)
    mkpath(joinpath(path, default_pn[:input]))
    mkpath(joinpath(path, default_pn[:output]))
    fn = cp(default_pn[:controlfile], joinpath(path, basename(default_pn[:controlfile])), force = force)
    chmod(fn, 0o664)
    FlexExtractDir(path, fn)
end

struct FeControl{K<:Symbol, V} <: WrappedOrderedDict{K, V}
    path::AbstractString
    dict:: OrderedDict{K, V}
end
FeControl(path::String) = FeControl(abspath(path), control2dict(path))
FeControl(fedir::FlexExtractDir) = FeControl(fedir[:controlfile])
FeControl() = FeControl(PATH_FLEXEXTRACT_DEFAULT_CONTROL)


function add_exec_path(fcontrol::FeControl)
    push!(fcontrol, CALC_ETADOT_PARAMETER => PATH_CALC_ETADOT)
    save(fcontrol)
end
add_exec_path(fedir::FlexExtractDir) = add_exec_path(FeControl(fedir))

function save_request(fedir::FlexExtractDir)
    csvp = csvpath(fedir)
    cp(csvp, joinpath(fedir.path, basename(csvp)))
end

function EcRequests.EcRequest(row::CSV.Row)
    d = EcRequestType()
    for name in propertynames(row)
        valuestr = row[name] |> string |> strip
        valuestr |> isempty && continue
        valuestr = valuestr[1]=='/' ? "\"" * valuestr * "\""  : valuestr
        key = name == :marsclass ? "class" : name
        push!(d, string(key) => valuestr)
    end
    # flex_extract add a :request_number column that makes retrieval fail
    pop!(d, "request_number")
    d
    # MarsRequest(d, parse(Int64, pop!(d, :request_number)))
end
allrequests(csv::CSV.File) = EcRequests.EcRequest.(collect(csv))
ferequests(path::String) = allrequests(CSV.File(path, normalizenames= true))
# MarsRequest(dict::AbstractDict) = MarsRequest(convert(OrderedDict, dict), 1)

adapt_env(cmd) = addenv(cmd, CMD_CALC_ETADOT.env)
function adapt_and_run(cmd)
    cmd_with_new_env = adapt_env(cmd)
    Base.run(cmd_with_new_env)
end

# function modify_control(fedir::FlexExtractDir)
#     dir = mktempdir()
#     newcontrol = cp(fedir[:controlfile], joinpath(dir, basename(fedir[:controlfile])))
#     newfedir = FlexExtractDir(fedir.path, FePathnames(fedir[:input], fedir[:output], newcontrol))
#     add_exec_path(newfedir)
#     newfedir
# end

submitcmd(fedir::FlexExtractDir) = `$(PYTHON_EXECUTABLE) $(PATH_PYTHON_SCRIPTS[:submit]) $(feparams(fedir))`

function submit(fedir::FlexExtractDir)
    # params = feparams(fedir)
    # cmd = `$(fesource.python) $(fesource.scripts[:submit]) $(params)`
    add_exec_path(fedir)
    cmd = submitcmd(fedir)
    adapt_and_run(cmd)
end

# Works only on Julia 1.7
function submit(f::Function, fedir::FlexExtractDir)
    add_exec_path(fedir)
    cmd = submitcmd(fedir)
    pipe = Pipe()

    @async while true
        f(pipe)
    end

    redirect_stdio(; stderr = pipe, stdout = pipe) do 
        adapt_and_run(cmd)
        # retrieve(req; polytope = polytope)
    end
    
    # cmd = pipeline(adapt_env(cmd), stdout=pipe, stderr=pipe)
    # run(cmd)
end

function retrieve(request; polytope = false)
    !polytope ? EcRequests.runmars(request) : EcRequests.runpolytope(request)
end

function retrieve(requests::AbstractVector; polytope = false)
    for req in requests
        retrieve(req, polytope = polytope)
    end
end

# To be tested on julia v1.7
function retrieve(f::Function, req; polytope = false)
    pipe = Pipe()

    @async while true
        f(pipe)
    end
    
    redirect_stdio(; stderr = pipe, stdout = pipe) do 
        retrieve(req; polytope = polytope)
    end
end

function retrieve(fedir::FlexExtractDir; polytope = false)
    cpath = csvpath(fedir)
    !isfile(cpath) && error("No flex_extract csv requests file found at $cpath")
    requests = ferequests(cpath)

    retrieve(requests, polytope = polytope)
end

function preparecmd(fedir::FlexExtractDir)
    files = readdir(fedir[:input])
    ifile = findfirst(files) do x
        splitext(x)[2] !== ".grb" && return false
        try
            split(x, '.')[4]
        catch
            false
        end
        true
    end
    isnothing(ifile) && error("No ECMWF file found in the input directory")
    ppid = split(files[ifile], '.')[4]
    `$(PYTHON_EXECUTABLE) $(PATH_PYTHON_SCRIPTS[:prepare]) $(feparams(fedir)) $(["--ppid", ppid])`
end

function prepare(fedir::FlexExtractDir)
    add_exec_path(fedir)
    cmd = preparecmd(fedir)
    adapt_and_run(cmd)
end

# Works only on Julia 1.7
function prepare(f::Function, fedir::FlexExtractDir)
    add_exec_path(fedir)
    cmd = preparecmd(fedir)
    pipe = Pipe()

    @async while true
        f(pipe)
    end

    redirect_stdio(; stderr = pipe, stdout = pipe) do 
        adapt_and_run(cmd)
        # retrieve(req; polytope = polytope)
    end
    
end

function feparams(control::String, input::String, output::String)
    formated_exec = Dict("inputdir" => input, "outputdir" => output, "controlfile" => control)
    params = []
    for (k, v) in formated_exec 
        push!(params, "--$k") 
        push!(params, v)
    end
    params
end
feparams(fedir::FlexExtractDir) = feparams(fedir[:controlfile], fedir[:input], fedir[:output])

csvpath(fedir::FlexExtractDir) = joinpath(fedir[:input], "mars_requests.csv")

function control2dict(filepath) :: OrderedDict{Symbol, Any}
    pairs = []
    open(filepath, "r") do f
        for line in eachline(f)
            line == "" && continue
            m = match(r"(.*?)\s(.*)", line)
            isnothing(m) && error("line $line could not be parsed")
            push!(pairs, m.captures[1] |> Symbol => m.captures[2])
        end
    end
    OrderedDict{Symbol, Any}(pairs)
end

function save(fcontrol::FeControl)
    dest = fcontrol.path
    writelines(dest, format(fcontrol))
end

function format(fcontrol::FeControl)::Vector{String}
    ["$(uppercase(String(k))) $v" for (k,v) in fcontrol]
end

function set_area!(fcontrol::FeControl, area; grid = nothing)
    new = Dict()
    if !isnothing(grid)
        alons = -180.0:grid:180.0 |> collect
        outerlons = outer_vals(alons, (area[2], area[4]))
        alats = -90.0:grid:90.0 |> collect
        outerlats = outer_vals(alats, (area[3], area[1]))
        area = [outerlats[2], outerlons[1], outerlats[1], outerlons[2]]
        push!(new, :GRID => grid)
    end
    new = push!(new,
        :LOWER => area[3],
        :UPPER => area[1],
        :LEFT => area[2],
        :RIGHT => area[4],
    )
    merge!(fcontrol, new)
end
function set_area(fedir::FlexExtractDir, area; grid = nothing)::FeControl
    fcontrol = FeControl(fedir)
    set_area!(fcontrol , area; grid = grid)
    fcontrol
end

function set_steps!(fcontrol::FeControl, startdate, enddate, timestep)
    stepdt = startdate:Dates.Hour(timestep):(enddate - Dates.Hour(1))
    type_ctrl = []
    time_ctrl = []
    step_ctrl = []

    format_opt = opt -> opt < 10 ? "0$(opt)" : "$(opt)"
    if occursin("EA", fcontrol[:CLASS])
        for st in stepdt
            push!(time_ctrl, Dates.Hour(st).value % 24 |> format_opt)
            push!(type_ctrl, "AN")
            push!(step_ctrl, 0 |> format_opt)
        end
    elseif occursin("ENFO", fcontrol[:STREAM])
        fc_startdate = enddate - Dates.Hour(36)
        fc_startdate = Dates.floorceil(fc_startdate, Dates.Hour(12))[2]
        for st in stepdt
            push!(time_ctrl, Dates.hour(fc_startdate) |> format_opt)
            push!(type_ctrl, "PF")
            step = Dates.Hour(st - fc_startdate).value
            push!(step_ctrl, step |> format_opt)
        end
        startdate = fc_startdate
        enddate = startdate
        merge!(fcontrol, Dict(:ACCTIME => time_ctrl[1]))
    else
        for st in stepdt
            push!(time_ctrl, div(Dates.Hour(st).value, 12) * 12 |> format_opt)
            step = Dates.Hour(st).value .% 12
            step == 0 ? push!(type_ctrl, "AN") : push!(type_ctrl, "FC")
            push!(step_ctrl, step |> format_opt)
        end
    end

    if Dates.Date(startdate) == Dates.Date(enddate)
        newd = Dict(
            :START_DATE => Dates.format(startdate, "yyyymmdd"), 
            :TYPE => join(type_ctrl, " "),
            :TIME => join(time_ctrl, " "), 
            :STEP => join(step_ctrl, " "), 
            :DTIME => timestep isa String || string(timestep),
        )
    else
        newd = Dict(
            :START_DATE => Dates.format(startdate, "yyyymmdd"), 
            :END_DATE => Dates.format(enddate, "yyyymmdd"), 
            :TYPE => join(type_ctrl, " "),
            :TIME => join(time_ctrl, " "), 
            :STEP => join(step_ctrl, " "), 
            :DTIME => timestep isa String || string(timestep),
        )
    end

    merge!(fcontrol, newd)
end
set_steps!(fedir::FlexExtractDir, startdate, enddate, timestep) = set_steps!(fedir.control, startdate, enddate, timestep)

function set_ensemble_rest!(fcontrol::FeControl)
    members = sample(1:50, 9; replace=false)
    new = Dict(
        :NUMBER => join(members, "/"),
        :LEVELIST => "1/to/137",
        :RESOL => 799,
        :FORMAT => "GRIB2",
        :GAUSS => 0,
    )
    merge!(fcontrol, new)
end
set_ensemble_rest!(fedir::FlexExtractDir) = set_ensemble_rest!(FeControl(fedir))

end
