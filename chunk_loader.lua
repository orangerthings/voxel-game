-- Load all the modules because threads are stupid and do not have them loaded already
require 'lovr.filesystem'
lovr = require 'lovr'
lovr.data = require 'lovr.data'
lovr.timer = require 'lovr.timer'
lovr.thread = require 'lovr.thread'
lovr.math = require 'lovr.math'

-- Reregister every single module needed again
require('content.load')

local ChunkSpace = require('classes.chunkspace')
local Chunk = require('classes.chunk')
local Data = require('libraries.data')

local channel_in = lovr.thread.getChannel("chunk_loader_in")
local channel_out = lovr.thread.getChannel("chunk_loader_out")
while true do
    local message = channel_in:pop()
    if message then
        local mtype, payload = Data.readMessage(message)
        if mtype == "create" then
            local chunk = Chunk(payload.cx, payload.cy, payload.cz)
            chunk:generateMesh()
            channel_out:push(Data.createMessage("create", chunk, message.name))
        end
        if mtype == "update" then
            payload:updateMesh()
            channel_out:push(Data.createMessage("update", payload, message.name))
        end
        if mtype == "batch" then
            local chunkspace = ChunkSpace()
            for _, data in ipairs(payload) do
                local chunk = Chunk(data.cx, data.cy, data.cz)
                chunkspace:addChunk(chunk)
            end
            for _, chunk in pairs(chunkspace.chunks) do
                chunk:generateMesh()
            end
            channel_out:push(Data.createMessage("batch", chunkspace.chunks, message.name))
        end
    end
end