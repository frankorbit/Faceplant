//
//  Shaders.metal
//  烘焙（capturedImage 展开到 canonical UV）、背景（相机画面全屏）、平面网格（放置提示）、
//  空闲墙面（还没有脸时的静态墙 + 等待光晕）、脸（挤出 + 折射）。
//

#include <metal_stdlib>
#include "ShaderTypes.h"
using namespace metal;

constexpr sampler linearClamp(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
// 静态墙面按镜像平铺，照片也能铺满整面墙
constexpr sampler wallRepeat(mag_filter::linear, min_filter::linear, address::mirrored_repeat);

// BT.601 全范围 YCbCr -> RGB，与 Apple ARKit Metal 示例一致
static inline float3 ycbcrToRGB(float y, float2 cbcr) {
    const float4x4 m = float4x4(
        float4( 1.0000f,  1.0000f,  1.0000f, 0.0f),
        float4( 0.0000f, -0.3441f,  1.7720f, 0.0f),
        float4( 1.4020f, -0.7141f,  0.0000f, 0.0f),
        float4(-0.7010f,  0.5291f, -0.8860f, 1.0f));
    return (m * float4(y, cbcr, 1.0f)).rgb;
}

// isRGB 时 luma 槽位绑定的是一张 BGRA 纹理（录制页的静态墙面），直接取 rgb
static inline float3 sampleCamera(texture2d<float> luma, texture2d<float> chroma, float2 uv, int isRGB) {
    if (isRGB != 0) {
        return luma.sample(linearClamp, uv).rgb;
    }
    float y = luma.sample(linearClamp, uv).r;
    float2 cbcr = chroma.sample(linearClamp, uv).rg;
    return ycbcrToRGB(y, cbcr);
}

// MARK: - 烘焙 pass

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

    // 把 canonical UV 当作裁剪空间坐标，网格就被"摊平"到渲染目标上。
    // M0 已验证：v = 0 落在纹理顶部，和 Metal 的左上角原点一致，不需要翻转。
    BakeVertexOut out;
    out.position = float4(uv.x * 2.0f - 1.0f, 1.0f - uv.y * 2.0f, 0.0f, 1.0f);
    out.cameraUV = uvImage.xy;
    return out;
}

fragment float4 bakeFragment(BakeVertexOut in [[stage_in]],
                             texture2d<float> luma [[texture(BakeTextureIndexLuma)]],
                             texture2d<float> chroma [[texture(BakeTextureIndexChroma)]])
{
    return float4(sampleCamera(luma, chroma, in.cameraUV, 0), 1.0f);
}

// MARK: - 背景 pass：全屏三角形显示 capturedImage

struct BackgroundVertexOut {
    float4 position [[position]];
    float2 viewUV;
};

vertex BackgroundVertexOut backgroundVertex(uint vid [[vertex_id]])
{
    // 覆盖整个视口的单个大三角形，视口外的部分被裁掉
    float2 ndc = float2((vid == 1) ? 3.0f : -1.0f, (vid == 2) ? -3.0f : 1.0f);
    BackgroundVertexOut out;
    out.position = float4(ndc, 1.0f, 1.0f);
    out.viewUV = ndc * float2(0.5f, -0.5f) + 0.5f;
    return out;
}

fragment float4 backgroundFragment(BackgroundVertexOut in [[stage_in]],
                                   constant BackgroundUniforms &u [[buffer(BackgroundBufferIndexUniforms)]],
                                   texture2d<float> luma [[texture(BackgroundTextureIndexLuma)]],
                                   texture2d<float> chroma [[texture(BackgroundTextureIndexChroma)]])
{
    float3 uvImage = u.displayTransformInverse * float3(in.viewUV, 1.0f);
    return float4(sampleCamera(luma, chroma, uvImage.xy, u.cameraIsRGB), 1.0f);
}

// MARK: - 脸 pass 与墙面补丁 pass 共用

// 脸局部 xy 到椭圆归一化距离
static inline float faceDistance(float2 localXY, constant FaceUniforms &u) {
    return length((localXY - u.faceCenter) / u.faceRadius);
}

// 橡皮膜拉伸：把采样点往脸中心拉，d <= 1 时全力，到 warpOuter 衰减为零
static inline float2 restPosition(float2 localXY, float d, constant FaceUniforms &u) {
    float weight = 1.0f - smoothstep(1.0f, u.warpOuter, d);
    return u.faceCenter + (localXY - u.faceCenter) * (1.0f - u.warpStrength * weight);
}

// 墙面上一点（脸局部坐标，z = 0）的墙纹：AR 场景投影到 capturedImage 后采样，静态墙面直接按墙面坐标取贴图。
// viewOffset 是叠加的小偏移，AR 下在视口空间，静态墙面下在贴图 uv 空间
static inline float3 sampleWall(float2 localXY, float2 viewOffset, constant FaceUniforms &u,
                                texture2d<float> luma, texture2d<float> chroma) {
    if (u.cameraIsRGB != 0) {
        float2 uv = localXY * u.wallScale + u.wallOffset + viewOffset;
        return luma.sample(wallRepeat, uv).rgb;
    }
    float4 clip = u.projectionViewModel * float4(localXY, 0.0f, 1.0f);
    float2 ndc = clip.xy / max(clip.w, 1e-4f);
    float2 uvView = ndc * float2(0.5f, -0.5f) + 0.5f + viewOffset;
    float3 uvImage = u.displayTransformInverse * float3(uvView, 1.0f);
    return sampleCamera(luma, chroma, saturate(uvImage.xy), u.cameraIsRGB);
}

// MARK: - 脸 pass：挤出，外圈淡出到被推开的墙纹

struct FaceVertexOut {
    float4 position [[position]];
    float2 uv;
    float2 localXY;
    float3 normalView;
    float localZ;
    float rim;
};

vertex FaceVertexOut faceVertex(uint vid [[vertex_id]],
                                const device float3 *vertices [[buffer(FaceBufferIndexVertices)]],
                                const device float2 *uvs [[buffer(FaceBufferIndexUVs)]],
                                const device float3 *normals [[buffer(FaceBufferIndexNormals)]],
                                const device float *rims [[buffer(FaceBufferIndexRim)]],
                                constant FaceUniforms &u [[buffer(FaceBufferIndexUniforms)]])
{
    float3 v = vertices[vid];
    // 脸的 +z 与墙面法线一致，z 方向的缩放与偏移决定脸"种"得多深、起伏多夸张
    v.z = v.z * u.depthScale + u.depthOffset;

    FaceVertexOut out;
    out.position = u.projectionViewModel * float4(v, 1.0f);
    out.uv = uvs[vid];
    out.localXY = v.xy;
    out.rim = rims[vid];
    out.normalView = normalize((u.viewModel * float4(normals[vid], 0.0f)).xyz);
    out.localZ = v.z;
    return out;
}

fragment float4 faceFragment(FaceVertexOut in [[stage_in]],
                             constant FaceUniforms &u [[buffer(FaceBufferIndexUniforms)]],
                             texture2d<float> faceTexture [[texture(FaceTextureIndexFace)]],
                             texture2d<float> luma [[texture(FaceTextureIndexLuma)]],
                             texture2d<float> chroma [[texture(FaceTextureIndexChroma)]])
{
    // 墙面作为切平面，墙后的网格不画
    if (in.localZ < 0.0f) {
        discard_fragment();
    }

    // 沿真实轮廓的淡出带，两侧比上下宽；鼓包顶点 rim 为负，始终是墙纹
    float2 rel = (in.localXY - u.faceCenter) / u.faceRadius;
    float sideness = abs(rel.x) / max(length(rel), 1e-4f);
    float fade = u.edgeFade * mix(1.0f, u.sideFade, sideness);
    float mask = smoothstep(0.0f, fade, in.rim);

    float3 face = faceTexture.sample(linearClamp, in.uv).rgb * u.faceTint;
    if (mask >= 1.0f) {
        return float4(face, 1.0f);
    }

    // 过渡带：墙纹按橡皮膜拉伸采样，再叠一点法线折射让起伏处的墙纹跟着弯。
    // 视空间 +y 朝上而屏幕 v 朝下，所以 y 取反。
    float d = faceDistance(in.localXY, u);
    float3 n = normalize(in.normalView);
    float2 refract = float2(n.x, -n.y) * u.refractStrength * (1.0f - mask);
    float3 wall = sampleWall(restPosition(in.localXY, d, u), refract, u, luma, chroma);
    return float4(mix(wall, face, mask), 1.0f);
}

// MARK: - 墙面补丁 pass：脸周围的墙纹被向外推开

struct WallVertexOut {
    float4 position [[position]];
    float2 localXY;
};

vertex WallVertexOut wallVertex(uint vid [[vertex_id]],
                                const device float3 *vertices [[buffer(FaceBufferIndexVertices)]],
                                constant FaceUniforms &u [[buffer(FaceBufferIndexUniforms)]])
{
    float3 v = vertices[vid];
    WallVertexOut out;
    out.position = u.projectionViewModel * float4(v, 1.0f);
    out.localXY = v.xy;
    return out;
}

fragment float4 wallFragment(WallVertexOut in [[stage_in]],
                             constant FaceUniforms &u [[buffer(FaceBufferIndexUniforms)]],
                             texture2d<float> luma [[texture(FaceTextureIndexLuma)]],
                             texture2d<float> chroma [[texture(FaceTextureIndexChroma)]])
{
    float d = faceDistance(in.localXY, u);
    // AR 场景里拉伸范围之外和背景完全一致，直接丢弃省带宽；静态墙面整面墙都靠这个 pass 画
    if (u.cameraIsRGB == 0 && d >= u.warpOuter) {
        discard_fragment();
    }
    return float4(sampleWall(restPosition(in.localXY, d, u), float2(0.0f), u, luma, chroma), 1.0f);
}

// MARK: - 平面网格 pass：已检测的平面上铺一层半透明网格，提示哪里能放脸

struct PlaneGridVertexOut {
    float4 position [[position]];
    float2 planeXZ;
};

vertex PlaneGridVertexOut planeGridVertex(uint vid [[vertex_id]],
                                          const device float3 *vertices [[buffer(PlaneGridBufferIndexVertices)]],
                                          constant PlaneGridUniforms &u [[buffer(PlaneGridBufferIndexUniforms)]])
{
    float3 v = vertices[vid];
    PlaneGridVertexOut out;
    out.position = u.projectionViewModel * float4(v, 1.0f);
    out.planeXZ = v.xz;
    return out;
}

fragment float4 planeGridFragment(PlaneGridVertexOut in [[stage_in]],
                                  constant PlaneGridUniforms &u [[buffer(PlaneGridBufferIndexUniforms)]])
{
    // 到最近网格线的距离按屏幕像素算，线宽恒定不随远近变粗变细
    float2 cell = in.planeXZ / u.gridSpacing;
    float2 dist = abs(fract(cell - 0.5f) - 0.5f) / max(fwidth(cell), float2(1e-5f));
    float line = 1.0f - min(min(dist.x, dist.y), 1.0f);
    // 格子内部留一点底色，让整块平面的范围也看得出来
    float alpha = u.lineColor.a * (0.12f + 0.88f * line);
    return float4(u.lineColor.rgb, alpha);
}

// MARK: - 空闲墙面 pass：静态场景里还没有脸时整面墙 + 等待光晕

struct IdleWallVertexOut {
    float4 position [[position]];
    float2 localXY;
};

vertex IdleWallVertexOut idleWallVertex(uint vid [[vertex_id]],
                                        const device float3 *vertices [[buffer(IdleWallBufferIndexVertices)]],
                                        constant IdleWallUniforms &u [[buffer(IdleWallBufferIndexUniforms)]])
{
    float3 v = vertices[vid];
    IdleWallVertexOut out;
    out.position = u.projectionViewModel * float4(v, 1.0f);
    out.localXY = v.xy;
    return out;
}

fragment float4 idleWallFragment(IdleWallVertexOut in [[stage_in]],
                                 constant IdleWallUniforms &u [[buffer(IdleWallBufferIndexUniforms)]],
                                 texture2d<float> wall [[texture(IdleWallTextureIndexWall)]])
{
    float3 color = wall.sample(wallRepeat, in.localXY * u.wallScale + u.wallOffset).rgb;
    // 光晕用加法叠上去而不是压暗四周：脸到了之后整面墙按原亮度画，周边不会突然变亮
    float d = length((in.localXY - u.glowCenter) / u.glowRadius);
    float glow = (1.0f - smoothstep(0.0f, 1.0f, d)) * u.glowStrength;
    return float4(color + u.glowColor * glow, 1.0f);
}
