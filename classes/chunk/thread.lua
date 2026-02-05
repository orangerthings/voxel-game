-- Load all the modules because threads are stupid and do not have them loaded already
require 'lovr.filesystem'
lovr = require 'lovr'
lovr.data = require 'lovr.data'
lovr.timer = require 'lovr.timer'
lovr.thread = require 'lovr.thread'
lovr.math = require 'lovr.math'
lovr.graphics = require 'lovr.graphics'

-- Reregister every single module needed again
require('content.load')

local Primitive = require('classes.chunk.primitive')
local chunkSize = Primitive.chunkSize

local ChunkSpace = require('classes.chunkspace')

-- generate blob and blocks
local ffi = require("ffi")
ffi.cdef [[
	typedef struct { uint16_t tile; } block;
]]
local function generate(cx, cy, cz)
    local blob = lovr.data.newBlob(ffi.sizeof("block") * (chunkSize ^ 3), "byteData")
    local blocks = ffi.cast("block*", blob:getPointer())
    local noise = lovr.math.noise
    local mult = 1/16
    local base = cx * 32
    local basey = cy * 32
    local basez = cz * 32
    for x = 1, chunkSize do
        local wx_base = x + base
        local x0 = x - 1
        for y = 1, chunkSize do
            local wy = y + basey
            local y0 = y - 1
            for z = 1, chunkSize do
                local wz = z + basez
                local height = noise(wx_base * mult, wz * mult) * 8
                local tile
                if wy <= height then
                    if wy < 3 then
                        tile = 2
                    elseif wy < 6 then
                        tile = 1
                    else
                        tile = 3
                    end
                else
                    tile = 0
                end
                local z0 = z - 1
                local id = x0 * chunkSize * chunkSize + y0 * chunkSize + z0
                blocks[id].tile = tile
            end
        end
    end
    return blob, blocks
end

-- generate mesh vertices using greedy meshing
local BlockRegistry = require("registry.block")
local lovrMeshFaces = { -- set of cube faces with attributes for vertices to work off of
    [1] = {
        { 0, 0, 0 ; 0, 1},
        { 0, 0, 1 ; 1, 1},
        { 0, 1, 1 ; 1, 0},
        { 0, 1, 0 ; 0, 0}
    },
    [2] = {
        { 0, 0, 0 ; 0, 1},
        { 1, 0, 0 ; 1, 1},
        { 1, 0, 1 ; 1, 0},
        { 0, 0, 1 ; 0, 0}
    },
    [3] = {
        { 1, 0, 0 ; 0, 1},
        { 0, 0, 0 ; 1, 1},
        { 0, 1, 0 ; 1, 0},
        { 1, 1, 0 ; 0, 0},
    },
    [4] = {
        { 1, 0, 1 ; 0, 1},
        { 1, 0, 0 ; 1, 1},
        { 1, 1, 0 ; 1, 0},
        { 1, 1, 1 ; 0, 0}
    },
    [5] = {
        { 0, 1, 1 ; 0, 1},
        { 1, 1, 1 ; 1, 1},
        { 1, 1, 0 ; 1, 0},
        { 0, 1, 0 ; 0, 0}
    },
    [6] = {
        { 0, 0, 1 ; 0, 1},
        { 1, 0, 1 ; 1, 1},
        { 1, 1, 1 ; 1, 0},
        { 0, 1, 1 ; 0, 0}
    }
}
local normals = { -- first three = direction vector, fourth = coordinate index for the direction
    [1] = {-1, 0, 0, 1},  -- x- (left)
    [2] = {0, -1, 0, 2}, -- y- (bottom)
    [3] = {0, 0, -1, 3},  -- z- (front)
    [4] = {1, 0, 0, 1}, -- x+ (right)
    [5] = {0, 1, 0, 2}, -- y+ (top)
    [6] = {0, 0, 1, 3} -- z+ (back)
}
local function generateVerticesAndIndices(cx, cy, cz, pointer, space)
    local transparent = BlockRegistry.propertiesById.transparent

    local vertices = {}
    local indices = {}

    local vertexCount = 0
    local quadCount = 0
    local indicesCount = 0

    -- reusable 2D grid
    local grid = {}
    for i = 1, chunkSize do grid[i] = {} end

    local function greedyMesh(dir, slice)
        local face = lovrMeshFaces[dir]
        local ndix = normals[dir][4]

        for u = 1, chunkSize do
            local col = grid[u]
            for v = 1, chunkSize do
                local tile = col[v]
                if tile ~= 0 then
                    -- width
                    local w = 1
                    while u + w <= chunkSize and grid[u + w][v] == tile do
                        w = w + 1
                    end

                    -- height
                    local h = 1
                    local expand = true
                    while v + h <= chunkSize and expand do
                        for dx = 0, w - 1 do
                            if grid[u + dx][v + h] ~= tile then
                                expand = false
                                break
                            end
                        end
                        if expand then h = h + 1 end
                    end

                    -- clear grid
                    for du = 0, w - 1 do
                        local gcol = grid[u + du]
                        for dv = 0, h - 1 do
                            gcol[v + dv] = 0
                        end
                    end

                    -- base position
                    local px, py, pz
                    if ndix == 1 then
                        px, py, pz = slice, u, v
                    elseif ndix == 2 then
                        px, py, pz = u, slice, v
                    else
                        px, py, pz = u, v, slice
                    end

                    local dx, dy, dz
                    if ndix == 1 then
                        dx, dy, dz = 1, w, h
                    elseif ndix == 2 then
                        dx, dy, dz = w, 1, h
                    else
                        dx, dy, dz = w, h, 1
                    end

                    -- emit vertices
                    for i = 1, 4 do
                        local fv = face[i]
                        vertexCount = vertexCount + 1
                        vertices[vertexCount] = {
                            fv[1] * dx + (px - 1),
                            fv[2] * dy + (py - 1),
                            fv[3] * dz + (pz - 1),
                            fv[4] * (ndix == 1 and h or w),
                            fv[5] * (ndix == 1 and w or h),
                            tile-1
                        }
                    end

                    -- emit indices
                    local b = quadCount * 4
                    indicesCount = indicesCount + 1; indices[indicesCount] = b + 2
                    indicesCount = indicesCount + 1; indices[indicesCount] = b + 3
                    indicesCount = indicesCount + 1; indices[indicesCount] = b + 1
                    indicesCount = indicesCount + 1; indices[indicesCount] = b + 3
                    indicesCount = indicesCount + 1; indices[indicesCount] = b + 4
                    indicesCount = indicesCount + 1; indices[indicesCount] = b + 1

                    quadCount = quadCount + 1
                end
            end
        end
    end

    -- main pass
    for dir = 1, 6 do
        local n = normals[dir]
        local nx, ny, nz, ndix = n[1], n[2], n[3], n[4]

        for slice = 1, chunkSize do
            for u = 1, chunkSize do
                local col = grid[u]
                for v = 1, chunkSize do
                    local x, y, z
                    if ndix == 1 then
                        x, y, z = slice, u, v
                    elseif ndix == 2 then
                        x, y, z = u, slice, v
                    else
                        x, y, z = u, v, slice
                    end

                    local tile = Primitive.getTileId(nil, x, y, z, cx, cy, cz, pointer, space)
                    if tile == 0 then
                        col[v] = 0
                    else
                        -- 0 (air) = transparent
                        -- draw the tile if: tile is solid and neighbor is transparent, or tile is transparent and neighbor is a different tile
                        local neighbor = Primitive.getTileId(nil, x+nx, y+ny, z+nz, cx, cy, cz, pointer, space)
                        local isSolidTile
                        if tile == 0 then
                            isSolidTile = false
                        else
                            isSolidTile = not transparent[tile]
                        end
                        local isSolidNeighbor
                        if neighbor == 0 then
                            isSolidNeighbor = false
                        else
                            isSolidNeighbor = not transparent[neighbor]
                        end
                        local shouldDrawTile = (isSolidTile and (not isSolidNeighbor)) or ((not isSolidTile) and neighbor == 0)
                        col[v] = shouldDrawTile and tile or 0
                    end
                end
            end
            greedyMesh(dir, slice)
        end
    end
    
    return vertices, indices
end

local funcs = {
    generate = generate,
    generateVerticesAndIndices = generateVerticesAndIndices,
    createChunkPrimitives = function(to_create)
        local to_send = ChunkSpace()
        for _, r in ipairs(to_create) do
            local p = Primitive(r.cx, r.cy, r.cz)
            to_send.chunks[p:getKey()] = p
            if r.blob then
                p.blob = r.blob
                p.blocks = ffi.cast("block*", p.blob:getPointer())
            else
                p.blob, p.blocks = generate(p.cx, p.cy, p.cz)
            end
            print("Created chunk primitive at ", p.cx, p.cy, p.cz)
        end
        for _, p in pairs(to_send.chunks) do
            p.vertices, p.indices = generateVerticesAndIndices(p.cx, p.cy, p.cz, p.blocks, to_send)
            print("Generated mesh for chunk at ", p.cx, p.cy, p.cz, #p.vertices, #p.indices)
        end
        for _, p in pairs(to_send.chunks) do
            p.blocks = nil
        end
        return to_send.chunks
    end
}

local channel_in = lovr.thread.getChannel("chunk_thread_in")
local channel_out = lovr.thread.getChannel("chunk_thread_out")
while true do
    local message = channel_in:pop()
    if message then
        local result = funcs[message.func](unpack(message.args))
        channel_out:push(result)
    end
end