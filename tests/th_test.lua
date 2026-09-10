local h = require('tests.harness')
local th = require('core.th')

local THF = th.THF
local WAR = 1

local function actor(o)
    return o
end

local function eval(actors, max_th)
    local r = th.evaluate(actors, max_th)
    return r.min, r.exact, r.source
end

h.check('no THF gives none', function()
    local m, e, s = eval({ actor({ main_job = WAR, sub_job = 2, level = 75 }) })
    h.eq(m, 0); h.eq(e, true); h.eq(s, 'none')
    m, e, s = eval({})
    h.eq(m, 0); h.eq(e, true); h.eq(s, 'none')
end)

h.check('THF sub or low level main gives TH1', function()
    local m, e, s = eval({ actor({ main_job = WAR, sub_job = THF, level = 75 }) })
    h.eq(m, 1); h.eq(e, true); h.eq(s, 'sub_or_lowlevel')
    m, e, s = eval({ actor({ main_job = THF, sub_job = WAR, level = 44 }) })
    h.eq(m, 1); h.eq(e, true); h.eq(s, 'sub_or_lowlevel')
end)

h.check('main THF 45 to 74 gives TH2 level_inferred', function()
    local m, e, s = eval({ actor({ main_job = THF, level = 45 }) })
    h.eq(m, 2); h.eq(e, true); h.eq(s, 'level_inferred')
    m = eval({ actor({ main_job = THF, level = 74 }) })
    h.eq(m, 2)
end)

h.check('self 75 THF uses gear sources', function()
    local m, e, s = eval({ actor({ is_self = true, main_job = THF, level = 75, gear_sources = 0 }) })
    h.eq(m, 2); h.eq(e, true); h.eq(s, 'gear_detected')
    m = eval({ actor({ is_self = true, main_job = THF, level = 75, gear_sources = 1 }) })
    h.eq(m, 3)
    m = eval({ actor({ is_self = true, main_job = THF, level = 75, gear_sources = 2 }) })
    h.eq(m, 4)
    m = eval({ actor({ is_self = true, main_job = THF, level = 75, gear_sources = 5 }) }, 4)
    h.eq(m, 4)
end)

h.check('other 75 THF unanswered is TH2 unknown', function()
    local m, e, s = eval({ actor({ main_job = THF, level = 75 }) })
    h.eq(m, 2); h.eq(e, false); h.eq(s, 'unknown')
end)

h.check('other 75 THF answered is user_prompted', function()
    local m, e, s = eval({ actor({ main_job = THF, level = 75, answer = 3 }) })
    h.eq(m, 3); h.eq(e, true); h.eq(s, 'user_prompted')
end)

h.check('multiple THFs take the highest resolved tier', function()
    local m, e, s = eval({
        actor({ main_job = THF, level = 60 }),
        actor({ main_job = THF, level = 75, answer = 4 }),
        actor({ main_job = WAR, sub_job = THF, level = 75 }),
    })
    h.eq(m, 4); h.eq(e, true); h.eq(s, 'user_prompted')
end)

h.check('unresolved 75 THF makes a lower exact tier inexact', function()
    local m, e, s = eval({
        actor({ is_self = true, main_job = THF, level = 75, gear_sources = 1 }),
        actor({ main_job = THF, level = 75 }),
    })
    h.eq(m, 3); h.eq(e, false); h.eq(s, 'gear_detected')
    m, e, s = eval({
        actor({ main_job = THF, level = 50 }),
        actor({ main_job = THF, level = 75 }),
    })
    h.eq(m, 2); h.eq(e, false); h.eq(s, 'unknown')
end)

h.check('unresolved THF cannot exceed max tier so exact stays', function()
    local m, e, s = eval({
        actor({ is_self = true, main_job = THF, level = 75, gear_sources = 2 }),
        actor({ main_job = THF, level = 75 }),
    })
    h.eq(m, 4); h.eq(e, true); h.eq(s, 'gear_detected')
end)

h.check('gear sources count distinct slots only', function()
    local ids = { 100, 101, 200 }
    h.eq(th.gear_sources({ { slot = 6, item_id = 100 } }, ids), 1)
    h.eq(th.gear_sources({ { slot = 6, item_id = 100 }, { slot = 6, item_id = 101 } }, ids), 1)
    h.eq(th.gear_sources({ { slot = 6, item_id = 101 }, { slot = 9, item_id = 200 } }, ids), 2)
    h.eq(th.gear_sources({ { slot = 6, item_id = 999 } }, ids), 0)
    h.eq(th.gear_sources({}, ids), 0)
end)

h.check('needs_prompt only for other unanswered 75 THFs', function()
    h.eq(th.needs_prompt({ main_job = THF, level = 75 }), true)
    h.eq(th.needs_prompt({ main_job = THF, level = 75, answer = 2 }), false)
    h.eq(th.needs_prompt({ main_job = THF, level = 74 }), false)
    h.eq(th.needs_prompt({ is_self = true, main_job = THF, level = 75 }), false)
    h.eq(th.needs_prompt({ main_job = WAR, sub_job = THF, level = 75 }), false)
end)
