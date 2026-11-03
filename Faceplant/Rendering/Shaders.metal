//
//  Shaders.metal
//  M0：烘焙 pass，把 capturedImage 按 canonical UV 展开成正方形贴图。
//

#include <metal_stdlib>
#include "ShaderTypes.h"
using namespace metal;

constexpr sampler linearClamp(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

// BT.601 全范围 YCbCr -> RGB，与 Apple ARKit Metal 示例一致
static inline float3 ycbcrToRGB(float y, float2 cbcr) {
    const float4x4 m = float4x4(
        float4( 1.0000f,  1.0000f,  1.0000f, 0.0f),
        float4( 0.0000f, -0.3441f,  1.7720f, 0.0f),
        float4( 1.4020f, -0.7141f,  0.0000f, 0.0f),
        float4(-0.7010f,  0.5291f, -0.8860f, 1.0f));
    return (m * float4(y, cbcr, 1.0f)).rgb;
}

struct BakeVertexOut {
    float4 position [[position]];
    float2 cameraUV;
};

vertex BakeVertexOut bakeVertex(uint vid [[vertex_id]],
                                const device float3 *vertices [[buffer(BakeBufferIndexVertices)]],
                                const device float2 *uvs [[buffer(BakeBufferIndexUVs)]],
                                constant BakeUniforms &u [[buffer(BakeBufferIndexUniforms)]])
{
    float2 uv = uvs[vid];

    // 顶点投影到视口，再映射回相机图像坐标
    float4 clip = u.projectionViewModel * float4(vertices[vid], 1.0f);
    float2 ndc = clip.xy / clip.w;
    float2 uvView = ndc * float2(0.5f, -0.5f) + 0.5f;
    float3 uvImage = u.displayTransformInverse * float3(uvView, 1.0f);

    // 把 canonical UV 当作裁剪空间坐标，网格就被"摊平"到渲染目标上
    float ndcY = (u.flipV != 0) ? (uv.y * 2.0f - 1.0f) : (1.0f - uv.y * 2.0f);

    BakeVertexOut out;
    out.position = float4(uv.x * 2.0f - 1.0f, ndcY, 0.0f, 1.0f);
    out.cameraUV = uvImage.xy;
    return out;
}

fragment float4 bakeFragment(BakeVertexOut in [[stage_in]],
                             texture2d<float> luma [[texture(BakeTextureIndexLuma)]],
                             texture2d<float> chroma [[texture(BakeTextureIndexChroma)]])
{
    float y = luma.sample(linearClamp, in.cameraUV).r;
    float2 cbcr = chroma.sample(linearClamp, in.cameraUV).rg;
    return float4(ycbcrToRGB(y, cbcr), 1.0f);
}
