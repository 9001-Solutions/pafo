local h = require('tests.harness')
local envelope = require('core.envelope')
local ids = require('core.ids')

h.check('ids are 24 hex characters and unique', function()
    local a = ids.new()
    local b = ids.new()
    h.eq(#a, 24)
    h.truthy(a:match('^[0-9a-f]+$'))
    h.truthy(a ~= b)
end)

h.check('envelope computes ago from observation time and strips it', function()
    local ctx = {
        addon_version = '0.1.0',
        server_slug = 'horizon',
        reporter = { char_name = 'Hanayaka', job = 'THF', sub = 'NIN', level = 75 },
    }
    local events = {
        { id = 'a', type = 'steal', observed_at = 1000, zone_id = 103, result = 'failed', server_slug = 'horizon' },
        { id = 'b', type = 'kill', observed_at = 1090.7, zone_id = 103, drops = {} },
    }
    local env = envelope.build(ctx, events, 1100)
    h.eq(env.protocol, 1)
    h.eq(env.addon_version, '0.1.0')
    h.eq(env.server_slug, 'horizon')
    h.eq(env.reporter.sub, 'NIN')
    h.eq(#env.events, 2)
    h.eq(env.events[1].ago, 100)
    h.eq(env.events[1].observed_at, nil)
    h.eq(env.events[1].server_slug, nil)
    h.eq(env.events[2].ago, 9)
    h.eq(events[1].observed_at, 1000)
end)

h.check('ago never goes negative and sub is omitted when empty', function()
    local ctx = { addon_version = 'x', server_slug = 's', reporter = { char_name = 'c', job = 'WAR', sub = '', level = 1 } }
    local env = envelope.build(ctx, { { id = 'a', observed_at = 500 } }, 400)
    h.eq(env.events[1].ago, 0)
    h.eq(env.reporter.sub, nil)
end)
