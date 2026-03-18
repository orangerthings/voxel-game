// because the fastest way to do anything in lua is to write it in C!
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
    bool mask_buffer[CHUNK_SIZE * CHUNK_SIZE];
    uint16_t tile_buffer[CHUNK_SIZE * CHUNK_SIZE];
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
void init_space(ChunkSpace* space) {
    space->size = 1024;
    space->count = 0;
    space->buckets = calloc(space->size, sizeof(ChunkEntry*));
}

static void resize(ChunkSpace* map) {
    size_t newSize = map->size*2;
    ChunkEntry** newBuckets = calloc(newSize, sizeof(ChunkEntry*));
    for (size_t i = 0; i < map->size; i++) {
        ChunkEntry* current = map->buckets[i];
        while (current) {
            ChunkEntry* next = current->next;
            size_t index = (current->hash) & (newSize-1);
            current->next = newBuckets[index];
            newBuckets[index] = current;
            current = next;
        }
    }
    free(map->buckets);
    map->buckets = newBuckets;
    map->size = newSize;
}

__declspec(dllexport)
void init_chunk(ChunkPrimitive* chunk, position pos, uint8_t lod, block* blocks) {
    chunk->pos = pos;
    chunk->chunkSize = CHUNK_SIZE;
    chunk->lod = lod;
    chunk->last_computed_lod_mask = 0;
    chunk->neighbors = 0;
    chunk->blocks = blocks;
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
            return current->chunk;
        }
        current = current->next;
    }
    *found = false;
    return NULL;
}

__declspec(dllexport)
void add_chunk(ChunkSpace* space, ChunkPrimitive* chunk) {
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
}

__declspec(dllexport)
void remove_chunk(ChunkSpace* space, position pos) {
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
            free(current);
            space->count--;
            break;
        }
        previous = current;
        current = next;
    }
}

__declspec(dllexport)
void free_space(ChunkSpace* space) {
    for (size_t i = 0; i < space->size; i++) {
        ChunkEntry* current = space->buckets[i];
        while (current) {
            ChunkEntry* next = current->next;
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

const block AIR = {
    .tile = 0,
    .state = 0,
    .mask = 0
};

// meshing

// faces and normal directions
const float QUADS[6][4][5] = {
    {{0,0,0,0,1},{0,0,1,1,1},{0,1,1,1,0},{0,1,0,0,0}},
    {{0,0,0,0,1},{1,0,0,1,1},{1,0,1,1,0},{0,0,1,0,0}},
    {{1,0,0,0,1},{0,0,0,1,1},{0,1,0,1,0},{1,1,0,0,0}},
    {{1,0,1,0,1},{1,0,0,1,1},{1,1,0,1,0},{1,1,1,0,0}},
    {{0,1,1,0,1},{1,1,1,1,1},{1,1,0,1,0},{0,1,0,0,0}},
    {{0,0,1,0,1},{1,0,1,1,1},{1,1,1,1,0},{0,1,1,0,0}}
};

// for offsetting an id quickly without having to use a special function
const int offsets[6] = {
    -(1 << (LOG2_CHUNK_SIZE * 2)),  // -x
    -(1 << LOG2_CHUNK_SIZE),        // -y
    -1,                             // -z
    1 << (LOG2_CHUNK_SIZE * 2),     // +x
    1 << LOG2_CHUNK_SIZE,           // +y
    1                               // +z
};

__declspec(dllexport)
void compute_mask(
    ChunkPrimitive* chunk,
    ChunkSpace* space,
    bool* transparent // transparency buffer
) {
    ChunkPrimitive* neighbors[6];
    for (int dir = 0; dir < 6; dir++) {
        position npos = {
            chunk->pos.x + NORMALS[dir][0],
            chunk->pos.y + NORMALS[dir][1],
            chunk->pos.z + NORMALS[dir][2]
        };
        bool found;
        neighbors[dir] = get_chunk(space, npos, &found);
        if (!found) {
            neighbors[dir] = NULL;
        }
    }

    uint8_t lod = chunk->lod;
    block* blocks = chunk->blocks;
    for (int x = 0; x < CHUNK_SIZE; x += lod) {
        for (int y = 0; y < CHUNK_SIZE; y += lod) {
            for (int z = 0; z < CHUNK_SIZE; z += lod) {
                int id = (x << (LOG2_CHUNK_SIZE*2)) | (y << LOG2_CHUNK_SIZE) | z;
                uint16_t tile = blocks[id].tile;
                if (tile == 0) {
                    blocks[id].mask = 0;
                    continue;
                }
                uint8_t mask = 0;
                bool solid = !transparent[tile];
                for (int dir = 0; dir < 6; dir++) {
                    uint16_t neighbor = 0;
                    if (
                        x < lod || x >= CHUNK_SIZE-lod ||
                        y < lod || y >= CHUNK_SIZE-lod ||
                        z < lod || z >= CHUNK_SIZE-lod // check to see if on border or not
                    ) {
                        int nx = x + NORMALS[dir][0]*lod;
                        int ny = y + NORMALS[dir][1]*lod;
                        int nz = z + NORMALS[dir][2]*lod;
                        if (
                            nx >= 0 && nx < CHUNK_SIZE &&
                            ny >= 0 && ny < CHUNK_SIZE &&
                            nz >= 0 && nz < CHUNK_SIZE // check to see if block is in bounds or not
                        ) {
                            neighbor = blocks[id + offsets[dir] * lod].tile;
                        } else {
                            ChunkPrimitive* neighbor_chunk = neighbors[dir];
                            if (neighbor_chunk) {
                                neighbor = neighbor_chunk->blocks[get_block_id(nx & CHUNK_SIZE_M1, ny & CHUNK_SIZE_M1, nz & CHUNK_SIZE_M1)].tile;
                            }
                        }
                    } else {
                        neighbor = blocks[id + offsets[dir] * lod].tile;
                    }
                    bool is_solid_neighbor = neighbor != 0 && !transparent[neighbor];
                    bool draw = (solid && !is_solid_neighbor) || (!solid && neighbor == 0);
                    mask |= draw << dir;
                }
                blocks[id].mask = mask;
            }
        }
    }
    chunk->last_computed_lod_mask = lod;
}

// meshing untouched... FOR NOW
// *dun dun DUN*
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
    
    if (chunk->last_computed_lod_mask != chunk->lod) {
        compute_mask(chunk, space, transparent);
    }

    int vertex_count = 0;
    int index_count = 0;
    int quad_count = 0;

    bool* masks = chunk->mask_buffer;
    uint16_t* tiles = chunk->tile_buffer;
    vertex_count = 1;
    index_count = 0;
    quad_count = 0;
    // then start the real loops
    for (int dir = 0; dir < 6; dir++) {
        int nx = NORMALS[dir][0] * lod;
        int ny = NORMALS[dir][1] * lod;
        int nz = NORMALS[dir][2] * lod;
        int ndix = NORMALS[dir][3];

        for (int slice = 1; slice <= lod_size; slice++) {
            for (int u = 1; u <= lod_size; u++) {
                for (int v = 1; v <= lod_size; v++) {
                    int x,y,z;
                    if (ndix == 1) {
                        x = (slice-1) * lod;
                        y = (u-1) * lod;
                        z = (v-1) * lod;
                    } else if (ndix == 2) {
                        x = (u-1) * lod;
                        y = (slice-1) * lod;
                        z = (v-1) * lod;
                    } else {
                        x = (u-1) * lod;
                        y = (v-1) * lod;
                        z = (slice-1) * lod;
                    }
                    block b = (chunk->blocks)[get_block_id(x,y,z)];
                    masks[(u-1)*lod_size + (v-1)] = (b.mask >> dir) & 1;
                    tiles[(u-1)*lod_size + (v-1)] = b.tile;
                }
            }

            for (int u = 0; u < lod_size; u++) {
                for (int v = 0; v < lod_size; v++) {
                    uint16_t tile = tiles[u*lod_size + v];
                    bool mask = masks[u*lod_size + v];
                    if (mask == 0) continue;

                    int w = 1;
                    while (
                        u+w < lod_size &&
                        tiles[(u+w)*lod_size + v] == tile && 
                        masks[(u+w)*lod_size + v] == 1
                    ) {
                        w++;
                    }
                    int h = 1;
                    int expand = 1;
                    while (v+h < lod_size && expand) {
                        for (int dx = 0; dx < w; dx++) {
                            if (
                                tiles[(u+dx)*lod_size + (v+h)] != tile || 
                                masks[(u+dx)*lod_size + (v+h)] == 0
                            ) {
                                expand = 0;
                                break;
                            }
                        }
                        if (expand) h++;
                    }
                    for (int du = 0; du < w; du++) {
                        for (int dv = 0; dv < h; dv++) {
                            tiles[(u+du)*lod_size + (v+dv)] = 0;
                            masks[(u+du)*lod_size + (v+dv)] = 0;
                        }
                    }

                    int px,py,pz;
                    if (ndix == 1) { 
                        px=slice; 
                        py=u+1; 
                        pz=v+1; 
                    } else if (ndix == 2) { 
                        px=u+1; 
                        py=slice; 
                        pz=v+1; 
                    } else { 
                        px=u+1; 
                        py=v+1; 
                        pz=slice; 
                    }
                    int dx,dy,dz;
                    if (ndix == 1) { 
                        dx=1; 
                        dy=w; 
                        dz=h; 
                    } else if (ndix == 2) { 
                        dx=w; 
                        dy=1; 
                        dz=h; 
                    } else {
                        dx=w; 
                        dy=h; 
                        dz=1; 
                    }
                    for (int i = 0; i < 4; i++) {
                        int b = vertex_count * 6;
                        vertex_buffer[b+0] = (QUADS[dir][i][0]*dx + (px-1)) * lod;
                        vertex_buffer[b+1] = (QUADS[dir][i][1]*dy + (py-1)) * lod;
                        vertex_buffer[b+2] = (QUADS[dir][i][2]*dz + (pz-1)) * lod;
                        vertex_buffer[b+3] = QUADS[dir][i][3] * (ndix==1 ? h : w) * lod;
                        vertex_buffer[b+4] = QUADS[dir][i][4] * (ndix==1 ? w : h) * lod;
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
