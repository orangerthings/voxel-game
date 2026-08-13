#include <signal.h>
#include <stdio.h>
#include <time.h>

#include <windows.h>
static LONG WINAPI crash_handler(EXCEPTION_POINTERS* info) {
    FILE* f = fopen("crash.log", "a");
    if (f) {
        time_t t = time(NULL);
        fprintf(f, "=== CRASH %s", ctime(&t));
        fprintf(f, "Exception code: 0x%08lX\n", info->ExceptionRecord->ExceptionCode);
        fprintf(f, "Exception addr: 0x%p\n", info->ExceptionRecord->ExceptionAddress);
        // print exception-specific info
        if (info->ExceptionRecord->ExceptionCode == EXCEPTION_ACCESS_VIOLATION) {
            ULONG_PTR* info_arr = info->ExceptionRecord->ExceptionInformation;
            fprintf(f, "Access violation: %s address 0x%p\n",
                info_arr[0] == 0 ? "READ" : "WRITE",
                (void*)info_arr[1]);
        }
        fclose(f);
    }
    return EXCEPTION_CONTINUE_SEARCH; // let the OS handle it after logging
}

__declspec(dllexport)
void init_crash_handler(void) {
    AddVectoredExceptionHandler(1, crash_handler); // 1 = call first
}

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>

#define CHUNK_SIZE 32
#define CHUNK_SIZE_M1 31
#define LOG2_CHUNK_SIZE 5

// important structs
typedef struct { 
    uint16_t tile;
    uint8_t state;
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

    // BUFFERS ARE ARRAYS OF 64-BIT INTEGERS INSTEAD OF 32-BIT TO AVOID UNDEFINED BEHAVIOR WITH __builtin_ctz(0)
    uint64_t meshing_buffer[CHUNK_SIZE]; // array of bitfields to encode all v values into one binary number
    uint64_t prefix_buffer[CHUNK_SIZE]; // bitfield to encode whether or not tile v at a given position is equivalent to v-1
    uint16_t tile_buffer[CHUNK_SIZE][CHUNK_SIZE];
} ChunkPrimitive;

typedef struct ChunkEntry {
    int hash;
    position pos;
    ChunkPrimitive* chunk;
    struct ChunkEntry* next;
} ChunkEntry;

typedef struct {
    ChunkEntry** buckets;
    size_t size;
    size_t count;
    CRITICAL_SECTION lock;
} ChunkSpace;

// hashmap methods
static inline int get_hash(position pos) {
    return (
        pos.x * 0x9E3779B1 ^
        pos.y * 0x85EBCA6B ^
        pos.z * 0xC2B2AE35
    );
}

__declspec(dllexport)
ChunkSpace* init_space() {
    ChunkSpace* space = malloc(sizeof(ChunkSpace));
    space->size = 1024;
    space->count = 0;
    space->buckets = calloc(space->size, sizeof(ChunkEntry*));
    InitializeCriticalSection(&space->lock);
    return space;
}

static void resize(ChunkSpace* space) {
    EnterCriticalSection(&space->lock);
    size_t newSize = space->size*2;
    ChunkEntry** newBuckets = calloc(newSize, sizeof(ChunkEntry*));
    for (size_t i = 0; i < space->size; i++) {
        ChunkEntry* current = space->buckets[i];
        while (current) {
            ChunkEntry* next = current->next;
            size_t index = (current->hash) & (newSize-1);
            current->next = newBuckets[index];
            newBuckets[index] = current;
            current = next;
        }
    }
    free(space->buckets);
    space->buckets = newBuckets;
    space->size = newSize;
    LeaveCriticalSection(&space->lock);
}

__declspec(dllexport)
block* allocate_blocks() {
    return (block*)malloc(sizeof(block) * CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE);
}

__declspec(dllexport)
void copy_blocks(block* dst, block* src) {
    memcpy(dst, src, sizeof(block) * CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE);
}

static void init_chunk(ChunkPrimitive* chunk, position pos, uint8_t lod) {
    chunk->pos = pos;
    chunk->chunkSize = CHUNK_SIZE;
    chunk->lod = lod;
    chunk->neighbors = 0;
    chunk->blocks = allocate_blocks();
}

__declspec(dllexport)
ChunkPrimitive* new_chunk(position pos, uint8_t lod) {
    ChunkPrimitive* chunk = malloc(sizeof(ChunkPrimitive));
    init_chunk(chunk, pos, lod);
    return chunk;
}

const int NORMALS[6][4] = {
    {-1,0 ,0, 1}, // x- (left)
    {0 ,-1,0, 2}, // y- (bottom)
    {0 ,0, -1,3}, // z- (front)
    {1 ,0 ,0 ,1}, // x+ (right)
    {0 ,1 ,0 ,2}, // y+ (top)
    {0 ,0 ,1 ,3}  // z+ (back)
};

__declspec(dllexport)
ChunkPrimitive* get_chunk(ChunkSpace* space, position pos, bool* found) {
    EnterCriticalSection(&space->lock);
    int hash = get_hash(pos);
    size_t index = hash & (space->size-1);
    ChunkEntry* current = space->buckets[index];
    while (current) {
        if (
            current->pos.x == pos.x && 
            current->pos.y == pos.y && 
            current->pos.z == pos.z
        ) {
            *found = true;
            LeaveCriticalSection(&space->lock);
            return current->chunk;
        }
        current = current->next;
    }
    *found = false;
    LeaveCriticalSection(&space->lock);
    return NULL;
}

__declspec(dllexport)
void add_chunk(ChunkSpace* space, ChunkPrimitive* chunk) {
    EnterCriticalSection(&space->lock);
    for (int dir = 0; dir < 6; dir++) {
        position neighbor_pos = {
            .x = chunk->pos.x+NORMALS[dir][0],
            .y = chunk->pos.y+NORMALS[dir][1],
            .z = chunk->pos.z+NORMALS[dir][2]
        };
        bool found = false;
        ChunkPrimitive* neighbor = get_chunk(space, neighbor_pos, &found);
        if (found) {
            neighbor->neighbors++;
            chunk->neighbors++;
        }
    }
    if ((double)space->count / space->size >= 0.5) {
        resize(space);
    }
    int hash = get_hash(chunk->pos);
    size_t index = hash & (space->size-1);

    ChunkEntry* current = space->buckets[index];
    while (current) {
        if (
            current->pos.x == chunk->pos.x && 
            current->pos.y == chunk->pos.y && 
            current->pos.z == chunk->pos.z
        ) {
            current->chunk = chunk;
            LeaveCriticalSection(&space->lock);
            return;
        }
        current = current->next;
    }

    ChunkEntry* entry = malloc(sizeof(ChunkEntry));
    entry->pos = chunk->pos;
    entry->hash = hash;
    entry->chunk = chunk;
    entry->next = space->buckets[index];
    space->buckets[index] = entry;
    space->count++;
    LeaveCriticalSection(&space->lock);
}

__declspec(dllexport)
void remove_chunk(ChunkSpace* space, position pos) {
    EnterCriticalSection(&space->lock);
    for (int dir = 0; dir < 6; dir++) {
        position neighbor_pos = {
            .x = pos.x+NORMALS[dir][0],
            .y = pos.y+NORMALS[dir][1],
            .z = pos.z+NORMALS[dir][2]
        };
        bool found = false;
        ChunkPrimitive* neighbor = get_chunk(space, neighbor_pos, &found);
        if (found) {
            if (neighbor->neighbors > 0) {
                neighbor->neighbors--;
            }
        }
    }
    int hash = get_hash(pos);
    size_t index = hash & (space->size-1);
    ChunkEntry* current = space->buckets[index];
    ChunkEntry* previous = NULL;
    while (current) {
        ChunkEntry* next = current->next;
        if (
            current->pos.x == pos.x && 
            current->pos.y == pos.y && 
            current->pos.z == pos.z
        ) {
            if (previous == NULL) {
                space->buckets[index] = current->next;
            } else {
                previous->next = current->next;
            }
            if (current->chunk) {
                free(current->chunk->blocks);
                free(current->chunk);
            }
            free(current);
            space->count--;
            break;
        }
        previous = current;
        current = next;
    }
    LeaveCriticalSection(&space->lock);
}

// note for running: unused for now but unprotected so run with dicsretion
__declspec(dllexport)
void free_space(ChunkSpace* space) {
    for (size_t i = 0; i < space->size; i++) {
        ChunkEntry* current = space->buckets[i];
        while (current) {
            ChunkEntry* next = current->next;
            if (current->chunk) {
                free(current->chunk->blocks);
                free(current->chunk);
            }
            free(current);
            current = next;
        }
    }
    free(space->buckets);
}

// methods for manipulating chunk data and stuff now
static inline uint16_t get_block_id(int8_t x, int8_t y, int8_t z) {
    return ((uint16_t)x<<LOG2_CHUNK_SIZE*2) | (y<<LOG2_CHUNK_SIZE) | z;
}

// for offsetting an id quickly without having to use a special function
const int STRIDES[6] = {
    -(1 << (LOG2_CHUNK_SIZE * 2)),  // -x
    -(1 << LOG2_CHUNK_SIZE),        // -y
    -1,                             // -z
    1 << (LOG2_CHUNK_SIZE * 2),     // +x
    1 << LOG2_CHUNK_SIZE,           // +y
    1                               // +z
};

const int CUTS[6] = {
    CHUNK_SIZE_M1 << LOG2_CHUNK_SIZE * 2, // x
    CHUNK_SIZE_M1 << LOG2_CHUNK_SIZE,     // y
    CHUNK_SIZE_M1,                        // z
    CHUNK_SIZE_M1 << LOG2_CHUNK_SIZE * 2, // x
    CHUNK_SIZE_M1 << LOG2_CHUNK_SIZE,     // y
    CHUNK_SIZE_M1                         // z
};

// creating duh terrains

#define FNL_IMPL
#include "FastNoiseLite.h"
__declspec(dllexport)
void generate_chunk(ChunkSpace* space, ChunkPrimitive* chunk) {
    static fnl_state noise;
    static int noise_init = 0;
    if (!noise_init) {
        noise = fnlCreateState();
        noise.seed = 1337;
        noise.noise_type = FNL_NOISE_OPENSIMPLEX2;
        noise.frequency = 1.0f / 64.0f;
        noise_init = 1;
    }

    uint8_t lod = chunk->lod;
    block* blocks = chunk->blocks;
    int base_x = chunk->pos.x * CHUNK_SIZE;
    int base_y = chunk->pos.y * CHUNK_SIZE;
    int base_z = chunk->pos.z * CHUNK_SIZE;

    if (base_y > 8) {
        memset(blocks, 0, sizeof(block) * CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE);
        return;
    }

    float heights[CHUNK_SIZE][CHUNK_SIZE];
    int x;
    #pragma omp parallel for schedule(static) firstprivate(noise)
    for (x = 0; x < CHUNK_SIZE; x += lod) {
        for (int z = 0; z < CHUNK_SIZE; z += lod) {
            heights[x][z] = fnlGetNoise2D(&noise,
                (float)(x + base_x),
                (float)(z + base_z)) * 4.0f + 4.0f;
        }
    }

    uint8_t solid_tile[CHUNK_SIZE];
    for (int y = 0; y < CHUNK_SIZE; y += lod) {
        int wy = y + base_y;
        solid_tile[y] = (wy < 3) ? 2 : (wy < 6) ? 1 : 3;
    }

    #pragma omp parallel for schedule(static)
    for (x = 0; x < CHUNK_SIZE; x += lod) {
        for (int z = 0; z < CHUNK_SIZE; z += lod) {
            float height = heights[x][z];
            for (int y = 0; y < CHUNK_SIZE; y += lod) {
                int wy = y + base_y;
                blocks[get_block_id(x,y,z)].tile = (wy <= height) ? solid_tile[y] : 0;
            }
        }
    }
}

// meshing

const block AIR = {
    .tile = 0,
    .state = 0
};

// faces and normal directions
const float QUADS[6][4][5] = {
    {{0,0,0,0,1},{0,0,1,1,1},{0,1,1,1,0},{0,1,0,0,0}},
    {{0,0,0,0,1},{1,0,0,1,1},{1,0,1,1,0},{0,0,1,0,0}},
    {{1,0,0,0,1},{0,0,0,1,1},{0,1,0,1,0},{1,1,0,0,0}},
    {{1,0,1,0,1},{1,0,0,1,1},{1,1,0,1,0},{1,1,1,0,0}},
    {{0,1,1,0,1},{1,1,1,1,1},{1,1,0,1,0},{0,1,0,0,0}},
    {{0,0,1,0,1},{1,0,1,1,1},{1,1,1,1,0},{0,1,1,0,0}}
};

// strides but specialized for generate_mesh
const int DIR_SHIFT[8] = {
    LOG2_CHUNK_SIZE * 2,     // x
    LOG2_CHUNK_SIZE,         // y
    0,                       // z
    LOG2_CHUNK_SIZE * 2,     // x
    LOG2_CHUNK_SIZE,         // y
    0,                       // z
    LOG2_CHUNK_SIZE * 2,     // x
    LOG2_CHUNK_SIZE,         // y
};

const int MOD_3[8] = {0,1,2,0,1,2,0,1};
const int INV_MOD_3[6] = {0,2,1,0,2,1};

// meshing
__declspec(dllexport)
void generate_mesh(
    ChunkPrimitive* chunk,
    ChunkSpace* space,
    bool* transparent,
    float* vertex_buffer,
    uint32_t* index_buffer,
    int* vertex_num_out,
    int* index_num_out
) {
    uint8_t lod = chunk->lod;
    uint8_t lod_size = CHUNK_SIZE / lod;

    block* blocks = chunk->blocks;

    uint64_t* meshing_buffer = chunk->meshing_buffer;
    uint64_t* prefix_buffer = chunk->prefix_buffer;
    uint16_t (*tiles)[CHUNK_SIZE] = chunk->tile_buffer;
    int vertex_count = 1;
    int index_count = 0;
    int quad_count = 0;
    ChunkPrimitive* neighbors[6];
    // its important to lock this part 
    EnterCriticalSection(&space->lock);
    for (int dir = 0; dir < 6; dir++) {
        position npos = {
            chunk->pos.x + NORMALS[dir][0],
            chunk->pos.y + NORMALS[dir][1],
            chunk->pos.z + NORMALS[dir][2]
        };
        bool found;
        neighbors[dir] = get_chunk(space, npos, &found);
        if (!found) neighbors[dir] = NULL;
    }
    LeaveCriticalSection(&space->lock);
    for (int dir = 0; dir < 6; dir++) {
        for (int slice = 0; slice < CHUNK_SIZE; slice++) {
            memset(meshing_buffer, 0, CHUNK_SIZE * sizeof(uint64_t));
            memset(prefix_buffer, 0, CHUNK_SIZE * sizeof(uint64_t));
            for (int u = 0; u < CHUNK_SIZE; u++) {
                int b_id = (slice << DIR_SHIFT[dir]) | (u << DIR_SHIFT[dir+1]);
                for (int v = 0; v < CHUNK_SIZE; v++) {
                    block b = blocks[b_id];
                    uint16_t tile = b.tile;

                    // masking logic for meshing buffer
                    if (tile != 0) {
                        uint16_t neighbor = 0;
                        int CUT = CUTS[dir];
                        int nid = b_id + STRIDES[dir];
                        int id_odid = b_id & ~CUT;
                        if (id_odid == (nid & ~CUT)) { // oob?
                            neighbor = blocks[nid].tile;
                        } else {
                            ChunkPrimitive* neighbor_chunk = neighbors[dir];
                            if (neighbor_chunk) {
                                neighbor = neighbor_chunk->blocks[id_odid | (nid & CUT)].tile;
                            }
                        }
                        bool solid = !transparent[tile];
                        bool is_solid_neighbor = neighbor != 0 && !transparent[neighbor];
                        bool draw = (solid && !is_solid_neighbor) || (!solid && neighbor == 0);
                        if (draw) {
                            meshing_buffer[u] |= (1ULL << v);
                        }
                    }

                    // prefix buffer 
                    b_id += (1 << DIR_SHIFT[dir+2]);
                    if (v < CHUNK_SIZE-1) {
                        if (tile == blocks[b_id].tile) {
                            prefix_buffer[u] |= (1ULL << (v+1));
                        }
                    }
                    tiles[u][v] = tile;
                }
            }
            for (int u = 0; u < CHUNK_SIZE; u++) {
                uint64_t v_col = meshing_buffer[u];
                while (v_col != 0) {
                    int v = __builtin_ctz(v_col); // get position lowest draw of the column
                    uint16_t tile = tiles[u][v];

                    // h expands v-wise
                    uint64_t shifted = v_col >> v;
                    int h_vsbl = __builtin_ctz(shifted+1); // counts how many down the line are visible
                    int h_same = __builtin_ctz((prefix_buffer[u]>>(v+1))+1)+1; // counts how many down the line are same
                    int h = (h_vsbl < h_same) ? h_vsbl : h_same; // their min is the true height

                    // w expands u-wise
                    uint64_t height_cut = ((1ULL << h) - 1) << v; // bits from v to v+h-1 to check colums later
                    uint64_t prefix_height_cut = ((1ULL << h) - 1) << (v+1); // bits from v+1 to v+h-1 to check the prefixes later
                    int w = 1;
                    while (u + w < CHUNK_SIZE) {
                        // is the next column entirely visible?
                        if ((meshing_buffer[u + w] & height_cut) != height_cut) {
                            break;
                        }
                        // is the next column entirely the same?
                        if ((prefix_buffer[u + w] & prefix_height_cut) != prefix_height_cut) {
                            break;
                        }
                        // is the next column the same tile?
                        if (tile != tiles[u + w][v]) {
                            break;
                        }
                        // we have succeeded if so!!
                        w++;
                    }

                    // remove the bits for this quad
                    uint64_t prefix_eraser_cut = ((1ULL << h) - 1) << (v+1); // bits from v to v+h to erase prefixes
                    for (int du = 0; du < w; du++) {
                        meshing_buffer[u + du] &= ~height_cut;
                        prefix_buffer[u + du] &= ~prefix_eraser_cut;
                    }
                    v_col = meshing_buffer[u];

                    // emit quad
                    int rx = INV_MOD_3[dir],ry=MOD_3[rx+1],rz=MOD_3[rx+2];
                    int p[3] = {slice,u,v}; // extracts u,v from uv_id
                    int px=p[rx],py=p[ry],pz=p[rz];
                    int d[3] = {1,w,h}; // dimensions
                    int dx=d[rx],dy=d[ry],dz=d[rz];
                    for (int i = 0; i < 4; i++) {
                        int b = vertex_count * 6;
                        vertex_buffer[b+0] = (QUADS[dir][i][0]*dx + (px-1)) * lod;
                        vertex_buffer[b+1] = (QUADS[dir][i][1]*dy + (py-1)) * lod;
                        vertex_buffer[b+2] = (QUADS[dir][i][2]*dz + (pz-1)) * lod;
                        vertex_buffer[b+3] = QUADS[dir][i][3] * (dir==2||dir==5 ? w : h) * lod;
                        vertex_buffer[b+4] = QUADS[dir][i][4] * (dir==2||dir==5 ? h : w) * lod;
                        vertex_buffer[b+5] = tile - 1;
                        vertex_count++;
                    }

                    int b = quad_count * 4 + 1;
                    index_buffer[index_count+0] = b + 1;
                    index_buffer[index_count+1] = b + 2;
                    index_buffer[index_count+2] = b + 0;
                    index_buffer[index_count+3] = b + 2;
                    index_buffer[index_count+4] = b + 3;
                    index_buffer[index_count+5] = b + 0;
                    index_count += 6;
                    quad_count++;
                }
            }
        }
    }
    *vertex_num_out = vertex_count;
    *index_num_out = index_count;
}
