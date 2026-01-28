local Data = require('libraries.data')
local Debug = require('libraries.debug')
local BlockRegistry = require("registry.block")
require('load')

local World = require('classes.world')
local world = World()

local renderDistance = 16
local requested = {}
local channel_in = lovr.thread.getChannel("chunk_loader_in")
local channel_out = lovr.thread.getChannel("chunk_loader_out")
function lovr.load()
    local chunk_loader = lovr.thread.newThread("chunk_loader.lua")
    chunk_loader:start()
end
-- Receive and update chunks
local pcx, pcy, pcz = 0, 0, 10
function lovr.update(dt)
    local x, y, z = lovr.headset.getPosition()
    local cx, cy, cz = World:positionToChunkCoords(x, y, z)

    local message = channel_out:pop()
    if message then
        local mtype, payload, name = Data.readMessage(message)
        if mtype == "create" then
            local chunk = payload
            if (chunk.cx - cx)^2 + (chunk.cy - cy)^2 + (chunk.cz - cz)^2 <= renderDistance^2 then
                world:addChunk(chunk)
                chunk:buildMesh()
            end
            requested[chunk:getKey()] = nil
        end
        if mtype == "update" then
            local chunk = payload
            if (chunk.cx - cx)^2 + (chunk.cy - cy)^2 + (chunk.cz - cz)^2 <= renderDistance^2 then
                world.chunks[chunk:getKey()] = chunk
                chunk:buildMesh()
            end
        end
        if mtype == "batch" then
            for k, chunk in pairs(payload) do
                if (chunk.cx - cx)^2 + (chunk.cy - cy)^2 + (chunk.cz - cz)^2 <= renderDistance^2 then
                    world:addChunk(chunk)
                    chunk:buildMesh()
                end
                requested[k] = nil
            end
        end
        if mtype == "batch_update" then
            for k, chunk in pairs(payload) do
                if (chunk.cx - cx)^2 + (chunk.cy - cy)^2 + (chunk.cz - cz)^2 <= renderDistance^2 then
                    world.chunks[chunk:getKey()] = chunk
                    chunk:buildMesh()
                end
                requested[k] = nil
            end
        end
    end

    local to_update = {}
    for _, chunk in ipairs(world.unorderedChunks) do
        if (chunk.cx - cx)^2 + (chunk.cy - cy)^2 + (chunk.cz - cz)^2 <= renderDistance^2 then
            if chunk.dirty then
                requested[chunk:getKey()] = true
                table.insert(to_update, chunk)
            end
        end
    end
    if #to_update > 0 then
        channel_in:push(Data.createMessage("batch_update", to_update, "Chunk Update"))
        to_update = nil
    end

    local to_load = {}
    if pcx ~= cx or pcy ~= cy or pcz ~= cz then
        pcx, pcy, pcz = cx, cy, cz
        for _, chunk in ipairs(world.unorderedChunks) do
            if (chunk.cx - cx)^2 + (chunk.cy - cy)^2 + (chunk.cz - cz)^2 > renderDistance^2 then
                world:removeChunk(chunk.cx, chunk.cy, chunk.cz)
            end
        end
        for dx = -renderDistance, renderDistance do
            for dy = -1, 1 do
                for dz = -renderDistance, renderDistance do
                    if dx^2 + dy^2 + dz^2 <= renderDistance^2 then
                        local ncx, ncy, ncz = cx + dx, dy, cz + dz
                        local key = world:chunkKeyFromCoords(ncx, ncy, ncz)
                        if not world:getChunk(ncx, ncy, ncz) and not requested[key] then
                            requested[key] = true
                            table.insert(to_load, {cx = ncx, cy = ncy, cz = ncz})
                        end
                    end
                end
            end
        end
        if #to_load > 0 then
            channel_in:push(Data.createMessage("batch", to_load, "Chunk Load"))
            to_load = nil
        end
    end
end

-- Sampler
local sampler = lovr.graphics.newSampler({filter="nearest", wrap="repeat"})
-- Textures
local images = {}
for id, block in ipairs(BlockRegistry.byId) do
    local texturePath = "textures/"..block.texture..".png"
    images[id] = texturePath
end
local array = lovr.graphics.newTexture(images, {mipmaps=true,usage={"sample"},format="rgba8",type="array"})
-- Shader
local shader = lovr.graphics.newShader("shaders/tiled.vert", "shaders/tiled.frag")
-- Draw
function lovr.draw(pass)
    pass:setCullMode('back')
    pass:setAlphaToCoverage(false)
    pass:setSampler(sampler)
    pass:setShader(shader)
    pass:send("textureArray", array)

    for _, chunk in ipairs(world.unorderedChunks) do
        pass:origin()
        pass:translate(chunk.cx * 32, chunk.cy * 32, chunk.cz * 32)
        if chunk.mesh then
            pass:draw(chunk.mesh)
        end
    end
    pass:text("Hello World!")
end
