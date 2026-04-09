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

    void init_crash_handler(void);

    void init_space(ChunkSpace* space);
    block* alloc_blocks();
    void copy_blocks(block* dst, block* src);

    ChunkPrimitive* new_chunk(position pos, uint8_t lod);
    ChunkPrimitive* get_chunk(ChunkSpace* space, position pos, bool* found);
    void add_chunk(ChunkSpace* space, ChunkPrimitive* chunk);
    void remove_chunk(ChunkSpace* space, position pos);
    void free_space(ChunkSpace* space);

    void generate_chunk(ChunkSpace* space, ChunkPrimitive* chunk);

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
C.init_crash_handler()

local CSpace = ffi.new("ChunkSpace")
C.init_space(CSpace)

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

local function C_set_blocks(chunk, blocks)
    C.copy_blocks(chunk.blocks, blocks)
end

local function C_new_chunk(cx, cy, cz, lod, blocks)
    local pos = ffi.new("position", cx, cy, cz)
    local chunk = C.new_chunk(pos, lod)
    if blocks then
        C_set_blocks(chunk, blocks)
    end
    return chunk
end

local function C_generate_chunk(chunk)
    C.generate_chunk(CSpace, chunk)
end

local function C_add_chunk(chunk)
    C.add_chunk(CSpace, chunk)
end

local function C_remove_chunk(cx, cy, cz)
    local pos = ffi.new("position", cx, cy, cz)
    C.get_chunk(CSpace, pos, C_found)
    if C_found[0] then
        C.remove_chunk(CSpace, pos)
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

local channel_worker_in = lovr.thread.getChannel("chunks_worker_in")
local channel_worker_out = lovr.thread.getChannel("chunks_worker_out")
while true do
    local message = channel_worker_in:pop()
    if message then
        local t, payload = message.type, message.payload
        local k = "Worker thread overhead processing Chunk("..payload.cx..", "..payload.cy..", "..payload.cz..") (code: "..t..")"
        local debug_code = t + 100
        Debug.timerStart(k, debug_code)
        -- -1: delete
        if t == -1 then
            C_remove_chunk(payload.cx, payload.cy, payload.cz)
        -- 0: update/create if not exist
        elseif t == 0 then
            local chunk = C_get_chunk(payload.cx, payload.cy, payload.cz)
            if chunk then
                C_set_blocks(chunk, ffi.cast("block*", payload.blob:getPointer()))
            else
                C_add_chunk(C_new_chunk(payload.cx, payload.cy, payload.cz, payload.lod, ffi.cast("block*", payload.blob:getPointer())))
            end
        -- 1: create
        elseif t == 1 then
            local chunk = C_new_chunk(payload.cx, payload.cy, payload.cz, payload.lod)
            C_generate_chunk(chunk)
            C_add_chunk(chunk)
            local blob = lovr.data.newBlob(chunkSize * chunkSize * chunkSize * ffi.sizeof("block"))
            ffi.copy(blob:getPointer(), chunk.blocks, chunkSize * chunkSize * chunkSize * ffi.sizeof("block"))
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
            local chunk = C_new_chunk(payload.cx, payload.cy, payload.cz, payload.lod)
            C_generate_chunk(chunk)
            C_add_chunk(chunk)
            local blob = lovr.data.newBlob(chunkSize * chunkSize * chunkSize * ffi.sizeof("block"))
            ffi.copy(blob:getPointer(), chunk.blocks, chunkSize * chunkSize * chunkSize * ffi.sizeof("block"))
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
    end
    local debug_request = lovr.thread.getChannel("chunks_worker_debug_in"):pop()
    if debug_request and debug_request.type == 1000 then
        lovr.thread.getChannel("chunks_worker_debug_out"):push({type = 1000, payload = Debug.stats})
    end
end