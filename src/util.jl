# Helpful utility functions

using Compat

# Set the value of a field of a pointer
# Equivalent to s->name = value
function av_setfield{T}(s::Ptr{T}, name::Symbol, value)
    field = findfirst(fieldnames(T), name)
    byteoffset = fieldoffsets(T)[field]
    S = T.types[field]
    
    p = convert(Ptr{S}, s+byteoffset)
    a = pointer_to_array(p,1)
    a[1] = convert(S, value)
end

function av_pointer_to_field{T}(s::Ptr{T}, name::Symbol)
    field = findfirst(fieldnames(T), name)
    byteoffset = fieldoffsets(T)[field]
    return s + byteoffset
end

av_pointer_to_field(s::Array, name::Symbol) = av_pointer_to_field(pointer(s), name)

function open_stdout_stderr(cmd::Cmd)
	if(VERSION >= v"0.4.0-dev")
		out = Base.Pipe()
		err = Base.Pipe()
		cmd_out = Base.Pipe()
		cmd_err = Base.Pipe()

		Base.link_pipe(out.in,true,cmd_out.in,false)
		Base.link_pipe(out.out,true,cmd_out.out,false)
		Base.link_pipe(err.in,true,cmd_err.in,false)
		Base.link_pipe(err.out,true,cmd_err.out,false)
		
		r = spawn(ignorestatus(cmd), (DevNull, cmd_out, cmd_err))

		Base.close_pipe_sync(cmd_out.in)
		Base.close_pipe_sync(cmd_out.out)
		Base.close_pipe_sync(cmd_err.in)
		Base.close_pipe_sync(cmd_err.out)

		# NOTE: these are not necessary on v0.4 (although they don't seem
		#       to hurt). Remove when we drop support for v0.3.
		#Base.start_reading(out)
		#Base.start_reading(err)

		return (out, err, r)
	else
		out = Base.Pipe(C_NULL)
    err = Base.Pipe(C_NULL)
    cmd_out = Base.Pipe(C_NULL)
    cmd_err = Base.Pipe(C_NULL)
    Base.link_pipe(out, true, cmd_out, false)
    Base.link_pipe(err, true, cmd_err, false)

    r = spawn(false, ignorestatus(cmd), (DevNull, cmd_out, cmd_err))

    Base.close_pipe_sync(cmd_out)
    Base.close_pipe_sync(cmd_err)

    # NOTE: these are not necessary on v0.4 (although they don't seem
    #       to hurt). Remove when we drop support for v0.3.
    Base.start_reading(out)
    Base.start_reading(err)

    return (out, err, r)
	end
end
    
function readall_stdout_stderr(cmd::Cmd)
    (out, err, proc) = open_stdout_stderr(cmd)
    return (readall(out), readall(err))
end
