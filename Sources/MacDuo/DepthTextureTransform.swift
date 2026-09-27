import AppKit
import simd

/// Maps framebuffer pixels directly into the padded picture texture.
struct DepthTextureTransform {
    let matrix: simd_double3x3
    let heightOffset: Double
    let heightScale: Double

    init(
        screenToPicture: simd_double3x3,
        screenSize: CGSize,
        pixelScale: CGFloat,
        paddedOrigin: CGPoint,
        paddedSize: CGSize
    ) {
        precondition(
            screenSize.width > 0 && screenSize.height > 0
                && pixelScale > 0 && paddedSize.width > 0 && paddedSize.height > 0
        )

        let scale = Double(pixelScale)
        let screenHeight = Double(screenSize.height)
        let pixelToScreen = simd_double3x3(columns: (
            SIMD3(1 / scale, 0, 0),
            SIMD3(0, -1 / scale, 0),
            SIMD3(0, screenHeight, 1)
        ))

        let originX = Double(paddedOrigin.x)
        let originY = Double(paddedOrigin.y)
        let paddedWidth = Double(paddedSize.width)
        let paddedHeight = Double(paddedSize.height)
        let pictureToTexture = simd_double3x3(columns: (
            SIMD3(1 / paddedWidth, 0, 0),
            SIMD3(0, -1 / paddedHeight, 0),
            SIMD3(-originX / paddedWidth, (originY + paddedHeight) / paddedHeight, 1)
        ))

        matrix = pictureToTexture * screenToPicture * pixelToScreen
        heightOffset = (originY + paddedHeight) / screenHeight
        heightScale = -paddedHeight / screenHeight
    }
}
