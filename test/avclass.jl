using Base.Test
using Compat
import VideoIO

buf = VideoIO.CBuffer(1024)
VideoIO.free(buf)
@test buf.pptr == [C_NULL]

fc = VideoIO.FormatContext()
VideoIO.free(fc)
@test fc.pptr == [C_NULL]

