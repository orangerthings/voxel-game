-- Load all the modules because threads are stupid and do not have them loaded already
require 'lovr.filesystem'
lovr = require 'lovr'
lovr.data = require 'lovr.data'
lovr.filesystem = require 'lovr.filesystem'
lovr.timer = require 'lovr.timer'
lovr.thread = require 'lovr.thread'
lovr.math = require 'lovr.math'
lovr.graphics = require 'lovr.graphics'

-- Reregister every single module needed again
require('content.load')

local Debug = require('libraries.debug')

local chunkSize = 32

-- C stuff
local ffi = require("ffi")
-- define chunk space c structs for ffi
ffi.cdef(string.format([[
    typedef struct { 
        uint16_t tile;
        uint8_t state;
        uint8_t mask;
    } block;

    typedef struct { 
        int x, y, z;
    } position;

    typedef struct ChunkPrimitive {
        position pos;
        uint8_t chunkSize;
        uint8_t lod;
        block* blocks;
        uint8_t neighbors;

        uint8_t last_computed_lod_mask;
        bool mask_buffer[%d];
        uint16_t tile_buffer[%d];
    } ChunkPrimitive;

    typedef struct ChunkEntry ChunkEntry;

    typedef struct {
        ChunkEntry** buckets;
        size_t size;
        size_t count;
    } ChunkSpace;

    void init_space(ChunkSpace* space);
    void init_chunk(ChunkPrimitive* chunk, position pos, uint8_t lod, block* blocks);
    ChunkPrimitive* get_chunk(ChunkSpace* space, position pos, bool* found);
    void add_chunk(ChunkSpace* space, ChunkPrimitive* chunk);
    void remove_chunk(ChunkSpace* space, position pos);
    void free_space(ChunkSpace* space);

    void compute_mask(ChunkPrimitive* chunk, ChunkSpace* space, bool* transparent);
    void generate_mesh(
        ChunkPrimitive* chunk,
        ChunkSpace* space,
        bool* transparent,
        float* vertex_buffer,
        uint32_t* index_buffer,
        int* vertex_num_out,
        int* index_num_out
    );
]], chunkSize * chunkSize, chunkSize * chunkSize))

local C = ffi.load(lovr.filesystem.getSource().."/c/chunk")

local CSpace = ffi.new("ChunkSpace")
C.init_space(CSpace)

-- stuff to sync chunks on the main thread and worker thread
-- table of references so that the gc doesnt behead the ffi objects while they are still in use by the worker thread
local references = {}

local C_found = ffi.new("bool[1]") -- reuse

local function C_get_chunk(cx, cy, cz)
    local pos = ffi.new("position", cx, cy, cz)
    local chunk = C.get_chunk(CSpace, pos, C_found)
    if C_found[0] then
        C_found[0] = false
        return chunk
    else
        C_found[0] = false
        return nil
    end
end

local function C_new_chunk(cx, cy, cz, lod, blocks)
    local pos = ffi.new("position", cx, cy, cz)
    local chunk = ffi.new("ChunkPrimitive")
    C.init_chunk(chunk, pos, lod, blocks)
    return chunk
end

local function C_add_chunk(chunk)
    references[chunk.pos.x..","..chunk.pos.y..","..chunk.pos.z] = chunk
    C.add_chunk(CSpace, chunk)
end

local function C_remove_chunk(cx, cy, cz)
    local pos = ffi.new("position", cx, cy, cz)
    C.get_chunk(CSpace, pos, C_found)
    if C_found[0] then
        C.remove_chunk(CSpace, pos)
        references[cx..","..cy..","..cz] = nil  -- release GC reference
        C_found[0] = false
    end
end

-- convert transparency table to a usable C form
BlockRegistry = require("registry.block")
local transparentTable = BlockRegistry.propertiesById.transparent
local transparent = ffi.new("bool[256]")
for id, v in pairs(transparentTable) do
    if v then
        transparent[id] = 1
    end
end

local maxQuads = 32 * 32 * 32 * 3
local vertexBuffer = lovr.data.newBlob(maxQuads * 4 * 6 * 4)
local indexBuffer  = lovr.data.newBlob(maxQuads * 6 * 4)
local vertexPointer = ffi.cast("float*", vertexBuffer:getPointer())
local indexPointer  = ffi.cast("uint32_t*", indexBuffer:getPointer())
local vertexCount = ffi.new("int[1]")
local indexCount  = ffi.new("int[1]")

-- generate mesh vertices using greedy meshing
local function buildMesh(chunk)
    if chunk.neighbors ~= 6 then
        return nil
    end

    C.generate_mesh(
        chunk,
        CSpace,
        transparent,
        vertexPointer,
        indexPointer,
        vertexCount,
        indexCount
    )
    if indexCount[0] == 0 then return nil end

    local indices = lovr.data.newBlob(indexCount[0] * 4)
    ffi.copy(indices:getPointer(), indexPointer, indexCount[0] * 4)
    local vertices = lovr.data.newBlob(vertexCount[0] * 24)
    ffi.copy(vertices:getPointer(), vertexPointer, vertexCount[0] * 24)

    vertexCount[0] = 0
    indexCount[0] = 0
    return vertices, indices
end

-- generate blob and blocks
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

local channel_worker_in = lovr.thread.getChannel("chunks_worker_in")
local channel_worker_out = lovr.thread.getChannel("chunks_worker_out")
while true do
    local message = channel_worker_in:pop(true)
    if message then
        local t, payload = message.type, message.payload
        local k = "Worker thread overhead processing Chunk("..payload.cx..", "..payload.cy..", "..payload.cz..") (code: "..t..")"
        Debug.timerStart(k, 100 + t)
        -- -1: delete
        if t == -1 then
            C_remove_chunk(payload.cx, payload.cy, payload.cz)
        -- 0: update
        elseif t == 0 then
            local chunk = C_get_chunk(payload.cx, payload.cy, payload.cz)
            if chunk then
                chunk.blocks = ffi.cast("block*", payload.blob:getPointer())
            else
                C_add_chunk(C_new_chunk(payload.cx, payload.cy, payload.cz, payload.lod, ffi.cast("block*", payload.blob:getPointer())))
            end
        -- 1: create
        elseif t == 1 then
            local blob, blocks = generate(payload.cx, payload.cy, payload.cz)
            C_add_chunk(C_new_chunk(payload.cx, payload.cy, payload.cz, payload.lod, blocks))
            channel_worker_out:push({type = 1, payload = {
                cx = payload.cx, cy = payload.cy, cz = payload.cz,
                blob = blob
            }})
        -- 2: mesh
        elseif t == 2 then
            local chunk = C_get_chunk(payload.cx, payload.cy, payload.cz)
            if chunk then
                local vertices, indices = buildMesh(chunk)
                if vertices then
                    channel_worker_out:push({type = 2, payload = {
                        cx = payload.cx, cy = payload.cy, cz = payload.cz,
                        vertices = vertices,
                        indices = indices
                    }})
                else
                    channel_worker_out:push({type = 12, payload = { -- failed to mesh
                        cx = payload.cx, cy = payload.cy, cz = payload.cz,
                    }})
                end
            end
        -- 3: create and mesh
        elseif t == 3 then
            local blob, blocks = generate(payload.cx, payload.cy, payload.cz)
            local chunk = C_new_chunk(payload.cx, payload.cy, payload.cz, payload.lod, blocks)
            C_add_chunk(chunk)
            local vertices, indices = buildMesh(chunk)
            if vertices then
                channel_worker_out:push({type = 3, payload = {
                    cx = payload.cx, cy = payload.cy, cz = payload.cz,
                    blob = blob,
                    vertices = vertices,
                    indices = indices
                }})
            else
                channel_worker_out:push({type = 13, payload = { -- failed to mesh
                    cx = payload.cx, cy = payload.cy, cz = payload.cz,
                    blob = blob
                }})
            end
        end
        Debug.timerStop(k)
        Debug.printAverages()
    end
end