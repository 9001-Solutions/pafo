local h = require('tests.harness')
local submit = require('core.submit')

local function fake(overrides)
    local f = {
        clock = 1000,
        sent = {},
        notices = {},
        logs = {},
        persisted = 0,
        auth_lost = 0,
        disabled = 0,
        outdated = 0,
        ctx = {
            token = 'tok',
            ingest_url = 'https://ingest.example',
            server_slug = 'horizon',
            addon_version = '0.1.0',
            reporter = { char_name = 'Me', job = 'THF', level = 75 },
            batch = { flush_seconds = 60, max_events = 3 },
        },
        ctx_reason = nil,
    }
    f.deps = {
        now = function() return f.clock end,
        context = function()
            if f.ctx_reason then return nil, f.ctx_reason end
            return f.ctx
        end,
        send = function(url, token, body, cb)
            f.sent[#f.sent + 1] = { url = url, token = token, body = body, cb = cb }
        end,
        notify = function(t) f.notices[#f.notices + 1] = t end,
        log = function(t) f.logs[#f.logs + 1] = t end,
        persist = function() f.persisted = f.persisted + 1 end,
        on_auth_lost = function() f.auth_lost = f.auth_lost + 1 end,
        on_server_disabled = function() f.disabled = f.disabled + 1 end,
        on_outdated = function() f.outdated = f.outdated + 1 end,
    }
    for k, v in pairs(overrides or {}) do f[k] = v end
    return f
end

local function ev(id, at)
    return { id = id, type = 'steal', observed_at = at, zone_id = 1, result = 'failed' }
end

h.check('nothing is sent without context and the server prompt fires once', function()
    local f = fake({ ctx_reason = 'no_server' })
    local s = submit.new(f.deps)
    submit.push(s, ev('a', 0))
    h.eq(submit.tick(s), false)
    submit.tick(s)
    h.eq(#f.notices, 1)
    h.eq(#f.sent, 0)
end)

h.check('flush sends the envelope with bearer token and ago', function()
    local f = fake()
    local s = submit.new(f.deps)
    submit.push(s, ev('a', 900))
    h.eq(submit.tick(s), true)
    h.eq(#f.sent, 1)
    h.eq(f.sent[1].url, 'https://ingest.example/ingest')
    h.eq(f.sent[1].token, 'tok')
    h.eq(f.sent[1].body.events[1].ago, 100)
    h.eq(f.sent[1].body.server_slug, 'horizon')
    h.eq(submit.tick(s), false)
    f.sent[1].cb(200, { accepted = 1, duplicates = 0, rejected = {} })
    h.eq(submit.depth(s), 0)
end)

h.check('retry keeps events and persists', function()
    local f = fake()
    local s = submit.new(f.deps)
    submit.push(s, ev('a', 900))
    submit.tick(s)
    f.sent[1].cb(nil, 'timeout')
    h.eq(submit.depth(s), 1)
    h.eq(f.persisted, 1)
    h.eq(submit.status(s).retry_in, 30)
    f.clock = 1029
    h.eq(submit.tick(s), false)
    f.clock = 1030
    h.eq(submit.tick(s), true)
end)

h.check('401 halts until resume and calls on_auth_lost', function()
    local f = fake()
    local s = submit.new(f.deps)
    submit.push(s, ev('a', 900))
    submit.tick(s)
    f.sent[1].cb(401, { error = 'invalid_token' })
    h.eq(f.auth_lost, 1)
    h.eq(submit.halted(s), 'auth')
    f.clock = 5000
    h.eq(submit.tick(s), false)
    submit.resume(s)
    h.eq(submit.tick(s), true)
end)

h.check('server_disabled drops everything', function()
    local f = fake()
    local s = submit.new(f.deps)
    submit.push(s, ev('a', 900))
    submit.push(s, ev('b', 900))
    submit.tick(s)
    f.sent[1].cb(403, { error = 'server_disabled' })
    h.eq(f.disabled, 1)
    h.eq(submit.depth(s), 0)
end)

h.check('unsupported protocol halts as outdated', function()
    local f = fake()
    local s = submit.new(f.deps)
    submit.push(s, ev('a', 900))
    submit.tick(s)
    f.sent[1].cb(400, { error = 'unsupported_protocol' })
    h.eq(f.outdated, 1)
    h.eq(submit.halted(s), 'outdated')
    h.eq(submit.depth(s), 1)
end)

h.check('400 with rejections drops only the rejected events and resends the rest', function()
    local f = fake()
    local s = submit.new(f.deps)
    submit.push(s, ev('a', 900))
    submit.push(s, ev('b', 900))
    submit.tick(s)
    f.sent[1].cb(400, { rejected = { { index = 0, reason = 'bad ago' } } })
    h.eq(submit.depth(s), 1)
    h.eq(s.q.events[1].id, 'b')
    h.eq(submit.tick(s), true)
    h.eq(#f.sent, 2)
    h.eq(f.sent[2].body.events[1].id, 'b')
end)

h.check('server_disabled drops only that server and unlabelled events', function()
    local f = fake()
    local s = submit.new(f.deps)
    submit.push(s, ev('a', 900))
    local other = ev('c', 900)
    other.server_slug = 'phoenix'
    submit.push(s, other)
    submit.tick(s)
    f.sent[1].cb(403, { error = 'server_disabled' })
    h.eq(submit.depth(s), 1)
    h.eq(s.q.events[1].id, 'c')
end)

h.check('a late response for a timed-out request is ignored', function()
    local f = fake()
    local s = submit.new(f.deps)
    submit.push(s, ev('a', 900))
    submit.tick(s)
    local stale = f.sent[1].cb
    f.clock = 1000 + submit.IN_FLIGHT_TIMEOUT + 1
    submit.tick(s)
    stale(200, { accepted = 1, duplicates = 0, rejected = {} })
    h.eq(submit.depth(s), 1)
    h.eq(s.q.in_flight ~= nil, true)
    f.sent[2].cb(200, { accepted = 1, duplicates = 0, rejected = {} })
    h.eq(submit.depth(s), 0)
end)

h.check('rejected events are logged and removed with the batch', function()
    local f = fake()
    local s = submit.new(f.deps)
    submit.push(s, ev('a', 900))
    submit.push(s, ev('b', 900))
    submit.tick(s)
    f.sent[1].cb(200, { accepted = 1, duplicates = 0, rejected = { { index = 1, reason = 'bad zone_id' } } })
    h.eq(submit.depth(s), 0)
    h.truthy(f.logs[1]:find('bad zone_id'))
end)

h.check('a request that never answers is released after the timeout', function()
    local f = fake()
    local s = submit.new(f.deps)
    submit.push(s, ev('a', 900))
    submit.tick(s)
    f.clock = 1000 + submit.IN_FLIGHT_TIMEOUT + 1
    h.eq(submit.tick(s), true)
    h.eq(#f.sent, 2)
end)

h.check('rate limit uses retry_after', function()
    local f = fake()
    local s = submit.new(f.deps)
    submit.push(s, ev('a', 900))
    submit.tick(s)
    f.sent[1].cb(429, { error = 'rate_limited' }, { ['retry-after'] = '600' })
    h.eq(submit.status(s).retry_in, 600)
end)
