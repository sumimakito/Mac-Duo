import CoreVideo
import Metal

/// A captured texture with Core Video owner prevents pixel buffer from
/// being recycled while GPU is still reading it.
struct CapturedFrame: @unchecked Sendable {
    let texture: MTLTexture
    private let owner: CVMetalTexture

    init?(_ owner: CVMetalTexture) {
        guard let texture = CVMetalTextureGetTexture(owner) else { return nil }
        self.texture = texture
        self.owner = owner
    }
}
