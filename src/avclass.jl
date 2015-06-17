
abstract PPtr{T}
abstract AVClass{T} <: PPtr{T}

Base.getindex(c::PPtr) = c.pptr[1]
Base.setindex!(c::PPtr, x) = (c.pptr[1] = x)
Base.convert{T}(::Type{Ptr{Ptr{T}}}, c::PPtr) = convert(Ptr{Ptr{T}}, c.pptr)
Base.convert(::Type{Ptr{Void}}, c::PPtr) = convert(Ptr{Void}, c.pptr) # pointer(c.pptr)

function free(c::PPtr)
    Base.sigatomic_begin()
    av_freep(c)
    c[] = C_NULL
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
    if is_allocated(c)
        avformat_close_input(c.pptr)
        c[] = C_NULL
    end
    Base.sigatomic_end()
end

############

type IOContext <: AVClass{AVIOContext}
    pptr::Vector{Ptr{AVIOContext}}
    buffer::CBuffer
end

IOContext() = IOContext(Ptr{AVIOContext}[C_NULL], CBuffer())

function IOContext(bufsize::Integer, write_flag::Integer, opaque_ptr::Ptr, read_packet, write_packet, seek)
    buffer = CBuffer(bufsize)

    ptr = avio_alloc_context(buffer[], bufsize, write_flag, opaque_ptr, read_packet, write_packet, seek)
    if ptr == C_NULL
        free(buffer)
        throw(ErrorException("Unable to allocate IOContext (out of memory"))
    end

    ioc = IOContext([ptr], buffer)
    finalizer(ioc, free)
    ioc
end

function free(c::IOContext)
    #free(c.buffer)
    Base.sigatomic_begin()
    av_freep(c)
    c[] = C_NULL
    Base.sigatomic_end()
end

#type AVStream
