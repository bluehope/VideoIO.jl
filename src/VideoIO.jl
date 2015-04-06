module VideoIO

using Compat

include("init.jl")

using AVUtil
using AVCodecs
using AVFormat
using SWScale

include("util.jl")
include("avclass.jl")
include("avio.jl")
include("testvideos.jl")
using .TestVideos

end # VideoIO
