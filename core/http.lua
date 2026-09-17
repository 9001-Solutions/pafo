local http = {}

function http.parse_url(url)
    local scheme, rest = tostring(url):match('^(https?)://(.+)$')
    if scheme == nil then
        return nil, 'unsupported url: ' .. tostring(url)
    end
    local hostport, path = rest:match('^([^/?#]+)(.*)$')
    if hostport == nil then
        return nil, 'bad url: ' .. tostring(url)
    end
    if path == '' then
        path = '/'
    elseif path:sub(1, 1) ~= '/' then
        path = '/' .. path
    end
    local secure = scheme == 'https'
    local host, port = hostport:match('^(.-):(%d+)$')
    if host == nil then
        host, port = hostport, secure and 443 or 80
    end
    return { secure = secure, host = host:lower(), port = tonumber(port), path = path }
end

function http.build_request(method, u, headers, body)
    local host = u.host
    if u.port ~= (u.secure and 443 or 80) then
        host = host .. ':' .. u.port
    end
    local lines = {
        ('%s %s HTTP/1.1'):format(method, u.path),
        'Host: ' .. host,
        'Connection: close',
    }
    local names = {}
    for name in pairs(headers or {}) do
        names[#names + 1] = name
    end
    table.sort(names)
    for _, name in ipairs(names) do
        lines[#lines + 1] = name .. ': ' .. tostring(headers[name])
    end
    if body ~= nil then
        lines[#lines + 1] = 'Content-Length: ' .. #body
    end
    return table.concat(lines, '\r\n') .. '\r\n\r\n' .. (body or '')
end

function http.new_response()
    return { state = 'status', buf = '', headers = {}, parts = {} }
end

local function take_line(r)
    local i = r.buf:find('\r\n', 1, true)
    if i == nil then
        return nil
    end
    local line = r.buf:sub(1, i - 1)
    r.buf = r.buf:sub(i + 2)
    return line
end

local function take_bytes(r)
    local n = math.min(r.remaining, #r.buf)
    if n > 0 then
        r.parts[#r.parts + 1] = r.buf:sub(1, n)
        r.buf = r.buf:sub(n + 1)
        r.remaining = r.remaining - n
    end
    return r.remaining == 0
end

local function start_body(r)
    if r.status < 200 then
        r.state = 'status'
        r.headers = {}
        return true
    end
    if r.status == 204 or r.status == 304 then
        r.state = 'done'
        return true
    end
    local te = (r.headers['transfer-encoding'] or ''):lower()
    if te:find('chunked', 1, true) then
        r.state = 'chunk_size'
        return true
    end
    local cl = r.headers['content-length']
    if cl ~= nil then
        local n = tonumber(cl:match('^%s*(%d+)%s*$'))
        if n == nil then
            return nil, 'bad content-length'
        end
        r.remaining = n
        r.state = n == 0 and 'done' or 'length'
        return true
    end
    r.state = 'until_close'
    return true
end

function http.feed(r, data)
    r.buf = r.buf .. data
    while true do
        local st = r.state
        if st == 'done' then
            return true
        elseif st == 'until_close' then
            if #r.buf > 0 then
                r.parts[#r.parts + 1] = r.buf
                r.buf = ''
            end
            return false
        elseif st == 'length' then
            if not take_bytes(r) then
                return false
            end
            r.state = 'done'
        elseif st == 'chunk_data' then
            if not take_bytes(r) then
                return false
            end
            r.state = 'chunk_end'
        elseif st == 'chunk_end' then
            if #r.buf < 2 then
                return false
            end
            if r.buf:sub(1, 2) ~= '\r\n' then
                return nil, 'bad chunk terminator'
            end
            r.buf = r.buf:sub(3)
            r.state = 'chunk_size'
        else
            local line = take_line(r)
            if line == nil then
                return false
            end
            if st == 'status' then
                local code = line:match('^HTTP/%d%.%d%s+(%d%d%d)')
                if code == nil then
                    return nil, 'bad status line'
                end
                r.status = tonumber(code)
                r.state = 'headers'
            elseif st == 'headers' then
                if line == '' then
                    local ok, err = start_body(r)
                    if not ok then
                        return nil, err
                    end
                else
                    local name, value = line:match('^([^:]+):%s*(.-)%s*$')
                    if name == nil then
                        return nil, 'bad header line'
                    end
                    name = name:lower()
                    r.headers[name] = r.headers[name] and (r.headers[name] .. ', ' .. value) or value
                end
            elseif st == 'chunk_size' then
                local size = tonumber(line:match('^%s*(%x+)') or '', 16)
                if size == nil then
                    return nil, 'bad chunk size'
                end
                if size == 0 then
                    r.state = 'trailers'
                else
                    r.remaining = size
                    r.state = 'chunk_data'
                end
            elseif st == 'trailers' then
                if line == '' then
                    r.state = 'done'
                end
            end
        end
    end
end

function http.close(r)
    if r.state == 'done' then
        return true
    end
    if r.state == 'until_close' or r.state == 'trailers' then
        r.state = 'done'
        return true
    end
    return nil, 'connection closed before the response finished'
end

function http.body(r)
    return table.concat(r.parts)
end

return http
