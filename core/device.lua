local device = {}

device.DEFAULT_INTERVAL = 5
device.DEFAULT_EXPIRES = 600

function device.start_result(body)
    if type(body) ~= 'table' then
        return nil, 'bad device response'
    end
    if type(body.device_code) ~= 'string' or type(body.user_code) ~= 'string' then
        return nil, 'device response missing code'
    end
    local interval = tonumber(body.interval) or device.DEFAULT_INTERVAL
    if interval < 1 then
        interval = 1
    end
    return {
        device_code = body.device_code,
        user_code = body.user_code,
        verify_url = type(body.verify_url) == 'string' and body.verify_url or nil,
        expires_in = tonumber(body.expires_in) or device.DEFAULT_EXPIRES,
        interval = interval,
    }
end

function device.start_error(status, body)
    if status == nil then
        return tostring(body or 'network error')
    end
    if status == 429 then
        return 'too many login attempts; wait 10 minutes and try again'
    end
    if type(body) == 'table' and type(body.error) == 'string' then
        return body.error
    end
    return 'http ' .. tostring(status)
end

function device.poll(d, deps)
    local deadline = deps.now() + d.expires_in
    while deps.active() and deps.now() < deadline do
        deps.sleep(d.interval)
        if not deps.active() then
            break
        end
        local result, value = device.poll_result(deps.request(d.device_code))
        if result == 'ok' or result == 'terminal' then
            return result, value
        end
    end
    if not deps.active() then
        return 'cancelled'
    end
    return 'timeout'
end

function device.verify_link(d, base)
    return d.verify_url or (base .. '/link')
end

function device.poll_result(status, body)
    if status == nil then
        return 'retry', tostring(body or 'network error')
    end
    if status ~= 200 then
        local reason = type(body) == 'table' and body.error or ('http ' .. tostring(status))
        return 'terminal', tostring(reason)
    end
    if type(body) == 'table' and type(body.token) == 'string' and body.token ~= '' then
        return 'ok', body.token
    end
    return 'pending'
end

return device
