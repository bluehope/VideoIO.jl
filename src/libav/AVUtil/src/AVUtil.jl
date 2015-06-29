module AVUtil
  include(joinpath(Pkg.dir("VideoIO"),"src","init.jl"))
  w(f) = joinpath(avutil_dir, f)

  include(w("LIBAVUTIL.jl"))

  Base.zero(::Type{AVRational}) = AVRational(0, 1)

# for compatibility with ffmpeg
# Note that these constants aren't actually defined by libav,
# but they will allow us to use them without error

  const AV_OPT_TYPE_IMAGE_SIZE = @compat UInt32(1397316165)
  const AV_OPT_TYPE_PIXEL_FMT = @compat UInt32(1346784596)
  const AV_OPT_TYPE_SAMPLE_FMT = @compat UInt32(1397116244)
  const AV_OPT_TYPE_VIDEO_RATE = @compat UInt32(1448231252)
  const AV_OPT_TYPE_DURATION = @compat UInt32(1146442272)
  const AV_OPT_TYPE_COLOR = @compat UInt32(1129270354)
  const AV_OPT_TYPE_CHANNEL_LAYOUT = @compat UInt32(1128811585)

export
  AV_PIX_FMT_0RGB,
  AV_PIX_FMT_RGB0,
  AV_PIX_FMT_0BGR,
  AV_PIX_FMT_BGR0


  const AV_PIX_FMT_0RGB = @compat Int32(295)
  const AV_PIX_FMT_RGB0 = @compat Int32(296)
  const AV_PIX_FMT_0BGR = @compat Int32(297)
  const AV_PIX_FMT_BGR0 = @compat Int32(298)

end
