import CoreVideo
import Metal

/// 把 CVPixelBuffer 零拷贝包成 MTLTexture：相机的 Y / CbCr 双平面、录制用的 BGRA 目标、回放解码出的视频帧都走这里。
///
/// 返回值里持有 CVMetalTexture 引用，调用方必须保留到 GPU 读写完成，否则 IOSurface 可能被回收。
final class PixelBufferTextureCache {
    struct TextureRef {
        let texture: MTLTexture
        let pixelBuffer: CVPixelBuffer
        /// 延长 IOSurface 生命周期
        fileprivate let backing: CVMetalTexture
    }

    struct CameraPlanes {
        let luma: TextureRef
        let chroma: TextureRef
    }

    private let cache: CVMetalTextureCache

    init(device: MTLDevice) throws {
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw FaceplantError.textureCacheCreationFailed(status)
        }
        self.cache = cache
    }

    /// ARFrame.capturedImage 是 420YpCbCr8BiPlanarFullRange，两个平面分别包成 r8 与 rg8
    func cameraPlanes(for pixelBuffer: CVPixelBuffer) throws -> CameraPlanes {
        try CameraPlanes(
            luma: texture(for: pixelBuffer, plane: 0, format: .r8Unorm),
            chroma: texture(for: pixelBuffer, plane: 1, format: .rg8Unorm)
        )
    }

    func texture(for pixelBuffer: CVPixelBuffer, plane: Int = 0, format: MTLPixelFormat) throws -> TextureRef {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil, format, width, height, plane, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else {
            throw FaceplantError.cameraTextureCreationFailed(plane: plane, status: status)
        }
        return TextureRef(texture: texture, pixelBuffer: pixelBuffer, backing: cvTexture)
    }

    /// 每帧结束后调用，释放缓存里已经不再引用的纹理
    func flush() {
        CVMetalTextureCacheFlush(cache, 0)
    }
}
