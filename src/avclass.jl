
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

    pptr = [ptr]
    cb = CBuffer(pptr)
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

function IOContext(buffer::Ptr, bufsize::Integer, write_flag::Integer, opaque_ptr::Ptr, read_packet, write_packet, seek)
    ptr = avio_alloc_context(buffer, bufsize, write_flag, opaque_ptr, read_packet, write_packet, seek)
    ptr == C_NULL && throw(ErrorException("Unable to allocate IOContext (out of memory"))

    ioc = IOContext([ptr])
    finalizer(ioc, free)
    ioc
end

#type AVStream
