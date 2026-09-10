local ingest = {}

local function header(headers, name)
    if type(headers) ~= 'table' then
        return nil
    end
    for k, v in pairs(headers) do
        if type(k) == 'string' and k:lower() == name then
            return v
        end
    end
    return nil
end

local function err_code(body)
    if type(body) == 'table' and type(body.error) == 'string' then
        return body.error
    end
    return nil
end

-- status nil means the transport failed before the server answered.
function ingest.classify(status, body, headers)
    if status == nil then
        return { kind = 'retry', reason = tostring(body or 'network error') }
    end
    if status == 200 then
        local rejected = type(body) == 'table' and type(body.rejected) == 'table' and body.rejected or {}
        return {
            kind = 'ok',
            accepted = type(body) == 'table' and tonumber(body.accepted) or 0,
            duplicates = type(body) == 'table' and tonumber(body.duplicates) or 0,
            rejected = rejected,
        }
    end
    if status == 401 then
        return { kind = 'auth' }
    end
    if status == 403 then
        if err_code(body) == 'server_disabled' then
            return { kind = 'server_disabled' }
        end
        return { kind = 'drop_batch', reason = err_code(body) or 'forbidden' }
    end
    if status == 429 then
        return { kind = 'rate_limited', retry_after = tonumber(header(headers, 'retry-after')) }
    end
    if status == 400 then
        local code = err_code(body)
        if code == 'unsupported_protocol' then
            return { kind = 'outdated' }
        end
        if type(body) == 'table' and type(body.rejected) == 'table' then
            return { kind = 'partial', rejected = body.rejected }
        end
        if code == 'unknown_server' then
            return { kind = 'server_disabled' }
        end
        return { kind = 'drop_batch', reason = code or 'bad request' }
    end
    if status >= 500 then
        return { kind = 'retry', reason = 'server error ' .. tostring(status) }
    end
    return { kind = 'drop_batch', reason = err_code(body) or ('http ' .. tostring(status)) }
end

return ingest
