local Object = require("libraries.classic")
ChunkSpace = Object:extend("ChunkSpace")

function ChunkSpace:new()
    self.chunks = {}
    -- one super mesh for each texture
    self.meshes = {}
end

function ChunkSpace:getChunk(x, y, z)
    local key = x .. "," .. y .. "," .. z
    return self.chunks[key]
end

function ChunkSpace:addChunk(chunk)
    local key = chunk.cx .. "," .. chunk.cy .. "," .. chunk.cz
    self.chunks[key] = chunk
    chunk.space = self
end

function ChunkSpace:removeChunk(x, y, z)
    local key = x .. "," .. y .. "," .. z
    self.chunks[key] = nil
end

function ChunkSpace:positionToChunkCoords(x, y, z)
    local cx = math.floor((x - 1) / 16)
    local cy = math.floor((y - 1) / 16)
    local cz = math.floor((z - 1) / 16)
    return cx, cy, cz
end

function ChunkSpace:positionToLocalCoords(x, y, z)
    local lx = ((x - 1) % 16) + 1
    local ly = ((y - 1) % 16) + 1
    local lz = ((z - 1) % 16) + 1
    return lx, ly, lz
end

function ChunkSpace:getTile(x, y, z)
    local chunk = self:getChunk(self:positionToChunkCoords(x, y, z))
    if chunk then
        return chunk:getTileId(self:positionToLocalCoords(x, y, z))
    end
    return nil
end

function ChunkSpace:setTile(x, y, z, tile)
    local chunk = self:getChunk(self:positionToChunkCoords(x, y, z))
    if chunk then
        chunk:setTileId(self:positionToLocalCoords(x, y, z), tile)
    end
end

return ChunkSpace