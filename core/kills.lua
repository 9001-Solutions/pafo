local th = require('core.th')
local drops = require('core.drops')

local kills = {}

kills.GRACE_SECONDS = 3
kills.LOAD_GUARD_SECONDS = 30

function kills.new(now)
    return {
        mobs = {},
        tracking_since = now or 0,
    }
end

function kills.reset(t, now)
    t.mobs = {}
    t.tracking_since = now
end

local function mob_state(t, mob_id)
    local m = t.mobs[mob_id]
    if m == nil then
        m = {
            id = mob_id,
            actors = {},
            drops = {},
            dead = false,
            first_seen = nil,
        }
        t.mobs[mob_id] = m
    end
    return m
end

function kills.on_action(t, mob_id, actor, now, mob_hpp)
    local m = mob_state(t, mob_id)
    if m.first_seen == nil then
        m.first_seen = { at = now, hpp = mob_hpp }
    end
    local a = m.actors[actor.server_id]
    if a == nil then
        a = {
            server_id = actor.server_id,
            name = actor.name,
            is_self = actor.is_self,
            gear_sources = 0,
        }
        m.actors[actor.server_id] = a
    end
    a.name = actor.name or a.name
    a.main_job = actor.main_job
    a.sub_job = actor.sub_job
    a.level = actor.level
    if actor.thf_hint ~= nil and (a.thf_hint == nil or actor.thf_hint > a.thf_hint) then
        a.thf_hint = actor.thf_hint
    end
    if actor.is_self and (actor.gear_sources or 0) > a.gear_sources then
        a.gear_sources = actor.gear_sources
    end
    return a
end

function kills.on_death(t, mob_id, now, info)
    local m = t.mobs[mob_id]
    if m == nil or m.dead then
        return false
    end
    m.dead = true
    m.died_at = now
    m.close_at = now + kills.GRACE_SECONDS
    m.name = info.name
    m.claimed = info.claimed
    m.zone_id = info.zone_id
    return true
end

function kills.on_drop(t, dropper_id, item_id, count, now)
    local m = t.mobs[dropper_id]
    if m == nil then
        return false
    end
    drops.add(m.drops, item_id, count)
    if m.dead then
        m.close_at = now + kills.GRACE_SECONDS
    end
    return true
end

function kills.tracked(t, mob_id)
    return t.mobs[mob_id] ~= nil
end

function kills.actor_list(m)
    local list = {}
    for _, a in pairs(m.actors) do
        list[#list + 1] = a
    end
    table.sort(list, function(x, y) return x.server_id < y.server_id end)
    return list
end

local function discard_reason(t, m)
    if not m.claimed then
        return 'unclaimed'
    end
    local fs = m.first_seen
    if fs and fs.hpp ~= nil and fs.hpp < 100 and fs.at - t.tracking_since < kills.LOAD_GUARD_SECONDS then
        return 'mid_fight'
    end
    return nil
end

function kills.tick(t, now, resolve, max_th)
    local events = {}
    local discards = {}
    for id, m in pairs(t.mobs) do
        if m.dead and m.close_at <= now then
            t.mobs[id] = nil
            local reason = discard_reason(t, m)
            if reason then
                discards[#discards + 1] = { mob_id = id, reason = reason }
            else
                local actors = kills.actor_list(m)
                for _, a in ipairs(actors) do
                    if not a.is_self and resolve then
                        a.answer = resolve(a)
                    end
                end
                events[#events + 1] = {
                    type = 'kill',
                    observed_at = m.died_at,
                    zone_id = m.zone_id,
                    mob = { actor_id = id, name = m.name },
                    drops = m.drops,
                    th = th.evaluate(actors, max_th),
                }
            end
        end
    end
    return events, discards
end

return kills
