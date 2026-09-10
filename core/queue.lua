local queue = {}

queue.DISK_CAP = 5000
queue.BACKOFF_BASE = 30
queue.BACKOFF_CAP = 900

function queue.new()
    return {
        events = {},
        in_flight = nil,
        attempts = 0,
        next_attempt_at = 0,
        halted = nil,
        cap_warned = false,
    }
end

function queue.depth(q)
    return #q.events
end

function queue.push(q, event)
    q.events[#q.events + 1] = event
    local dropped = 0
    while #q.events > queue.DISK_CAP do
        table.remove(q.events, 1)
        dropped = dropped + 1
    end
    local warn = dropped > 0 and not q.cap_warned
    if dropped > 0 then
        q.cap_warned = true
    end
    return dropped, warn
end

-- Events queued before a server was chosen carry no slug and go to
-- whichever server is active when they are sent.
local function belongs(ev, slug)
    return ev.server_slug == nil or ev.server_slug == slug
end

function queue.ready(q, now, batch, slug)
    if q.halted or q.in_flight then
        return false
    end
    if now < q.next_attempt_at then
        return false
    end
    local n = 0
    local oldest = nil
    for _, ev in ipairs(q.events) do
        if belongs(ev, slug) then
            n = n + 1
            if oldest == nil or ev.observed_at < oldest then
                oldest = ev.observed_at
            end
        end
    end
    if n == 0 then
        return false
    end
    if n >= batch.max_events then
        return true
    end
    return now - oldest >= batch.flush_seconds
end

function queue.begin_batch(q, max, slug)
    local batch = {}
    local ids = {}
    for _, ev in ipairs(q.events) do
        if #batch >= max then
            break
        end
        if belongs(ev, slug) then
            batch[#batch + 1] = ev
            ids[#ids + 1] = ev.id
        end
    end
    q.in_flight = ids
    return batch
end

local function remove_ids(q, ids)
    local set = {}
    for _, id in ipairs(ids) do
        set[id] = true
    end
    local kept = {}
    local removed = 0
    for _, ev in ipairs(q.events) do
        if set[ev.id] then
            removed = removed + 1
        else
            kept[#kept + 1] = ev
        end
    end
    q.events = kept
    return removed
end

function queue.finish_ok(q)
    local ids = q.in_flight or {}
    q.in_flight = nil
    q.attempts = 0
    q.next_attempt_at = 0
    return remove_ids(q, ids)
end

-- indexes are zero-based positions within the in-flight batch.
function queue.drop_indexes(q, indexes)
    local ids = q.in_flight or {}
    q.in_flight = nil
    local drop = {}
    for _, i in ipairs(indexes) do
        local id = ids[(tonumber(i) or -1) + 1]
        if id then
            drop[#drop + 1] = id
        end
    end
    return remove_ids(q, drop)
end

function queue.backoff_delay(attempts, retry_after)
    if retry_after and retry_after > 0 then
        return retry_after
    end
    return math.min(queue.BACKOFF_BASE * 2 ^ (attempts - 1), queue.BACKOFF_CAP)
end

function queue.finish_retry(q, now, retry_after)
    q.in_flight = nil
    q.attempts = q.attempts + 1
    local delay = queue.backoff_delay(q.attempts, retry_after)
    q.next_attempt_at = now + delay
    return delay
end

function queue.finish_halt(q, reason)
    q.in_flight = nil
    q.halted = reason
end

function queue.drop_batch(q)
    local ids = q.in_flight or {}
    q.in_flight = nil
    return remove_ids(q, ids)
end

function queue.drop_server(q, slug)
    local kept = {}
    local removed = 0
    for _, ev in ipairs(q.events) do
        if belongs(ev, slug) then
            removed = removed + 1
        else
            kept[#kept + 1] = ev
        end
    end
    q.events = kept
    q.in_flight = nil
    return removed
end

function queue.drop_all(q)
    local n = #q.events
    q.events = {}
    q.in_flight = nil
    return n
end

function queue.resume(q)
    q.halted = nil
    q.attempts = 0
    q.next_attempt_at = 0
end

function queue.release(q)
    q.in_flight = nil
end

function queue.export(q)
    local out = {}
    for i, ev in ipairs(q.events) do
        out[i] = ev
    end
    return { events = out }
end

function queue.import(q, data)
    if type(data) ~= 'table' or type(data.events) ~= 'table' then
        return 0
    end
    local n = 0
    for _, ev in ipairs(data.events) do
        if type(ev) == 'table' and ev.id and ev.observed_at then
            q.events[#q.events + 1] = ev
            n = n + 1
        end
    end
    while #q.events > queue.DISK_CAP do
        table.remove(q.events, 1)
    end
    return n
end

return queue
