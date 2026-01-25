uniform texture2DArray textureArray;

in vec2 vUV;
flat in float vTile;

vec4 lovrmain() {
    return texture(sampler2DArray(textureArray, Sampler), vec3(vUV, vTile));
}
