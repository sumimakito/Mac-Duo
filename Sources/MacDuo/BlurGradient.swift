import Foundation

/// How far out of focus the picture is, and how much light it has lost, as
/// the lid travels. Spatial falloff lives in the shader so blur and dim
/// follow the same receded-depth pose.
struct BlurGradient {

    /// Exponent on the closing travel. Values above 1 start slowly.
    var blurCurve: Double = 1.6

    /// Exponent on the closing travel for the dimming.
    var dimCurve: Double = 0.7

    /// Dimming at the hinge edge, as a fraction of the dimming at the far
    /// edge.
    var dimHingeFloor: Double = 0.2

    func blurStrength(progress: Double) -> Double {
        pow(min(max(progress, 0), 1), blurCurve)
    }

    func dimStrength(progress: Double) -> Double {
        pow(min(max(progress, 0), 1), dimCurve)
    }
}
