local h = require('tests.harness')
local steal = require('core.steal')

local SELF = 0x1000001
local MOB = 0x1000200

local function action(actor, cmd_no, cmd_arg, results)
    return { actor_id = actor, cmd_no = cmd_no, cmd_arg = cmd_arg, targets = { { id = MOB, results = results } } }
end

h.check('successful steal yields item result', function()
    local evs = steal.from_action(action(SELF, 6, 41, { { message = 125, value = 4357 } }), SELF)
    h.eq(#evs, 1)
    h.eq(evs[1].kind, 'steal')
    h.eq(evs[1].result, 'item')
    h.eq(evs[1].item_id, 4357)
    h.eq(evs[1].mob_id, MOB)
end)

h.check('failed steal and aura steal count as failed', function()
    local evs = steal.from_action(action(SELF, 6, 41, { { message = 153, value = 0 } }), SELF)
    h.eq(evs[1].result, 'failed')
    h.eq(evs[1].item_id, nil)
    evs = steal.from_action(action(SELF, 6, 41, { { message = 453, value = 33 } }), SELF)
    h.eq(evs[1].result, 'failed')
end)

h.check('despoil success messages yield item result', function()
    local evs = steal.from_action(action(SELF, 6, 228, { { message = 597, value = 900 } }), SELF)
    h.eq(evs[1].kind, 'despoil')
    h.eq(evs[1].result, 'item')
    h.eq(evs[1].item_id, 900)
end)

h.check('steal and despoil arrive as SkillFinish (category 3) on LandSandBoat', function()
    local evs = steal.from_action(action(SELF, 3, 41, { { message = 125, value = 750 } }), SELF)
    h.eq(#evs, 1)
    h.eq(evs[1].kind, 'steal')
    h.eq(evs[1].result, 'item')
    h.eq(evs[1].item_id, 750)
    evs = steal.from_action(action(SELF, 3, 41, { { message = 153, value = 0 } }), SELF)
    h.eq(#evs, 1)
    h.eq(evs[1].result, 'failed')
    evs = steal.from_action(action(SELF, 3, 228, { { message = 593, value = 4458 } }), SELF)
    h.eq(#evs, 1)
    h.eq(evs[1].kind, 'despoil')
    h.eq(evs[1].item_id, 4458)
end)

h.check('a weapon skill sharing the steal id is not a steal', function()
    h.eq(#steal.from_action(action(SELF, 3, 41, { { message = 185, value = 612 } }), SELF), 0)
    h.eq(#steal.from_action(action(SELF, 3, 228, { { message = 185, value = 90 } }), SELF), 0)
end)

h.check("another player's successful steal is recorded with its item", function()
    local evs = steal.from_action(action(SELF + 1, 3, 41, { { message = 125, value = 750 } }), SELF)
    h.eq(#evs, 1)
    h.eq(evs[1].kind, 'steal')
    h.eq(evs[1].result, 'item')
    h.eq(evs[1].item_id, 750)
    evs = steal.from_action(action(SELF + 1, 3, 228, { { message = 593, value = 4458 } }), SELF)
    h.eq(#evs, 1)
    h.eq(evs[1].kind, 'despoil')
end)

h.check("another player's failures and itemless results are not recorded", function()
    h.eq(#steal.from_action(action(SELF + 1, 3, 41, { { message = 153, value = 0 } }), SELF), 0)
    h.eq(#steal.from_action(action(SELF + 1, 3, 41, { { message = 453, value = 33 } }), SELF), 0)
    h.eq(#steal.from_action(action(SELF + 1, 3, 41, { { message = 125, value = 0 } }), SELF), 0)
end)

h.check('other abilities and categories are ignored', function()
    h.eq(#steal.from_action(action(SELF, 6, 42, { { message = 125, value = 1 } }), SELF), 0)
    h.eq(#steal.from_action(action(SELF, 1, 41, { { message = 125, value = 1 } }), SELF), 0)
    h.eq(#steal.from_action(action(SELF + 1, 1, 41, { { message = 125, value = 1 } }), SELF), 0)
end)

h.check('nothing_left message ids map when configured', function()
    steal.MSG_NOTHING_LEFT[999] = true
    local evs = steal.from_action(action(SELF, 6, 41, { { message = 999, value = 0 } }), SELF)
    h.eq(evs[1].result, 'nothing_left')
    steal.MSG_NOTHING_LEFT[999] = nil
end)

h.check('to_event builds the wire shape', function()
    local ev = steal.to_event({ kind = 'steal', mob_id = MOB, result = 'item', item_id = 5 }, 1000, 103, 'Goblin Thug')
    h.eq(ev.type, 'steal')
    h.eq(ev.observed_at, 1000)
    h.eq(ev.zone_id, 103)
    h.eq(ev.mob.name, 'Goblin Thug')
    h.eq(ev.item_id, 5)
    local ev2 = steal.to_event({ kind = 'despoil', mob_id = MOB, result = 'failed' }, 1, 2, 'x')
    h.eq(ev2.item_id, nil)
end)
