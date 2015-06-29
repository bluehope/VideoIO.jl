module AVUtil
  include(joinpath(Pkg.dir("VideoIO"),"src","init.jl"))
  w(f) = joinpath(avutil_dir, f)

  include(w("LIBAVUTIL.jl"))

  Base.zero(::Type{AVRational}) = AVRational(0, 1)

  # for compatibility with ffmpeg
  const AV_OPT_TYPE_IMAGE_SIZE = @compat UInt32(1397316165)
  const AV_OPT_TYPE_PIXEL_FMT = @compat UInt32(1346784596)
  const AV_OPT_TYPE_SAMPLE_FMT = @compat UInt32(1397116244)
  const AV_OPT_TYPE_VIDEO_RATE = @compat UInt32(1448231252)
  const AV_OPT_TYPE_DURATION = @compat UInt32(1146442272)
  const AV_OPT_TYPE_COLOR = @compat UInt32(1129270354)
  const AV_OPT_TYPE_CHANNEL_LAYOUT = @compat UInt32(1128811585)

end
