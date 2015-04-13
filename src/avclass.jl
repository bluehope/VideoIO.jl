
abstract PPtr{T}
abstract AVClass{T} <: PPtr{T}

*(c::PPtr) = c.pptr[1]
Base.convert{T}(::Type{Ptr{Ptr{T}}}, c::PPtr{T}) = pointer(c.pptr)
Base.convert{T}(::Type{Ptr{T}}, c::PPtr{T}) = c.pptr[1]

function free(c::PPtr)
    Base.sigatomic_begin()
    av_freep(c)
    Base.sigatomic_end()
end

is_allocated(p::PPtr) = p.pptr[1] != C_NULL

type CBuffer <: PPtr{Void}
    pptr::Vector{Ptr{Void}}
end

function CBuffer(sz::Integer)
    ptr = av_malloc(sz)
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
    fc = FormatContext([ptr])
    finalizer(fc, free)
    fc
end

function free(c::FormatContext)
    Base.sigatomic_begin()
    if is_allocated(c)
        avformat_close_input(c.pptr)
        c.pptr[1] = C_NULL
    end
    Base.sigatomic_end()
end

############

type IOContext <: AVClass{AVIOContext}
    pptr::Vector{Ptr{AVIOContext}}
end

function IOContext(buffer::Ptr, bufsize::Integer, write_flag::Integer, opaque_ptr::Ptr, read_packet, write_packet, seek)
    ptr = avio_alloc_context(buffer, bufsize, write_flag, opaque_ptr, read_packet, write_packet, seek)
    ioc = IOContext([ptr])
    finalizer(ioc, free)
end

#type AVStream
