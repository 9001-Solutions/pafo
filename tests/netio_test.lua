local h = require('tests.harness')
local netio = require('core.netio')
local http = require('core.http')

local function clock(limit)
    local io = { t = 0, yields = 0, deadline = limit or 100 }
    io.now = function() return io.t end
    io.yield = function()
        io.yields = io.yields + 1
        io.t = io.t + 1
    end
    return io
end

local function script(steps)
    local i = 0
    return function(...)
        i = i + 1
        local step = steps[i] or steps[#steps]
        if type(step) == 'function' then
            return step(...)
        end
        return unpack(step)
    end
end

h.check('connect waits for the socket to become writable', function()
    local io = clock()
    local sock = {
        connect = function() return nil, 'timeout' end,
        getpeername = function() return '1.2.3.4', 443 end,
    }
    local select = script({ { {}, {} }, { {}, {} }, { {}, { sock } } })
    h.eq(netio.connect(sock, '1.2.3.4', 443, io, select), true)
    h.eq(io.yields, 2)
end)

h.check('connect gives up at the deadline and on hard errors', function()
    local io = clock(3)
    local sock = { connect = function() return nil, 'timeout' end }
    local ok, err = netio.connect(sock, 'ip', 1, io, function() return {}, {} end)
    h.eq(ok, nil)
    h.eq(err, 'timeout')
    h.eq(io.yields, 3)
    local r, e = netio.connect({ connect = function() return nil, 'host unreachable' end }, 'ip', 1, clock(), nil)
    h.eq(r, nil)
    h.eq(e, 'host unreachable')
end)

h.check('handshake yields on wantread and wantwrite', function()
    local io = clock()
    local conn = { dohandshake = script({ { nil, 'wantread' }, { nil, 'wantwrite' }, { true } }) }
    h.eq(netio.handshake(conn, io), true)
    h.eq(io.yields, 2)
    local bad = { dohandshake = function() return nil, 'certificate verify failed' end }
    local ok, err = netio.handshake(bad, clock())
    h.eq(ok, nil)
    h.eq(err, 'certificate verify failed')
end)

h.check('send_all resumes partial writes in order', function()
    local io = clock()
    local sent = {}
    local conn = {
        send = function(_, data, i)
            local j = math.min(i + 2, #data)
            sent[#sent + 1] = data:sub(i, j)
            if j < #data then
                return nil, 'wantwrite', j
            end
            return j
        end,
    }
    h.eq(netio.send_all(conn, 'abcdefgh', io), true)
    h.eq(table.concat(sent), 'abcdefgh')
    h.eq(io.yields, 2)
end)

h.check('receive feeds partial reads and stops once the response is complete', function()
    local io = clock()
    local conn = {
        receive = script({
            { nil, 'wantread', '' },
            { nil, 'timeout', 'HTTP/1.1 200 OK\r\nContent-Le' },
            { nil, 'wantread', nil },
            { nil, 'timeout', 'ngth: 2\r\n\r\nh' },
            { nil, 'wantread', 'i' },
            function() error('read past the end of the response') end,
        }),
    }
    local resp = http.new_response()
    h.eq(netio.receive(conn, resp, io, http.feed, http.close), true)
    h.eq(resp.status, 200)
    h.eq(http.body(resp), 'hi')
    h.eq(io.yields, 4)
end)

h.check('receive finishes an until-close body on closed', function()
    local conn = {
        receive = script({
            { nil, 'wantread', 'HTTP/1.1 429 X\r\n\r\n<ht' },
            { nil, 'closed', 'ml>' },
        }),
    }
    local resp = http.new_response()
    h.eq(netio.receive(conn, resp, clock(), http.feed, http.close), true)
    h.eq(resp.status, 429)
    h.eq(http.body(resp), '<html>')
end)

h.check('receive times out instead of spinning forever', function()
    local io = clock(5)
    local conn = { receive = function() return nil, 'wantread', '' end }
    local ok, err = netio.receive(conn, http.new_response(), io, http.feed, http.close)
    h.eq(ok, nil)
    h.eq(err, 'timeout')
    h.eq(io.yields, 5)
end)
