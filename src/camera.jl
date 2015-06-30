# camera.jl

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
        camera = MediaDecoder(device, format)
        VideoContext(camera, args...; kwargs...)
    end
end
