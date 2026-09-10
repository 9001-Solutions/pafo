local th = {}

th.THF = 6
th.LEVEL_TH2 = 45
th.LEVEL_TH3 = 75

local function has_id(list, id)
    for _, v in ipairs(list) do
        if v == id then
            return true
        end
    end
    return false
end

-- Sources are distinct slots, not distinct items: both Assassin's Armlets
-- variants must collapse to one hands-slot source per SPEC.md section 5.
function th.gear_sources(equipped, th_plus_item_ids)
    local slots = {}
    local n = 0
    for _, e in ipairs(equipped or {}) do
        if e.item_id and has_id(th_plus_item_ids or {}, e.item_id) and not slots[e.slot] then
            slots[e.slot] = true
            n = n + 1
        end
    end
    return n
end

function th.is_thf_main(actor)
    return actor.main_job == th.THF
end

function th.needs_prompt(actor)
    return not actor.is_self
        and actor.main_job == th.THF
        and (actor.level or 0) >= th.LEVEL_TH3
        and actor.answer == nil
end

function th.actor_tier(actor, max_th)
    max_th = max_th or 4
    local level = actor.level or 0
    if actor.main_job == th.THF then
        if level >= th.LEVEL_TH3 then
            if actor.is_self then
                local tier = math.min(2 + (actor.gear_sources or 0), max_th)
                return { min = tier, exact = true, source = 'gear_detected' }
            end
            if actor.answer ~= nil then
                local tier = math.max(2, math.min(tonumber(actor.answer) or 2, max_th))
                return { min = tier, exact = true, source = 'user_prompted' }
            end
            return { unresolved = true }
        end
        if level >= th.LEVEL_TH2 then
            return { min = 2, exact = true, source = 'level_inferred' }
        end
        return { min = 1, exact = true, source = 'sub_or_lowlevel' }
    end
    if actor.sub_job == th.THF then
        return { min = 1, exact = true, source = 'sub_or_lowlevel' }
    end
    return nil
end

function th.evaluate(actors, max_th)
    max_th = max_th or 4
    local best = nil
    local unresolved = false
    for _, actor in ipairs(actors or {}) do
        local tier = th.actor_tier(actor, max_th)
        if tier then
            if tier.unresolved then
                unresolved = true
            elseif best == nil or tier.min > best.min then
                best = tier
            end
        end
    end
    if best == nil then
        if unresolved then
            return { min = 2, exact = false, source = 'unknown' }
        end
        return { min = 0, exact = true, source = 'none' }
    end
    if unresolved and best.min < max_th then
        if best.min <= 2 then
            return { min = 2, exact = false, source = 'unknown' }
        end
        return { min = best.min, exact = false, source = best.source }
    end
    return { min = best.min, exact = best.exact, source = best.source }
end

return th
