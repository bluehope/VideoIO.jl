# image.jl

try
    if isa(Main.Images, Module)
        # Define read and retrieve for Images
        global retrieve, retrieve!, read!, read
        for r in [:read, :retrieve]
            r! = symbol("$(r)!")

            @eval begin
                # read!, retrieve!
                $r!(c::VideoContext, img::Main.Images.Image) = ($r!(c, Main.Images.data(img)); img)

                # read, retrieve
                function $r(c::VideoContext, ::Type{Main.Images.Image}) #, colorspace="RGB", colordim=1, spatialorder=["x","y"])
                    img = Main.Images.colorim($r(c::VideoContext))
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
