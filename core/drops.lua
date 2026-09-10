local drops = {}

function drops.add(list, item_id, count)
    for _, d in ipairs(list) do
        if d.item_id == item_id then
            d.count = d.count + (count or 1)
            return d
        end
    end
    local d = { item_id = item_id, count = count or 1 }
    list[#list + 1] = d
    return d
end

return drops
