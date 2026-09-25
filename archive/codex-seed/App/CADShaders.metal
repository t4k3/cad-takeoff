#include <metal_stdlib>
using namespace metal;

struct CADVertex { float4 position; float4 normal; };
struct Uniforms { float4x4 mvp; float4x4 rotation; };
struct RasterVertex { float4 position [[position]]; float3 normal; };

vertex RasterVertex cadVertex(uint id [[vertex_id]],
                             const device CADVertex *vertices [[buffer(0)]],
                             constant Uniforms &uniforms [[buffer(1)]]) {
    RasterVertex out;
    out.position = uniforms.mvp * vertices[id].position;
    out.normal = (uniforms.rotation * vertices[id].normal).xyz;
    return out;
}

fragment float4 cadFragment(RasterVertex in [[stage_in]]) {
    float diffuse = max(dot(normalize(in.normal), normalize(float3(-0.4, 0.7, 1.0))), 0.0);
    return float4(float3(0.22, 0.68, 0.84) * (0.3 + 0.7 * diffuse), 1);
}

