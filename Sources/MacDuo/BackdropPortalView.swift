import AppKit
import QuartzCore
import simd

/// The depth effect done entirely by the window server, on whatever is behind
/// the overlay. Nothing is captured, so it needs no Screen Recording
/// permission, runs no capture stream and draws nothing on the GPU from this
/// process.
///
/// A `CABackdropLayer` shows what is behind the window. A mesh transform on
/// that layer draws it where the picture lands, so the picture holds still in
/// the room while the glass turns away from it. A `variableBlur` filter then
/// softens it by how far it sits behind the glass: nothing at the hinge, most
/// at the far edge. Around the picture the glass goes black.
///
/// `CABackdropLayer`, `CAMeshTransform` and `CAFilter` are private Core
/// Animation classes, looked up at run time; `isSupported` is false when any
/// of them is missing.
@MainActor
final class BackdropPortalView: NSView {

    /// The blur setting is a radius for a Gaussian; this is the share of it
    /// the filter's radius takes, as in the Metal renderer.
    private static let radiusScale: Double = 0.7
    private static let blurName = "variableBlur"
    private static let dimStops = 17
    /// Mesh cells across and up. Each cell is drawn as a flat quad, so too
    /// few bend straight lines near the edges.
    private static let meshColumns = 24
    private static let meshRows = 24

    private struct MeshPoint3D { var x: CGFloat; var y: CGFloat; var z: CGFloat }
    private struct MeshVertex { var from: CGPoint; var to: MeshPoint3D }
    private struct MeshFace {
        var indices: (UInt32, UInt32, UInt32, UInt32)
        var w: (Float, Float, Float, Float)
    }
    private typealias MeshFactory = @convention(c) (
        AnyClass, Selector, UInt, UnsafeRawPointer, UInt, UnsafeRawPointer, NSString
    ) -> Unmanaged<AnyObject>?

    private static let meshSelector =
        NSSelectorFromString("meshTransformWithVertexCount:vertices:faceCount:faces:depthNormalization:")

    static var isSupported: Bool {
        guard NSClassFromString("CABackdropLayer") != nil,
              NSClassFromString("CAFilter") != nil,
              let mesh = NSClassFromString("CAMeshTransform") else { return false }
        return class_getClassMethod(mesh, meshSelector) != nil
    }

    private let backdrop: CALayer?
    private let dim = CAGradientLayer()
    private let surround = CAShapeLayer()
    private var maskFloor: Double?
    private var lastState: [Double] = []

    init(frame: NSRect, scale: CGFloat) {
        backdrop = Self.makeBackdrop()
        super.init(frame: frame)
        let root = CALayer()
        root.contentsScale = scale
        layer = root
        wantsLayer = true
        layerContentsRedrawPolicy = .never

        if let backdrop {
            backdrop.contentsScale = scale
            backdrop.anchorPoint = .zero
            backdrop.isHidden = true
            root.addSublayer(backdrop)
        }
        // Hinge at the bottom, far edge at the top, as in the Metal picture.
        dim.anchorPoint = .zero
        dim.startPoint = CGPoint(x: 0.5, y: 0)
        dim.endPoint = CGPoint(x: 0.5, y: 1)
        dim.locations = (0..<Self.dimStops).map { NSNumber(value: Double($0) / Double(Self.dimStops - 1)) }
        dim.isHidden = true
        root.addSublayer(dim)

        surround.fillColor = CGColor(gray: 0, alpha: 1)
        surround.fillRule = .evenOdd
        surround.isHidden = true
        root.addSublayer(surround)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.frame = bounds
        backdrop?.frame = bounds
        dim.frame = bounds
        CATransaction.commit()
        lastState = []
    }

    private static func makeBackdrop() -> CALayer? {
        guard isSupported,
              let backdropClass = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              let blur = makeFilter(blurName) else { return nil }
        blur.setValue(blurName, forKey: "name")
        blur.setValue(0.0, forKey: "inputRadius")
        blur.setValue(true, forKey: "inputNormalizeEdges")
        // A wide blur of a dark screen is a smooth near-black gradient, which
        // 8 bits draw as contour bands about 30 pt wide. They crawl as the
        // radius changes. Dithered, they read as one smooth gradient.
        blur.setValue(true, forKey: "inputDither")

        let backdrop = backdropClass.init()
        // Samples what other windows draw, not only this window's content.
        backdrop.setValue(true, forKey: "windowServerAware")
        backdrop.filters = [blur]
        return backdrop
    }

    private static func makeFilter(_ type: String) -> NSObject? {
        guard let filterClass = NSClassFromString("CAFilter") as? NSObject.Type else { return nil }
        let selector = NSSelectorFromString("filterWithType:")
        guard filterClass.responds(to: selector) else { return nil }
        return filterClass.perform(selector, with: type)?.takeUnretainedValue() as? NSObject
    }

    /// - Parameters:
    ///   - corners: the picture corners projected onto the screen, in points,
    ///     listed bottom-left, bottom-right, top-right, top-left.
    ///   - blurRadius: blur at the picture's far edge, in points.
    ///   - blurFloor: blur at the hinge as a fraction of `blurRadius`.
    func apply(
        corners: [CGPoint],
        blurRadius: Double,
        blurFloor: Double,
        dimStrength: Double,
        dimHingeFloor: Double,
        dimReach: Double,
        maxDim: Double
    ) {
        let size = bounds.size
        guard corners.count == 4, size.width > 0, size.height > 0 else { return }
        let state = corners.flatMap { [Double($0.x), Double($0.y)] }
            + [blurRadius, blurFloor, dimStrength, dimHingeFloor, dimReach, maxDim]
        guard state != lastState else { return }
        lastState = state

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let screenCorners = [
            CGPoint(x: 0, y: 0), CGPoint(x: size.width, y: 0),
            CGPoint(x: size.width, y: size.height), CGPoint(x: 0, y: size.height),
        ]
        let isFlat = zip(corners, screenCorners).allSatisfy { abs($0.x - $1.x) < 0.01 && abs($0.y - $1.y) < 0.01 }
        let radius = blurRadius * Self.radiusScale
        let mesh = isFlat ? nil : Self.mesh(corners: corners, size: size)

        if let backdrop {
            // At the handover the picture is the screen itself. A hidden
            // backdrop costs the window server nothing and cannot differ.
            backdrop.isHidden = isFlat && radius < 0.25
            if !backdrop.isHidden {
                backdrop.setValue(mesh.flatMap { Self.padded($0, size: size) }, forKey: "meshTransform")
                let floor = (min(max(blurFloor, 0), 1) * 64).rounded() / 64
                if maskFloor != floor {
                    maskFloor = floor
                    backdrop.setValue(Self.mask(floor: floor), forKeyPath: "filters.\(Self.blurName).inputMaskImage")
                }
                backdrop.setValue(max(radius, 0), forKeyPath: "filters.\(Self.blurName).inputRadius")
            }
        }

        // The shader dims by a factor on encoded brightness; a black layer at
        // that opacity does the same on the window server's blend.
        var colours: [CGColor] = []
        var strongest = 0.0
        for stop in 0..<Self.dimStops {
            let height = Double(stop) / Double(Self.dimStops - 1)
            let spread = Self.smoothstep(0, max(dimReach, 0.02), height)
            let fade = dimStrength * (dimHingeFloor + (1 - dimHingeFloor) * spread)
            let alpha = min(max(maxDim * fade, 0), 1)
            strongest = max(strongest, alpha)
            colours.append(CGColor(gray: 0, alpha: alpha))
        }
        dim.isHidden = strongest < 0.002
        if !dim.isHidden {
            dim.colors = colours
            dim.setValue(mesh.flatMap { Self.build($0) }, forKey: "meshTransform")
        }

        // Black where the picture no longer covers the glass. Only lightly
        // softened: the wedges at the sides are thin, and a wide blur would
        // wash them out to grey.
        surround.isHidden = isFlat
        if !isFlat {
            let softness = min(max(radius * 0.05, 0.75), 3)
            let outset = softness * 3
            surround.frame = bounds.insetBy(dx: -outset, dy: -outset)
            let path = CGMutablePath()
            path.addRect(CGRect(origin: .zero, size: surround.frame.size))
            path.addLines(between: corners.map { CGPoint(x: $0.x + outset, y: $0.y + outset) })
            path.closeSubpath()
            surround.path = path
            if let blur = Self.makeFilter("gaussianBlur") {
                blur.setValue(softness, forKey: "inputRadius")
                surround.filters = [blur]
            }
        }
    }

    // MARK: - Mesh

    private struct Mesh {
        var vertices: [MeshVertex]
        var faces: [MeshFace]
    }

    /// Picture points in unit space, y up, to where they land on the screen.
    private static func mesh(corners: [CGPoint], size: CGSize) -> Mesh {
        let matrix = Homography.matrix(
            width: 1,
            height: 1,
            to: corners.map { SIMD2(Double($0.x), Double($0.y)) }
        )
        var vertices: [MeshVertex] = []
        vertices.reserveCapacity((meshColumns + 1) * (meshRows + 1))
        for row in 0...meshRows {
            for column in 0...meshColumns {
                let u = Double(column) / Double(meshColumns)
                let v = Double(row) / Double(meshRows)
                let p = matrix * SIMD3(u, v, 1)
                vertices.append(MeshVertex(
                    from: CGPoint(x: u, y: v),
                    to: MeshPoint3D(
                        x: CGFloat(p.x / p.z) / size.width,
                        y: CGFloat(p.y / p.z) / size.height,
                        z: 0
                    )
                ))
            }
        }
        var faces: [MeshFace] = []
        faces.reserveCapacity(meshColumns * meshRows)
        let stride = UInt32(meshColumns + 1)
        for row in 0..<meshRows {
            for column in 0..<meshColumns {
                let i = UInt32(row) * stride + UInt32(column)
                faces.append(MeshFace(indices: (i, i + 1, i + 1 + stride, i + stride), w: (0, 0, 0, 0)))
            }
        }
        return Mesh(vertices: vertices, faces: faces)
    }

    /// The window server only captures behind the area a meshed backdrop
    /// covers, and maps that capture onto the whole mesh. Two slivers left in
    /// place at the top corners stretch the covered area to the full layer,
    /// so the capture lines up with the screen. The black surround hides them.
    private static func padded(_ mesh: Mesh, size: CGSize) -> AnyObject? {
        var mesh = mesh
        let sliver = 0.002
        for (x0, x1) in [(0.0, sliver), (1 - sliver, 1.0)] {
            let base = UInt32(mesh.vertices.count)
            for (x, y) in [(x0, 1 - sliver), (x1, 1 - sliver), (x1, 1.0), (x0, 1.0)] {
                mesh.vertices.append(MeshVertex(
                    from: CGPoint(x: x, y: y),
                    to: MeshPoint3D(x: CGFloat(x), y: CGFloat(y), z: 0)
                ))
            }
            mesh.faces.append(MeshFace(indices: (base, base + 1, base + 2, base + 3), w: (0, 0, 0, 0)))
        }
        return build(mesh)
    }

    private static func build(_ mesh: Mesh) -> AnyObject? {
        guard let meshClass = NSClassFromString("CAMeshTransform"),
              let implementation = class_getMethodImplementation(object_getClass(meshClass), meshSelector)
        else { return nil }
        let factory = unsafeBitCast(implementation, to: MeshFactory.self)
        return mesh.vertices.withUnsafeBytes { vertices in
            mesh.faces.withUnsafeBytes { faces in
                guard let vertexBase = vertices.baseAddress, let faceBase = faces.baseAddress else { return nil }
                return factory(
                    meshClass, meshSelector,
                    UInt(mesh.vertices.count), vertexBase,
                    UInt(mesh.faces.count), faceBase,
                    "none" as NSString
                )?.takeUnretainedValue()
            }
        }
    }

    // MARK: - Blur mask

    /// Blur radius as a fraction of the full radius, rising from the hinge at
    /// the bottom to the far edge at the top. White with matching alpha, so
    /// the filter reads the same value from either.
    private static func mask(floor: Double) -> CGImage? {
        let height = 256
        guard let context = CGContext(
            data: nil,
            width: 1,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let bottom = CGFloat(floor)
        let colours = [
            CGColor(red: bottom, green: bottom, blue: bottom, alpha: bottom),
            CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours, locations: [0, 1])
        else { return nil }
        // Bitmap contexts put y = 0 at the bottom row.
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 0, y: height),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        return context.makeImage()
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
