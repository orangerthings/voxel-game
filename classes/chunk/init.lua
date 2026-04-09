local Object = require("libraries.classic")
Chunk = Object:extend("Chunk")

local ffi = require("ffi")
ffi.cdef [[
    typedef struct { 
        uint16_t tile;
        uint8_t state;
        uint8_t mask;
    } block;
]]

Chunk.chunkSize = 32
local chunkSize = Chunk.chunkSize

local Debug = require('libraries.debug')

-- create a chunk. idk what else to say
function Chunk:new(cx, cy, cz)
    self.cx = cx
    self.cy = cy
    self.cz = cz
    self.blocks = nil
    self.blob = nil
    self.mesh = nil
    self.vertices = nil
    self.indices = nil

    self.space = nil

    -- 0: not generated
    -- 1: in process of generating
    -- 2: generated
    self.generateState = 0
    -- 0: not meshed
    -- 1: in process of meshing
    -- 2: meshed
    self.meshState = 0

    return self
end

function Chunk:delete()
    self.mesh = nil
    self.blob = nil
    self.blocks = nil
end

function Chunk:getKey()
    return self.cx..","..self.cy..","..self.cz
end

function Chunk:outOfBounds(x, y, z)
    return x < 1 or x > chunkSize or y < 1 or y > chunkSize or z < 1 or z > chunkSize
end

function Chunk:getId(x, y, z)
    if self:outOfBounds(x, y, z) then
        return nil
    else
        x, y, z = x-1, y-1, z-1
	    return x * chunkSize * chunkSize + y * chunkSize + z
    end
end

function Chunk:getTileId(x, y, z)
    local id = self:getId(x, y, z)
    if id then
        return self.blocks[id].tile
    else
        return self.space and self.space:getTile(x + self.cx * chunkSize, y + self.cy * chunkSize, z + self.cz * chunkSize) or 0
    end
end

function Chunk:setTileId(x, y, z, tile)
    local id = self:getId(x, y, z)
    if id then
        self.blocks[id].tile = tile
    else
        return
    end
end

return Chunk