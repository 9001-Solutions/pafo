local drops = require('core.drops')

local battlefield = {}

battlefield.CRATE_NAME = 'Armoury Crate'
battlefield.ENTRY_EVENT = 32000
battlefield.GRACE_SECONDS = 5

function battlefield.new()
    return { selected = nil, window = nil }
end

function battlefield.is_crate(name)
    return name == battlefield.CRATE_NAME
end

function battlefield.option_index(option)
    if option == 0 or option == 255 then
        return nil
    end
    return math.floor(option / 16)
end

function battlefield.on_select(s, zone_id, index, name)
    s.selected = { zone_id = zone_id, index = index, name = name }
end

function battlefield.on_open(s, crate_id, now, gil, zone_id)
    if s.window and s.window.crate_id == crate_id then
        s.window.last_at = now
        return
    end
    s.window = {
        crate_id = crate_id,
        opened_at = now,
        last_at = now,
        gil_before = gil,
        zone_id = zone_id,
        items = {},
    }
end

function battlefield.on_drop(s, dropper_id, item_id, count, now)
    local w = s.window
    if w == nil or w.crate_id ~= dropper_id then
        return false
    end
    drops.add(w.items, item_id, count)
    w.last_at = now
    return true
end

local function build(s, w, gil, partial)
    local sel = s.selected
    local name = sel and sel.name or nil
    if name == nil or name == '' then
        name = ('unknown zone %d'):format(w.zone_id or 0)
    end
    local delta = 0
    if gil ~= nil and w.gil_before ~= nil then
        delta = math.max(0, gil - w.gil_before)
    end
    return {
        type = 'battlefield',
        observed_at = w.opened_at,
        zone_id = w.zone_id,
        battlefield = { name = name, entry_zone_id = sel and sel.zone_id or w.zone_id },
        crate_actor_id = w.crate_id,
        items = w.items,
        gil = delta,
        partial = partial,
    }
end

function battlefield.tick(s, now, gil)
    local w = s.window
    if w == nil or now - w.last_at < battlefield.GRACE_SECONDS then
        return nil
    end
    s.window = nil
    return build(s, w, gil, false)
end

function battlefield.on_zone(s, gil)
    local w = s.window
    if w == nil then
        return nil
    end
    s.window = nil
    return build(s, w, gil, true)
end

return battlefield
