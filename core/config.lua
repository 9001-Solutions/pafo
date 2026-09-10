local config = {}

config.DEFAULT_BATCH = { flush_seconds = 60, max_events = 25 }

local function host_list(raw)
    local out, seen = {}, {}
    for _, h in ipairs(type(raw) == 'table' and raw or {}) do
        if type(h) == 'string' and h ~= '' then
            h = h:lower()
            if not seen[h] then
                seen[h] = true
                out[#out + 1] = h
            end
        end
    end
    return out
end

function config.normalize(body)
    if type(body) ~= 'table' then
        return nil, 'config is not an object'
    end
    if tonumber(body.protocol) == nil then
        return nil, 'config missing protocol'
    end
    if type(body.ingest_url) ~= 'string' or body.ingest_url == '' then
        return nil, 'config missing ingest_url'
    end
    if type(body.servers) ~= 'table' then
        return nil, 'config missing servers'
    end
    local batch = type(body.batch) == 'table' and body.batch or {}
    local servers = {}
    for _, s in ipairs(body.servers) do
        if type(s) == 'table' and type(s.slug) == 'string' then
            local ids = {}
            for _, id in ipairs(type(s.th_plus_item_ids) == 'table' and s.th_plus_item_ids or {}) do
                if tonumber(id) then
                    ids[#ids + 1] = tonumber(id)
                end
            end
            servers[#servers + 1] = {
                slug = s.slug,
                name = type(s.name) == 'string' and s.name or s.slug,
                enabled = s.enabled ~= false,
                max_th = tonumber(s.max_th) or 4,
                th_plus_item_ids = ids,
                hosts = host_list(s.hosts),
            }
        end
    end
    return {
        protocol = tonumber(body.protocol),
        ingest_url = body.ingest_url:gsub('/+$', ''),
        batch = {
            flush_seconds = tonumber(batch.flush_seconds) or config.DEFAULT_BATCH.flush_seconds,
            max_events = tonumber(batch.max_events) or config.DEFAULT_BATCH.max_events,
        },
        servers = servers,
    }
end

function config.server(cfg, slug)
    if cfg == nil or slug == nil then
        return nil
    end
    for _, s in ipairs(cfg.servers) do
        if s.slug == slug then
            return s
        end
    end
    return nil
end

function config.server_host(cmdline)
    if type(cmdline) ~= 'string' then
        return nil
    end
    local padded = ' ' .. cmdline
    local host = padded:match('%s%-%-server[=%s]+"([^"]+)"') or padded:match('%s%-%-server[=%s]+([^%s"]+)')
    if host == nil then
        return nil
    end
    host = host:lower():gsub(':%d+$', '')
    if host == '' then
        return nil
    end
    return host
end

local function host_matches(host, pattern)
    return host == pattern or host:sub(-(#pattern + 1)) == '.' .. pattern
end

function config.slug_for_host(cfg, host)
    if host == nil then
        return nil
    end
    for _, s in ipairs(cfg and cfg.servers or {}) do
        for _, h in ipairs(s.hosts or {}) do
            if host_matches(host, h) then
                return s.slug
            end
        end
    end
    return nil
end

function config.slugs(cfg)
    local out = {}
    for _, s in ipairs(cfg and cfg.servers or {}) do
        out[#out + 1] = s.slug
    end
    return out
end

return config
