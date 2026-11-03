import CoreVideo
import Foundation

/// 全局错误类型。所有 I/O 与 Metal 资源创建失败都走这里，不允许静默吞错。
enum FaceplantError: Error, CustomStringConvertible {
    case metalUnavailable
    case metalLibraryMissing
    case shaderFunctionMissing(String)
    case pipelineCreationFailed(underlying: Error)
    case textureCacheCreationFailed(CVReturn)
    case cameraTextureCreationFailed(plane: Int, status: CVReturn)
    case bufferCreationFailed(label: String)
    case textureCreationFailed(label: String)
    case faceTrackingUnsupported
    case frontCameraUnavailable

    var description: String {
        switch self {
        case .metalUnavailable: "Metal 不可用"
        case .metalLibraryMissing: "找不到默认 Metal library"
        case let .shaderFunctionMissing(name): "找不到 shader 函数 \(name)"
        case let .pipelineCreationFailed(underlying): "创建 pipeline 失败: \(underlying)"
        case let .textureCacheCreationFailed(status): "创建 CVMetalTextureCache 失败: \(status)"
        case let .cameraTextureCreationFailed(plane, status): "相机纹理 plane \(plane) 创建失败: \(status)"
        case let .bufferCreationFailed(label): "创建 MTLBuffer 失败: \(label)"
        case let .textureCreationFailed(label): "创建 MTLTexture 失败: \(label)"
        case .faceTrackingUnsupported: "设备不支持人脸追踪"
        case .frontCameraUnavailable: "找不到前置摄像头"
        }
    }
}
