
abstract PPtr{T}
abstract AVClass{T} <: PPtr{T}

getindex(c::PPtr) = c.pptr[1]
setindex!(c::PPtr, x) = (c.pptr[1] = x)
Base.convert{T}(::Type{Ptr{Ptr{T}}}, c::PPtr{T}) = pointer(c.pptr)
Base.convert{T}(::Type{Ptr{T}}, c::PPtr{T}) = c[]

function free(c::PPtr)
    Base.sigatomic_begin()
    av_freep(c)
    Base.sigatomic_end()
end

is_allocated(p::PPtr) = (p[] != C_NULL)

type CBuffer <: PPtr{Void}
    pptr::Vector{Ptr{Void}}
end

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
end

IOContext() = IOContext(Ptr{AVIOContext}[C_NULL])

function IOContext(bufsize::Integer, write_flag::Integer, opaque_ptr::Ptr, read_packet, write_packet, seek)
    buffer = av_malloc(bufsize)
    buffer == C_NULL && throw(ErrorException("Unable to allocate buffer (out of memory)"))

    ptr = avio_alloc_context(buffer, bufsize, write_flag, opaque_ptr, read_packet, write_packet, seek)
    if ptr == C_NULL
        pBuffer = [buffer]
        av_freep(pBuffer)
        throw(ErrorException("Unable to allocate IOContext (out of memory"))
    end

    ioc = IOContext([ptr])
    finalizer(ioc, free)
    ioc
end

function free(c::IOContext)
    Base.sigatomic_begin()
    pBuffer = [c.buffer]
    av_freep(pBuffer)
    av_freep(c)
    Base.sigatomic_end()
end

#type AVStream
