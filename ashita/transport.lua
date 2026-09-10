local json = require('json')
local http = require('core.http')
local netio = require('core.netio')

local transport = {}

transport.TIMEOUT = 10

local socket = nil
local ssl = nil
local cafile = nil
local pending = {}
local dns_cache = {}

function transport.init(addon_path)
    cafile = addon_path .. 'cacert.pem'
end

local function resolve(host)
    if host:match('^%d+%.%d+%.%d+%.%d+$') then
        return host
    end
    local ip = dns_cache[host]
    if ip ~= nil then
        return ip
    end
    local addr, err = socket.dns.toip(host)
    if addr == nil then
        return nil, err
    end
    dns_cache[host] = addr
    return addr
end

local function next_frame()
    coroutine.sleepf(1)
end

local function exchange(method, u, headers, body)
    local io = { yield = next_frame, now = socket.gettime, deadline = socket.gettime() + transport.TIMEOUT }
    local ip, derr = resolve(u.host)
    if ip == nil then
        return nil, 'dns: ' .. tostring(derr)
    end
    local sock = socket.tcp()
    sock:settimeout(0)
    local conn = sock
    local ok, err = netio.connect(sock, ip, u.port, io, socket.select)
    if not ok then
        dns_cache[u.host] = nil
        sock:close()
        return nil, 'connect: ' .. tostring(err)
    end
    if u.secure then
        conn, err = ssl.wrap(sock, {
            mode = 'client',
            protocol = 'any',
            options = { 'all', 'no_sslv2', 'no_sslv3', 'no_tlsv1' },
            verify = 'peer',
            cafile = cafile,
        })
        if conn == nil then
            sock:close()
            return nil, 'tls: ' .. tostring(err)
        end
        conn:sni(u.host)
        conn:settimeout(0)
        ok, err = netio.handshake(conn, io)
        if not ok then
            conn:close()
            return nil, 'tls: ' .. tostring(err)
        end
    end
    ok, err = netio.send_all(conn, http.build_request(method, u, headers, body), io)
    local resp = http.new_response()
    if ok then
        ok, err = netio.receive(conn, resp, io, http.feed, http.close)
    end
    conn:close()
    if not ok then
        return nil, tostring(err)
    end
    return resp
end

-- Must run inside an ashita task: it yields a frame whenever the socket is
-- not ready, so the game keeps rendering. Calling it from an event handler
-- errors with "attempt to yield from outside a coroutine".
function transport.request_sync(method, url, headers, body)
    local u, uerr = http.parse_url(url)
    if u == nil then
        return nil, uerr, nil
    end
    if socket == nil then
        socket = require('socket')
    end
    if u.secure and ssl == nil then
        ssl = require('socket.ssl')
    end
    local h = { Accept = 'application/json', ['User-Agent'] = socket._VERSION }
    for k, v in pairs(headers or {}) do
        h[k] = v
    end
    local encoded = nil
    if body ~= nil then
        encoded = json.encode(body)
        h['Content-Type'] = 'application/json'
    end
    local resp, err = exchange(method, u, h, encoded)
    if resp == nil then
        return nil, err, nil
    end
    local raw = http.body(resp)
    local decoded = nil
    if raw ~= '' then
        local parsed_ok, parsed = pcall(json.decode, raw)
        if parsed_ok then
            decoded = parsed
        else
            decoded = raw
        end
    end
    return resp.status, decoded, resp.headers
end

function transport.request(method, url, headers, body, callback)
    ashita.tasks.once(0, function()
        local status, decoded, rheaders = transport.request_sync(method, url, headers, body)
        pending[#pending + 1] = function()
            callback(status, decoded, rheaders)
        end
    end)
end

function transport.defer(fn)
    pending[#pending + 1] = fn
end

function transport.pump()
    while #pending > 0 do
        local fn = table.remove(pending, 1)
        local ok, err = pcall(fn)
        if not ok then
            print('[pafo] callback error: ' .. tostring(err))
        end
    end
end

return transport
