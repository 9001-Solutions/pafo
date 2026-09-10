local bytes = require('core.bytes')

local packets = {}

packets.ID = {
    ZONE_IN = 0x00A,
    ZONE_OUT = 0x00B,
    ENTITY_UPDATE = 0x00E,
    ACTION = 0x028,
    TROPHY = 0x0D2,
    OUT_ACTION = 0x01A,
    OUT_EVENT_END = 0x05B,
}

packets.CMD = {
    MELEE = 1,
    RANGED = 2,
    WEAPONSKILL = 3,
    MAGIC = 4,
    ITEM = 5,
    JOB_ABILITY = 6,
    MOB_SKILL_START = 7,
    MAGIC_START = 8,
    ITEM_START = 9,
    JOB_ABILITY_START = 10,
    MOB_SKILL = 11,
    RANGED_START = 12,
    DANCER = 14,
    RUNE_FENCER = 15,
}

packets.HOSTILE_CMDS = {
    [1] = true, [2] = true, [3] = true, [4] = true, [6] = true, [11] = true, [14] = true, [15] = true,
}

packets.STATUS_DEAD = { [2] = true, [3] = true }
packets.FLAG_DESPAWN = 0x20

-- LandSandBoat reuses status 2 for out-of-range despawns, flagged in the
-- send mask; only an unflagged 2 or a 3 is an actual death.
function packets.is_death(update)
    if update.status == 3 then
        return true
    end
    if update.status ~= 2 then
        return false
    end
    return math.floor(update.flags / packets.FLAG_DESPAWN) % 2 == 0
end

function packets.action(data)
    local r = bytes.reader(data, 5)
    local action = {}
    action.actor_id = r:read(32)
    action.target_count = r:read(6)
    action.result_count = r:read(4)
    action.cmd_no = r:read(4)
    action.cmd_arg = r:read(32)
    action.info = r:read(32)
    action.targets = {}
    for _ = 1, action.target_count do
        local target = { id = r:read(32), results = {} }
        local n = r:read(4)
        for _ = 1, n do
            local res = {}
            res.miss = r:read(3)
            res.kind = r:read(2)
            res.sub_kind = r:read(12)
            res.info = r:read(5)
            res.scale = r:read(5)
            res.value = r:read(17)
            res.message = r:read(10)
            res.bit = r:read(31)
            if r:read(1) > 0 then
                res.proc_kind = r:read(6)
                res.proc_info = r:read(4)
                res.proc_value = r:read(17)
                res.proc_message = r:read(10)
            end
            if r:read(1) > 0 then
                res.react_kind = r:read(6)
                res.react_info = r:read(4)
                res.react_value = r:read(14)
                res.react_message = r:read(10)
            end
            target.results[#target.results + 1] = res
        end
        action.targets[#action.targets + 1] = target
    end
    return action
end

function packets.entity_update(data)
    local flags = bytes.u8(data, 0x0A)
    local out = {
        server_id = bytes.u32(data, 0x04),
        index = bytes.u16(data, 0x08),
        flags = flags,
        hpp = bytes.u8(data, 0x1E),
        status = bytes.u8(data, 0x1F),
    }
    if flags % 4 >= 2 and #data >= 0x30 then
        out.claim_id = bytes.u32(data, 0x2C)
    end
    return out
end

function packets.trophy(data)
    return {
        count = bytes.u32(data, 0x04),
        dropper_id = bytes.u32(data, 0x08),
        gold = bytes.u16(data, 0x0C),
        item_id = bytes.u16(data, 0x10),
        dropper_index = bytes.u16(data, 0x12),
        slot = bytes.u8(data, 0x14),
        old = bytes.u8(data, 0x15),
        is_container = bytes.u8(data, 0x16),
    }
end

function packets.event_end_out(data)
    return {
        target_id = bytes.u32(data, 0x04),
        option = bytes.u32(data, 0x08),
        target_index = bytes.u16(data, 0x0C),
        mode = bytes.u16(data, 0x0E),
        event_num = bytes.u16(data, 0x10),
        event_para = bytes.u16(data, 0x12),
    }
end

function packets.action_out(data)
    return {
        target_id = bytes.u32(data, 0x04),
        target_index = bytes.u16(data, 0x08),
        action_id = bytes.u16(data, 0x0A),
    }
end

return packets
