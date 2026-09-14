local th = {}

local packets = require('core.packets')

th.THF = 6
th.LEVEL_TH2 = 45
th.LEVEL_TH3 = 75

th.JA_SNEAK_ATTACK = 44
th.JA_TRICK_ATTACK = 76
th.JA_ACCOMPLICE = 84
th.JA_COLLABORATOR = 236
th.WS_EVISCERATION = 25

-- Values are the TH floor the action proves for a hidden job: Evisceration
-- is any dagger job (0), SA/TA need THF main or sub (1), Accomplice and
-- Collaborator need THF main 65+ (2).
th.HINT_ACTIONS = {
    [packets.CMD.JOB_ABILITY] = {
        [th.JA_SNEAK_ATTACK] = 1,
        [th.JA_TRICK_ATTACK] = 1,
        [th.JA_ACCOMPLICE] = 2,
        [th.JA_COLLABORATOR] = 2,
    },
    [packets.CMD.WEAPONSKILL] = { [th.WS_EVISCERATION] = 0 },
}

th.HINT_NOTES = {
    [0] = 'job hidden (/anon); Evisceration seen, may not be a THF',
    [1] = 'job hidden (/anon); Sneak/Trick Attack seen, may be a subjob',
    [2] = 'job hidden (/anon); Accomplice/Collaborator seen, THF main 65+',
}

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

-- Anonymous party members arrive with job and level zeroed (LandSandBoat
-- 0x0DD/0x0DF skip those fields for /anon), so 0 means hidden, not a job.
function th.job_known(actor)
    return (actor.main_job or 0) ~= 0
end

function th.hint_floor(cmd_no, cmd_arg)
    local ids = th.HINT_ACTIONS[cmd_no]
    if ids == nil then
        return nil
    end
    return ids[cmd_arg]
end

local function hidden_thf(actor)
    return not th.job_known(actor) and type(actor.thf_hint) == 'number'
end

function th.hint_note(actor)
    if hidden_thf(actor) then
        return th.HINT_NOTES[actor.thf_hint]
    end
    return nil
end

function th.prompt_min(actor)
    if actor.is_self or actor.answer ~= nil then
        return nil
    end
    if actor.main_job == th.THF and (actor.level or 0) >= th.LEVEL_TH3 then
        return 2
    end
    if hidden_thf(actor) then
        return actor.thf_hint
    end
    return nil
end

function th.needs_prompt(actor)
    return th.prompt_min(actor) ~= nil
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
            return { unresolved = true, min = 2 }
        end
        if level >= th.LEVEL_TH2 then
            return { min = 2, exact = true, source = 'level_inferred' }
        end
        return { min = 1, exact = true, source = 'sub_or_lowlevel' }
    end
    if actor.sub_job == th.THF then
        return { min = 1, exact = true, source = 'sub_or_lowlevel' }
    end
    if hidden_thf(actor) then
        local floor = actor.thf_hint
        if actor.answer ~= nil then
            local tier = math.max(floor, math.min(tonumber(actor.answer) or floor, max_th))
            if tier == 0 then
                return nil
            end
            return { min = tier, exact = true, source = 'user_prompted' }
        end
        return { unresolved = true, min = floor }
    end
    return nil
end

function th.evaluate(actors, max_th)
    max_th = max_th or 4
    local best = nil
    local floor = nil
    for _, actor in ipairs(actors or {}) do
        local tier = th.actor_tier(actor, max_th)
        if tier then
            if tier.unresolved then
                if floor == nil or tier.min > floor then
                    floor = tier.min
                end
            elseif best == nil or tier.min > best.min then
                best = tier
            end
        end
    end
    if best == nil then
        if floor ~= nil then
            return { min = floor, exact = false, source = 'unknown' }
        end
        return { min = 0, exact = true, source = 'none' }
    end
    if floor ~= nil and best.min < max_th then
        if best.min <= floor then
            return { min = floor, exact = false, source = 'unknown' }
        end
        return { min = best.min, exact = false, source = best.source }
    end
    return { min = best.min, exact = best.exact, source = best.source }
end

return th
