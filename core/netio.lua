local netio = {}

local WAIT = { timeout = true, wantread = true, wantwrite = true }

local function wait(io)
    if io.now() >= io.deadline then
        return nil, 'timeout'
    end
    io.yield()
    return true
end

function netio.connect(sock, ip, port, io, select)
    local ok, err = sock:connect(ip, port)
    if ok then
        return true
    end
    if err ~= 'timeout' then
        return nil, err
    end
    while true do
        local _, writable = select(nil, { sock }, 0)
        if writable ~= nil and #writable > 0 then
            if sock:getpeername() then
                return true
            end
            return nil, 'connection refused'
        end
        local w, werr = wait(io)
        if not w then
            return nil, werr
        end
    end
end

function netio.handshake(conn, io)
    while true do
        local ok, err = conn:dohandshake()
        if ok then
            return true
        end
        if not WAIT[err] then
            return nil, err
        end
        local w, werr = wait(io)
        if not w then
            return nil, werr
        end
    end
end

function netio.send_all(conn, data, io)
    local i = 1
    while i <= #data do
        local last, err, partial = conn:send(data, i)
        if last then
            i = last + 1
        else
            if not WAIT[err] then
                return nil, err
            end
            if partial ~= nil and partial >= i then
                i = partial + 1
            end
            if i <= #data then
                local w, werr = wait(io)
                if not w then
                    return nil, werr
                end
            end
        end
    end
    return true
end

function netio.receive(conn, resp, io, feed, close)
    while true do
        local data, err, partial = conn:receive(8192)
        local chunk = data or partial
        if chunk ~= nil and #chunk > 0 then
            local done, ferr = feed(resp, chunk)
            if done == nil then
                return nil, ferr
            end
            if done then
                return true
            end
        end
        if data == nil then
            if err == 'closed' then
                return close(resp)
            end
            if not WAIT[err] then
                return nil, err
            end
            local w, werr = wait(io)
            if not w then
                return nil, werr
            end
        end
    end
end

return netio
