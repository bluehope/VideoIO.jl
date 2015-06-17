
abstract PPtr{T}
abstract AVClass{T} <: PPtr{T}

Base.getindex(c::PPtr) = c.pptr[1]
Base.setindex!(c::PPtr, x) = (c.pptr[1] = x)
if VERSION < v"0.4.0"
    Base.convert{T}(::Type{Ptr{Ptr{T}}}, c::PPtr) = Base.convert(Ptr{Ptr{T}}, pointer(c.pptr))
    Base.convert(::Type{Ptr{Void}}, c::PPtr) = Base.convert(Ptr{Void}, pointer(c.pptr))
else
    Base.unsafe_convert{T}(::Type{Ptr{Ptr{T}}}, c::PPtr) = Base.unsafe_convert(Ptr{Ptr{T}}, pointer(c.pptr))
    Base.unsafe_convert(::Type{Ptr{Void}}, c::PPtr) = Base.unsafe_convert(Ptr{Void}, pointer(c.pptr))
end

function free(c::PPtr)
    Base.sigatomic_begin()
    av_freep(c)
    Base.sigatomic_end()
end

is_allocated(p::PPtr) = (p[] != C_NULL)

type CBuffer <: PPtr{Void}
    pptr::Vector{Ptr{Void}}
end

CBuffer() = CBuffer([C_NULL])

function CBuffer(sz::Integer)
    ptr = av_malloc(sz)
    ptr == C_NULL && throw(ErrorException("Unable to allocate buffer (out of memory"))

    cb = CBuffer([ptr])
    finalizer(cb, free)
    cb
end

############

type FormatContext <: AVClass{AVFormatContext}
    pptr::Vector{Ptr{AVFormatContext}}
end

function FormatContext()
    ptr = avformat_alloc_context()
    ptr == C_NULL && throw(ErrorException("Unable to allocate FormatContext (out of memory"))

    fc = FormatContext([ptr])
    finalizer(fc, free)
    fc
end

function free(c::FormatContext)
    Base.sigatomic_begin()
    is_allocated(c) && avformat_close_input(c.pptr)
    Base.sigatomic_end()
end

############

type IOContext <: AVClass{AVIOContext}
    pptr::Vector{Ptr{AVIOContext}}
end

IOContext() = IOContext(Ptr{AVIOContext}[C_NULL])

function IOContext(bufsize::Integer, write_flag::Integer, opaque_ptr::Ptr, read_packet, write_packet, seek)
    pBuffer = av_malloc(bufsize)

    ptr = avio_alloc_context(pBuffer, bufsize, write_flag, opaque_ptr, read_packet, write_packet, seek)
    if ptr == C_NULL
        cbuf = CBuffer([pBuffer])
        free(cbuf)
        throw(ErrorException("Unable to allocate IOContext (out of memory"))
    end

    ioc = IOContext([ptr])
    finalizer(ioc, free)
    ioc
end

function free(c::IOContext)
    if is_allocated(c)
        cbuf = CBuffer([av_getfield(c, :buffer)])
        free(cbuf)
    end
    
    Base.sigatomic_begin()
    av_freep(c)
    Base.sigatomic_end()
end

#############

#type AVStream
