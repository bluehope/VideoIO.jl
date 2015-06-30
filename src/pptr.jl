# PPtr

"""
Wrapping a pointer to a pointer

This is a common form for storing ffmpeg/libav objects, and creating a class
allows for convenient creation, cleanup, and dispatch on the objects.

"""
type PPtr{T}
    pptr::Vector{Ptr{T}}

    PPtr() = new([reinterpret(Ptr{T}, C_NULL)])
    PPtr(p) = new(p)
end


PPtr{T}(p::Ptr{T}) = PPtr{T}([p])

"""
Dereference a PPtr

c = PPtr{AVFormatContext}([C_NULL])
c[] # -> C_NULL

"""
Base.getindex(c::PPtr) = c.pptr[1]


"""
Dereference and set a PPtr

x = pointer(AVFormatContext())
c[] = x # c.pptr[1] now contains x

"""
Base.setindex!(c::PPtr, x) = (c.pptr[1] = x)

##########
# The definitions below allow the conversion of PPtrs to appropriate types in ccall
##########
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


"""
Free the object referred to, and set the pointer to C_NULL

Uses av_freep by default.  av_freep takes a pointer to a pointer as input,
frees the object, and then writes NULL to the inner pointer value.

Should be overridden for specific wrapped types.

"""
function free(c::PPtr)
    @sigatomic av_freep(c)
end

"""
Returns true if a PPtr points to an object (i.e., isn't NULL)
"""
is_allocated(p::PPtr) = (p[] != C_NULL)

############
# Getting and setting fields of structs via pointer

_fieldnum{T}(::Type{T}, name::Symbol) = findfirst(fieldnames(T), name)
_fieldnum{T}( ::Ptr{T}, name)         = _fieldnum(T, name)

_isfield{T}( ::Type{T}, name)         = (_fieldnum(T, name) > 0)
_isfield{T}(  ::Ptr{T}, name)         = _isfield(T, name)

"""
Returns a pointer to field :name in an object of type T

"""
function _pointer_to_field{T}(s::Ptr{T}, name)
    field = _fieldnum(T, name)
    field == 0 && throw(ArgumentError("$name is not a field of $T"))

    byteoffset = fieldoffsets(T)[field]
    S = T.types[field]
    p = convert(Ptr{S}, s+byteoffset)

    return pointer_to_array(p,1)
end

"""
Get the value of field :name in the object pointed to by `p`
"""
function Base.getindex{T}(p::PPtr{T}, name::Symbol)
    p[] == C_NULL && throw(ArgumentError("NULL pointer to $T"))
    a = _pointer_to_field(p[], name)
    return a[1]
end


"""
Set the value of field :name to value in the object pointed to by `p`
"""
function Base.setindex!{T}(p::PPtr{T}, value, name::Symbol)
    p[] == C_NULL && throw(ArgumentError("NULL pointer to $T"))
    a = _pointer_to_field(p[], name)
    a[1] = convert(eltype(a), value)
    return value
end

############

"""
A plain old (malloc'ed) buffer

(Uses the default PPtr free() function above)
"""
typealias CBuffer PPtr{Void}

CBuffer() = CBuffer(C_NULL)
CBuffer(p::Ptr{Void}) = CBuffer([p])

function CBuffer(sz::Integer)
    ptr = av_malloc(sz)
    ptr == C_NULL && throw(ErrorException("Unable to allocate buffer (out of memory"))

    cb = CBuffer(ptr)
    finalizer(cb, free)
    cb
end

############

"""
Context (parameters) describing the format of an io stream
"""
typealias FormatContext PPtr{AVFormatContext}
FormatContext(p::Ptr{AVFormatContext}) = FormatContext([p])

function FormatContext()
    ptr = avformat_alloc_context()
    ptr == C_NULL && throw(ErrorException("Unable to allocate FormatContext (out of memory"))

    fc = FormatContext(ptr)
    finalizer(fc, free)
    fc
end

function free(c::FormatContext)
    @sigatomic begin
        if is_allocated(c)
            avformat_free_context(c[])
            c[] = C_NULL
        end
    end
end

############

"""
Context (parameters) describing the input/output details of an io stream
"""
typealias IOContext PPtr{AVIOContext}

IOContext() = IOContext(Ptr{AVIOContext}[C_NULL])
IOContext(p::Ptr{AVIOContext}) = IOContext([p])

function IOContext(bufsize::Integer, write_flag::Integer, opaque_ptr::Ptr, read_packet, write_packet, seek)
    # We allocate this buffer directly (and deallocate it below in free) because it has the possibility
    # of being resized while it's a member of an AVIOContext object
    pBuffer = av_malloc(bufsize)

    ptr = avio_alloc_context(pBuffer, bufsize, write_flag, opaque_ptr, read_packet, write_packet, seek)
    if ptr == C_NULL
        cbuf = CBuffer([pBuffer])
        free(cbuf)
        throw(ErrorException("Unable to allocate IOContext (out of memory"))
    end

    ioc = IOContext(ptr)
    finalizer(ioc, free)
    ioc
end

function free(c::IOContext)
    @sigatomic begin
        if is_allocated(c)
            # TODO: is Ref usable here?
            buf = [c[:buffer]]
            av_freep(pointer(buf))
            c[:buffer] = C_NULL
        end

        av_freep(c)
    end
end

#############

typealias Stream PPtr{AVStream}

Stream() = Stream(Ptr{AVStream}[C_NULL])
