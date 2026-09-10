local envelope = {}

envelope.PROTOCOL = 1

local function strip(event, now)
    local out = {}
    for k, v in pairs(event) do
        if k ~= 'observed_at' and k ~= 'server_slug' then
            out[k] = v
        end
    end
    out.ago = math.max(0, math.floor(now - event.observed_at))
    return out
end

function envelope.build(ctx, events, now)
    local list = {}
    for i, ev in ipairs(events) do
        list[i] = strip(ev, now)
    end
    local reporter = {
        char_name = ctx.reporter.char_name,
        job = ctx.reporter.job,
        level = ctx.reporter.level,
    }
    if ctx.reporter.sub ~= nil and ctx.reporter.sub ~= '' then
        reporter.sub = ctx.reporter.sub
    end
    return {
        protocol = envelope.PROTOCOL,
        addon_version = ctx.addon_version,
        server_slug = ctx.server_slug,
        reporter = reporter,
        events = list,
    }
end

return envelope
