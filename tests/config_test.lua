local h = require('tests.harness')
local config = require('core.config')

local sample = {
    protocol = 1,
    ingest_url = 'https://ingest.example/',
    batch = { flush_seconds = 30, max_events = 10 },
    servers = {
        { slug = 'horizon', name = 'HorizonXI', enabled = true, max_th = 4, th_plus_item_ids = { 1, 2, 3 } },
        { slug = 'phoenix', name = 'Phoenix', enabled = false },
    },
    future_field = 'ignored',
}

h.check('normalize keeps servers and strips trailing slash', function()
    local cfg, err = config.normalize(sample)
    h.eq(err, nil)
    h.eq(cfg.ingest_url, 'https://ingest.example')
    h.eq(cfg.batch.flush_seconds, 30)
    h.eq(#cfg.servers, 2)
    h.eq(cfg.servers[2].enabled, false)
    h.eq(cfg.servers[2].max_th, 4)
    h.eq(#cfg.servers[1].th_plus_item_ids, 3)
end)

h.check('normalize rejects malformed config', function()
    local cfg, err = config.normalize({ protocol = 1 })
    h.eq(cfg, nil)
    h.truthy(err)
    h.eq(config.normalize('x'), nil)
end)

h.check('missing batch falls back to defaults', function()
    local cfg = config.normalize({ protocol = 1, ingest_url = 'u', servers = {} })
    h.eq(cfg.batch.flush_seconds, 60)
    h.eq(cfg.batch.max_events, 25)
end)

h.check('server lookup by slug', function()
    local cfg = config.normalize(sample)
    h.eq(config.server(cfg, 'phoenix').name, 'Phoenix')
    h.eq(config.server(cfg, 'nope'), nil)
    h.eq(config.server(nil, 'x'), nil)
    h.eq(#config.slugs(cfg), 2)
end)

h.check('server_host reads --server from the loader command line', function()
    h.eq(config.server_host('"C:\\game\\bootloader\\horizon-loader.exe" --server play.horizonxi.com --user x'), 'play.horizonxi.com')
    h.eq(config.server_host('xiloader.exe --server=Play.HorizonXI.com'), 'play.horizonxi.com')
    h.eq(config.server_host('xiloader.exe --server "play.horizonxi.com" --hairpin'), 'play.horizonxi.com')
    h.eq(config.server_host('xiloader.exe --server 10.0.0.5:54231'), '10.0.0.5')
    h.eq(config.server_host('--server play.horizonxi.com'), 'play.horizonxi.com')
    h.eq(config.server_host('pol.exe /game eAZcFcB'), nil)
    h.eq(config.server_host('x.exe --serverx a.com --xserver b.com'), nil)
    h.eq(config.server_host(nil), nil)
end)

h.check('slug_for_host matches config hosts exactly or as a subdomain', function()
    local cfg = config.normalize({
        protocol = 1,
        ingest_url = 'u',
        servers = {
            { slug = 'edenxi', hosts = { 'Play.EdenXI.com', 5 } },
            { slug = 'horizonxi', hosts = { 'play.horizonxi.com' } },
            { slug = 'nohost' },
        },
    })
    h.eq(cfg.servers[1].hosts[1], 'play.edenxi.com')
    h.eq(#cfg.servers[1].hosts, 1)
    h.eq(#cfg.servers[3].hosts, 0)
    h.eq(config.slug_for_host(cfg, 'play.edenxi.com'), 'edenxi')
    h.eq(config.slug_for_host(cfg, 'eu.play.edenxi.com'), 'edenxi')
    h.eq(config.slug_for_host(cfg, 'evilplay.edenxi.com'), nil)
    h.eq(config.slug_for_host(cfg, 'play.horizonxi.com'), 'horizonxi')
    h.eq(config.slug_for_host(nil, 'play.horizonxi.com'), nil)
    h.eq(config.slug_for_host(cfg, '10.0.0.5'), nil)
    h.eq(config.slug_for_host(cfg, nil), nil)
end)
