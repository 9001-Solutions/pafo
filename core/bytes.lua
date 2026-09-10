local bytes = {}

function bytes.u8(s, off)
    return s:byte(off + 1) or 0
end

function bytes.u16(s, off)
    local a, b = s:byte(off + 1, off + 2)
    return (a or 0) + (b or 0) * 256
end

function bytes.u32(s, off)
    local a, b, c, d = s:byte(off + 1, off + 4)
    return (a or 0) + (b or 0) * 256 + (c or 0) * 65536 + (d or 0) * 16777216
end

local reader = {}
reader.__index = reader

function bytes.reader(s, pos)
    local data = {}
    for i = 1, #s do
        data[i] = s:byte(i)
    end
    return setmetatable({ data = data, pos = pos or 0, bit = 0, len = #s }, reader)
end

function reader:read(bits)
    if self.pos >= self.len then
        error(('bit reader overrun at byte %d of %d'):format(self.pos, self.len))
    end
    local ret = 0
    local scale = 1
    for _ = 1, bits do
        local byte = self.data[self.pos + 1] or 0
        local shifted = math.floor(byte / (2 ^ self.bit))
        if shifted % 2 == 1 then
            ret = ret + scale
        end
        scale = scale * 2
        self.bit = self.bit + 1
        if self.bit == 8 then
            self.bit = 0
            self.pos = self.pos + 1
        end
    end
    return ret
end

return bytes
