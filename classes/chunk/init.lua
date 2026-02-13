local Primitive = require("classes.chunk.primitive")
Chunk = Primitive:extend("Chunk")

local ffi = require("ffi")
ffi.cdef [[
	typedef struct { uint16_t tile; } block;
]]

local chunkSize = Primitive.chunkSize

local chunk_loader = lovr.thread.newThread("classes/chunk/thread.lua")
chunk_loader:start()

local Debug = require('libraries.debug')

local World = require('classes.world')
Chunk.space = World() -- global world

-- create a chunk. idk what else to say
function Chunk:new(cx, cy, cz)
    Chunk.super.new(self, cx, cy, cz)

    self.space = Chunk.space
    self.space:addChunk(self)

    self.generated = false
    self.dirty = false

    return self
end

function Chunk:delete()
    if self.mesh then
        self.mesh:release()
        self.mesh = nil
    end
    if self.blob then
        self.blob:release()
        self.blob = nil
    end
    self.blocks = nil
end

-- redefine these cause whyyy not
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

local channel_in = lovr.thread.getChannel("chunk_thread_in")
local channel_out = lovr.thread.getChannel("chunk_thread_out")
-- each to_create has cx, cy, cz, and optionally, blob.
-- if blob not provided: generate terrain (to create blob) AND give a mesh (so like generate)
-- if blob is provided: just give a mesh (so like update)
function Chunk.makeMany(to_create)
    for _, r in ipairs(to_create) do
        Chunk.space:addChunk(Chunk(r.cx, r.cy, r.cz))
    end
    channel_in:push({func = "createChunkPrimitives", args = {to_create}})
end

function Chunk.makeOne(r)
    Chunk.space:addChunk(Chunk(r.cx, r.cy, r.cz))
    channel_in:push({func = "createChunkPrimitives", args = {{r}}})
end

-- runs everry lovr.update
function Chunk.lovrUpdate()
    local data = channel_out:pop()
    if data then
        Debug.timerStart("Main thread overhead processing chunk data")

        for _, primitive in pairs(data) do
            local chunk = Chunk.space:getChunk(primitive.cx, primitive.cy, primitive.cz)
            if chunk then
                if primitive.blob then
                    chunk.blob = primitive.blob
                    chunk.blocks = ffi.cast("block*", chunk.blob:getPointer())
                end
                chunk.mesh = primitive.mesh
                chunk.generated = true
            end
        end

        Debug.timerStop("Main thread overhead processing chunk data")
    else
        return
    end
end

-- WARNING THIS CANNOT BE CALLED FROM A THREAD!!!!!!!!!!!
function Chunk:buildMesh(vertices, indices)
    --this part will build the mesh and send it back
    -- if there are no indices, dont create a mesh
    if #indices == 0 then
        self.mesh = nil
        return
    end
    if self.mesh then
        self.mesh:release()
        self.mesh = nil
    end
    self.mesh = lovr.graphics.newMesh({{"VertexPosition", "vec3"},{"VertexUV", "vec2"},{"VertexTile", "float"}}, vertices, "gpu")
    self.mesh:setIndices(indices)
end

return Chunk