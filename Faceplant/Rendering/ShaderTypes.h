//
//  ShaderTypes.h
//  Swift 与 Metal Shading Language 共享的缓冲索引与 uniform 布局。
//  只能放 C 语法，不能引入 Foundation。
//

#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

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

#endif /* ShaderTypes_h */
