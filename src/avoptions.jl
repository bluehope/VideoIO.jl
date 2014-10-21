###############################################################################################################
# AVOptions API for VideoIO.jl
#
# Maximiliano Suster
# October 2014
###############################################################################################################

# AVOptions provides a generic system to get/set options for Devices, formats and Codecs.
# It relies on AVOptions, AVDictionary and AVDeviceCapabilitiesQuery APIs.

# The API consists of 3 modules:
#    Evaluate option strings  -> eval "string" option, return 0/-1
#    Option setting functions -> set value for a key string, if not string, then parsed
#    Option getting functions -> get value for a key string, if not string, then parsed

# Options are stored in 3 structure types:
#    AVOption
#    AVOptionRange
#    AVOptionRanges

#  key, value pairs can be optionally passed to AVOption functions using AVDictionary
#       typealias AVDictionary Void in libavutil.h
#       in ffmpeg dict.c
#       struct AVDictionary {
#         int count
#         AVDictionaryEntry *elems
#       }

#  To access options, the object(structure) must have Ptr{AVClass} as the first element,
#  because option keys and values are stored in AVOption, a child of AVClass.
#  e.g., avin::AVInput (see VideoIO/avio.jl)
#       -> avin.apFormatContext[1] = Ptr{AVFormatContext}
#       AVFormatContext has av_class::Ptr{AVClass} as first field
#       AVClass has option::Ptr{AVOption}
#       1. AVFormatContext
#            av_class:: Ptr{AVClass}
#              AVClass
#                 option::Ptr{AVOption}
#       2. AVCodecContext
#           av_class:: Ptr{AVClass}
#              AVClass
#                 option::Ptr{AVOption}
#       3.  AVDeviceCapabilitiesQuery
#            av_class:: Ptr{AVClass}
#               AVClass
#                 option::Ptr{AVOption}

# Initialized structures:
# formats => avin::AVInput
#                apFormatContext::Vector{Ptr{AVFormatContext}}

# codecs  => avin::AVInput
#               video_info::Vector{StreamInfo}
#                   stream_info::StreamInfo
#                     codec_ctx::AVCodecContext

# Devices => avdeviceQuery::AVDeviceCapabilitiesQuery

# Issues solved
  #find/get/set options
  #44

# to solve
  #25  -> AVFormatContext.iformat
  #31  -> AVDeviceCapabilitiesQuery

# To do:
# 1. Cleaning up
# 2. Documentation
# 3. Testing

# **************************************************************************************************************

export document_all_options,
       print_options,
       is_option,
       set_default_options,
       set_option,
       get_option,
       create_dictionary,
       set_options_with_dictionary,
       create_device_query,
       query_device_ranges,
       set_device_with_query,
       list_devices
       # get_metadata -> requires AVUtil >= v53


# Support functions
cint(n) = convert(Cint,n)

# **************************************************************************************************************
# Document and view (optional) all accessible options
# document_all_options
# Input: AVInput
#   1. Create a dictionary to hold all accessible options (from AVOption-enabled structures) with option to print
#   2. Print a list of all options
# **************************************************************************************************************

function document_all_options(I::AVInput, view=false)
    if !I.isopen
        error("No input file/device open!")
    end

    # Set default formats on Ptr{AVFormatContext}
    pFormatContext = I.apFormatContext[1]
    prevs = Ptr{AVOption}[C_NULL]
    prev = prevs[1]

    # Initialize the search of AVOption with Ptr{AVFormatContext}
    obj = pFormatContext
    # Create a dictionary of {option => [minvalue, maxvalue]}
    options = Dict{String,Vector{Cdouble}}()

    # Run through all AVOptions and store them in options
    while(true)
       while (true)
          prev = av_opt_next(obj, prev)
          if prev ==C_NULL
              break
          end
          avoption = unsafe_load(prev)
          name = bytestring(avoption.name)
          options[name] = [avoption.min, avoption.max]
       end

       obj = av_opt_child_next(obj, prev)
       if obj == C_NULL
           break
       end
    end

    if view
        print_options (options)
    end

    options
end

function print_options (options::Dict{String,Vector{Cdouble}})
    if isempty(options)
        error("Options dictionary is empty!")
    end

    # Display options
    # Sort keys alphabetically for easier viewing
    optionKeys = collect(keys(options))
    longest = maximum(map(i -> length(optionKeys[i]), 1:length(optionKeys)))
    sort!(vec(optionKeys))

    # Print options
    println("-"^75,"\n ", " "^10, "LIST OF ALL OPTIONS FOR FORMAT, CODEC AND DEVICES\n","-"^75)
    for i=1:length(optionKeys)
        name = optionKeys[i]
        println(name, " "^(longest-length(optionKeys[i]) +1), "=>  min: ",
                options[optionKeys[i]][1], " , max: " , options[optionKeys[i]][2])
     end
     println("\n\n")
end

# Examples:
# using VideoIO
# f = opencamera(VideoIO.DEFAULT_CAMERA_DEVICE, VideoIO.DEFAULT_CAMERA_FORMAT)
# OptionsDictionary = document_all_options(f.avin, true)

# **************************************************************************************************************
# Setting options
#
# 1. set_default_options  => Set all options to default values
# 2. set_option           => Set using "key", "value" pairs
# **************************************************************************************************************

function set_default_options(I::AVInput)
    if !I.isopen
        error("No input file/device open!")
    end

    # Set default formats on Ptr{AVFormatContext}
    pFormatContext = I.apFormatContext[1]
    # av_opt_set_defaults2 (mask = 0, flags = 0)
    av_opt_set_defaults(pFormatContext) # input is Ptr{Void}

    # Set default codecs on Ptr{AVCodecContext}
    FormatContext = unsafe_load(pFormatContext)
    for i = 1:FormatContext.nb_streams
        pStream = unsafe_load(FormatContext.streams,i)
        stream = unsafe_load(pStream)
        av_opt_set_defaults(stream.codec)
    end

    println("Set default format and codec options")
    av_opt_free(pFormatContext)
end

#  Example:
#  using VideoIO
#  f = opencamera(VideoIO.DEFAULT_CAMERA_DEVICE, VideoIO.DEFAULT_CAMERA_FORMAT)
#  set_default_options(f.avin)
# **************************************************************************************************************

function set_option(I::AVInput, key::String, val::String)
    if !I.isopen
        error("No input file/device open!")
    end

    # Select Ptr{AVFormatContext}
    pFormatContext = I.apFormatContext[1]

    # key, value and pair separators
    key_val_sep = ","
    pairs_sep = ";"
    opts = string(key, "," , val)

    res = av_set_options_string(pFormatContext, pointer(opts),
                                pointer(key_val_sep), pointer(pairs_sep))
    if res < 0
        error("Could not set '$key' option.")
    else
       println("$key set to $val.")
    end
end

## Examples:
#  using VideoIO
#  f = opencamera(VideoIO.DEFAULT_CAMERA_DEVICE, VideoIO.DEFAULT_CAMERA_FORMAT)
#  print_options (OptionsDictionary)
#  set probing size
#     set_option(f.avin, "probesize", "100000000")
#  set how many microseconds
#     set_option(f.avin, "analyzeduration", "10000000")
#  set number of frames used to probe -> fps (from -1 to 2.14748e+09)
#     set_option(f.avin, "fpsprobesize", "10")
#     set_option(f.avin, "formatprobesize", "50000000")
#  set pixel format
#     set_option(f.avin, "pixel_format", string(VideoIO.AV_PIX_FMT_UYVY422))
#     set_option(f.avin, "pixel_format", string(VideoIO.AV_PIX_FMT_YUYV422))
#     set_option(f.avin, "pixel_format", string(VideoIO.AV_PIX_FMT_NV12))
#     set_option(f.avin, "pixel_format", string(VideoIO.AV_PIX_FMT_0RGB))
#     set_option(f.avin, "pixel_format", string(VideoIO.AV_PIX_FMT_BGR0))
#  set frame rate
#     set_option(f.avin, "frame_rate", "15")

# **************************************************************************************************************
# Find whether an option exists
#
# is_option => Checks if an option exists
# **************************************************************************************************************

function is_option(I::AVInput, key::String)
    pFormatContext = I.apFormatContext[1]
    #AVOptionType named constants (Ptr{Uint8})
    unit =  C_NULL  # "AVOptionType"?, but not clear from docs
    opt_flag = cint(0)

    # AV_OPT_INT
    # AV_OPT_INT64
    # AV_OPT_DOUBLE
    # AV_OPT_FLOAT
    # AV_OPT_STRING
    # AV_OPT_RATIONAL
    # AV_OPT_BINARY
    # AV_OPT_DICT
    # AV_OPT_IMAGE_SIZE
    # AV_OPT_PIXEL_FMT
    # AV_OPT_SAMPLE_FMT
    # AV_OPT_VIDEO_RATE
    # AV_OPT_DURATION
    # AV_OPT_COLOR
    # AV_OPT_CHANNEL_LAYOUT

    # Search in nested objects (e.g., AVCodecContext)
    search_flags = cint(AV_OPT_SEARCH_CHILDREN)

    # Initialize a Ptr{AVOption}
    prevs = Ptr{AVOption}[C_NULL]
    prev = prevs[1]

    prev = av_opt_find(pFormatContext,pointer(key),unit, opt_flag, search_flags)
    if prev == C_NULL
        error("$key not found!")
    else
        println("$key found!")
    end
end

# Examples:
# using VideoIO
# f = opencamera(VideoIO.DEFAULT_CAMERA_DEVICE, VideoIO.DEFAULT_CAMERA_FORMAT)
# is_option(f.avin, "probesize")
# is_option(f.avin, "list_devices")
# is_option(f.avin, "max_delay")
# is_option(f.avin, "analyzeduration")
# **************************************************************************************************************


# **************************************************************************************************************
# Getting the value of an option
#
# get_option => returns value for a given option string key
# **************************************************************************************************************

# Check the type of option to search for e.g., image_size, pixel_fmt
macro assert_type(ex)
    option =""
    return :($ex=="" ? option = :default:
             $ex=="image_size" ? option = :image_size:
             $ex=="pixel_fmt" ? option = :pixel_fmt :
             $ex=="video_rate" ? option = :video_rate :
              error("option", $(string(ex)), " does not exist!"))
    return option
end

function get_option (I::AVInput, key::String, OPTION_TYPE="")
    option = @assert_type(OPTION_TYPE)
    pFormatContext = I.apFormatContext[1]

    # Get value from children of FormatContext -> AVCodecContext
    search_flags = cint(AV_OPT_SEARCH_CHILDREN)

    if option==:default
    # Passing a double pointer
        outval = Array(Ptr{Uint8},1)
        if (av_opt_get(pFormatContext,pointer(key),search_flags, outval)<0)
            error("Cannot get value for $key")
        else
            val = bytestring(outval[1])
            println("$key = ", val)
            return val
        end
    elseif option ==:image_size
        out1 = Array(Ptr{Cint},1); pwidth = out1[1]
        out2 = Array(Ptr{Cint},1); pheight = out2[1]
        if (av_opt_get_image_size(pFormatContext,pointer(key),search_flags, pwidth, pheight)<0)
            error("Cannot get value for $key")
        else
            fval1 = convert(Int64, unsafe_load(pwidth))
            fval2 = convert(Int64, unsafe_load(pheight))
            println("Width: $fval1, Height: $fval2")
            return val1, val2
        end
    elseif option ==:pixel_fmt
        out = Array(Ptr{AVPixelFormat},1); ppix_fmt = out[1]
        if (av_opt_get_pixel_fmt(pFormatContext,pointer(key),search_flags, ppix_fmt)<0)
            error("Cannot get value for $key")
        else
            pix_fmt = convert(Int64, unsafe_load(ppix_fmt))
            println("Pixel format is: $pix_fmt")
            return pix_fmt
        end
    elseif option ==:video_rate
        out = Array(Ptr{AVRational},1); pvideorate = out[1]
        if (av_opt_get_video_rate(pFormatContext,pointer(key),search_flags, pvideorate)<0)
            error("Cannot get value for $key")
        else
            frame_rate = unsafe_load(pvideorate)
            println("Frame rate is: $(frame_rate.num/frame_rate.den) fps")
            return fps
        end
    end
end

# Examples:
# using VideoIO
# f = opencamera(VideoIO.DEFAULT_CAMERA_DEVICE, VideoIO.DEFAULT_CAMERA_FORMAT)
# get_option(f.avin, "probesize")
# get_option(f.avin, "list_devices")
# get_option(f.avin, "max_delay")
# get_option(f.avin, "analyzeduration")
# get_option (f.avin, "?", "image_size")
# get_option (f.avin, "?", "pixel_fmt")
# get_option (f.avin, "?", "video_rate")
# **************************************************************************************************************




# **************************************************************************************************************
# AVDictionary API
# 1. create_dictionary
# 2. set_options_with_dictionary
# **************************************************************************************************************

function create_dictionary(entries)

    # Get all the keys from the user entries
    entries_keys = collect(keys(entries))

    # Initialize a dictionary with the first entry
    entry = AVDictionaryEntry(pointer(entries_keys[1]),pointer(entries[entries_keys[1]]))
    dictionary = AVDictionary(cint(1), pointer_from_objref(entry))
    pDictionary = Ptr{AVDictionary}[pointer_from_objref(dictionary)]
    pDictionary[1] = C_NULL

    flags = cint(AV_DICT_DONT_OVERWRITE)
    #AV_DICT_MATCH_CASE
    #AV_DICT_IGNORE_SUFFIX
    # to avoid clearing val from memory
    #AV_DICT_DONT_STRDUP_KEY | AV_DICT_DONT_STRDUP_VAL
    #AV_DICT_DONT_OVERWRITE
    #AV_DICT_APPEND

    for k = 1:length(entries_keys)
        # Call av_dict_set() function
        if(av_dict_set(pDictionary, pointer(entries_keys[k]), pointer(entries[entries_keys[k]]),flags)< 0)
        #Cint = 0 on success, AVERROR <0 on failure
           error("Can not create $(user_options[option_keys[k]]) a dictionary")
        end
    end

    count = av_dict_count(pDictionary[1])
    println("The dictionary has $count entries.")

    return pDictionary
end


function set_options_with_dictionary (I::AVInput, pDictionary::Array{Ptr{AVDictionary}})

    pDictionary[1]==C_NULL ? error("Dictionary is empty!") : nothing

    # Retrieve Ptr{AVFormatContext}
    pFormatContext = I.apFormatContext[1]

    # Set value in children of FormatContext -> AVCodecContext
    search_flags = cint(AV_OPT_SEARCH_CHILDREN)

    # Set options with dictionary
    # 0 on success, < 0 (AVERROR) if found in obj, but could not be set
    if (av_opt_set_dict2(pFormatContext, pDictionary, search_flags) !=0)
        error("Cannot set options with this dictionary. Check your dictionary!")
    else
        println("Set all options in dictionary")
    end

    #av_dict_free(pDictionary)
    #av_opt_free(pFormatContext)
end

# Examples:
# using VideoIO
# f = opencamera(VideoIO.DEFAULT_CAMERA_DEVICE, VideoIO.DEFAULT_CAMERA_FORMAT)
# Initialize the dictionary:
# entries = Dict{String,String}()
# entries["probesize"] = "1000000"
# entries["iformat"] = "avfoundation"
# entries["duration"] = "3000"
# pDictionary = create_dictionary(entries)
# set_options_with_dictionary(f.avin, pDictionary)
# **************************************************************************************************************


# **************************************************************************************************************
# AVDeviceCapabilitiesQuery API
# 1. create_device_query
# 2. query_device_ranges
# 3. set_device_with_query
# **************************************************************************************************************

# Create a new device query structure
function create_device_query(I::AVInput, pDictionary)

    # Retrieve Ptr{AVFormatContext}
    pFormatContext = I.apFormatContext[1]
    FormatContext = unsafe_load(pFormatContext)

    pStream = unsafe_load(FormatContext.streams)
    stream = unsafe_load(pStream)
    codecContext = unsafe_load(stream.codec) #Ptr{AVCodecContext}
    frame_width, frame_height = codecContext.width, codecContext.height
    fps = AVRational(codecContext.time_base.den, codecContext.time_base.num)

    # Initialize a device query structure
    DeviceQuery = AVDeviceCapabilitiesQuery (FormatContext.av_class,
                                             pFormatContext,
                                             AV_CODEC_ID_MPEG4,
                                             AV_SAMPLE_FMT_NONE,
                                             AV_PIX_FMT_YUYV422,
                                             cint(0),
                                             cint(0),
                                             convert(Culonglong,0),
                                             cint(640),
                                             cint(480),
                                             frame_width,
                                             frame_height,
                                             fps)


    queries = avdevice_capabilities_create[pointer_from_objref(DeviceQuery)]
    #queries = Array(Ptr{AVDeviceCapabilitiesQuery},1)
    queries[1] = C_NULL
    #pDictionary[1] = C_NULL

    # Can also set pDictionary => C_NULL
    if (avdevice_capabilities_create(queries[1],pFormatContext,pDictionary) < 0)
        error("Can not create a device query. Try again")
    end

    #avdevice_capabilities_free(queries, pFormatContext)
    return queries
end

# Probe and set device capabilities
function query_device_ranges (I::AVInput, key::String, queries::Array{Ptr{AVDeviceCapabilitiesQuery}})
    # Select Ptr{AVFormatContext}
    pFormatContext = I.apFormatContext[1]

    # Initialize AVOptionRanges
    ranges = Array(Ptr{AVOptionRanges},1)
    search_flags = cint(AV_OPT_MULTI_COMPONENT_RANGE)

    # Query ranges
    if (av_opt_query_ranges(ranges,queries, pointer(key),search_flags)<0)
        # av_free(key)
        # avdevice_capabilities_free(queries, pFormatContext)
        # av_opt_free_ranges(ranges): av_opt_freep_ranges(ranges) #deallocate
        error("Invalid input, failed to access device data.")

    else
        ranges = unsafe_load(ranges[1])         #Ptr{AVOptionRanges}}
        prange = unsafe_load(ranges.range)      #Ptr{AVOptionRange}
        range = unsafe_load(prange)             #AVOptionRange

        minVal = range.value_min  #Cdouble => Float64
        maxVal = range.value_max  #Cdouble => Float64

        println("$key, mininum = $minVal, maximum = $maxVal")

        #deallocate
        #av_opt_free_ranges(ranges)
        #av_free(key)
        #avdevice_capabilities_free(query, pFormatContext)
    end
end

# Examples:
# using VideoIO
# f = opencamera(VideoIO.DEFAULT_CAMERA_DEVICE, VideoIO.DEFAULT_CAMERA_FORMAT)
# query_device_ranges(f.avin, "codec", queries)
# query_device_ranges(f.avin, "pixel_format", queries)
# query_device_ranges(f.avin, "window_width", queries)
# query_device_ranges(f.avin, "window_height", queries)
# query_device_ranges(f.avin, "frame_width", queries)
# query_device_ranges(f.avin, "frame_height", queries)
# query_device_ranges(f.avin, "fps", queries)

# **************************************************************************************************************

function set_device_with_query (key::String, val::String, queries::Array{Ptr{AVDeviceCapabilitiesQuery}})

    # key, value and pair separators
    key_val_sep = ","
    pairs_sep = ";"
    opts = string(key, "," , val)

    #Ptr{AVDeviceCapabilitiesQuery}
    query = queries[1]

    res = av_set_options_string(query, pointer(opts), pointer(key_val_sep), pointer(pairs_sep))
    if res < 0
        error("Could not set '$key' option.")
    else
        println("$key set to $val.")
    end

    # deallocate
    # av_free(key)
    # av_free(pval)
    # avdevice_capabilities_free(query, pFormatContext)
end

# Examples:
# using VideoIO
# f = opencamera(VideoIO.DEFAULT_CAMERA_DEVICE, VideoIO.DEFAULT_CAMERA_FORMAT)
# set_device_with_query(f.avin, "codec", AV_CODEC_ID_RAWVIDEO, 0)
# set_device_with_query(f.avin, "codec", AV_CODEC_ID_MPEG4, 0)
# set_device_with_query(f.avin, "pixel_format", AV_PIX_FMT_YUV420P, 0)
# set_device_with_query(f.avin, "fps", AV_PIX_FMT_YUV420P, 0)


# **************************************************************************************************************
# List devices (may not be complete!)
#
# list_devices
# **************************************************************************************************************

function list_devices(I::AVInput)

    # AVDeviceCapabilitiesQuery
    # AVDeviceCapabilitiesQuery.device_context::Ptr{AVFormatContext}

    # Select Ptr{AVFormatContext}
    # pFormatContext = I.apFormatContext[1]
    # apFormatContext = Ptr{AVFormatContext}[avformat_alloc_context()]
    pFormatContext = apFormatContext[1]

    # Initialize Ptr{AVDeviceInfoList} array
    device_info0 = AVDeviceInfo(pointer("avfoundation"), pointer("avfoundation input device"))
    apdevice_list0 = Ptr{AVDeviceInfo}[pointer_from_objref(device_info0)]
    device_list0 = AVDeviceInfoList(pointer_from_objref(apdevice_list0[1]), cint(1), cint(0))
    pdevice_list = Ptr{AVDeviceInfoList}[pointer_from_objref(device_list0)]
    pdevice_list[1] = C_NULL

    if (avdevice_list_devices(pFormatContext, pdevice_list)<0)
        #avdevice_free_list_devices(device_list)
        error("Cannot list devices")
    else
        #get AVDeviceInfoList
        device_list = unsafe_load(pdevice_list)
        #number of autodetected devices
        nb_devices = device_list.nb_devices
        #index of default device or -1 if no default
        default_device =  device_list.default_device

        # get AVDeviceInfo
        pdevice_info = unsafe_load(device_list.devices)
        device_info = unsafe_load(pdevice_info)
        # get device_name and description
        device_name = bytestring(device_info.device_name)
        device_description = bytestring(device_info.device_description)

        println("Number of detected devices: $nb_devices")
        println("Default device index: $default_device")
        println(device_name,": ", device_description)

        #deallocate
        #avdevice_free_list_devices(device_list)
    end
end


# Examples:
# f = VideoIO.opencamera(VideoIO.DEFAULT_CAMERA_DEVICE, VideoIO.DEFAULT_CAMERA_FORMAT)
# list_devices(f.avin)
# **************************************************************************************************************


# **************************************************************************************************************
# Read metadata
# AVFormatContext
# -> metadata::Ptr{AVDictionary}
# f = VideoIO.opencamera(VideoIO.DEFAULT_CAMERA_DEVICE, VideoIO.DEFAULT_CAMERA_FORMAT)
# get_metadata(f.avin)
# **************************************************************************************************************

function get_metadata (I::AVInput, key::String)
    # Select Ptr{AVFormatContext}
    pFormatContext = I.apFormatContext[1]
    fmt_ctx = unsafe_load(pFormatContext)
    tags = Ptr{AVDictionaryEntry}[C_NULL]
    tag = tags[1]


    while (true)
        tag = av_dict_get(fmt_ctx.metadata, pointer(key), tag, cint(AV_DICT_IGNORE_SUFFIX))
        if tag !=C_NULL
            entry = unsafe_load(tag)
            metakey = bytestring(entry.key)
            metaentry = bytestring(entry.val)
            println(metakey, metaentry, "\n")
        else
            println("No entry!")
            break
        end
    end
end

# **************************************************************************************************************



