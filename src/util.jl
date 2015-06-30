# Helpful utility functions

using Compat

# Set the value of a field of a pointer
# Equivalent to s->name = value

function open_stdout_stderr(cmd::Cmd)
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

function readall_stdout_stderr(cmd::Cmd)
    (out, err, proc) = open_stdout_stderr(cmd)
    return (readall(out), readall(err))
end

macro sigatomic(code)
    quote
        try
            Base.sigatomic_begin()
            $code
        finally
            Base.sigatomic_end()
        end
    end
end
