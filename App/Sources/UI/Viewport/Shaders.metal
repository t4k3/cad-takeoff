// Viewport shaders. Xcode compiles this file into the app's default.metallib at build time,
// so a shader error breaks the build instead of silently losing the viewport at launch.
#include <metal_stdlib>
using namespace metal;

struct MeshVertex { float4 position; float4 normal; };
struct LineVertex { float4 position; float4 color; };

struct FrameUniforms {
    float4x4 viewProjection;
    float4 eye;          // xyz = camera position
    float4 lightDir;     // xyz = direction towards the key light
    float4 clip;         // section: points with dot(p, xyz) > w are cut away (xyz = 0: off)
};

// Cut away by the section plane (only bodies and their edges, never overlays or handles).
static bool clipped(float3 p, float4 clip) {
    return dot(clip.xyz, clip.xyz) > 0.0 && dot(p, clip.xyz) > clip.w;
}

struct DrawUniforms {
    float4 color;        // rgb + highlight strength in a
};

struct MeshOut {
    float4 position [[position]];
    float3 normal;
    float3 world;
    float clipOn;
};

vertex MeshOut meshVertex(uint id [[vertex_id]],
                          const device MeshVertex *v [[buffer(0)]],
                          constant FrameUniforms &frame [[buffer(1)]]) {
    MeshOut o;
    o.position = frame.viewProjection * v[id].position;
    o.normal = v[id].normal.xyz;
    o.world = v[id].position.xyz;
    o.clipOn = 1.0;
    return o;
}

// On-canvas handles (drag arrows): shaded like bodies but squeezed into the front 2% of the
// depth range, so they stay visible over the part while still hiding their own back faces.
vertex MeshOut gizmoVertex(uint id [[vertex_id]],
                           const device MeshVertex *v [[buffer(0)]],
                           constant FrameUniforms &frame [[buffer(1)]]) {
    MeshOut o;
    o.position = frame.viewProjection * v[id].position;
    o.position.z *= 0.02;
    o.normal = v[id].normal.xyz;
    o.world = v[id].position.xyz;
    o.clipOn = 0.0;
    return o;
}

fragment float4 meshFragment(MeshOut in [[stage_in]],
                             constant FrameUniforms &frame [[buffer(1)]],
                             constant DrawUniforms &draw [[buffer(2)]]) {
    if (in.clipOn > 0.5 && clipped(in.world, frame.clip)) discard_fragment();
    float3 n = normalize(in.normal);
    float3 viewDir = normalize(frame.eye.xyz - in.world);
    // Seen through the section: the inside of the part, drawn as a flat cut face.
    if (in.clipOn > 0.5 && dot(frame.clip.xyz, frame.clip.xyz) > 0.0 && dot(n, viewDir) < 0.0) {
        return float4(mix(draw.color.rgb, float3(0.95, 0.45, 0.2), 0.55) * 0.8, 1.0);
    }
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
    float3 world;
    float clipOn;
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
    o.world = v[id].position.xyz;
    o.clipOn = 1.0;
    return o;
}

// Thick lines (sketch, overlays, highlights): each segment is a strip of `params.y` pixels,
// built in screen space. params.x = side (±1); each end is pushed half a width away from the
// other end so consecutive segments join without gaps.
struct ThickVertex { float4 position; float4 other; float4 color; float4 params; };

vertex LineOut thickLineVertex(uint id [[vertex_id]],
                               const device ThickVertex *v [[buffer(0)]],
                               constant FrameUniforms &frame [[buffer(1)]],
                               constant float2 &viewport [[buffer(3)]]) {
    ThickVertex t = v[id];
    float4 a = frame.viewProjection * t.position;
    float4 b = frame.viewProjection * t.other;
    float2 half_vp = viewport * 0.5;
    float2 sa = a.xy / max(a.w, 1e-6) * half_vp;
    float2 sb = b.xy / max(b.w, 1e-6) * half_vp;
    float2 d = sb - sa;
    float len = length(d);
    float2 dir = len > 1e-5 ? d / len : float2(1.0, 0.0);
    float2 n = float2(-dir.y, dir.x);
    float w = t.params.y * 0.5;
    float2 offset = n * t.params.x * w - dir * w;
    a.xy += offset / half_vp * a.w;
    LineOut o;
    o.position = a;
    o.color = t.color;
    o.fade = 1.0;
    o.world = t.position.xyz;
    o.clipOn = 0.0;
    return o;
}

fragment float4 lineFragment(LineOut in [[stage_in]]) {
    return float4(in.color.rgb, in.color.a * in.fade);
}

fragment float4 edgeFragment(LineOut in [[stage_in]],
                             constant FrameUniforms &frame [[buffer(1)]],
                             constant DrawUniforms &draw [[buffer(2)]]) {
    if (in.clipOn > 0.5 && clipped(in.world, frame.clip)) discard_fragment();
    // draw.color.a > 0 overrides the baked edge colour (selection / hover highlight).
    return draw.color.a > 0 ? draw.color : in.color;
}

// On-canvas labels (constraint symbols and dimension values), in screen points with the origin
// at the top-left: one quad per box and one textured quad per run of the label atlas. Neither
// goes through depth: labels sit over the part, like Fusion's on-canvas text.

struct LabelBackgroundVertex {
    float2 origin;
    float2 size;
    float4 fill;
    float4 border;
    // x = corner radius, y = border width, z = dash period in points (0 = solid border).
    float4 params;
};

struct LabelBackgroundOut {
    float4 position [[position]];
    float2 local;        // point relative to the box centre, points
    float2 size;
    float4 fill;
    float4 border;
    float4 params;
};

// One quad as two triangles: (0,0) (1,0) (1,1) and (0,0) (1,1) (0,1), with y pointing down.
inline float2 quadCorner(uint vid) {
    switch (vid) {
    case 0: return float2(0.0, 0.0);
    case 1: return float2(1.0, 0.0);
    case 2: return float2(1.0, 1.0);
    case 3: return float2(0.0, 0.0);
    case 4: return float2(1.0, 1.0);
    default: return float2(0.0, 1.0);
    }
}

vertex LabelBackgroundOut labelBackgroundVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                                const device LabelBackgroundVertex *items [[buffer(0)]],
                                                constant float2 &viewport [[buffer(3)]]) {
    LabelBackgroundVertex b = items[iid];
    float2 p = b.origin + quadCorner(vid) * b.size;
    LabelBackgroundOut o;
    o.position = float4(p.x / viewport.x * 2.0 - 1.0, 1.0 - p.y / viewport.y * 2.0, 0.0, 1.0);
    o.local = p - (b.origin + b.size * 0.5);
    o.size = b.size;
    o.fill = b.fill;
    o.border = b.border;
    o.params = b.params;
    return o;
}

// Rounded box through a signed distance: one point of antialiasing, the border ring just inside
// the edge. Reference dimensions draw it dashed (the stripe runs along the border).
fragment float4 labelBackgroundFragment(LabelBackgroundOut in [[stage_in]]) {
    float2 halfSize = in.size * 0.5;
    float r = min(in.params.x, min(halfSize.x, halfSize.y));
    float2 q = abs(in.local) - halfSize + r;
    float d = length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - r;
    float cover = clamp(0.5 - d, 0.0, 1.0);
    float4 color = in.fill;
    if (in.params.y > 0.0 && d > -in.params.y) {
        bool on = true;
        if (in.params.z > 0.0) {
            on = fract((in.local.x + in.local.y) / in.params.z) < 0.5;
        }
        if (on) { color = in.border; }
    }
    return float4(color.rgb, color.a * cover);
}

struct TextVertex {
    float2 origin;
    float2 size;
    float4 uv;       // x, y, w, h in normalised atlas coordinates
    float4 color;
};

struct TextOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
};

vertex TextOut textVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                          const device TextVertex *items [[buffer(0)]],
                          constant float2 &viewport [[buffer(3)]]) {
    TextVertex t = items[iid];
    float2 corner = quadCorner(vid);
    float2 p = t.origin + corner * t.size;
    TextOut o;
    o.position = float4(p.x / viewport.x * 2.0 - 1.0, 1.0 - p.y / viewport.y * 2.0, 0.0, 1.0);
    o.uv = t.uv.xy + corner * t.uv.zw;
    o.color = t.color;
    return o;
}

fragment float4 textFragment(TextOut in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float alpha = atlas.sample(s, in.uv).r;
    return float4(in.color.rgb, in.color.a * alpha);
}

// GPU picking (T148): the identity of the surface under one pixel. The app translates the
// projection so the click ray lands on the centre of a 1×1 target, draws the bodies there and
// reads back which surface won the depth test: no CPU triangle scan (and no BVH) on hover or click.

// Same layout as MeshVertex: the bodies' drawing buffers are reused as pick buffers.
struct PickUniforms {
    float4x4 viewProjection;   // projection shifted so the click ray is at NDC (0,0)
    float4 rayOrigin;          // xyz = ray origin
    float4 rayDirection;       // xyz = ray direction (unit)
};

struct PickDraw {
    uint feature;              // index of the body in the pick list
};

struct PickOut {
    float4 position [[position]];
    float3 world;
};

vertex PickOut pickVertex(uint id [[vertex_id]],
                          const device MeshVertex *v [[buffer(0)]],
                          constant PickUniforms &pick [[buffer(1)]]) {
    PickOut o;
    o.position = pick.viewProjection * v[id].position;
    o.world = v[id].position.xyz;
    return o;
}

struct PickFragOut {
    uint4 ids [[color(0)]];    // (feature index, triangle index, 1 = hit, 0)
    float distance [[color(1)]];  // ray parameter of the fragment
};

fragment PickFragOut pickFragment(PickOut in [[stage_in]],
                                  uint triangle [[primitive_id]],
                                  constant PickUniforms &pick [[buffer(1)]],
                                  constant PickDraw &draw [[buffer(2)]]) {
    PickFragOut o;
    o.ids = uint4(draw.feature, triangle, 1, 0);
    o.distance = dot(in.world - pick.rayOrigin.xyz, normalize(pick.rayDirection.xyz));
    return o;
}
