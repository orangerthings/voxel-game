in float VertexTile;

out vec2 vUV;
flat out float vTile;

vec4 lovrmain() {
    vUV = VertexUV;
    vTile = VertexTile;
    return Projection * View * Transform * VertexPosition;
}
