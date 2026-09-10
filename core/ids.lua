local ids = {}

ids.LENGTH = 24

function ids.new(rng)
    rng = rng or math.random
    local out = {}
    for i = 1, ids.LENGTH do
        out[i] = ('%x'):format(rng(0, 15))
    end
    return table.concat(out)
end

return ids
