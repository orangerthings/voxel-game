local Object = require("libraries.classic")
ChunkSpace = Object:extend("ChunkSpace")

-- a sp ace of chunks
function ChunkSpace:new()
    self.chunks = {}
    self.unorderedChunks = {}
end

function ChunkSpace:delete()
    for _, chunk in pairs(self.chunks) do
        chunk:delete()
    end
    self.chunks = {}
    self.unorderedChunks = {}
end

function ChunkSpace:chunkKeyFromCoords(x, y, z)
    return x..","..y..","..z
end

function ChunkSpace:getChunk(x, y, z)
    local key = self:chunkKeyFromCoords(x, y, z)
    return self.chunks[key]
end

function ChunkSpace:addChunk(chunk)
    local key = self:chunkKeyFromCoords(chunk.cx, chunk.cy, chunk.cz)
    self.chunks[key] = chunk
    table.insert(self.unorderedChunks, chunk)
    chunk.space = self
end

function ChunkSpace:removeChunk(x, y, z)
    local key = self:chunkKeyFromCoords(x, y, z)
    for i, chunk in ipairs(self.unorderedChunks) do
        if chunk.cx == x and chunk.cy == y and chunk.cz == z then
            table.remove(self.unorderedChunks, i)
            break
        end
    end
    self.chunks[key]:delete()
    self.chunks[key] = nil
end

function ChunkSpace:positionToChunkCoords(x, y, z)
    local cx = math.floor((x - 1) / 32)
    local cy = math.floor((y - 1) / 32)
    local cz = math.floor((z - 1) / 32)
    return cx, cy, cz
end

function ChunkSpace:positionToLocalCoords(x, y, z)
    local lx = ((x - 1) % 32) + 1
    local ly = ((y - 1) % 32) + 1
    local lz = ((z - 1) % 32) + 1
    return lx, ly, lz
end

function ChunkSpace:getTile(x, y, z)
    local cx, cy, cz = self:positionToChunkCoords(x, y, z)
    local chunk = self:getChunk(cx, cy, cz)
    if chunk then
        local lx, ly, lz = self:positionToLocalCoords(x, y, z)
        return chunk:getTileId(lx, ly, lz)
    end
    return nil
end

function ChunkSpace:setTile(x, y, z, tile)
    local cx, cy, cz = self:positionToChunkCoords(x, y, z)
    local chunk = self:getChunk(cx, cy, cz)
    if chunk then
        local lx, ly, lz = self:positionToLocalCoords(x, y, z)
        chunk:setTileId(lx, ly, lz, tile)
    end
end

return ChunkSpace