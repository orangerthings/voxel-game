local Data = require('libraries.data')
local Debug = require('libraries.debug')
local BlockRegistry = require("registry.block")
require('load')

local Chunk = require('classes.chunk')

local world = Chunk.space

local renderDistance = 4
local rd2 = renderDistance * renderDistance

-- Receive and update chunks
local pcx, pcy, pcz = 0, 0, 10
function lovr.update(dt)
    local cx, cy, cz = world:positionToChunkCoords(lovr.headset.getPosition())

    if cx ~= pcx or cy ~= pcy or cz ~= pcz then
        pcx, pcy, pcz = cx, cy, cz
        -- unload chunks outside render distance
        for _, chunk in pairs(world.chunks) do
            local dx, dy, dz = chunk.cx - cx, chunk.cy - cy, chunk.cz - cz
            if dx * dx + dy * dy + dz * dz > rd2 then
                world:removeChunk(chunk.cx, chunk.cy, chunk.cz)
            end
        end

        -- load/update chunks within render distance
        local to_create = {}
        for lx = cx - renderDistance, cx + renderDistance do
            for ly = -1, 1 do
                for lz = cz - renderDistance, cz + renderDistance do
                    local dx, dy, dz = lx - cx, ly - cy, lz - cz
                    if dx * dx + dy * dy + dz * dz <= rd2 then
                        local chunk = world:getChunk(lx, ly, lz)
                        if not chunk then
                            table.insert(to_create, {cx = lx, cy = ly, cz = lz})
                        elseif chunk.dirty then
                            table.insert(to_create, {cx = lx, cy = ly, cz = lz, blob = chunk.blob})
                        end
                    end
                end
            end
        end
        Chunk.makeMany(to_create)
    end
    Chunk.lovrUpdate()
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
