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
    case worldTrackingUnsupported
    case frontCameraUnavailable
    case recordingSetupFailed(String)
    case meshStreamCorrupted(String)
    case recordingPackageInvalid(String)
    case thumbnailFailed
    case playbackSetupFailed(String)

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
        case .worldTrackingUnsupported: "设备不支持世界追踪"
        case .frontCameraUnavailable: "找不到前置摄像头"
        case let .recordingSetupFailed(reason): "录制初始化失败: \(reason)"
        case let .meshStreamCorrupted(reason): "顶点流损坏: \(reason)"
        case let .recordingPackageInvalid(reason): "录制包无效: \(reason)"
        case .thumbnailFailed: "生成缩略图失败"
        case let .playbackSetupFailed(reason): "回放初始化失败: \(reason)"
        }
    }
}
