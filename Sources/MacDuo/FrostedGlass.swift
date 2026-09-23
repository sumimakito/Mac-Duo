import Foundation

/// The optics the window server fold draws: a frosted sheet hinged along one
/// edge of a page, lifted off it.
///
/// The page is the screen as it was when the fold began, and it stays there.
/// The sheet is the glass. Frosted, it is a Lambertian transmitter: each point
/// shows the light reaching it from the page behind, cosine weighted about
/// the sheet's own normal. What it shows does not depend on where the eye is,
/// so nothing moves across the hinge and there are no black sides.
///
/// For a point a distance `s` from the hinge on a sheet lifted by `lift`, at
/// height `d = s · sin(lift)` above the page, the light comes from around a
/// spot on the page. Half of it comes from within `halfLightRadiusPerHeight ·
/// d` of the spot's centre, and a share of the light misses the page
/// altogether, off its edges or away from it, which is where the darkening
/// comes from. The spot's peak stays within 6% of straight under the point up
/// to a 30 degree lift and 20% at 60 degrees, so the content is drawn where it
/// is. These were checked against a ray-traced render of the same sheet.
enum FrostedGlass {

    /// Radius holding half of the light a sheet point shows, per unit of its
    /// height above the page. For a Lambertian sheet parallel to the page the
    /// share inside radius `r` is `r² / (r² + d²)`, so exactly one. The spread
    /// has long tails, so this matches how much it washes out detail far
    /// better than its half-maximum width does.
    static let halfLightRadiusPerHeight = 1.0

    /// The share of each sheet point's light that comes from the page, on a
    /// `columns` by `rows` grid over a `width` by `height` sheet, rows from
    /// the hinge up. Ones where it all does; the rest is dark.
    static func brightness(
        lift: Double,
        width: Double,
        height: Double,
        columns: Int,
        rows: Int,
        samplesPerSide: Int = 12
    ) -> [Double] {
        let a = min(max(lift, 0), .pi / 2)
        var result = [Double](repeating: 1, count: columns * rows)
        guard a > 1e-4, width > 0, height > 0 else { return result }
        // The sheet's normal toward the page, and a tangent across the hinge
        // and one along the sheet, for sampling about it.
        let normal = (y: sin(a), z: -cos(a))
        let along = (y: cos(a), z: sin(a))
        let count = Double(samplesPerSide * samplesPerSide)
        for row in 0..<rows {
            let s = (Double(row) + 0.5) / Double(rows) * height
            let qy = s * cos(a), qz = s * sin(a)
            for column in 0..<columns {
                let qx = (Double(column) + 0.5) / Double(columns) * width
                var landed = 0
                // Stratified cosine-weighted directions about the normal.
                for i in 0..<samplesPerSide {
                    for j in 0..<samplesPerSide {
                        let r1 = (Double(i) + 0.5) / Double(samplesPerSide)
                        let r2 = (Double(j) + 0.5) / Double(samplesPerSide)
                        let r = sqrt(r1), phi = 2 * .pi * r2
                        let dx = r * cos(phi)
                        let dy = along.y * r * sin(phi) + normal.y * sqrt(1 - r1)
                        let dz = along.z * r * sin(phi) + normal.z * sqrt(1 - r1)
                        guard dz < -1e-9 else { continue }
                        let t = -qz / dz
                        let px = qx + dx * t, py = qy + dy * t
                        if px >= 0, px <= width, py >= 0, py <= height { landed += 1 }
                    }
                }
                result[row * columns + column] = Double(landed) / count
            }
        }
        return result
    }
}
