# AVClass related definitions

## Mapping from AVOptionType to Julia types

av_opt_type2julia = @compat Dict{UInt32, DataType}(AVUtil.AV_OPT_TYPE_FLAGS => UInt64,
                                                   AVUtil.AV_OPT_TYPE_INT => Int32,
                                                   AVUtil.AV_OPT_TYPE_INT64 => Int64,
                                                   AVUtil.AV_OPT_TYPE_DOUBLE => Float64,
                                                   AVUtil.AV_OPT_TYPE_FLOAT => Float32,
                                                   #AVUtil.AV_OPT_TYPE_STRING => Cstring,
                                                   #AVUtil.AV_OPT_TYPE_RATIONAL => Rational{Int32},
                                                   #AVUtil.AV_OPT_TYPE_BINARY => _AVBinaryBlob,
                                                   #AVUtil.AV_OPT_TYPE_DICT => AVDict,
                                                   #AVUtil.AV_OPT_TYPE_CONST => Int64 or Float64,
                                                   #AVUtil.AV_OPT_TYPE_IMAGE_SIZE => _AVImageSize,
                                                   #AVUtil.AV_OPT_TYPE_PIXEL_FMT => UInt32,
                                                   #AVUtil.AV_OPT_TYPE_SAMPLE_FMT => UInt32,
                                                   #AVUtil.AV_OPT_TYPE_VIDEO_RATE => Rational{Int32},
                                                   AVUtil.AV_OPT_TYPE_DURATION => Int64,
                                                   #AVUtil.AV_OPT_TYPE_COLOR => <needs to be decoded>,
                                                   #AVUtil.AV_OPT_TYPE_CHANNEL_LAYOUT => Int64
                                                   )


############

# getindex, get_opt

function av_isoption{T<:AVUtil._AVClass}(x::Ptr{T}, s)
    x == C_NULL && throw(ArgumentError("NULL pointer to $T"))

    p_av_opt = av_opt_find(x, string(s), C_NULL, 0, 0)
    return p_av_opt != C_NULL
end

function av_typeof_opt{T<:AVUtil._AVClass}(x::Ptr{T}, s)
    x == C_NULL && throw(ArgumentError("NULL pointer to $T"))

    p_av_opt = av_opt_find(x, string(s), C_NULL, 0, 0)
    p_av_opt == C_NULL && throw(ErrorException("\"$s\" not found in $T"))

    av_opt = unsafe_load(p_av_opt)

    return av_opt._type
end

function get_opt_string{T<:AVUtil._AVClass}(x::Ptr{T}, s)
    outval = Vector{Ptr{UInt8}}(1)
    ret = av_opt_get(x, string(s), 0, outval)
    ret < 0 && throw(ErrorException("Cannot get value for \"$s\" from object of type $T"))

    val = bytestring(outval[1])
    av_free(outval[1]) # free the returned string

    return val
end

get_opt_string(x::Ptr, s) = throw(ErrorException("$x must be a pointer to an AVClass enabled struct"))

get_opt{T}(x::Ptr, s, ::Type{Val{T}}) = get_opt_string(x, s)
#get_opt(x::Ptr, s, Val{AVUtil.AV_OPT_TYPE_STRING}) = get_opt_string(x, s)
#get_opt(x::Ptr, s, Val{AVUtil.AV_OPT_TYPE_SAMPLE_FMT}) = get_opt_string(x, s)
#get_opt(x::Ptr, s, Val{AVUtil.AV_OPT_TYPE_PIXEL_FMT}) = get_opt_string(x, s)
#get_opt(x::Ptr, s, Val{AVUtil.AV_OPT_TYPE_COLOR}) = get_opt_string(x, s)
#get_opt(x::Ptr, s, Val{AVUtil.AV_OPT_TYPE_CHANNEL_LAYOUT}) = get_opt_string(x, s)

typealias AV_RATIONAL Union(Val{AVUtil.AV_OPT_TYPE_RATIONAL},
                            Val{AVUtil.AV_OPT_TYPE_VIDEO_RATE})

function get_opt{T<:AV_RATIONAL}(x::Ptr, s, ::Type{T})
    val = get_opt_string(x, s)
    num, den = [parse(Int32, x) for x in split(val, '/')]
    return num//den
end

function get_opt(x::Ptr, s, ::Type{Val{AVUtil.AV_OPT_TYPE_IMAGE_SIZE}})
    val = get_opt_string(x, s)
    width, height = [parse(Int32, x) for x in split(val, 'x')]
    return (width, height)
end

function get_opt{T<:Real}(x::Ptr, s, ::Type{T})
    val = get_opt_string(x, s)
    return parse(T, val)
end


function Base.getindex{T<:AVUtil._AVClass}(x::Ptr{T}, s::String)
    x == C_NULL && throw(ArgumentError("NULL pointer to $T"))

    if !av_isoption(x, s)
        throw(ArgumentError("$s is not an option for type $T"))
    end

    # First, get the enum type defined by ffmpeg/libav
    av_type = av_typeof_opt(x, s)

    # See if there's a corresponding julia type, to use for dispatch
    # (defined above)
    # If not, wrap av_type in a Val
    S = get(av_opt_type2julia, av_type, Val{av_type})

    # Dispatch to the appropriate method
    return get_opt(x, s, S)
end

Base.getindex{T<:AVUtil._AVClass}(x::PPtr{T}, s::String) = getindex(x[], s)

## setindex!, set_opt!

function set_opt!{T<:AVUtil._AVClass}(x::Ptr{T}, v::String, s::String)
    ret = av_opt_set(x, s, v, 0)
    ret < 0 && throw(ErrorException("Cannot set value of \"$s\" to $v for type $T"))

    return v
end

set_opt!(x::Ptr, v, s) = throw(ErrorException("$s must be a pointer to an AVClass enabled struct"))

set_opt!{T<:Real}(x::Ptr, v, s, ::Type{T}) = set_opt!(x, string(v), string(s))
set_opt!{T<:Val}(x::Ptr, v, s, ::Type{T})  = set_opt!(x, string(v), string(s))

function set_opt!{T<:AV_RATIONAL}(x::Ptr, v, s, ::Type{T})
    set_str = replace(string(v), "//", "/")
    return set_opt!(x, set_str, string(s))
end

function set_opt!(x::Ptr, v, s, ::Type{Val{AVUtil.AV_OPT_TYPE_IMAGE_SIZE}})
    length(v) != 2 && throw(ArgumentError("Please pass width and height as a tuple when setting $s"))
    set_str = "$(v[1])x$(v[2])"
    return set_opt!(x, set_str, string(s))
end


function Base.setindex!{T<:AVUtil._AVClass}(x::Ptr{T}, v, s::String)
    x == C_NULL && throw(ArgumentError("NULL pointer to $T"))

    if !av_isoption(x, s)
        throw(ArgumentError("$s is not an option for type $T"))
    end

    # First, get the enum type defined by ffmpeg/libav
    av_type = av_typeof_opt(x, s)

    # See if there's a corresponding julia type, to use for dispatch
    # (defined above)
    # If not, wrap av_type in a Val
    S = get(av_opt_type2julia, av_type, Val{av_type})

    return set_opt!(x, v, s, S)
end

Base.setindex!{T<:AVUtil._AVClass}(x::PPtr{T}, v, s::String) = setindex!(x[], v, s)

##

function Base.keys{T<:AVUtil._AVClass}(x::Ptr{T})
    x == C_NULL && throw(ArgumentException("NULL pointer to $T"))

    ks = String[]
    p_av_opt = av_opt_next(x, C_NULL)

    while p_av_opt != C_NULL
        av_opt = unsafe_load(p_av_opt)

        if av_opt.offset != 0
            name = bytestring(av_opt.name)
            push!(ks, name)
        end

        p_av_opt = av_opt_next(x, p_av_opt)
    end

    return ks
end

Base.keys{T<:AVUtil._AVClass}(x::PPtr{T}) = keys(x[])

#type AVOption

function Base.show(io::IO, x::AVOption)
    println(io, "AVOption(", join([bytestring(x.name),
                                   x.help != C_NULL ? bytestring(x.help) : "",
                                   "offset=" * string(x.offset),
                                   "type=" * string(get(av_opt_type2julia, x._type, String)),
                                   "default=xxxx",
                                   "min=" * string(x.min),
                                   "max=" * string(x.max),
                                   "flags=" * string(x.flags),
                                   "unit=..."], ", "),
    ")")
end
