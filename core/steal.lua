local packets = require('core.packets')

local steal = {}

steal.ABILITIES = {
    [41] = 'steal',
    [228] = 'despoil',
}

-- LandSandBoat sends Steal, Mug and Despoil as SkillFinish (3), not
-- AbilityFinish (6): the category comes from abilities.sql actionType. A
-- category 3 cmd_arg can also be a weapon skill id that collides with these
-- ability ids; classify() only accepts steal/despoil messages, which is what
-- keeps those out.
steal.CMDS = {
    [packets.CMD.WEAPONSKILL] = true,
    [packets.CMD.JOB_ABILITY] = true,
}

steal.MSG_STEAL_SUCCESS = 125
steal.MSG_STEAL_FAIL = 153
steal.MSG_STEAL_EFFECT = 453
steal.MSG_DESPOIL_MIN = 593
steal.MSG_DESPOIL_MAX = 599

-- No known LandSandBoat message distinguishes an empty mob from a failed
-- attempt; ids listed here are treated as nothing_left when they appear.
steal.MSG_NOTHING_LEFT = {}

local function classify(res)
    local msg = res.message
    if steal.MSG_NOTHING_LEFT[msg] then
        return 'nothing_left', nil
    end
    if msg == steal.MSG_STEAL_SUCCESS then
        return 'item', res.value
    end
    if msg >= steal.MSG_DESPOIL_MIN and msg <= steal.MSG_DESPOIL_MAX then
        return 'item', res.value
    end
    if msg == steal.MSG_STEAL_FAIL or msg == steal.MSG_STEAL_EFFECT then
        return 'failed', nil
    end
    return nil
end

function steal.from_action(action, self_id)
    if not steal.CMDS[action.cmd_no] or action.actor_id ~= self_id then
        return {}
    end
    local kind = steal.ABILITIES[action.cmd_arg]
    if kind == nil then
        return {}
    end
    local out = {}
    for _, target in ipairs(action.targets) do
        for _, res in ipairs(target.results) do
            local result, item_id = classify(res)
            if result then
                local ev = { kind = kind, mob_id = target.id, result = result }
                if result == 'item' and item_id and item_id > 0 then
                    ev.item_id = item_id
                elseif result == 'item' then
                    ev.result = 'failed'
                end
                out[#out + 1] = ev
            end
        end
    end
    return out
end

function steal.to_event(ev, now, zone_id, mob_name)
    local out = {
        type = ev.kind,
        observed_at = now,
        zone_id = zone_id,
        mob = { actor_id = ev.mob_id, name = mob_name },
        result = ev.result,
    }
    if ev.result == 'item' then
        out.item_id = ev.item_id
    end
    return out
end

return steal
