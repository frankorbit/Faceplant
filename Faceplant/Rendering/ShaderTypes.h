//
//  ShaderTypes.h
//  Swift 与 Metal Shading Language 共享的缓冲索引与 uniform 布局。
//  只能放 C 语法，不能引入 Foundation。
//

#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

// MARK: - 烘焙 pass

typedef enum : int {
    BakeBufferIndexVertices = 0,
    BakeBufferIndexUVs = 1,
    BakeBufferIndexUniforms = 2
} BakeBufferIndex;

typedef enum : int {
    BakeTextureIndexLuma = 0,
    BakeTextureIndexChroma = 1
} BakeTextureIndex;

/// 烘焙 pass 的 uniform。
/// projectionViewModel 把 face 局部坐标送到裁剪空间；
/// displayTransformInverse 把视口归一化坐标映射回 capturedImage 归一化坐标。
typedef struct {
    matrix_float4x4 projectionViewModel;
    matrix_float3x3 displayTransformInverse;
} BakeUniforms;

// MARK: - 背景 pass

typedef enum : int {
    BackgroundBufferIndexUniforms = 0
} BackgroundBufferIndex;

typedef enum : int {
    BackgroundTextureIndexLuma = 0,
    BackgroundTextureIndexChroma = 1
} BackgroundTextureIndex;

/// 全屏三角形把视口归一化坐标映射回相机图像坐标。
/// cameraIsRGB 非零时背景是一张 BGRA 静态图（绑定在 luma 槽位），否则是 ARKit 的 Y/CbCr 双平面。
typedef struct {
    matrix_float3x3 displayTransformInverse;
    int cameraIsRGB;
} BackgroundUniforms;

// MARK: - 脸 pass

typedef enum : int {
    FaceBufferIndexVertices = 0,
    FaceBufferIndexUVs = 1,
    FaceBufferIndexNormals = 2,
    FaceBufferIndexUniforms = 3,
    FaceBufferIndexRim = 4
} FaceBufferIndex;

typedef enum : int {
    FaceTextureIndexFace = 0,
    FaceTextureIndexLuma = 1,
    FaceTextureIndexChroma = 2
} FaceTextureIndex;

/// 脸 pass 与墙面补丁 pass 共用的 uniform。
/// 顶点先做 z' = z * depthScale + depthOffset，再送进 projectionViewModel；片元里 z' < 0 的部分被墙面切掉。
/// 遮罩按顶点到外轮廓的测地距离 rim（米）算：rim >= edgeFade 完整显示脸，到轮廓处淡成墙纹。
/// 拉伸在脸局部 xy 平面上按椭圆距离 d = |(xy - faceCenter) / faceRadius| 计算：
///   墙纹采样点按 rest = faceCenter + (xy - faceCenter) * (1 - warpStrength * w(d)) 往脸中心拉，
///   w 在 d <= 1 为 1，到 warpOuter 衰减为 0，墙纹看起来被脸向外推开。
typedef struct {
    matrix_float4x4 projectionViewModel;
    matrix_float4x4 viewModel;
    matrix_float3x3 displayTransformInverse;
    vector_float2 viewportSize;
    vector_float2 faceCenter;
    vector_float2 faceRadius;
    /// cameraIsRGB 时墙纹不走投影，直接按脸局部 xy 取贴图：uv = xy * wallScale + wallOffset
    vector_float2 wallScale;
    vector_float2 wallOffset;
    vector_float3 faceTint;
    /// 上下方向的淡出带宽度，两侧的宽度是 edgeFade * sideFade
    float edgeFade;
    float sideFade;
    float warpStrength;
    float warpOuter;
    float refractStrength;
    float depthScale;
    float depthOffset;
    int cameraIsRGB;
} FaceUniforms;

#endif /* ShaderTypes_h */
