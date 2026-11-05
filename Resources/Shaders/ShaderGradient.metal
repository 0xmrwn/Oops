// ShaderGradient's "defaults" sphere (@shadergradient/react 2.4.24 on three.js r169), ported line for line:
// its vertex shader (shaders/defaults/sphere/vertex.glsl) and the parts of three's MeshPhysicalMaterial
// that its fragment shader runs for this scene: image-based light from the "city" environment only,
// no lights, no clearcoat (USE_CLEARCOAT is off at clearcoat 0), no IOR define, no tone mapping and no
// output encoding (the canvas is `linear` and `flat`). Compiled at run time by GradientRenderer.

#include <metal_stdlib>
using namespace metal;

constant float PI = 3.141592653589793;
constant float RECIPROCAL_PI = 0.3183098861837907;

struct SceneUniforms {
    float4x4 modelView;
    float4x4 projection;
    float4x4 view;
    float4 color1, color2, color3;
    float time, speed, density, strength, frequency, amplitude, roughness, metalness;
};

struct SphereVertex { packed_float3 position; packed_float3 normal; packed_float2 uv; };

struct Varyings {
    float4 position [[position]];
    float3 vPos;
    float3 vNormal;
    float3 vViewPosition;
};

// MARK: - Classic Perlin noise, periodic variant (glsl-noise/periodic/3d)

// GLSL's mod, not C's fmod: the result takes the divisor's sign.
template <typename T> T glslMod(T x, T y) { return x - y * floor(x / y); }

float3 mod289(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
float4 mod289(float4 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
float4 permute(float4 x) { return mod289(((x * 34.0) + 1.0) * x); }
float4 taylorInvSqrt(float4 r) { return 1.79284291400159 - 0.85373472095314 * r; }
float3 fade(float3 t) { return t * t * t * (t * (t * 6.0 - 15.0) + 10.0); }

float pnoise(float3 P, float3 rep) {
    float3 Pi0 = glslMod(floor(P), rep);
    float3 Pi1 = glslMod(Pi0 + float3(1.0), rep);
    Pi0 = mod289(Pi0);
    Pi1 = mod289(Pi1);
    float3 Pf0 = fract(P);
    float3 Pf1 = Pf0 - float3(1.0);
    float4 ix = float4(Pi0.x, Pi1.x, Pi0.x, Pi1.x);
    float4 iy = float4(Pi0.yy, Pi1.yy);
    float4 iz0 = Pi0.zzzz;
    float4 iz1 = Pi1.zzzz;

    float4 ixy = permute(permute(ix) + iy);
    float4 ixy0 = permute(ixy + iz0);
    float4 ixy1 = permute(ixy + iz1);

    float4 gx0 = ixy0 * (1.0 / 7.0);
    float4 gy0 = fract(floor(gx0) * (1.0 / 7.0)) - 0.5;
    gx0 = fract(gx0);
    float4 gz0 = float4(0.5) - abs(gx0) - abs(gy0);
    float4 sz0 = step(gz0, float4(0.0));
    gx0 -= sz0 * (step(0.0, gx0) - 0.5);
    gy0 -= sz0 * (step(0.0, gy0) - 0.5);

    float4 gx1 = ixy1 * (1.0 / 7.0);
    float4 gy1 = fract(floor(gx1) * (1.0 / 7.0)) - 0.5;
    gx1 = fract(gx1);
    float4 gz1 = float4(0.5) - abs(gx1) - abs(gy1);
    float4 sz1 = step(gz1, float4(0.0));
    gx1 -= sz1 * (step(0.0, gx1) - 0.5);
    gy1 -= sz1 * (step(0.0, gy1) - 0.5);

    float3 g000 = float3(gx0.x, gy0.x, gz0.x);
    float3 g100 = float3(gx0.y, gy0.y, gz0.y);
    float3 g010 = float3(gx0.z, gy0.z, gz0.z);
    float3 g110 = float3(gx0.w, gy0.w, gz0.w);
    float3 g001 = float3(gx1.x, gy1.x, gz1.x);
    float3 g101 = float3(gx1.y, gy1.y, gz1.y);
    float3 g011 = float3(gx1.z, gy1.z, gz1.z);
    float3 g111 = float3(gx1.w, gy1.w, gz1.w);

    float4 norm0 = taylorInvSqrt(float4(dot(g000, g000), dot(g010, g010), dot(g100, g100), dot(g110, g110)));
    g000 *= norm0.x;
    g010 *= norm0.y;
    g100 *= norm0.z;
    g110 *= norm0.w;
    float4 norm1 = taylorInvSqrt(float4(dot(g001, g001), dot(g011, g011), dot(g101, g101), dot(g111, g111)));
    g001 *= norm1.x;
    g011 *= norm1.y;
    g101 *= norm1.z;
    g111 *= norm1.w;

    float n000 = dot(g000, Pf0);
    float n100 = dot(g100, float3(Pf1.x, Pf0.yz));
    float n010 = dot(g010, float3(Pf0.x, Pf1.y, Pf0.z));
    float n110 = dot(g110, float3(Pf1.xy, Pf0.z));
    float n001 = dot(g001, float3(Pf0.xy, Pf1.z));
    float n101 = dot(g101, float3(Pf1.x, Pf0.y, Pf1.z));
    float n011 = dot(g011, float3(Pf0.x, Pf1.yz));
    float n111 = dot(g111, Pf1);

    float3 fade_xyz = fade(Pf0);
    float4 n_z = mix(float4(n000, n100, n010, n110), float4(n001, n101, n011, n111), fade_xyz.z);
    float2 n_yz = mix(n_z.xy, n_z.zw, fade_xyz.y);
    float n_xyz = mix(n_yz.x, n_yz.y, fade_xyz.x);
    return 2.2 * n_xyz;
}

// GLSL's mat3(c, 0, -s, 0, 1, 0, s, 0, c), column by column.
float3 rotateY(float3 v, float angle) {
    float s = sin(angle), c = cos(angle);
    return float3x3(float3(c, 0.0, -s), float3(0.0, 1.0, 0.0), float3(s, 0.0, c)) * v;
}

// MARK: - Vertex (uLoop off: linear time)

vertex Varyings sphereVertex(uint vid [[vertex_id]], const device SphereVertex *vertices [[buffer(0)]],
                             constant SceneUniforms &u [[buffer(1)]]) {
    SphereVertex v = vertices[vid];
    float3 position = float3(v.position), normal = float3(v.normal);
    float2 uv = float2(v.uv);
    float t = u.time * u.speed;
    float distortion = pnoise((normal + t) * u.density, float3(10.0)) * u.strength;
    float angle = sin(uv.y * u.frequency + t) * u.amplitude;
    float3 pos = position + (normal * distortion);
    pos = rotateY(pos, angle);

    Varyings out;
    out.vPos = pos;
    out.vNormal = normal; // The undeformed object-space normal, which three then treats as a view-space one.
    out.position = u.projection * (u.modelView * float4(pos, 1.0));
    // Lighting keeps the undeformed position, as the original does.
    out.vViewPosition = -(u.modelView * float4(position, 1.0)).xyz;
    return out;
}

// MARK: - three's cube-UV environment lookup (cube_uv_reflection_fragment)

// The bundled texture holds only the atlas rows this material reads: roughness is at least 0.6, so every
// lookup lands in the 16-texel extra levels at GL y 960 of the 768-wide atlas (a 256 cube, CUBEUV_MAX_MIP 8),
// columns 0…335.
constant float cubeUV_minMipLevel = 4.0;
constant float cubeUV_minTileSize = 16.0;
constant float CUBEUV_MAX_MIP = 8.0;
constant float atlasRowsStart = 960.0;

float getFace(float3 direction) {
    float3 absDirection = abs(direction);
    float face = -1.0;
    if (absDirection.x > absDirection.z) {
        if (absDirection.x > absDirection.y) face = direction.x > 0.0 ? 0.0 : 3.0;
        else face = direction.y > 0.0 ? 1.0 : 4.0;
    } else {
        if (absDirection.z > absDirection.y) face = direction.z > 0.0 ? 2.0 : 5.0;
        else face = direction.y > 0.0 ? 1.0 : 4.0;
    }
    return face;
}

float2 getUV(float3 direction, float face) {
    float2 uv;
    if (face == 0.0) uv = float2(direction.z, direction.y) / abs(direction.x);
    else if (face == 1.0) uv = float2(-direction.x, -direction.z) / abs(direction.y);
    else if (face == 2.0) uv = float2(-direction.x, direction.y) / abs(direction.z);
    else if (face == 3.0) uv = float2(-direction.z, direction.y) / abs(direction.x);
    else if (face == 4.0) uv = float2(-direction.x, direction.z) / abs(direction.y);
    else uv = float2(direction.x, direction.y) / abs(direction.z);
    return 0.5 * (uv + 1.0);
}

float3 bilinearCubeUV(texture2d<float> envMap, float3 direction, float mipInt) {
    constexpr sampler linear(filter::linear, address::clamp_to_edge);
    float face = getFace(direction);
    float filterInt = max(cubeUV_minMipLevel - mipInt, 0.0);
    mipInt = max(mipInt, cubeUV_minMipLevel);
    float faceSize = exp2(mipInt);
    float2 uv = getUV(direction, face) * (faceSize - 2.0) + 1.0;
    if (face > 2.0) {
        uv.y += faceSize;
        face -= 3.0;
    }
    uv.x += face * faceSize;
    uv.x += filterInt * 3.0 * cubeUV_minTileSize;
    uv.y += 4.0 * (exp2(CUBEUV_MAX_MIP) - faceSize);
    // Texel coordinates to the bundled rows: same texel centres as the full atlas.
    return envMap.sample(linear, float2(uv.x / float(envMap.get_width()), (uv.y - atlasRowsStart) / float(envMap.get_height()))).rgb;
}

float roughnessToMip(float roughness) {
    float mip = 0.0;
    if (roughness >= 0.8) mip = (1.0 - roughness) * (-1.0 - -2.0) / (1.0 - 0.8) + -2.0;
    else if (roughness >= 0.4) mip = (0.8 - roughness) * (2.0 - -1.0) / (0.8 - 0.4) + -1.0;
    else if (roughness >= 0.305) mip = (0.4 - roughness) * (3.0 - 2.0) / (0.4 - 0.305) + 2.0;
    else if (roughness >= 0.21) mip = (0.305 - roughness) * (4.0 - 3.0) / (0.305 - 0.21) + 3.0;
    else mip = -2.0 * log2(1.16 * roughness);
    return mip;
}

float3 textureCubeUV(texture2d<float> envMap, float3 sampleDir, float roughness) {
    float mip = clamp(roughnessToMip(roughness), -2.0, CUBEUV_MAX_MIP);
    float mipF = fract(mip);
    float mipInt = floor(mip);
    float3 color0 = bilinearCubeUV(envMap, sampleDir, mipInt);
    if (mipF == 0.0) return color0;
    float3 color1 = bilinearCubeUV(envMap, sampleDir, mipInt + 1.0);
    return mix(color0, color1, mipF);
}

// Row vector times matrix: the transposed rotation, as three's inverseTransformDirection.
float3 inverseTransformDirection(float3 dir, float4x4 matrix) { return normalize((float4(dir, 0.0) * matrix).xyz); }

float2 DFGApprox(float3 normal, float3 viewDir, float roughness) {
    float dotNV = saturate(dot(normal, viewDir));
    const float4 c0 = float4(-1, -0.0275, -0.572, 0.022);
    const float4 c1 = float4(1, 0.0425, 1.04, -0.04);
    float4 r = roughness * c0 + c1;
    float a004 = min(r.x * r.x, exp2(-9.28 * dotNV)) * r.x + r.y;
    return float2(-1.04, 1.04) * a004 + r.zw;
}

// MARK: - Fragment

fragment float4 sphereFragment(Varyings in [[stage_in]], bool frontFacing [[front_facing]],
                               constant SceneUniforms &u [[buffer(1)]], texture2d<float> envMap [[texture(0)]]) {
    float distanceToCenter = distance(in.vPos, float3(0.0));
    float3 diffuseColor = mix(u.color3.rgb, mix(u.color2.rgb, u.color1.rgb, smoothstep(-1.0, 1.0, in.vPos.y)), distanceToCenter);

    // normal_fragment_begin, double sided
    float faceDirection = frontFacing ? 1.0 : -1.0;
    float3 normal = normalize(in.vNormal) * faceDirection;

    // lights_physical_fragment
    float3 materialDiffuse = diffuseColor * (1.0 - u.metalness);
    float3 dxy = max(abs(dfdx(normal)), abs(dfdy(normal)));
    float geometryRoughness = max(max(dxy.x, dxy.y), dxy.z);
    float roughness = max(u.roughness, 0.0525);
    roughness += geometryRoughness;
    roughness = min(roughness, 1.0);
    float3 specularColor = mix(float3(0.04), diffuseColor, u.metalness);
    float specularF90 = 1.0;

    // lights_fragment_begin and _maps: no lights, so only the environment's irradiance and radiance.
    float3 viewDir = normalize(in.vViewPosition);
    float3 iblIrradiance = PI * textureCubeUV(envMap, inverseTransformDirection(normal, u.view), 1.0);
    float3 reflectVec = reflect(-viewDir, normal);
    reflectVec = normalize(mix(reflectVec, normal, roughness * roughness));
    float3 radiance = textureCubeUV(envMap, inverseTransformDirection(reflectVec, u.view), roughness);

    // RE_IndirectSpecular_Physical with computeMultiscattering
    float2 fab = DFGApprox(normal, viewDir, roughness);
    float3 FssEss = specularColor * fab.x + specularF90 * fab.y;
    float Ess = fab.x + fab.y;
    float Ems = 1.0 - Ess;
    float3 Favg = specularColor + (1.0 - specularColor) * 0.047619;
    float3 Fms = FssEss * Favg / (1.0 - Ems * Favg);
    float3 singleScattering = FssEss;
    float3 multiScattering = Fms * Ems;
    float3 cosineWeightedIrradiance = iblIrradiance * RECIPROCAL_PI;
    float3 totalScattering = singleScattering + multiScattering;
    float3 diffuse = materialDiffuse * (1.0 - max(max(totalScattering.r, totalScattering.g), totalScattering.b));
    float3 indirectSpecular = radiance * singleScattering + multiScattering * cosineWeightedIrradiance;
    float3 indirectDiffuse = diffuse * cosineWeightedIrradiance;

    // Transmission is 0, so the TRANSMISSION alpha term is 1.
    return float4(indirectDiffuse + indirectSpecular, 1.0);
}
