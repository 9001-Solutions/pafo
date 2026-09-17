local h = require('tests.harness')
local http = require('core.http')

local function parse_whole(raw, splits)
    local r = http.new_response()
    local done, err = false, nil
    local pos = 1
    for _, cut in ipairs(splits) do
        done, err = http.feed(r, raw:sub(pos, cut))
        if done == nil then
            return nil, err
        end
        pos = cut + 1
    end
    done, err = http.feed(r, raw:sub(pos))
    if done == nil then
        return nil, err
    end
    if not done then
        done, err = http.close(r)
        if not done then
            return nil, err
        end
    end
    return r
end

local function every_split(raw, want_status, want_body)
    for cut = 0, #raw do
        local r, err = parse_whole(raw, { cut })
        h.truthy(r, ('split at %d failed: %s'):format(cut, tostring(err)))
        h.eq(r.status, want_status)
        h.eq(http.body(r), want_body)
    end
    local bytes = {}
    for i = 1, #raw - 1 do
        bytes[#bytes + 1] = i
    end
    local r = parse_whole(raw, bytes)
    h.eq(http.body(r), want_body)
end

h.check('parse_url handles scheme, port, path, and query', function()
    local u = http.parse_url('https://www.PSXI.gg/api/pafo/config')
    h.eq(u.secure, true)
    h.eq(u.host, 'www.psxi.gg')
    h.eq(u.port, 443)
    h.eq(u.path, '/api/pafo/config')
    local l = http.parse_url('http://127.0.0.1:8787')
    h.eq(l.secure, false)
    h.eq(l.port, 8787)
    h.eq(l.path, '/')
    h.eq(http.parse_url('https://x.test?a=1').path, '/?a=1')
    h.eq(http.parse_url('ftp://x'), nil)
end)

h.check('build_request sets host, close, and body length', function()
    local get = http.build_request('GET', http.parse_url('https://x.test/a'), { Accept = 'application/json' })
    h.eq(get, 'GET /a HTTP/1.1\r\nHost: x.test\r\nConnection: close\r\nAccept: application/json\r\n\r\n')
    local post = http.build_request('POST', http.parse_url('http://x.test:8787/i'), {}, '{"a":1}')
    h.eq(post, 'POST /i HTTP/1.1\r\nHost: x.test:8787\r\nConnection: close\r\nContent-Length: 7\r\n\r\n{"a":1}')
end)

h.check('content-length response parses at every split', function()
    every_split('HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n{"ok":true}', 200, '{"ok":true}')
end)

h.check('chunked response parses at every split', function()
    every_split('HTTP/1.1 201 Created\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n{"ok\r\n7;ext=1\r\n":true}\r\n0\r\nX-Trailer: y\r\n\r\n', 201, '{"ok":true}')
end)

h.check('response without length reads until close', function()
    every_split('HTTP/1.0 429 Too Many Requests\r\nContent-Type: text/html\r\n\r\n<html>slow down</html>', 429, '<html>slow down</html>')
end)

h.check('content-length response completes without waiting for close', function()
    local r = http.new_response()
    h.eq(http.feed(r, 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi'), true)
    h.eq(http.body(r), 'hi')
end)

h.check('chunked response closed after the last chunk but before the final crlf is complete', function()
    local r = parse_whole('HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nok\r\n0\r\n', {})
    h.truthy(r)
    h.eq(r.status, 200)
    h.eq(http.body(r), 'ok')
end)

h.check('interim, empty, and header-merge responses', function()
    local r = parse_whole('HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 204 No Content\r\nSet-Cookie: a\r\nSet-Cookie: b\r\n\r\n', {})
    h.eq(r.status, 204)
    h.eq(r.headers['set-cookie'], 'a, b')
    h.eq(http.body(r), '')
end)

h.check('malformed or truncated responses fail', function()
    h.eq(parse_whole('garbage\r\n\r\n', {}), nil)
    h.eq(parse_whole('HTTP/1.1 200 OK\r\nContent-Length: x\r\n\r\n', {}), nil)
    h.eq(parse_whole('HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort', {}), nil)
    h.eq(parse_whole('HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n', {}), nil)
end)
