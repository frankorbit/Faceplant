import Metal
import MetalKit
import UIKit

/// 程序生成的砖墙贴图，给录制页的实时预览当静态墙面，不依赖美术资源。
enum BrickTexture {
    static func makeImage(size: CGFloat = 1024) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { context in
            let cg = context.cgContext
            cg.setFillColor(UIColor(red: 0.82, green: 0.78, blue: 0.72, alpha: 1).cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: size, height: size))

            let brickWidth = size / 6
            let brickHeight = size / 16
            let mortar = size / 110
            var seed: UInt32 = 0x9E37_79B9
            func noise() -> CGFloat {
                // 简单的 LCG，保证每次生成的砖墙一样
                seed = seed &* 1_664_525 &+ 1_013_904_223
                return CGFloat(seed >> 8) / CGFloat(1 << 24)
            }

            var row = 0
            var y: CGFloat = 0
            while y < size {
                let offset = row.isMultiple(of: 2) ? 0 : brickWidth / 2
                var x = -brickWidth + offset
                while x < size {
                    let red = 0.55 + noise() * 0.18
                    let green = 0.26 + noise() * 0.10
                    let blue = 0.18 + noise() * 0.08
                    cg.setFillColor(UIColor(red: red, green: green, blue: blue, alpha: 1).cgColor)
                    let rect = CGRect(x: x + mortar / 2, y: y + mortar / 2, width: brickWidth - mortar, height: brickHeight - mortar)
                    cg.fill(rect)
                    // 砖面上几条浅色划痕，方便看出拉伸
                    cg.setStrokeColor(UIColor(white: 1, alpha: 0.08).cgColor)
                    cg.setLineWidth(1)
                    for _ in 0 ..< 3 {
                        let startX = rect.minX + noise() * rect.width
                        let startY = rect.minY + noise() * rect.height
                        cg.move(to: CGPoint(x: startX, y: startY))
                        cg.addLine(to: CGPoint(x: startX + (noise() - 0.5) * 40, y: startY + (noise() - 0.5) * 8))
                        cg.strokePath()
                    }
                    x += brickWidth
                }
                y += brickHeight
                row += 1
            }
        }
    }

    static func makeTexture(device: MTLDevice, image: UIImage? = nil) throws -> MTLTexture {
        guard let cgImage = (image ?? makeImage()).cgImage else { throw FaceplantError.textureCreationFailed(label: "BrickWall") }
        let loader = MTKTextureLoader(device: device)
        do {
            // 不做 sRGB 解释，和相机纹理一样按线性值采样
            return try loader.newTexture(cgImage: cgImage, options: [.SRGB: false, .textureUsage: MTLTextureUsage.shaderRead.rawValue])
        } catch {
            throw FaceplantError.textureCreationFailed(label: "BrickWall: \(error)")
        }
    }
}
