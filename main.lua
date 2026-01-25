local Data = require('libraries.data')
local Debug = require('libraries.debug')
local BlockRegistry = require("registry.block")
require('load')

local World = require('classes.world')
local world = World()

local channel_in = lovr.thread.getChannel("chunk_loader_in")
local channel_out = lovr.thread.getChannel("chunk_loader_out")
function lovr.load()
    local chunk_loader = lovr.thread.newThread("chunk_loader.lua")
    chunk_loader:start()
    for bx = -5, 5 do
        for bz = -5, 5 do
            local to_load = {}
            for x = 0, 15 do
                for y = -1, 1 do
                    for z = 0, 15 do
                        table.insert(to_load, {cx = 16*bx + x, cy = y, cz = 16*bz + z})
                    end
                end
            end
            local label = string.format("Loaded chunk batch at bx=%d bz=%d", bx, bz)
            Debug.timerStart(label)
            channel_in:push(Data.createMessage("batch", to_load, label))
        end
    end
end
-- Receive and update chunks
function lovr.update(dt)
    local message = channel_out:pop()
    if message then
        local mtype, payload, name = Data.readMessage(message)
        if mtype == "create" then
            world:addChunk(payload)
            payload:buildMesh()
        end
        if mtype == "update" then
            for k, chunk in ipairs(world.chunks) do
                if chunk.cx == payload.cx and chunk.cy == payload.cy and chunk.cz == payload.cz then
                    world.chunks[k] = payload
                    break
                end
            end
            payload:buildMesh()
        end
        if mtype == "batch" then
            for _, chunk in pairs(payload) do
                world:addChunk(chunk)
                chunk:buildMesh()
            end
            Debug.timerStop(name)
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
local array = lovr.graphics.newTexture(images, {mipmaps=true,usage={"sample"},format="rgb565",type="array"})
-- Shader
local shader = lovr.graphics.newShader("shaders/tiled.vert", "shaders/tiled.frag")
-- Draw
function lovr.draw(pass)
    pass:setCullMode('back')
    pass:setAlphaToCoverage(false)
    pass:setSampler(sampler)
    pass:setShader(shader)
    pass:send("textureArray", array)

    for _, chunk in pairs(world.chunks) do
        pass:origin()
        pass:translate(chunk.cx * 16, chunk.cy * 16, chunk.cz * 16)
        if chunk.mesh then
            pass:draw(chunk.mesh)
        end
    end
    pass:text("Hello World!")
end
