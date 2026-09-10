local queue = require('core.queue')
local envelope = require('core.envelope')
local ingest = require('core.ingest')

local submit = {}

submit.IN_FLIGHT_TIMEOUT = 90

function submit.new(deps)
    return {
        deps = deps,
        q = queue.new(),
        prompted_server = false,
        last_error = nil,
        in_flight_at = nil,
        last_result = nil,
        seq = 0,
    }
end

function submit.push(s, event)
    local _, warn = queue.push(s.q, event)
    if warn then
        s.deps.notify('local queue is full (5000); oldest events are being discarded')
    end
end

function submit.depth(s)
    return queue.depth(s.q)
end

function submit.tick(s)
    local now = s.deps.now()
    if s.q.in_flight and s.in_flight_at and now - s.in_flight_at > submit.IN_FLIGHT_TIMEOUT then
        queue.release(s.q)
        s.in_flight_at = nil
        s.deps.log('ingest request timed out without a response')
    end
    local ctx, reason = s.deps.context()
    if ctx == nil then
        if reason == 'no_server' and not s.prompted_server and queue.depth(s.q) > 0 then
            s.prompted_server = true
            s.deps.notify('server not detected; queued reports will wait until it is')
        end
        return false
    end
    if not queue.ready(s.q, now, ctx.batch, ctx.server_slug) then
        return false
    end
    local events = queue.begin_batch(s.q, ctx.batch.max_events, ctx.server_slug)
    local body = envelope.build(ctx, events, now)
    s.in_flight_at = now
    s.seq = s.seq + 1
    local seq = s.seq
    s.deps.send(ctx.ingest_url .. '/ingest', ctx.token, body, function(status, resp, headers)
        submit.handle(s, status, resp, headers, seq)
    end)
    return true
end

function submit.handle(s, status, body, headers, seq)
    if seq ~= nil and seq ~= s.seq then
        s.deps.log('ignoring a late ingest response')
        return nil
    end
    if not s.q.in_flight then
        return nil
    end
    local now = s.deps.now()
    local r = ingest.classify(status, body, headers)
    s.in_flight_at = nil
    s.last_result = r.kind
    if r.kind == 'ok' then
        local removed = queue.finish_ok(s.q)
        s.last_error = nil
        for _, rej in ipairs(r.rejected) do
            s.deps.log(('event %s rejected: %s'):format(tostring(rej.index), tostring(rej.reason)))
        end
        s.deps.log(('batch sent: %d events, %d accepted, %d duplicates, %d rejected'):format(
            removed, r.accepted or 0, r.duplicates or 0, #r.rejected))
        s.deps.persist()
    elseif r.kind == 'partial' then
        local indexes = {}
        for _, rej in ipairs(r.rejected) do
            indexes[#indexes + 1] = rej.index
            s.deps.log(('event %s rejected: %s'):format(tostring(rej.index), tostring(rej.reason)))
        end
        local removed = queue.drop_indexes(s.q, indexes)
        s.last_error = nil
        s.deps.log(('batch refused; %d rejected events dropped, the rest will be resent'):format(removed))
        s.deps.persist()
    elseif r.kind == 'retry' or r.kind == 'rate_limited' then
        local delay = queue.finish_retry(s.q, now, r.retry_after)
        s.last_error = r.reason or 'rate limited'
        s.deps.log(('ingest failed (%s); retrying in %ds'):format(s.last_error, delay))
        s.deps.persist()
    elseif r.kind == 'auth' then
        queue.finish_halt(s.q, 'auth')
        s.last_error = 'token revoked'
        s.deps.persist()
        s.deps.on_auth_lost()
    elseif r.kind == 'outdated' then
        queue.finish_halt(s.q, 'outdated')
        s.last_error = 'protocol rejected'
        s.deps.persist()
        s.deps.on_outdated()
    elseif r.kind == 'server_disabled' then
        local ctx = s.deps.context()
        local n = queue.drop_server(s.q, ctx and ctx.server_slug or nil)
        s.last_error = nil
        s.deps.persist()
        s.deps.on_server_disabled(n)
    elseif r.kind == 'drop_batch' then
        local n = queue.drop_batch(s.q)
        s.last_error = r.reason
        s.deps.log(('batch of %d dropped: %s'):format(n, tostring(r.reason)))
        s.deps.persist()
    end
    return r
end

function submit.resume(s)
    queue.resume(s.q)
end

function submit.halted(s)
    return s.q.halted
end

function submit.status(s)
    local now = s.deps.now()
    local wait = s.q.next_attempt_at - now
    return {
        depth = queue.depth(s.q),
        halted = s.q.halted,
        in_flight = s.q.in_flight ~= nil,
        retry_in = wait > 0 and math.ceil(wait) or 0,
        attempts = s.q.attempts,
        last_error = s.last_error,
    }
end

function submit.export(s)
    return queue.export(s.q)
end

function submit.import(s, data)
    return queue.import(s.q, data)
end

return submit
