local ChunkSpace = require('classes.chunkspace')
World = ChunkSpace:extend("World")

local Chunk = require('classes.chunk')
local Debug = require("libraries.debug")

local ffi = require("ffi")

function World:new()
    -- the
    World.super.new(self)
end

local worker = lovr.thread.newThread("classes/world/workers/chunks.lua")
worker:start()

local channel_in = lovr.thread.getChannel("chunks_worker_in")
local channel_out = lovr.thread.getChannel("chunks_worker_out")

function World:removeChunk(cx, cy, cz)
    World.super.removeChunk(self, cx, cy, cz)
    channel_in:push({type = -1, payload = {cx = cx, cy = cy, cz = cz}})
end

-- each to_create has cx, cy, cz, and optionally, blob.
-- if blob not provided: generate terrain (to create blob) AND give a mesh (so like generate)
-- if blob is provided: just give a mesh (so like update)
function World:makeChunk(to_make) -- {cx, cy, cz, blob?}
    local chunk = Chunk(to_make.cx, to_make.cy, to_make.cz)
    -- mark processing started
    chunk.generateState = 1

    self:addChunk(chunk)
    if to_make.blob then
        chunk.blob = to_make.blob
        chunk.blocks = ffi.cast("block*", to_make.blob:getPointer())
        channel_in:push({type = 0, payload = to_make})
    else
        channel_in:push({type = 1, payload = to_make})
    end
end

function World:makeChunks(to_make) -- to_create is a list of {cx, cy, cz, blob?}
    for _, r in ipairs(to_make) do
       self:makeChunk(r)
    end
end

function World:meshChunk(to_mesh) -- {cx, cy, cz, chunk?}
    local chunk = to_mesh.chunk or self:getChunk(to_mesh.cx, to_mesh.cy, to_mesh.cz)
    if chunk then
        to_mesh.chunk = nil
        chunk.meshState = 1
        channel_in:push({type = 2, payload = to_mesh})
    end
end

function World:meshChunks(to_mesh) -- list of {cx, cy, cz, chunk?}
    for _, r in ipairs(to_mesh) do
        self:meshChunk(r)
    end
end

World.lovrUpdate = {
    -- recieveing end of things (each function MUST return a status on whether or not the data was found in the channel or not)
    chunk = function(self)
        local data = channel_out:pop()
        if data then
            local t, payload = data.type, data.payload
            local k = "Main thread overhead processing Chunk("..payload.cx..", "..payload.cy..", "..payload.cz..") (code: "..t..")"
            Debug.timerStart(k, 200 + t)
            -- blob {cx, cy, cz, blob}
            if t == 1 then
                local chunk = self:getChunk(payload.cx, payload.cy, payload.cz)
                if chunk then
                    chunk.blob = payload.blob
                    chunk.blocks = ffi.cast("block*", payload.blob:getPointer())

                    -- set to generated status
                    chunk.generateState = 2
                end
            end
            -- mesh {cx, cy, cz, mesh}
            if t == 2 then
                local chunk = self:getChunk(payload.cx, payload.cy, payload.cz)
                if chunk then
                    local mesh = lovr.graphics.newMesh(
                        {{"VertexPosition","vec3"},{"VertexUV","vec2"},{"VertexTile","float"}},
                        payload.vertices, "gpu"
                    )
                    mesh:setIndices(payload.indices, "u32")
                    chunk.mesh = mesh
                    -- set to meshed status
                    chunk.meshState = 2
                end
            end
            -- 2 failed
            if t == 12 then
                local chunk = self:getChunk(payload.cx, payload.cy, payload.cz)
                if chunk then
                    chunk.meshState = 0
                end
            end
            -- blob and mesh {cx, cy, cz, blob, mesh}
            if t == 3 then
                local chunk = self:getChunk(payload.cx, payload.cy, payload.cz)
                if chunk then
                    chunk.blob = payload.blob
                    chunk.blocks = ffi.cast("block*", payload.blob:getPointer())
                    local mesh = lovr.graphics.newMesh(
                        {{"VertexPosition","vec3"},{"VertexUV","vec2"},{"VertexTile","float"}},
                        payload.vertices, "gpu"
                    )
                    mesh:setIndices(payload.indices, "u32")
                    chunk.mesh = mesh
                    -- set to generated status
                    chunk.generateState = 2
                    -- set to meshed status
                    chunk.meshState = 2
                end
            end
            -- 3 failed
            if t == 13 then
                local chunk = self:getChunk(payload.cx, payload.cy, payload.cz)
                if chunk then
                    chunk.blob = payload.blob
                    chunk.blocks = ffi.cast("block*", payload.blob:getPointer())

                    chunk.generateState = 2
                    chunk.meshState = 0
                end
            end
            Debug.timerStop(k)
            return false
        else
            return true
        end
    end
}
-- runs every lovr.update
function World:lovrUpdateAll()
    for _, func in pairs(World.lovrUpdate) do
        local timer = lovr.timer.getTime()
        local empty = false
        while not empty and lovr.timer.getTime() - timer < 0.01 do -- frame budget
            empty = func(self)
        end
    end
end

return World