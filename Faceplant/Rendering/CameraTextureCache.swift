import CoreVideo
import Metal

/// 把 ARFrame.capturedImage 的 Y / CbCr 两个平面零拷贝包成 MTLTexture。
///
/// 线程约束：在 ARSession delegate 队列调用。返回的 Planes 必须保留到 GPU 读取完成，
/// 否则 CVMetalTexture 释放后 IOSurface 可能被回收。
final class CameraTextureCache {
    struct Planes {
        let luma: MTLTexture
        let chroma: MTLTexture
        /// 持有 CVMetalTexture 引用以延长 IOSurface 生命周期
        fileprivate let backing: [CVMetalTexture]
        fileprivate let pixelBuffer: CVPixelBuffer
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

    func planes(for pixelBuffer: CVPixelBuffer) throws -> Planes {
        let (luma, lumaBacking) = try texture(from: pixelBuffer, plane: 0, format: .r8Unorm)
        let (chroma, chromaBacking) = try texture(from: pixelBuffer, plane: 1, format: .rg8Unorm)
        return Planes(luma: luma, chroma: chroma, backing: [lumaBacking, chromaBacking], pixelBuffer: pixelBuffer)
    }

    /// 每帧结束后调用，释放缓存里已经不再引用的纹理
    func flush() {
        CVMetalTextureCacheFlush(cache, 0)
    }

    private func texture(
        from pixelBuffer: CVPixelBuffer,
        plane: Int,
        format: MTLPixelFormat
    ) throws -> (MTLTexture, CVMetalTexture) {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil, format, width, height, plane, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else {
            throw FaceplantError.cameraTextureCreationFailed(plane: plane, status: status)
        }
        return (texture, cvTexture)
    }
}
