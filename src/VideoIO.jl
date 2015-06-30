module VideoIO

using Compat
VERSION < v"0.4-" && using Docile

include("init.jl")

using AVUtil
using AVCodecs
using AVFormat
using SWScale

include("util.jl")
include("pptr.jl")
include("avclass.jl")
include("avio.jl")
include("video_io.jl")
include("image.jl")
include("camera.jl")
include("testvideos.jl")
using .TestVideos

end # VideoIO
