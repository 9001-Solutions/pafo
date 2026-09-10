local h = require('tests.harness')
local device = require('core.device')

h.check('start_result reads the shared device flow shape', function()
    local d = device.start_result({ device_code = 'D', user_code = 'ABCD-EFGH', verify_url = 'https://x/link', interval = 3, expires_in = 300 })
    h.eq(d.device_code, 'D')
    h.eq(d.user_code, 'ABCD-EFGH')
    h.eq(d.interval, 3)
    h.eq(d.expires_in, 300)
end)

h.check('start_result clamps interval and defaults expiry', function()
    local d = device.start_result({ device_code = 'D', user_code = 'U', interval = 0 })
    h.eq(d.interval, 1)
    h.eq(d.expires_in, device.DEFAULT_EXPIRES)
end)

h.check('start_result rejects junk', function()
    local d, err = device.start_result({ code = 'x', poll_secret = 'y' })
    h.eq(d, nil)
    h.truthy(err)
    h.eq(device.start_result('nope'), nil)
end)

h.check('start_error never echoes a raw body', function()
    h.eq(device.start_error(429, '<!DOCTYPE html>...'), 'too many login attempts; wait 10 minutes and try again')
    h.eq(device.start_error(403, '<!DOCTYPE html>...'), 'http 403')
    h.eq(device.start_error(400, { error = 'bad_request' }), 'bad_request')
    h.eq(device.start_error(nil, 'timeout'), 'timeout')
end)

h.check('verify_link never carries the user code', function()
    h.eq(device.verify_link({ verify_url = 'https://x/link', user_code = 'AB-CD' }, 'https://base'), 'https://x/link')
    h.eq(device.verify_link({ user_code = 'AB' }, 'https://base'), 'https://base/link')
end)

local function run_poll(responses, opts)
    opts = opts or {}
    local t, calls = 0, 0
    local co = coroutine.create(function()
        return device.poll({ device_code = 'D', interval = 5, expires_in = opts.expires_in or 60 }, {
            now = function() return t end,
            active = opts.active or function() return true end,
            sleep = function(s)
                t = t + s
                coroutine.yield()
            end,
            request = function(code)
                calls = calls + 1
                h.eq(code, 'D')
                return unpack(responses[calls] or { 200, { error = 'authorization_pending' } })
            end,
        })
    end)
    local frames, result, value = 0, nil, nil
    while coroutine.status(co) ~= 'dead' do
        local ok, r, v = coroutine.resume(co)
        h.truthy(ok)
        frames = frames + 1
        result, value = r, v
        h.truthy(frames < 1000)
    end
    return result, value, frames, calls
end

h.check('poll yields to the game loop before every request', function()
    local pending = { 200, { error = 'authorization_pending' } }
    local result, value, frames, calls = run_poll({ pending, pending, { 200, { token = 'pafo_x' } } })
    h.eq(result, 'ok')
    h.eq(value, 'pafo_x')
    h.eq(calls, 3)
    h.eq(frames, 4)
end)

h.check('poll stops on terminal, timeout, and cancel', function()
    local r, v = run_poll({ { 400, { error = 'expired_token' } } })
    h.eq(r, 'terminal')
    h.eq(v, 'expired_token')
    local rt, _, _, calls = run_poll({}, { expires_in = 20 })
    h.eq(rt, 'timeout')
    h.eq(calls, 4)
    local rc, _, _, ccalls = run_poll({}, { active = function() return false end })
    h.eq(rc, 'cancelled')
    h.eq(ccalls, 0)
end)

h.check('no addon code blocks the game thread with socket.sleep', function()
    for _, path in ipairs({ 'pafo.lua', 'ashita/transport.lua', 'ashita/store.lua', 'ashita/game.lua', 'ashita/ui.lua' }) do
        local f = assert(io.open(path, 'r'))
        local src = f:read('*a')
        f:close()
        h.eq(src:find('socket.sleep(', 1, true), nil)
    end
end)

h.check('poll_result states', function()
    h.eq(device.poll_result(200, { error = 'authorization_pending' }), 'pending')
    h.eq(device.poll_result(200, {}), 'pending')
    local s, tok = device.poll_result(200, { token = 'pafo_x' })
    h.eq(s, 'ok')
    h.eq(tok, 'pafo_x')
    local r, reason = device.poll_result(400, { error = 'expired_token' })
    h.eq(r, 'terminal')
    h.eq(reason, 'expired_token')
    h.eq(device.poll_result(502, nil), 'terminal')
    h.eq(device.poll_result(nil, 'boom'), 'retry')
end)
