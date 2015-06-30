# AVIO

import Base: read, read!, show, eof, isopen, seekstart

export read, read!, pump, openvideo, opencamera, playvideo, viewcam, play

abstract StreamContext

if isdefined(Main, :Color)
    typealias EightBitTypes Union(UInt8, Main.FixedPointNumbers.Ufixed8, Main.Color.RGB{Main.FixedPointNumbers.Ufixed8})
elseif isdefined(Main, :FixedPointNumbers)
    typealias EightBitTypes Union(UInt8, Main.FixedPointNumbers.Ufixed8)
else
    typealias EightBitTypes UInt8
end

type Packet
    p::Vector{AVPacket}
end

Packet() = Packet([AVPacket()])

# An audio-visual input stream/file
type MediaDecoder{I}
    io::I
    iocontext::IOContext
    format_context::FormatContext
    avio_ctx_buffer_size::Uint
    packet::Packet           # Reusable packet

    unknown_info::Vector{Stream}
    video_info::Vector{Stream}
    audio_info::Vector{Stream}
    data_info::Vector{Stream}
    subtitle_info::Vector{Stream}
    attachment_info::Vector{Stream}

    listening::Set{Int}
    stream_contexts::Vector{StreamContext}

    isopen::Bool
end

function MediaDecoder{T<:Union(IO, String)}(source::T, input_format=C_NULL; avio_ctx_buffer_size=65536)

    # Register all codecs and formats
    av_register_all()
    av_log_set_level(AVUtil.AV_LOG_ERROR)

    packet = Packet()
    format_context = FormatContext()
    iocontext = IOContext()

    # Allocate this object (needed to pass into AVIOContext in _openvideo)
    decoder = MediaDecoder{T}(source, iocontext, format_context, avio_ctx_buffer_size,
                              packet, [Stream[] for _=1:6]..., Set(Int[]), StreamContext[], false)

    # Set up the format context and open the input, based on the type of source
    _openvideo(decoder, source, input_format)
    decoder.isopen = true

    # Make sure we deallocate everything on exit
    finalizer(decoder, close)

    # Get the stream information
    fc = decoder.format_context
    if avformat_find_stream_info(fc[], C_NULL) < 0
        error("Unable to find stream information")
    end

    # Load streams, codec_contexts
    nb_streams = fc[:nb_streams]

    for i = 1:nb_streams
        stream = PPtr(unsafe_load(fc[:streams],i))
        codec_ctx = PPtr(stream[:codec])
        codec_type = codec_ctx[:codec_type]

        if codec_type == AVMEDIA_TYPE_VIDEO
            push!(decoder.video_info, stream)
        elseif codec_type == AVMEDIA_TYPE_AUDIO
            push!(decoder.audio_info, stream)
        elseif codec_type == AVMEDIA_TYPE_DATA
            push!(decoder.data_info, stream)
        elseif codec_type == AVMEDIA_TYPE_SUBTITLE
            push!(decoder.subtitle_info, stream)
        elseif codec_type == AVMEDIA_TYPE_ATTACHMENT
            push!(decoder.attachment_info, stream)
        elseif codec_type == AVMEDIA_TYPE_UNKNOWN
            push!(decoder.unknown_info, stream)
        end
    end

    resize!(decoder.stream_contexts, nb_streams)

    decoder
end



function show(io::IO, decoder::MediaDecoder)
    println(io, "MediaDecoder(", decoder.io, ", ...), with")
    (len = length(decoder.video_info))      > 0 && println(io, "  $len video stream(s)")
    (len = length(decoder.audio_info))      > 0 && println(io, "  $len audio stream(s)")
    (len = length(decoder.data_info))       > 0 && println(io, "  $len data stream(s)")
    (len = length(decoder.subtitle_info))   > 0 && println(io, "  $len subtitle stream(s)")
    (len = length(decoder.attachment_info)) > 0 && println(io, "  $len attachment stream(s)")
    (len = length(decoder.unknown_info))    > 0 && println(io, "  $len unknown stream(s)")
end



# type AudioContext <: StreamContext
#     stream::AVStream
#     codec_ctx::AVCodecContext

#     sample_format::Int
#     sample_rate::Int
#     #sample_bits::Int
#     channels::Int
# end

# type SubtitleContext <: StreamContext
#     stream::AVStream
#     codec_ctx::AVCodecContext
# end

# type DataContext <: StreamContext
#     stream::AVStream
#     codec_ctx::AVCodecContext
# end

# type AttachmentContext <: StreamContext
#     stream::AVStream
#     codec_ctx::AVCodecContext
# end

# type UnknownContext <: StreamContext
#     stream::AVStream
#     codec_ctx::AVCodecContext
# end

# Pump input for data
function pump(c::MediaDecoder)
    pFormatContext = c.format_context[]

    while true
        !c.isopen && break

        (@sigatomic av_read_frame(pFormatContext, c.packet.p)) < 0 && break

        packet = c.packet.p[1]
        stream_index = packet.stream_index

        # If we're not listening to this stream, skip it
        if stream_index in c.listening
            # Decode the packet, and check if the frame is complete
            frameFinished = decode_packet(c.stream_contexts[stream_index+1], c.packet)
            av_free_packet(c.packet.p)

            # If the frame is complete, we're done
            frameFinished && return stream_index
        else
            av_free_packet(c.packet.p)
        end
    end

    return -1
end

pump(r::StreamContext) = pump(r.decoder)

function _read_packet(pdecoder::Ptr{MediaDecoder}, pbuf::Ptr{UInt8}, buf_size::Cint)
    decoder = unsafe_pointer_to_objref(pdecoder)
    out = pointer_to_array(pbuf, (buf_size,))
    convert(Cint, readbytes!(decoder.io, out))
end

const read_packet = cfunction(_read_packet, Cint, (Ptr{MediaDecoder}, Ptr{UInt8}, Cint))

function _openvideo(decoder::MediaDecoder, io::IO, input_format=C_NULL)

    !isreadable(io) && error("IO not readable")

    # These allow control over how much of the stream to consume when
    # determining the stream type
    # TODO: Change these defaults if necessary, or allow user to set
    #av_opt_set(decoder.format_context[], "probesize", "100000000", 0)
    #av_opt_set(decoder.format_context[], "analyzeduration", "1000000", 0)

    decoder.iocontext = IOContext(decoder.avio_ctx_buffer_size, 0, pointer_from_objref(decoder),
                                  read_packet, C_NULL, C_NULL)

    # pFormatContext->pb = pAVIOContext
    decoder.format_context[:pb] = decoder.iocontext[]

    # "Open" the input
    if avformat_open_input(decoder.format_context, "dummy", input_format, C_NULL) != 0
        error("Unable to open input")
    end

    nothing
end

function _openvideo(decoder::MediaDecoder, source::String, input_format=C_NULL)
    if avformat_open_input(decoder.format_context,
                           source,
                           input_format,
                           C_NULL)    != 0
        error("Could not open file $source")
    end

    nothing
end



# Utility functions

# Not exported
open(filename::String) = MediaDecoder(filename)
openvideo(args...; kwargs...) = VideoContext(args...; kwargs...)

isopen{I<:IO}(decoder::MediaDecoder{I}) = isopen(decoder.io)
isopen(decoder::MediaDecoder) = decoder.isopen

function seekstart{T<:String}(decoder::MediaDecoder{T}, video_stream = 1)
    # AVFormatContext
    fc = decoder.format_context

    # Get stream information
    stream = decoder.video_info[video_stream]
    seek_stream_index = stream[:index]
    first_dts = stream[:first_dts]

    # Seek
    ret = avformat_seek_file(fc[], seek_stream_index, first_dts, first_dts, first_dts, AVSEEK_FLAG_BACKWARD)

    ret < 0 && throw(ErrorException("Could not seek to start of stream"))

    return decoder
end

## This doesn't work...
#seekstart{T<:IO}(decoder::MediaDecoder{T}, video_stream = 1) = seekstart(decoder.io)
seekstart{T<:IO}(decoder::MediaDecoder{T}, video_stream = 1) = throw(ErrorException("Sorry, Seeking is not supported for IO streams"))


function eof(decoder::MediaDecoder)
    !isopen(decoder) && return true
    have_frame(decoder) && return false
    got_frame = (pump(decoder) != -1)
    return !got_frame
end

function eof{I<:IO}(decoder::MediaDecoder{I})
    !isopen(decoder) && return true
    have_frame(decoder) && return false
    return eof(decoder.io)
end

# Free AVIOContext object when done
function Base.close(decoder::MediaDecoder)
    # Test and set isopen

    ## Within @sigatomic, we cannot define new variables (they're changed to gensyms)
    ## We do get the last value, however, and assign that to _isopen
    _isopen = @sigatomic begin
        __isopen = decoder.isopen
        decoder.isopen = false
        __isopen
    end

    !_isopen && return

    for i in decoder.listening
        _close(decoder.stream_contexts[i+1])
    end
    # Fix for segmentation fault issue #44
    empty!(decoder.listening)

    @sigatomic avformat_close_input(decoder.format_context.pptr)

    free(decoder.format_context)
    free(decoder.iocontext)
end
