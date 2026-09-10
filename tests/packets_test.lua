local h = require('tests.harness')
local packets = require('core.packets')

local function le16(v)
    return string.char(v % 256, math.floor(v / 256) % 256)
end

local function le32(v)
    return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

local function pad(s, n)
    return s .. string.rep('\0', n - #s)
end

local function writer()
    local w = { bits = {} }
    function w:put(value, nbits)
        for i = 0, nbits - 1 do
            self.bits[#self.bits + 1] = math.floor(value / (2 ^ i)) % 2
        end
    end
    function w:bytes()
        local out = {}
        for i = 1, #self.bits, 8 do
            local b = 0
            for j = 0, 7 do
                b = b + (self.bits[i + j] or 0) * (2 ^ j)
            end
            out[#out + 1] = string.char(b)
        end
        return table.concat(out)
    end
    return w
end

local function action_packet(actor, cmd_no, cmd_arg, targets)
    local w = writer()
    w:put(actor, 32)
    w:put(#targets, 6)
    w:put(1, 4)
    w:put(cmd_no, 4)
    w:put(cmd_arg, 32)
    w:put(0, 32)
    for _, t in ipairs(targets) do
        w:put(t.id, 32)
        w:put(#t.results, 4)
        for _, r in ipairs(t.results) do
            w:put(r.miss or 0, 3)
            w:put(r.kind or 0, 2)
            w:put(r.sub_kind or 0, 12)
            w:put(r.info or 0, 5)
            w:put(r.scale or 0, 5)
            w:put(r.value or 0, 17)
            w:put(r.message or 0, 10)
            w:put(0, 31)
            if r.proc then
                w:put(1, 1)
                w:put(r.proc.kind or 0, 6)
                w:put(0, 4)
                w:put(r.proc.value or 0, 17)
                w:put(r.proc.message or 0, 10)
            else
                w:put(0, 1)
            end
            w:put(0, 1)
        end
    end
    return string.char(0x28, 0, 0, 0, 0) .. w:bytes() .. string.rep('\0', 8)
end

h.check('action packet parses actor, command, targets and results', function()
    local data = action_packet(0x1000123, 6, 41, {
        { id = 0x1000456, results = { { message = 125, value = 4357 } } },
    })
    local a = packets.action(data)
    h.eq(a.actor_id, 0x1000123)
    h.eq(a.cmd_no, 6)
    h.eq(a.cmd_arg, 41)
    h.eq(#a.targets, 1)
    h.eq(a.targets[1].id, 0x1000456)
    h.eq(a.targets[1].results[1].message, 125)
    h.eq(a.targets[1].results[1].value, 4357)
end)

h.check('action packet with proc block still parses following targets', function()
    local data = action_packet(7, 1, 0, {
        { id = 100, results = { { message = 1, value = 50, proc = { kind = 3, value = 9, message = 161 } } } },
        { id = 200, results = { { message = 1, value = 60 } } },
    })
    local a = packets.action(data)
    h.eq(#a.targets, 2)
    h.eq(a.targets[1].results[1].proc_value, 9)
    h.eq(a.targets[2].id, 200)
    h.eq(a.targets[2].results[1].value, 60)
end)

h.check('entity update reads hpp, status and claim when flagged', function()
    local body = string.char(0x0E, 0, 0, 0) .. le32(0x1000ABC) .. le16(0xABC) .. string.char(0x02, 0)
    body = pad(body, 0x1E) .. string.char(42, 3)
    body = pad(body, 0x2C) .. le32(0x123456) .. string.rep('\0', 4)
    local e = packets.entity_update(body)
    h.eq(e.server_id, 0x1000ABC)
    h.eq(e.index, 0xABC)
    h.eq(e.hpp, 42)
    h.eq(e.status, 3)
    h.eq(e.claim_id, 0x123456)
end)

h.check('entity update omits claim when flag unset', function()
    local body = pad(string.char(0x0E, 0, 0, 0) .. le32(1) .. le16(1) .. string.char(0x01, 0), 0x30)
    h.eq(packets.entity_update(body).claim_id, nil)
end)

h.check('death detection ignores flagged despawns', function()
    h.eq(packets.is_death({ status = 3, flags = 0x30 }), true)
    h.eq(packets.is_death({ status = 2, flags = 0x04 }), true)
    h.eq(packets.is_death({ status = 2, flags = 0x30 }), false)
    h.eq(packets.is_death({ status = 1, flags = 0x00 }), false)
end)

h.check('trophy packet fields', function()
    local body = string.char(0xD2, 0, 0, 0) .. le32(2) .. le32(0x1000777) .. le16(0) .. le16(0) .. le16(17061) .. le16(0x777) .. string.char(4, 0, 1, 0)
    local t = packets.trophy(pad(body, 0x3C))
    h.eq(t.count, 2)
    h.eq(t.dropper_id, 0x1000777)
    h.eq(t.item_id, 17061)
    h.eq(t.dropper_index, 0x777)
    h.eq(t.slot, 4)
    h.eq(t.is_container, 1)
end)

h.check('outgoing event end and action packets', function()
    local ev = string.char(0x5B, 0, 0, 0) .. le32(9) .. le32(0x140) .. le16(1) .. le16(0) .. le16(32000) .. le16(0)
    local p = packets.event_end_out(ev)
    h.eq(p.event_num, 32000)
    h.eq(p.option, 0x140)
    local act = string.char(0x1A, 0, 0, 0) .. le32(55) .. le16(66) .. le16(0)
    local q = packets.action_out(pad(act, 0x1C))
    h.eq(q.target_id, 55)
    h.eq(q.target_index, 66)
    h.eq(q.action_id, 0)
end)
