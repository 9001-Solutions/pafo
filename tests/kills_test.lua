local h = require('tests.harness')
local kills = require('core.kills')
local th = require('core.th')

local MOB = 0x1000100
local SELF = { server_id = 1, name = 'Me', is_self = true, main_job = 1, sub_job = 2, level = 75, gear_sources = 0 }

local function finalize(t, now, resolve)
    return kills.tick(t, now, resolve, 4)
end

h.check('claimed kill with drops produces one event', function()
    local t = kills.new(0)
    kills.on_action(t, MOB, SELF, 100, 100)
    kills.on_death(t, MOB, 110, { name = 'Valkurm Emperor', claimed = true, zone_id = 103 })
    kills.on_drop(t, MOB, 17061, 1, 110)
    kills.on_drop(t, MOB, 17061, 1, 110)
    kills.on_drop(t, MOB, 4357, 1, 111)
    local events = finalize(t, 112)
    h.eq(#events, 0)
    events = finalize(t, 114)
    h.eq(#events, 1)
    local ev = events[1]
    h.eq(ev.type, 'kill')
    h.eq(ev.mob.actor_id, MOB)
    h.eq(ev.mob.name, 'Valkurm Emperor')
    h.eq(ev.zone_id, 103)
    h.eq(ev.observed_at, 110)
    h.eq(#ev.drops, 2)
    h.eq(ev.drops[1].item_id, 17061)
    h.eq(ev.drops[1].count, 2)
    h.eq(ev.th.source, 'none')
    h.eq(#finalize(t, 200), 0)
end)

h.check('kill with no drops sends empty drops', function()
    local t = kills.new(0)
    kills.on_action(t, MOB, SELF, 100, 100)
    kills.on_death(t, MOB, 110, { name = 'Bee', claimed = true, zone_id = 1 })
    local events = finalize(t, 120)
    h.eq(#events, 1)
    h.eq(#events[1].drops, 0)
end)

h.check('unclaimed kills are discarded', function()
    local t = kills.new(0)
    kills.on_action(t, MOB, SELF, 100, 100)
    kills.on_death(t, MOB, 110, { name = 'Bee', claimed = false, zone_id = 1 })
    local events, discards = finalize(t, 120)
    h.eq(#events, 0)
    h.eq(discards[1].reason, 'unclaimed')
end)

h.check('death of an untracked mob is ignored', function()
    local t = kills.new(0)
    h.eq(kills.on_death(t, MOB, 110, { name = 'Bee', claimed = true, zone_id = 1 }), false)
    h.eq(#finalize(t, 200), 0)
end)

h.check('mob first seen wounded right after load is discarded', function()
    local t = kills.new(100)
    kills.on_action(t, MOB, SELF, 110, 60)
    kills.on_death(t, MOB, 120, { name = 'Bee', claimed = true, zone_id = 1 })
    local events, discards = finalize(t, 130)
    h.eq(#events, 0)
    h.eq(discards[1].reason, 'mid_fight')
end)

h.check('mob first seen wounded long after load is kept', function()
    local t = kills.new(0)
    kills.on_action(t, MOB, SELF, 110, 60)
    kills.on_death(t, MOB, 120, { name = 'Bee', claimed = true, zone_id = 1 })
    h.eq(#finalize(t, 130), 1)
end)

h.check('drops extend the grace window', function()
    local t = kills.new(0)
    kills.on_action(t, MOB, SELF, 100, 100)
    kills.on_death(t, MOB, 110, { name = 'Bee', claimed = true, zone_id = 1 })
    kills.on_drop(t, MOB, 1, 1, 112)
    h.eq(#finalize(t, 113.5), 0)
    h.eq(#finalize(t, 115), 1)
end)

h.check('reset on zone drops in-flight kills', function()
    local t = kills.new(0)
    kills.on_action(t, MOB, SELF, 100, 100)
    kills.on_death(t, MOB, 110, { name = 'Bee', claimed = true, zone_id = 1 })
    kills.reset(t, 111)
    h.eq(#finalize(t, 200), 0)
    h.eq(t.tracking_since, 111)
end)

h.check('actors keep latest level and highest gear sources', function()
    local t = kills.new(0)
    local me = { server_id = 1, name = 'Me', is_self = true, main_job = th.THF, level = 75, gear_sources = 1 }
    kills.on_action(t, MOB, me, 100, 100)
    me.gear_sources = 2
    kills.on_action(t, MOB, me, 101, 90)
    me.gear_sources = 0
    kills.on_action(t, MOB, me, 102, 80)
    kills.on_death(t, MOB, 110, { name = 'Bee', claimed = true, zone_id = 1 })
    local ev = finalize(t, 120)[1]
    h.eq(ev.th.min, 4)
    h.eq(ev.th.exact, true)
    h.eq(ev.th.source, 'gear_detected')
end)

h.check('cached answers resolve other THFs at finalize', function()
    local t = kills.new(0)
    local other = { server_id = 2, name = 'Bob', is_self = false, main_job = th.THF, level = 75 }
    kills.on_action(t, MOB, SELF, 100, 100)
    kills.on_action(t, MOB, other, 101, 100)
    kills.on_death(t, MOB, 110, { name = 'Bee', claimed = true, zone_id = 1 })
    local ev = finalize(t, 120, function(a) if a.name == 'Bob' then return 3 end end)[1]
    h.eq(ev.th.min, 3)
    h.eq(ev.th.source, 'user_prompted')
end)

h.check('unanswered other THF submits as unknown immediately', function()
    local t = kills.new(0)
    local other = { server_id = 2, name = 'Bob', is_self = false, main_job = th.THF, level = 75 }
    kills.on_action(t, MOB, other, 101, 100)
    kills.on_death(t, MOB, 110, { name = 'Bee', claimed = true, zone_id = 1 })
    local ev = finalize(t, 120, function() return nil end)[1]
    h.eq(ev.th.min, 2)
    h.eq(ev.th.exact, false)
    h.eq(ev.th.source, 'unknown')
end)

h.check('two mobs dying together keep drops separate', function()
    local t = kills.new(0)
    local MOB2 = MOB + 1
    kills.on_action(t, MOB, SELF, 100, 100)
    kills.on_action(t, MOB2, SELF, 100, 100)
    kills.on_death(t, MOB, 110, { name = 'A', claimed = true, zone_id = 1 })
    kills.on_death(t, MOB2, 110, { name = 'B', claimed = true, zone_id = 1 })
    kills.on_drop(t, MOB2, 500, 1, 110)
    local events = finalize(t, 120)
    h.eq(#events, 2)
    local by = {}
    for _, e in ipairs(events) do by[e.mob.name] = e end
    h.eq(#by.A.drops, 0)
    h.eq(by.B.drops[1].item_id, 500)
end)
