# AVIO

#import Base: read, read!, show, close, eof, isopen, seekstart
import Base: read, read!, show, eof, isopen, seekstart

export read, read!, pump, openvideo, opencamera, playvideo, viewcam, play

type StreamInfo
    stream_index0::Int             # zero-based
    stream::AVStream
    codec_ctx::AVCodecContext
end

abstract StreamContext

if isdefined(Main, :Color)
    typealias EightBitTypes Union(UInt8, Main.FixedPointNumbers.Ufixed8, Main.Color.RGB{Main.FixedPointNumbers.Ufixed8})
elseif isdefined(Main, :FixedPointNumbers)
    typealias EightBitTypes Union(UInt8, Main.FixedPointNumbers.Ufixed8)
else
    typealias EightBitTypes UInt8
end

# An audio-visual input stream/file
type MediaInput{I}
    io::I
    format_context::FormatContext
    iocontext::IOContext
    avio_ctx_buffer_size::Uint
    aPacket::Vector{AVPacket}           # Reusable packet

    unknown_info::Vector{StreamInfo}
    video_info::Vector{StreamInfo}
    audio_info::Vector{StreamInfo}
    data_info::Vector{StreamInfo}
    subtitle_info::Vector{StreamInfo}
    attachment_info::Vector{StreamInfo}

    listening::IntSet
    stream_contexts::Vector{StreamContext}

    isopen::Bool
end


function show(io::IO, avin::MediaInput)
    println(io, "MediaInput(", avin.io, ", ...), with")
    (len = length(avin.video_info))      > 0 && println(io, "  $len video stream(s)")
    (len = length(avin.audio_info))      > 0 && println(io, "  $len audio stream(s)")
    (len = length(avin.data_info))       > 0 && println(io, "  $len data stream(s)")
    (len = length(avin.subtitle_info))   > 0 && println(io, "  $len subtitle stream(s)")
    (len = length(avin.attachment_info)) > 0 && println(io, "  $len attachment stream(s)")
    (len = length(avin.unknown_info))    > 0 && println(io, "  $len unknown stream(s)")
end


immutable Packed{M} end

ImagePixelType(::Val) = Packed{0}()
ImagePixelType(::Val{AV_PIX_FMT_GRAY8})   = Packed{1}()
#ImagePixelType(::Val{AV_PIX_FMT_GRAY8A})  = Packed{2}() # not defined for libav
ImagePixelType(::Val{AV_PIX_FMT_Y400A})   = Packed{2}()  # same as GRAY8A
ImagePixelType(::Val{AV_PIX_FMT_RGB24})   = Packed{3}()
ImagePixelType(::Val{AV_PIX_FMT_BGR24})   = Packed{3}()
ImagePixelType(::Val{AV_PIX_FMT_RGBA})    = Packed{4}()
ImagePixelType(::Val{AV_PIX_FMT_BGRA})    = Packed{4}()
ImagePixelType(::Val{AV_PIX_FMT_ARGB})    = Packed{4}()
ImagePixelType(::Val{AV_PIX_FMT_ABGR})    = Packed{4}()
ImagePixelType(::Val{AV_PIX_FMT_0RGB})    = Packed{4}()
ImagePixelType(::Val{AV_PIX_FMT_0BGR})    = Packed{4}()
ImagePixelType(::Val{AV_PIX_FMT_RGB0})    = Packed{4}()
ImagePixelType(::Val{AV_PIX_FMT_BGR0})    = Packed{4}()

type VideoFrame{FORMAT,B<:AbstractArray}
    frame::Vector{AVFrame}
    buffer::B
    format::AVPixelFormat
    width::Cint
    height::Cint
    initialized::Bool
end

function VideoFrame(format::Cint, width, height, args...)
    fmt = Val{format}()
    v = ImagePixelType(fmt)
    numBytes = avpicture_get_size(format, width, height)

    VideoFrame(fmt, v, numBytes, width, height, args...)
end

function VideoFrame{M}(format::Val, ::Packed{M}, numBytes::Integer, width, height)
    if M == 0
        buffer = Array(UInt8, numBytes)         # Array{UInt8}(numBytes)
    elseif M == 1
        buffer = Array(UInt8, width, height)    # Array{UInt8}(width, height)
    else
        buffer = Array(UInt8, M, width, height) # Array{UInt8}(M, width, height)
    end
    VideoFrame(format, numBytes, width, height, buffer)
end


# We could get the
function VideoFrame{T,B}(::Val{T}, numBytes::Integer, width, height, buffer::B)
    if sizeof(buffer) != numBytes
        throw(ArgumentError("Buffer is the wrong size!  Got $(sizeof(buffer)), expected $numBytes."))
    end

    frame = [AVFrame()]
    avpicture_fill(pointer(frame), buffer, T, width, height)

    return VideoFrame{T,B}(frame, buffer, T, width, height, true)
end


function copy(vf::VideoFrame)
    if !vf.initialized
        throw(ErrorException("VideoFrame wasn't initialized with a buffer size.  Please report this error"))
    end
    new_buf = copy(vf.buffer)
    return VideoFrame(vf.format, vf.width, vf.height, new_buf)
end


type VideoTranscodeContext
    source_format::AVPixelFormat
    source_width::Cint
    source_height::Cint

    dest_format::AVPixelFormat
    dest_width::Cint
    dest_height::Cint

    interpolation::Cint

    transcode_context::Ptr{SwsContext}
end


function VideoTranscodeContext(source_format, dest_format, width::Integer, height::Integer;
                               scale = 1.0, interpolation = SWS_BILINEAR)

    dest_width = round(Cint, width*scale)
    dest_height = round(Cint, height*scale)

    sws_context = sws_getContext(width,
                                 height,
                                 source_format,
                                 dest_width,
                                 dest_height,
                                 dest_format,
                                 interpolation, C_NULL, C_NULL, C_NULL)

    return VideoTranscodeContext(source_format, width, height, dest_format, dest_width, dest_height, interpolation, sws_context)
end


function transcode(source_frame::VideoFrame, dest_frame::VideoFrame, context::VideoTranscodeContext)
    source_buffers = dataBufferPtrs(source_frame)
    source_line_sizes = lineSizes(source_frame)

    dest_buffers = dataBufferPtrs(dest_frame)
    dest_line_sizes = lineSizes(dest_frame)

    Base.sigatomic_begin()
    sws_scale(context.transcode_context,
              source_buffers,
              source_line_sizes,
              zero(Int32),
              source_frame.height,
              dest_buffers,
              dest_line_sizes)
    Base.sigatomic_end()
end

dataBufferPtrs(vf::VideoFrame) = reinterpret(Ptr{UInt8}, [vf.frame[1].data])
lineSizes(vf::VideoFrame) = reinterpret(Cint, [vf.frame[1].linesize])

type VideoReader{S,T,N,M} <: StreamContext
    avin::MediaInput
    stream_info::StreamInfo

    stream_index0::Int
    pVideoCodecContext::Ptr{AVCodecContext}
    pVideoCodec::Ptr{AVCodec}
    aFrameFinished::Vector{Int32}

    videoFrame::VideoFrame{S,N}   # Reusable frame
    transcoded_frame::VideoFrame{T,M}

    format::Cint
    width::Cint
    height::Cint
    framerate::Rational
    aspect_ratio::Rational

    frame_queue::Vector{VideoFrame{S,N}}
    transcodeContext::VideoTranscodeContext
end

show(io::IO, vr::VideoReader) = print(io, "VideoReader(...)")

# type AudioContext <: StreamContext
#     stream_index0::Int             # zero-based
#     stream::AVStream
#     codec_ctx::AVCodecContext

#     sample_format::Int
#     sample_rate::Int
#     #sample_bits::Int
#     channels::Int
# end

# type SubtitleContext <: StreamContext
#     stream_index0::Int             # zero-based
#     stream::AVStream
#     codec_ctx::AVCodecContext
# end

# type DataContext <: StreamContext
#     stream_index0::Int             # zero-based
#     stream::AVStream
#     codec_ctx::AVCodecContext
# end

# type AttachmentContext <: StreamContext
#     stream_index0::Int             # zero-based
#     stream::AVStream
#     codec_ctx::AVCodecContext
# end

# type UnknownContext <: StreamContext
#     stream_index0::Int             # zero-based
#     stream::AVStream
#     codec_ctx::AVCodecContext
# end

# Pump input for data
function pump(c::MediaInput)
    pFormatContext = c.format_context[]

    while true
        !c.isopen && break

        Base.sigatomic_begin()
        av_read_frame(pFormatContext, pointer(c.aPacket)) < 0 && break
        Base.sigatomic_end()

        packet = c.aPacket[1]
        stream_index = packet.stream_index

        # If we're not listening to this stream, skip it
        if stream_index in c.listening
            # Decode the packet, and check if the frame is complete
            frameFinished = decode_packet(c.stream_contexts[stream_index+1], c.aPacket)
            av_free_packet(pointer(c.aPacket))

            # If the frame is complete, we're done
            frameFinished && return stream_index
        else
            av_free_packet(pointer(c.aPacket))
        end
    end

    return -1
end

pump(r::StreamContext) = pump(r.avin)

function _read_packet(pavin::Ptr{MediaInput}, pbuf::Ptr{UInt8}, buf_size::Cint)
    avin = unsafe_pointer_to_objref(pavin)
    out = pointer_to_array(pbuf, (buf_size,))
    convert(Cint, readbytes!(avin.io, out))
end

const read_packet = cfunction(_read_packet, Cint, (Ptr{MediaInput}, Ptr{UInt8}, Cint))

function _openvideo(avin::MediaInput, io::IO, input_format=C_NULL)

    !isreadable(io) && error("IO not readable")

    # These allow control over how much of the stream to consume when
    # determining the stream type
    # TODO: Change these defaults if necessary, or allow user to set
    #av_opt_set(avin.format_context[], "probesize", "100000000", 0)
    #av_opt_set(avin.format_context[], "analyzeduration", "1000000", 0)

    avin.iocontext = IOContext(avin.avio_ctx_buffer_size, 0, pointer_from_objref(avin),
                               read_packet, C_NULL, C_NULL, false)

    # pFormatContext->pb = pAVIOContext
    av_setfield!(avin.format_context[], :pb, avin.iocontext[])
    println("getfield: ", av_getfield(avin.format_context[], :pb))
    println("iocontext: ", avin.iocontext[])

    # "Open" the input
    if avformat_open_input(avin.format_context, "dummy", input_format, C_NULL) != 0
        error("Unable to open input")
    end

    nothing
end

function _openvideo(avin::MediaInput, source::String, input_format=C_NULL)
    if avformat_open_input(avin.format_context.pptr,
                           source,
                           input_format,
                           C_NULL)    != 0
        error("Could not open file $source")
    end

    nothing
end

function MediaInput{T<:Union(IO, String)}(source::T, input_format=C_NULL; avio_ctx_buffer_size=65536)

    # Register all codecs and formats
    av_register_all()
    av_log_set_level(AVUtil.AV_LOG_ERROR)

    aPacket = [AVPacket()]
    format_context = FormatContext()
    iocontext = IOContext()

    # Allocate this object (needed to pass into AVIOContext in _openvideo)
    avin = MediaInput{T}(source, format_context, iocontext, avio_ctx_buffer_size,
                      aPacket, [StreamInfo[] for _=1:6]..., IntSet(), StreamContext[], false)

    # Make sure we deallocate everything on exit
    # TODO: this currently crashes!
    #finalizer(avin, close)

    # Set up the format context and open the input, based on the type of source
    _openvideo(avin, source, input_format)
    avin.isopen = true

    # Get the stream information
    if avformat_find_stream_info(avin.format_context[], C_NULL) < 0
        error("Unable to find stream information")
    end

    # Load streams, codec_contexts
    avFormatContext = unsafe_load(avin.format_context[]);

    for i = 1:avFormatContext.nb_streams
        pStream = unsafe_load(avFormatContext.streams,i)
        stream = unsafe_load(pStream)
        codec_ctx = unsafe_load(stream.codec)
        codec_type = codec_ctx.codec_type

        stream_info = StreamInfo(i-1, stream, codec_ctx)

        if codec_type == AVMEDIA_TYPE_VIDEO
            push!(avin.video_info, stream_info)
        elseif codec_type == AVMEDIA_TYPE_AUDIO
            push!(avin.audio_info, stream_info)
        elseif codec_type == AVMEDIA_TYPE_DATA
            push!(avin.data_info, stream_info)
        elseif codec_type == AVMEDIA_TYPE_SUBTITLE
            push!(avin.subtitle_info, stream_info)
        elseif codec_type == AVMEDIA_TYPE_ATTACHMENT
            push!(avin.attachment_info, stream_info)
        elseif codec_type == AVMEDIA_TYPE_UNKNOWN
            push!(avin.unknown_info, stream_info)
        end
    end

    resize!(avin.stream_contexts, avFormatContext.nb_streams)

    avin
end


function VideoReader(avin::MediaInput, video_stream=1;
                     target_format=PIX_FMT_RGB24,
                     transcode::Bool=true,
                     transcode_interpolation=SWS_BILINEAR)

    1 <= video_stream <= length(avin.video_info) || error("video stream $video_stream not found")

    stream_info = avin.video_info[video_stream]

    # Get basic stream info
    pVideoCodecContext = stream_info.stream.codec
    codecContext = stream_info.codec_ctx

    width, height = codecContext.width, codecContext.height
    pix_fmt = codecContext.pix_fmt
    pix_fmt < 0 && error("Unknown pixel format")

    framerate = codecContext.time_base.den // codecContext.time_base.num
    aspect_ratio = codecContext.sample_aspect_ratio.num // codecContext.sample_aspect_ratio.den

    # Find the decoder for the video stream
    pVideoCodec = avcodec_find_decoder(codecContext.codec_id)
    pVideoCodec == C_NULL && error("Unsupported Video Codec")

    # Open the decoder
    avcodec_open2(pVideoCodecContext, pVideoCodec, C_NULL) < 0 && error("Could not open codec")

    videoFrame = VideoFrame(pix_fmt, width, height)
    aFrameFinished = Cint[0]

    # # Set up transcoding
    # # TODO: this should be optional

    pFmtDesc = av_pix_fmt_desc_get(target_format)
    bits_per_pixel = av_get_bits_per_pixel(pFmtDesc)

    transcodeContext = VideoTranscodeContext(pix_fmt, target_format, width, height,
                                             interpolation = transcode_interpolation)
    transcoded_frame = VideoFrame(target_format, width, height)

    vr = VideoReader(avin,
                     stream_info,

                     stream_info.stream_index0,
                     pVideoCodecContext,
                     pVideoCodec,
                     aFrameFinished,

                     videoFrame,
                     transcoded_frame,

                     pix_fmt,
                     width,
                     height,
                     framerate,
                     aspect_ratio,

                     typeof(videoFrame)[],
                     transcodeContext)

    idx0 = stream_info.stream_index0
    push!(avin.listening, idx0)
    avin.stream_contexts[idx0+1] = vr

    vr
end

VideoReader{T<:Union(IO, String)}(s::T, args...; kwargs...) = VideoReader(MediaInput(s), args...; kwargs... )

function decode_packet(r::VideoReader, aPacket)
    # Do we already have a complete frame that hasn't been consumed?
    if have_decoded_frame(r)
        push!(r.frame_queue, copy(r.videoFrame))
        reset_frame_flag!(r)
    end

    avcodec_decode_video2(r.pVideoCodecContext,
                          r.videoFrame.frame,
                          r.aFrameFinished,
                          aPacket)

    return have_decoded_frame(r)
end

"Retrieve a raw video frame"
function retrieve{S}(r::VideoReader{S,S}) # don't transcode
    dest_video_frame = VideoFrame(r.format, r.width, r.height)
    retrieve!(r, dest_video_frame)
    return dest_video_frame.buffer
end

"Retrieve a raw video frame into the given buffer"
function retrieve!{S,T<:EightBitTypes}(r::VideoReader{S,S}, buf::AbstractArray{T})
    if pointer(buf) != pointer(r.video_frame.buffer)
        dest_video_frame = VideoFrame(r.format, r.width, r.height, buf)
    else
        dest_video_frame = r.video_frame
    end

    retrieve!(r, dest_video_frame)

    return buf
end

"Retrieve a raw video frame into the given video frame object"
function retrieve!{S}(r::VideoReader{S,S}, dest_video_frame::VideoFrame)
    if r.videoFrame != dest_video_frame
        r.videoFrame = dest_video_frame
    end

    while !have_frame(r)
        idx = pump(r.avin)
        idx == r.stream_index0 && break
        idx == -1 && throw(EOFError())
    end

    # Raw frame is now in dest_video_frame
    return dest_video_frame
end


# Converts a grabbed frame to the correct format (RGB by default)

"Retrieve and return a transcoded a video frame"
function retrieve(r::VideoReader)
    t = r.transcodeContext
    dest_video_frame = VideoFrame(t.dest_format, t.dest_width, t.dest_height)
    retrieve!(r, dest_video_frame)
    return dest_video_frame.buffer
end

"Retrieve and transcode a video frame, placing the result in the given buffer"
function retrieve!{T<:EightBitTypes}(r::VideoReader, buf::AbstractArray{T})
    t = r.transcodeContext

    # This is a pointer comparison because the passed in array might be a wrapper
    # around UInt8 data (e.g., an array of RGB{Ufixed8}), but might point to the same
    # data
    if pointer(buf) != pointer(r.transcoded_frame.buffer)
        dest_video_frame = VideoFrame(t.dest_format, t.dest_width, t.dest_height, buf)
    else
        dest_video_frame = r.transcoded_frame
    end

    retrieve!(r, dest_video_frame)

    return buf
end

"Retrieve and transcode a video frame into the given VideoFrame"
function retrieve!(r::VideoReader, dest_frame::VideoFrame)
    while !have_frame(r)
        idx = pump(r.avin)
        idx == r.stream_index0 && break
        idx == -1 && throw(EOFError())
    end

    source_frame = isempty(r.frame_queue) ? r.videoFrame : shift!(r.frame_queue)
    transcode(source_frame, dest_frame, r.transcodeContext)

    r.transcoded_frame = dest_frame

    reset_frame_flag!(r)

    return dest_frame
end


# Utility functions

# Not exported
open(filename::String) = MediaInput(filename)
openvideo(args...; kwargs...) = VideoReader(args...; kwargs...)

read(r::VideoReader) = retrieve(r)
read!{T<:EightBitTypes}(r::VideoReader, buf::AbstractArray{T}) = retrieve!(r, buf)

isopen{I<:IO}(avin::MediaInput{I}) = isopen(avin.io)
isopen(avin::MediaInput) = avin.isopen
isopen(r::VideoReader) = isopen(r.avin)

bufsize_check{S,T<:EightBitTypes}(r::VideoReader{S,S}, buf::Array{T}) = (sizeof(buf)*sizeof(T) == avpicture_get_size(r.format, r.width, r.height))
bufsize_check{T<:EightBitTypes}(r::VideoReader, buf::Array{T}) = bufsize_check(r.transcodeContext, buf)
bufsize_check{T<:EightBitTypes}(t::VideoTranscodeContext, buf::Array{T}) = (sizeof(buf) == avpicture_get_size(t.dest_fmt, t.width, t.height))

have_decoded_frame(r) = r.aFrameFinished[1] > 0  # TODO: make sure the last frame was made available
have_frame(r::StreamContext) = !isempty(r.frame_queue) || have_decoded_frame(r)
have_frame(avin::MediaInput) = any([have_frame(avin.stream_contexts[i+1]) for i in avin.listening])

reset_frame_flag!(r) = (r.aFrameFinished[1] = 0)

function seekstart(s::VideoReader, video_stream=1)
    !isopen(s) && throw(ErrorException("Video input stream is not open!"))

    pCodecContext = s.pVideoCodecContext # AVCodecContext

    seekstart(s.avin, video_stream)
    avcodec_flush_buffers(pCodecContext)

    return s
end

function seekstart{T<:String}(avin::MediaInput{T}, video_stream = 1)
    # AVFormatContext
    fc = avin.format_context

    # Get stream information
    stream_info = avin.video_info[video_stream]
    seek_stream_index = stream_info.stream_index0
    stream = stream_info.stream
    first_dts = stream.first_dts

    # Seek
    ret = avformat_seek_file(fc[], seek_stream_index, first_dts, first_dts, first_dts, AVSEEK_FLAG_BACKWARD)

    ret < 0 && throw(ErrorException("Could not seek to start of stream"))

    return avin
end

## This doesn't work...
#seekstart{T<:IO}(avin::MediaInput{T}, video_stream = 1) = seekstart(avin.io)
seekstart{T<:IO}(avin::MediaInput{T}, video_stream = 1) = throw(ErrorException("Sorry, Seeking is not supported for IO streams"))


function eof(avin::MediaInput)
    !isopen(avin) && return true
    have_frame(avin) && return false
    got_frame = (pump(avin) != -1)
    return !got_frame
end

function eof{I<:IO}(avin::MediaInput{I})
    !isopen(avin) && return true
    have_frame(avin) && return false
    return eof(avin.io)
end

eof(r::VideoReader) = eof(r.avin)

Base.close(r::VideoReader) = close(r.avin)
function _close(r::VideoReader)
    Base.sigatomic_begin()
    avcodec_close(r.pVideoCodecContext)
    Base.sigatomic_end()
end

# Free AVIOContext object when done
function Base.close(avin::MediaInput)
    println("closing MediaInput (", avin.io, ")")
    # Test and set isopen
    Base.sigatomic_begin()
    isopen = avin.isopen
    avin.isopen = false
    Base.sigatomic_end()

    !isopen && (println("Already closed..."); return)

    for i in avin.listening
        _close(avin.stream_contexts[i+1])
    end
    # Fix for segmentation fault issue #44
    empty!(avin.listening)

    free(avin.format_context)
    free(avin.iocontext)
end


### Camera Functions

if have_avdevice()
    import AVDevice
    AVDevice.avdevice_register_all()

    function get_camera_devices(ffmpeg, idev, idev_name)
        CAMERA_DEVICES = UTF8String[]

        read_vid_devs = false
        out,err = readall_stdout_stderr(`$ffmpeg -list_devices true -f $idev -i $idev_name`)
        buf = length(out) > 0 ? out : err
        for line in eachline(IOBuffer(buf))
            if contains(line, "video devices")
                read_vid_devs = true
                continue
            elseif contains(line, "audio devices") || contains(line, "exit") || contains(line, "error")
                read_vid_devs = false
                continue
            end

            if read_vid_devs
                m = match(r"""\[.*"(.*)".?""", line)
                if m != nothing
                    push!(CAMERA_DEVICES, m.captures[1])
                end

                # Alternative format (TODO: could be combined with the regex above)
                m = match(r"""\[.*\] \[[0-9]\] (.*)""", line)
                if m != nothing
                    push!(CAMERA_DEVICES, m.captures[1])
                end
            end
        end

        return CAMERA_DEVICES
    end

    @windows_only begin
        ffmpeg = joinpath(Pkg.dir("VideoIO"), "deps", "ffmpeg-2.2.3-win$WORD_SIZE-shared", "bin", "ffmpeg.exe")

        DEFAULT_CAMERA_FORMAT = AVFormat.av_find_input_format("dshow")
        CAMERA_DEVICES = get_camera_devices(ffmpeg, "dshow", "dummy")
        DEFAULT_CAMERA_DEVICE = length(CAMERA_DEVICES) > 0 ? CAMERA_DEVICES[1] : "0"

    end

    @linux_only begin
        import Glob
        DEFAULT_CAMERA_FORMAT = AVFormat.av_find_input_format("video4linux2")
        CAMERA_DEVICES = Glob.glob("video*", "/dev")
        DEFAULT_CAMERA_DEVICE = length(CAMERA_DEVICES) > 0 ? CAMERA_DEVICES[1] : ""
    end

    @osx_only begin
        ffmpeg = joinpath(INSTALL_ROOT, "bin", "ffmpeg")

        DEFAULT_CAMERA_FORMAT = AVFormat.av_find_input_format("avfoundation")
        global CAMERA_DEVICES = UTF8String[]
        try
            CAMERA_DEVICES = get_camera_devices(ffmpeg, "avfoundation", "\"\"")
        catch
            try
                DEFAULT_CAMERA_FORMAT = AVFormat.av_find_input_format("qtkit")
                CAMERA_DEVICES = get_camera_devices(ffmpeg, "qtkit", "\"\"")
            end
        end

        DEFAULT_CAMERA_DEVICE = length(CAMERA_DEVICES) > 0 ? CAMERA_DEVICES[1] : "FaceTime"
    end

    function opencamera(device=DEFAULT_CAMERA_DEVICE, format=DEFAULT_CAMERA_FORMAT, args...; kwargs...)
        camera = MediaInput(device, format)
        VideoReader(camera, args...; kwargs...)
    end
end

try
    if isa(Main.Images, Module)
        # Define read and retrieve for Images
        global retrieve, retrieve!, read!, read
        for r in [:read, :retrieve]
            r! = symbol("$(r)!")

            @eval begin
                # read!, retrieve!
                $r!(c::VideoReader, img::Main.Images.Image) = ($r!(c, Main.Images.data(img)); img)

                # read, retrieve
                function $r(c::VideoReader, ::Type{Main.Images.Image}) #, colorspace="RGB", colordim=1, spatialorder=["x","y"])
                    img = Main.Images.colorim($r(c::VideoReader))
                end
            end
        end
    end
end

try
    if isa(Main.ImageView, Module)
        # Define read and retrieve for Images
        global playvideo, viewcam, play

        function play(f, flip=false)
            img = read(f, Main.Images.Image)
            canvas, _ = Main.ImageView.view(img, flipx=flip, interactive=false)
            buf = Main.Images.data(img)

            while !eof(f)
                read!(f, buf)
                Main.ImageView.view(canvas, img, flipx=flip, interactive=false)
                sleep(1/f.framerate)
            end
        end

        function playvideo(video)
            f = VideoIO.openvideo(video)
            play(f)
        end

        if have_avdevice()
            function viewcam(device=DEFAULT_CAMERA_DEVICE, format=DEFAULT_CAMERA_FORMAT)
                camera = opencamera(device, format)
                play(camera, true)
            end
        else
            function viewcam()
                error("libavdevice not present")
            end
        end
    end
catch
    global playvideo, viewcam, play
    no_imageview() = error("Please load ImageView before VideoIO to enable play(...), playvideo(...) and viewcam()")
    play() = no_imageview()
    playvideo() = no_imageview()
    viewcam() = no_imageview()
end
