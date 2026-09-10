import Foundation

/// Turns the sensor's 10 Hz steps into a value that changes smoothly at the
/// display refresh rate.
///
/// Semi-implicit Euler stays stable while `frequency * dt` is below 2. The
/// caller clamps `dt`.
struct CriticallyDampedSpring {
    var value: Double
    var velocity: Double = 0

    /// Radians per second. Higher follows the target faster and smooths less.
    var frequency: Double = 16

    init(value: Double = 0) {
        self.value = value
    }

    mutating func advance(to target: Double, dt: Double) {
        let acceleration = frequency * frequency * (target - value) - 2 * frequency * velocity
        velocity += acceleration * dt
        value += velocity * dt
    }

    mutating func reset(to newValue: Double) {
        value = newValue
        velocity = 0
    }
}
