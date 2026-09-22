import AppKit
import QuartzCore

/// The fold effect done entirely by the window server, on whatever is behind
/// the overlay. Nothing is captured, so it needs no Screen Recording
/// permission, runs no capture stream and draws nothing on the GPU from this
/// process.
///
/// The screen stays flat where the glass started, and the glass folds away
/// from it about the hinge. Looking straight at the flat screen through the
/// folded glass, a point on the glass a distance `s` from the hinge shows the
/// flat screen at `s · cos(fold)`. So the content is stretched away from the
/// hinge by `1 / cos(fold)`, along the fold only: the row nearest the hinge is
/// drawn out across the glass, as on the iPhone Fold. The glass is frosted,
/// so the further a point is from the flat screen the softer it gets, and it
/// darkens toward the far edge.
///
/// A `CABackdropLayer` shows what is behind the window. A mesh transform on
/// it does the stretch. A `variableBlur` filter, which applies before the
/// mesh, blurs by the gap; the stretch then draws the blur out along the fold
/// the way the fold streaks it.
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
        // Hinge at the bottom, far edge at the top.
        dim.anchorPoint = .zero
        dim.startPoint = CGPoint(x: 0.5, y: 0)
        dim.endPoint = CGPoint(x: 0.5, y: 1)
        dim.locations = (0..<Self.dimStops).map { NSNumber(value: Double($0) / Double(Self.dimStops - 1)) }
        dim.isHidden = true
        root.addSublayer(dim)
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
    ///   - stretch: how far the content is drawn out away from the hinge,
    ///     `1 / cos(fold)`. One leaves it as it is.
    ///   - blurRadius: blur at the far edge of the glass, in points of the
    ///     unstretched screen.
    ///   - hingeBlur: blur at the hinge, in the same points.
    func apply(
        stretch: Double,
        blurRadius: Double,
        hingeBlur: Double,
        dimStrength: Double,
        dimHingeFloor: Double,
        dimReach: Double,
        maxDim: Double
    ) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let stretch = max(stretch, 1)
        let state = [stretch, blurRadius, hingeBlur, dimStrength, dimHingeFloor, dimReach, maxDim]
        guard state != lastState else { return }
        lastState = state

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if let backdrop {
            // The glass shows the screen from the hinge up to `1 / stretch` of
            // its height. The blur mask covers the whole screen, so the radius
            // at its top is what the far edge of the glass wants, carried on
            // up the part of the screen that stays out of sight.
            let hinge = max(hingeBlur, 0) * Self.radiusScale
            let far = max(blurRadius, 0) * Self.radiusScale
            let radius = hinge + (far - hinge) * stretch
            let isFlat = stretch < 1.0005
            // At the handover the picture is the screen itself. A hidden
            // backdrop costs the window server nothing and cannot differ.
            backdrop.isHidden = isFlat && radius < 0.25
            if !backdrop.isHidden {
                backdrop.setValue(isFlat ? nil : Self.stretchMesh(stretch), forKey: "meshTransform")
                let floor = radius > 0 ? ((hinge / radius) * 64).rounded() / 64 : 1
                if maskFloor != floor {
                    maskFloor = floor
                    backdrop.setValue(Self.mask(floor: floor), forKeyPath: "filters.\(Self.blurName).inputMaskImage")
                }
                backdrop.setValue(radius, forKeyPath: "filters.\(Self.blurName).inputRadius")
            }
        }

        // Darker toward the far edge, on the glass itself.
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
        if !dim.isHidden { dim.colors = colours }
    }

    // MARK: - Mesh

    /// The bottom `1 / stretch` of the screen, drawn over the whole layer. One
    /// quad is exact: the stretch is linear. The mesh covers the whole layer,
    /// which the window server needs to line its capture up with the screen.
    private static func stretchMesh(_ stretch: Double) -> AnyObject? {
        let top = CGFloat(1 / stretch)
        let vertices = [
            MeshVertex(from: CGPoint(x: 0, y: 0), to: MeshPoint3D(x: 0, y: 0, z: 0)),
            MeshVertex(from: CGPoint(x: 1, y: 0), to: MeshPoint3D(x: 1, y: 0, z: 0)),
            MeshVertex(from: CGPoint(x: 1, y: top), to: MeshPoint3D(x: 1, y: 1, z: 0)),
            MeshVertex(from: CGPoint(x: 0, y: top), to: MeshPoint3D(x: 0, y: 1, z: 0)),
        ]
        let faces = [MeshFace(indices: (0, 1, 2, 3), w: (0, 0, 0, 0))]
        guard let meshClass = NSClassFromString("CAMeshTransform"),
              let implementation = class_getMethodImplementation(object_getClass(meshClass), meshSelector)
        else { return nil }
        let factory = unsafeBitCast(implementation, to: MeshFactory.self)
        return vertices.withUnsafeBytes { vertexBytes in
            faces.withUnsafeBytes { faceBytes in
                guard let vertexBase = vertexBytes.baseAddress, let faceBase = faceBytes.baseAddress else { return nil }
                return factory(
                    meshClass, meshSelector,
                    UInt(vertices.count), vertexBase,
                    UInt(faces.count), faceBase,
                    "none" as NSString
                )?.takeUnretainedValue()
            }
        }
    }

    // MARK: - Blur mask

    /// Blur radius as a fraction of the full radius, rising from the hinge at
    /// the bottom to the top of the screen. White with matching alpha, so the
    /// filter reads the same value from either. It applies to the screen
    /// before the stretch.
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
        let bottom = CGFloat(min(max(floor, 0), 1))
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
