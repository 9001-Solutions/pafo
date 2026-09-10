local game = {}

game.PLAYER_INDEX_MIN = 0x400
game.PLAYER_INDEX_MAX = 0x6FF
game.MOB_INDEX_MAX = 0x3FF
game.EQUIP_SLOTS = 16

local function mm()
    return AshitaCore:GetMemoryManager()
end

function game.command_line()
    local ok, line = pcall(function()
        local ffi = require('ffi')
        pcall(ffi.cdef, 'const char* GetCommandLineA(void);')
        return ffi.string(ffi.C.GetCommandLineA())
    end)
    if ok then
        return line
    end
    return nil
end

function game.job_abbr(id)
    if id == nil or id == 0 then
        return nil
    end
    local s = AshitaCore:GetResourceManager():GetString('jobs.names_abbr', id)
    if s == nil or s == '' then
        return nil
    end
    return s
end

function game.self()
    local ent = GetPlayerEntity()
    if ent == nil then
        return nil
    end
    local player = mm():GetPlayer()
    return {
        server_id = ent.ServerId,
        index = ent.TargetIndex,
        name = ent.Name,
        main_job = player:GetMainJob(),
        level = player:GetMainJobLevel(),
        sub_job = player:GetSubJob(),
    }
end

function game.zone_id()
    return mm():GetParty():GetMemberZone(0)
end

function game.gil()
    local item = mm():GetInventory():GetContainerItem(0, 0)
    if item == nil then
        return 0
    end
    return item.Count
end

function game.party_members()
    local party = mm():GetParty()
    local out = {}
    for i = 0, 17 do
        if party:GetMemberIsActive(i) ~= 0 then
            out[#out + 1] = {
                server_id = party:GetMemberServerId(i),
                name = party:GetMemberName(i),
                main_job = party:GetMemberMainJob(i),
                level = party:GetMemberMainJobLevel(i),
                sub_job = party:GetMemberSubJob(i),
            }
        end
    end
    return out
end

function game.party_member(server_id)
    for _, m in ipairs(game.party_members()) do
        if m.server_id == server_id then
            return m
        end
    end
    return nil
end

function game.party_ids()
    local set = {}
    for _, m in ipairs(game.party_members()) do
        set[m.server_id] = true
    end
    return set
end

function game.is_mob_id(server_id)
    if server_id == nil or server_id < 0x1000000 then
        return false
    end
    return server_id % 4096 <= game.MOB_INDEX_MAX
end

local function entity_at(index)
    local ent = GetEntity(index)
    if ent == nil or ent.ServerId == 0 then
        return nil
    end
    return {
        index = index,
        server_id = ent.ServerId,
        name = ent.Name,
        hpp = ent.HPPercent,
        claim_id = ent.ClaimStatus,
        status = ent.StatusServer,
    }
end

function game.entity_by_index(index)
    if index == nil or index < 0 or index > 2303 then
        return nil
    end
    return entity_at(index)
end

function game.entity_by_id(server_id)
    if server_id == nil or server_id == 0 then
        return nil
    end
    if server_id >= 0x1000000 then
        local e = entity_at(server_id % 4096)
        if e and e.server_id == server_id then
            return e
        end
    end
    for i = game.PLAYER_INDEX_MIN, game.PLAYER_INDEX_MAX do
        local e = entity_at(i)
        if e and e.server_id == server_id then
            return e
        end
    end
    return nil
end

function game.equipped()
    local inv = mm():GetInventory()
    local out = {}
    for slot = 0, game.EQUIP_SLOTS - 1 do
        local eq = inv:GetEquippedItem(slot)
        if eq ~= nil and eq.Index ~= 0 then
            local container = math.floor(eq.Index / 256)
            local index = eq.Index % 256
            local item = inv:GetContainerItem(container, index)
            if item ~= nil and item.Id ~= 0 and item.Id ~= 65535 then
                out[#out + 1] = { slot = slot, item_id = item.Id }
            end
        end
    end
    return out
end

return game
