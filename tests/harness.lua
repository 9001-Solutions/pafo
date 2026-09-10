local harness = {}

local failures = 0
local passes = 0

function harness.check(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passes = passes + 1
        print('ok   - ' .. name)
    else
        failures = failures + 1
        print('FAIL - ' .. name)
        print('       ' .. tostring(err))
    end
end

function harness.eq(a, b, msg)
    if a ~= b then
        error(string.format('%s\n  expected: %s\n  actual:   %s',
            msg or 'mismatch', tostring(b), tostring(a)), 3)
    end
end

function harness.truthy(v, msg)
    if not v then
        error(msg or 'expected truthy value', 3)
    end
end

function harness.finish()
    print('')
    if failures > 0 then
        print(string.format('%d passed, %d failed', passes, failures))
        os.exit(1)
    end
    print(string.format('%d passed', passes))
end

function harness.counts()
    return passes, failures
end

return harness
