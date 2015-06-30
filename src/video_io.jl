# video_input

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

##################################################

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

    @sigatomic sws_scale(context.transcode_context,
                      source_buffers,
                      source_line_sizes,
                      zero(Int32),
                      source_frame.height,
                      dest_buffers,
                      dest_line_sizes)
end

dataBufferPtrs(vf::VideoFrame) = reinterpret(Ptr{UInt8}, [vf.frame[1].data])
lineSizes(vf::VideoFrame) = reinterpret(Cint, [vf.frame[1].linesize])


type VideoContext{S,T,N,M} <: StreamContext
    decoder::MediaDecoder
    stream::Stream

    codecContext::PPtr{AVCodecContext}
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

show(io::IO, vr::VideoContext) = print(io, "VideoContext(...)")

function VideoContext(decoder::MediaDecoder, video_stream=1;
                      target_format=PIX_FMT_RGB24,
                      transcode::Bool=true,
                      transcode_interpolation=SWS_BILINEAR)

    1 <= video_stream <= length(decoder.video_info) || error("video stream $video_stream not found")

    stream = decoder.video_info[video_stream]

    # Get basic stream info
    codecContext = PPtr(stream[:codec])

    width, height = codecContext[:width], codecContext[:height]
    pix_fmt = codecContext[:pix_fmt]
    pix_fmt < 0 && error("Unknown pixel format")

    framerate = codecContext[:time_base].den // codecContext[:time_base].num
    aspect_ratio = codecContext[:sample_aspect_ratio].num // codecContext[:sample_aspect_ratio].den

    # Find the decoder for the video stream
    pVideoCodec = avcodec_find_decoder(codecContext[:codec_id])
    pVideoCodec == C_NULL && error("Unsupported Video Codec")

    # Open the decoder
    (@sigatomic avcodec_open2(codecContext[], pVideoCodec, C_NULL)) < 0 && error("Could not open codec")

    videoFrame = VideoFrame(pix_fmt, width, height)
    aFrameFinished = Cint[0]

    # # Set up transcoding
    # # TODO: this should be optional

    pFmtDesc = av_pix_fmt_desc_get(target_format)
    bits_per_pixel = av_get_bits_per_pixel(pFmtDesc)

    transcodeContext = VideoTranscodeContext(pix_fmt, target_format, width, height,
                                             interpolation = transcode_interpolation)
    transcoded_frame = VideoFrame(target_format, width, height)

    vr = VideoContext(decoder,
                      stream,

                      codecContext,
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

    idx0 = stream[:index]
    push!(decoder.listening, idx0)
    decoder.stream_contexts[idx0+1] = vr

    vr
end

VideoContext{T<:Union(IO, String)}(s::T, args...; kwargs...) = VideoContext(MediaDecoder(s), args...; kwargs... )

function decode_packet(r::VideoContext, packet)
    # Do we already have a complete frame that hasn't been consumed?
    if have_decoded_frame(r)
        push!(r.frame_queue, copy(r.videoFrame))
        reset_frame_flag!(r)
    end

    avcodec_decode_video2(r.codecContext[],
                          r.videoFrame.frame,
                          r.aFrameFinished,
                          packet.p)

    return have_decoded_frame(r)
end

"Retrieve a raw video frame"
function retrieve{S}(r::VideoContext{S,S}) # don't transcode
    dest_video_frame = VideoFrame(r.format, r.width, r.height)
    retrieve!(r, dest_video_frame)
    return dest_video_frame.buffer
end

"Retrieve a raw video frame into the given buffer"
function retrieve!{S,T<:EightBitTypes}(r::VideoContext{S,S}, buf::AbstractArray{T})
    if pointer(buf) != pointer(r.video_frame.buffer)
        dest_video_frame = VideoFrame(r.format, r.width, r.height, buf)
    else
        dest_video_frame = r.video_frame
    end

    retrieve!(r, dest_video_frame)

    return buf
end

"Retrieve a raw video frame into the given video frame object"
function retrieve!{S}(r::VideoContext{S,S}, dest_video_frame::VideoFrame)
    if r.videoFrame != dest_video_frame
        r.videoFrame = dest_video_frame
    end

    video_idx = r.stream[:index]
    while !have_frame(r)
        idx = pump(r.decoder)
        idx == video_idx && break
        idx == -1 && throw(EOFError())
    end

    # Raw frame is now in dest_video_frame
    return dest_video_frame
end


# Converts a grabbed frame to the correct format (RGB by default)

"Retrieve and return a transcoded video frame"
function retrieve(r::VideoContext)
    t = r.transcodeContext
    dest_video_frame = VideoFrame(t.dest_format, t.dest_width, t.dest_height)
    retrieve!(r, dest_video_frame)
    return dest_video_frame.buffer
end

"Retrieve and transcode a video frame, placing the result in the given buffer"
function retrieve!{T<:EightBitTypes}(r::VideoContext, buf::AbstractArray{T})
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
function retrieve!(r::VideoContext, dest_frame::VideoFrame)
    video_idx = r.stream[:index]
    while !have_frame(r)
        idx = pump(r.decoder)
        idx == video_idx && break
        idx == -1 && throw(EOFError())
    end

    source_frame = isempty(r.frame_queue) ? r.videoFrame : shift!(r.frame_queue)
    transcode(source_frame, dest_frame, r.transcodeContext)

    r.transcoded_frame = dest_frame

    reset_frame_flag!(r)

    return dest_frame
end


read(r::VideoContext) = retrieve(r)
read!{T<:EightBitTypes}(r::VideoContext, buf::AbstractArray{T}) = retrieve!(r, buf)

isopen(r::VideoContext) = isopen(r.decoder)

have_decoded_frame(r) = r.aFrameFinished[1] > 0  # TODO: make sure the last frame was made available
have_frame(r::StreamContext) = !isempty(r.frame_queue) || have_decoded_frame(r)
have_frame(decoder::MediaDecoder) = any(Bool[have_frame(decoder.stream_contexts[i+1]) for i in decoder.listening])

reset_frame_flag!(r) = (r.aFrameFinished[1] = 0)

function seekstart(s::VideoContext, video_stream=1)
    !isopen(s) && throw(ErrorException("Video input stream is not open!"))

    pCodecContext = s.codecContext[] # AVCodecContext

    seekstart(s.decoder, video_stream)
    avcodec_flush_buffers(pCodecContext)

    return s
end


Base.close(r::VideoContext) = close(r.decoder)
function _close(r::VideoContext)
    @sigatomic avcodec_close(r.codecContext[])
end

bufsize_check{S,T<:EightBitTypes}(r::VideoContext{S,S}, buf::Array{T}) = (sizeof(buf)*sizeof(T) == avpicture_get_size(r.format, r.width, r.height))
bufsize_check{T<:EightBitTypes}(r::VideoContext, buf::Array{T}) = bufsize_check(r.transcodeContext, buf)
bufsize_check{T<:EightBitTypes}(t::VideoTranscodeContext, buf::Array{T}) = (sizeof(buf) == avpicture_get_size(t.dest_fmt, t.width, t.height))

eof(r::VideoContext) = eof(r.decoder)
