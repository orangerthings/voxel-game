local Object = require('libraries.classic')
Primitive = Object:extend("ChunkPrimitive")

Primitive.chunkSize = 32
local chunkSize = Primitive.chunkSize

-- class containing only basic chunk data and functions to be shared between main thread and chunk loader thread
function Primitive:new(cx, cy, cz)
    self.cx = cx
    self.cy = cy
    self.cz = cz
    self.blocks = nil
    self.blob = nil
    self.vertices = nil
    self.indices = nil
end

function Primitive.getKey(self, cx, cy, cz)
    cx = cx or self.cx
    cy = cy or self.cy
    cz = cz or self.cz
    return cx..","..cy..","..cz
end

function Primitive.outOfBounds(x, y, z)
    return x < 1 or x > chunkSize or y < 1 or y > chunkSize or z < 1 or z > chunkSize
end

function Primitive.getId(x, y, z)
    if Primitive.outOfBounds(x, y, z) then
        return nil
    end
    x, y, z = x-1, y-1, z-1
    return x * chunkSize * chunkSize + y * chunkSize + z
end

function Primitive.getTileId(self, x, y, z, cx, cy, cz, pointer, space)
    cx = cx or self.cx
    cy = cy or self.cy
    cz = cz or self.cz
    pointer = pointer or self.blocks
    space = space or self.space
    local id = Primitive.getId(x, y, z)
    if id then
        return pointer[id].tile
    elseif space then
        return space and space:getTile(x + cx * chunkSize, y + cy * chunkSize, z + cz * chunkSize) or 0
    end
end

function Primitive.setTileId(self, x, y, z, tile, pointer)
    local id = Primitive.getId(x, y, z)
    pointer = pointer or self.blocks
    if id then
        pointer[id].tile = tile
    else
        return
    end
end

return Primitive