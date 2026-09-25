/// Metal shaders compiled at runtime (`makeLibrary(source:)`), so building the app
/// does not require the optional Metal Toolchain component of Xcode.
enum ShaderSource {
    static let code = #"""
#include <metal_stdlib>
using namespace metal;

struct MeshVertex { float4 position; float4 normal; };
struct LineVertex { float4 position; float4 color; };

struct FrameUniforms {
    float4x4 viewProjection;
    float4 eye;          // xyz = camera position
    float4 lightDir;     // xyz = direction towards the key light
};

struct DrawUniforms {
    float4 color;        // rgb + highlight strength in a
};

struct MeshOut {
    float4 position [[position]];
    float3 normal;
    float3 world;
};

vertex MeshOut meshVertex(uint id [[vertex_id]],
                          const device MeshVertex *v [[buffer(0)]],
                          constant FrameUniforms &frame [[buffer(1)]]) {
    MeshOut o;
    o.position = frame.viewProjection * v[id].position;
    o.normal = v[id].normal.xyz;
    o.world = v[id].position.xyz;
    return o;
}

fragment float4 meshFragment(MeshOut in [[stage_in]],
                             constant FrameUniforms &frame [[buffer(1)]],
                             constant DrawUniforms &draw [[buffer(2)]]) {
    float3 n = normalize(in.normal);
    float3 viewDir = normalize(frame.eye.xyz - in.world);
    float3 l = normalize(frame.lightDir.xyz);
    // Hemisphere ambient (sky above, ground below) + key light + soft headlight.
    float hemi = mix(0.35, 0.62, n.z * 0.5 + 0.5);
    float key = max(dot(n, l), 0.0) * 0.55;
    float head = max(dot(n, viewDir), 0.0) * 0.25;
    float3 h = normalize(l + viewDir);
    float spec = pow(max(dot(n, h), 0.0), 48.0) * 0.18;
    float3 rgb = draw.color.rgb * (hemi + key + head) + spec;
    // Fresnel rim for highlighted bodies.
    float rim = pow(1.0 - max(dot(n, viewDir), 0.0), 3.0) * draw.color.a;
    return float4(rgb + rim * float3(1.0, 0.6, 0.25), 1.0);
}

struct LineOut {
    float4 position [[position]];
    float4 color;
    float fade;
};

vertex LineOut lineVertex(uint id [[vertex_id]],
                          const device LineVertex *v [[buffer(0)]],
                          constant FrameUniforms &frame [[buffer(1)]]) {
    LineOut o;
    o.position = frame.viewProjection * v[id].position;
    o.color = v[id].color;
    // Fade the grid with distance from the camera.
    float d = distance(v[id].position.xyz, frame.eye.xyz);
    o.fade = clamp(1.6 - d / max(frame.eye.w, 1.0), 0.0, 1.0);
    return o;
}

fragment float4 lineFragment(LineOut in [[stage_in]]) {
    return float4(in.color.rgb, in.color.a * in.fade);
}

fragment float4 edgeFragment(LineOut in [[stage_in]],
                             constant DrawUniforms &draw [[buffer(2)]]) {
    // draw.color.a > 0 overrides the baked edge colour (selection / hover highlight).
    return draw.color.a > 0 ? draw.color : in.color;
}
"""#
}
