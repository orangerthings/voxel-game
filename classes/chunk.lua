local Object = require("libraries.classic")
Chunk = Object:extend("Chunk")

local ffi = require("ffi")
ffi.cdef [[
	typedef struct { uint16_t tile; } block;
]]

local chunkSize = 16

local BlockRegistry = require("registry.block")

local Debug = require("libraries.debug")

function Chunk:new(cx, cy, cz, space)
    self.space = space or nil
    if self.space then
        self.space:addChunk(self)
    end

    self.cx = cx or 0
    self.cy = cy or 0
    self.cz = cz or 0

    self.blob = lovr.data.newBlob(ffi.sizeof("block") * (chunkSize ^ 3), "byteData")
    self.blocks = ffi.cast("block*", self.blob:getPointer())

    self:generate()

    self.built = {vertices = {}, indices = {}, _ignore = true}

    self.mesh = nil
    self.dirty = false

    return self
end

function Chunk:onRestore()
    self.blocks = ffi.cast("block*", self.blob:getPointer())
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
        return self.space and self.space:getTile(x + self.cx * 16, y + self.cy * 16, z + self.cz * 16) or 0
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

function Chunk:generate()
    local debugLabel = string.format("Chunk (%d,%d,%d) generated", self.cx, self.cy, self.cz)
    Debug.timerStart(debugLabel)

    for x = 1, chunkSize do
        for y = 1, chunkSize do
            for z = 1, chunkSize do
                local wx, wy, wz = x+self.cx*16, y+self.cy*16, z+self.cz*16
                local height = lovr.math.noise(wx/16, wz/16)*8
                if wy <= height then
                    if wy < 3 then
                        self:setTileId(x, y, z, 2)
                    elseif wy < 6 then
                        self:setTileId(x, y, z, 1)
                    else
                        self:setTileId(x, y, z, 3)
                    end
                else
                    self:setTileId(x, y, z, 0)
                end
            end
        end
    end

    Debug.timerStop(debugLabel)
end

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

function Chunk:generateMesh()
    local debugLabel = string.format("Mesh for Chunk (%d,%d,%d) generated", self.cx, self.cy, self.cz)
    Debug.timerStart(debugLabel)

    local transparent = BlockRegistry.propertiesById.transparent

    local vertices = {}
    local indices = {}

    local vertexCount = 0
    local quadCount = 0

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
                    indices[#indices + 1] = b + 2
                    indices[#indices + 1] = b + 3
                    indices[#indices + 1] = b + 1
                    indices[#indices + 1] = b + 3
                    indices[#indices + 1] = b + 4
                    indices[#indices + 1] = b + 1

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

                    local tile = self:getTileId(x, y, z)
                    if tile == 0 then
                        col[v] = 0
                    else
                        -- 0 (air) = transparent
                        -- draw the tile if: tile is solid and neighbor is transparent, or tile is transparent and neighbor is a different tile
                        local neighbor = self:getTileId(x+nx, y+ny, z+nz)
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
    self.built.vertices = vertices
    self.built.indices = indices

    Debug.timerStop(debugLabel)
end

-- WARNING THIS CANNOT BE CALLED FROM A THREAD!!!!!!!!!!!
function Chunk:buildMesh()
    --this part will build the mesh and send it back
    -- if there are no indices, dont create a mesh
    if #self.built.indices == 0 or #self.built.vertices == 0 then
        self.mesh = nil
        return
    end
    self.mesh = lovr.graphics.newMesh({{"VertexPosition", "vec3"},{"VertexUV", "vec2"},{"VertexTile", "float"}}, self.built.vertices, "cpu")
    self.mesh:setIndices(self.built.indices)
end

function Chunk:updateMesh()
    if self.dirty then
        self:generateMesh()
        self.dirty = false
    end
end

return Chunk