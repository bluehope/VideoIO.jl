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


##

@doc doc"""
   Wrapping a pointer to a pointer

   This is a common form for storing ffmpeg/libav objects, and creating a class
   allows for convenient creation, cleanup, and dispatch on the objects.

""" ->
type PPtr{T}
    pptr::Vector{Ptr{T}}

    PPtr() = new([reinterpret(Ptr{T}, C_NULL)])
    PPtr(p) = new(p)
end

Base.getindex(c::PPtr) = c.pptr[1]
Base.setindex!(c::PPtr, x) = (c.pptr[1] = x)
if VERSION < v"0.4.0-"
    Base.convert{T}(::Type{Ptr{T}}, c::PPtr{T}) = Base.convert(Ptr{Ptr{T}}, c[])
    Base.convert{T}(::Type{Ptr{Ptr{T}}}, c::PPtr) = Base.convert(Ptr{Ptr{T}}, pointer(c.pptr))
    Base.convert(::Type{Ptr{Void}}, c::PPtr) = Base.convert(Ptr{Void}, pointer(c.pptr))
else
    Base.convert{T}(::Type{Ptr{T}}, c::PPtr{T}) = Base.unsafe_convert(Ptr{Ptr{T}}, c[])
    Base.convert{T}(::Type{Ptr{Ptr{T}}}, c::PPtr) = Base.unsafe_convert(Ptr{Ptr{T}}, pointer(c.pptr))
    Base.convert(::Type{Ptr{Void}}, c::PPtr) = Base.unsafe_convert(Ptr{Void}, pointer(c.pptr))

    Base.unsafe_convert{T}(::Type{Ptr{T}}, c::PPtr{T}) = Base.unsafe_convert(Ptr{Ptr{T}}, c[])
    Base.unsafe_convert{T}(::Type{Ptr{Ptr{T}}}, c::PPtr) = Base.unsafe_convert(Ptr{Ptr{T}}, pointer(c.pptr))
    Base.unsafe_convert(::Type{Ptr{Void}}, c::PPtr) = Base.unsafe_convert(Ptr{Void}, pointer(c.pptr))
end

@doc doc"""
  Free the object referred to, and set the pointer to C_NULL

  Uses av_free by default; should be overridden for specific wrapped types.
""" ->
function free(c::PPtr)
    Base.sigatomic_begin()
    av_freep(c)
    Base.sigatomic_end()
end

is_allocated(p::PPtr) = (p[] != C_NULL)


############

# getindex, get_opt


function av_typeof{T<:AVUtil._AVClass}(x::Ptr{T}, s)
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

get_opt(x::Ptr, s, ::Type{Val}) = get_opt_string(x, s)
#get_opt(x::Ptr, s, Val{AVUtil.AV_OPT_TYPE_STRING}) = get_opt_string(x, s)
#get_opt(x::Ptr, s, Val{AVUtil.AV_OPT_TYPE_SAMPLE_FMT}) = get_opt_string(x, s)
#get_opt(x::Ptr, s, Val{AVUtil.AV_OPT_TYPE_PIXEL_FMT}) = get_opt_string(x, s)
#get_opt(x::Ptr, s, Val{AVUtil.AV_OPT_TYPE_COLOR}) = get_opt_string(x, s)
#get_opt(x::Ptr, s, Val{AVUtil.AV_OPT_TYPE_CHANNEL_LAYOUT}) = get_opt_string(x, s)

function get_opt(x::Ptr, s, ::Type{Union(Val{AVUtil.AV_OPT_TYPE_RATIONAL},
                                                 Val{AVUtil.AV_OPT_TYPE_VIDEO_RATE})})
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


function Base.getindex{T<:AVUtil._AVClass}(x::Ptr{T}, s)
    x == C_NULL && throw(ArgumentError("NULL pointer to $T"))

    # First, get the enum type defined by ffmpeg/libav
    av_type = av_typeof(x, s)

    # See if there's a corresponding julia type, to use for dispatch
    # (defined above)
    # If not, wrap av_type in a Val
    S = get(av_opt_type2julia, av_type, Val{av_type})

    # Dispatch to the appropriate method
    return get_opt(x, s, S)
end

Base.getindex{T<:AVUtil._AVClass}(x::PPtr{T}, s) = getindex(x[], s)

## setindex!, set_opt!

function set_opt!{T<:AVUtil._AVClass}(x::Ptr{T}, v::String, s::String)
    ret = av_opt_set(x, s, v, 0)
    ret < 0 && throw(ErrorException("Cannot set value of \"$s\" to $v for type $T"))

    return v
end

set_opt!(x::Ptr, v, s) = throw(ErrorException("$s must be a pointer to an AVClass enabled struct"))

set_opt!{T<:Real}(x::Ptr, v, s, ::Type{T}) = set_opt!(x, string(v), string(s))
set_opt!{T<:Val}(x::Ptr, v, s, ::Type{T})  = set_opt!(x, string(v), string(s))

function set_opt!(x::Ptr, v, s, ::Type{Union(Val{AVUtil.AV_OPT_TYPE_RATIONAL},
                                                     Val{AVUtil.AV_OPT_TYPE_VIDEO_RATE})})
    set_str = replace(string(v), "//", "/")
    return set_opt!(x, set_str, string(s))
end

function set_opt!(x::Ptr, v, s, ::Type{Val{AVUtil.AV_OPT_TYPE_IMAGE_SIZE}})
    length(v) != 2 && throw(ArgumentError("Please pass width and height as a tuple when setting $s"))
    set_str = "$(v[1])x$(v[2])"
    return set_opt!(x, set_str, string(s))
end


function Base.setindex!{T<:AVUtil._AVClass}(x::Ptr{T}, v, s)
    # First, get the enum type defined by ffmpeg/libav
    av_type = av_typeof(x, s)

    # See if there's a corresponding julia type, to use for dispatch
    # (defined above)
    # If not, wrap av_type in a Val
    S = get(av_opt_type2julia, av_type, Val{av_type})

    return set_opt!(x, v, s, S)
end

Base.setindex!{T<:AVUtil._AVClass}(x::PPtr{T}, v, s) = setindex!(x[], v, s)

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


############

typealias CBuffer PPtr{Void}

CBuffer() = CBuffer([C_NULL])

function CBuffer(sz::Integer)
    ptr = av_malloc(sz)
    ptr == C_NULL && throw(ErrorException("Unable to allocate buffer (out of memory"))

    cb = CBuffer([ptr])
    finalizer(cb, free)
    cb
end

############

typealias FormatContext PPtr{AVFormatContext}

function FormatContext()
    ptr = avformat_alloc_context()
    ptr == C_NULL && throw(ErrorException("Unable to allocate FormatContext (out of memory"))

    av_opt_set_defaults(ptr)
    fc = FormatContext([ptr])
    finalizer(fc, free)
    fc
end

function free(c::FormatContext)
    Base.sigatomic_begin()
    is_allocated(c) && avformat_close_input(c.pptr)
    c[] = C_NULL
    Base.sigatomic_end()
end

############

typealias IOContext PPtr{AVIOContext}

IOContext() = IOContext(Ptr{AVIOContext}[C_NULL])

function IOContext(bufsize::Integer, write_flag::Integer, opaque_ptr::Ptr, read_packet, write_packet, seek, finalize::Bool = true)
    pBuffer = av_malloc(bufsize)

    ptr = avio_alloc_context(pBuffer, bufsize, write_flag, opaque_ptr, read_packet, write_packet, seek)
    if ptr == C_NULL
        cbuf = CBuffer([pBuffer])
        free(cbuf)
        throw(ErrorException("Unable to allocate IOContext (out of memory"))
    end

    ioc = IOContext([ptr])
    finalize && finalizer(ioc, free)
    ioc
end

function free(c::IOContext)
    Base.sigatomic_begin()
    if is_allocated(c)
        buf = [av_getfield(c[], :buffer)]
        av_freep(pointer(buf))
    end

    av_freep(c)
    Base.sigatomic_end()
end

#############

#type AVStream

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
