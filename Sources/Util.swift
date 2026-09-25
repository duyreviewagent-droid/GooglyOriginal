import AppKit
import SpriteKit
import SceneKit
import simd

typealias V2 = SIMD2<Float>
typealias V3 = SIMD3<Float>

extension SIMD3 where Scalar == Float {
    @inline(__always) var len: Float { simd_length(self) }
    @inline(__always) var norm: V3 { let l = simd_length(self); return l > 1e-6 ? self / l : V3(0, 0, 0) }
    @inline(__always) var xz: V2 { V2(x, z) }
    @inline(__always) var flat: V3 { V3(x, 0, z) }
    var scn: SCNVector3 { SCNVector3(CGFloat(x), CGFloat(y), CGFloat(z)) }
}
@inline(__always) func dot3(_ a: V3, _ b: V3) -> Float { simd_dot(a, b) }
@inline(__always) func cross3(_ a: V3, _ b: V3) -> V3 { simd_cross(a, b) }
typealias M3 = simd_float3x3

/// Rotation that best matches a 3×3 matrix (Müller et al. 2016), warm-started from q.
func extractRotation(_ A: M3, _ q0: simd_quatf, iterations: Int = 6) -> simd_quatf {
    var q = q0
    for _ in 0..<iterations {
        let R = M3(q)
        let num = simd_cross(R.columns.0, A.columns.0) + simd_cross(R.columns.1, A.columns.1) + simd_cross(R.columns.2, A.columns.2)
        let den = abs(simd_dot(R.columns.0, A.columns.0) + simd_dot(R.columns.1, A.columns.1) + simd_dot(R.columns.2, A.columns.2)) + 1e-9
        let w = num / den
        let a = simd_length(w)
        if a < 1e-9 { break }
        q = simd_normalize(simd_quatf(angle: a, axis: w / a) * q)
    }
    return q
}

extension SIMD2 where Scalar == Float {
    @inline(__always) var len: Float { simd_length(self) }
    @inline(__always) var norm: V2 { let l = simd_length(self); return l > 1e-6 ? self / l : V2(0, 0) }
    @inline(__always) var perp: V2 { V2(-y, x) }
    @inline(__always) var cg: CGPoint { CGPoint(x: CGFloat(x), y: CGFloat(y)) }
    init(_ p: CGPoint) { self.init(Float(p.x), Float(p.y)) }
}

@inline(__always) func dot(_ a: V2, _ b: V2) -> Float { a.x * b.x + a.y * b.y }
@inline(__always) func cross(_ a: V2, _ b: V2) -> Float { a.x * b.y - a.y * b.x }
@inline(__always) func rot(_ v: V2, _ a: Float) -> V2 { let c = cosf(a), s = sinf(a); return V2(c * v.x - s * v.y, s * v.x + c * v.y) }
@inline(__always) func mixf(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
@inline(__always) func clampf(_ x: Float, _ a: Float, _ b: Float) -> Float { min(max(x, a), b) }
@inline(__always) func wrapAngle(_ a: Float) -> Float { var x = fmodf(a + .pi, 2 * .pi); if x < 0 { x += 2 * .pi }; return x - .pi }
@inline(__always) func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
    let t = min(max((x - e0) / (e1 - e0), 0), 1)
    return t * t * (3 - 2 * t)
}

/// 2×2 matrix, column-major: [a c; b d].
struct M2 {
    var a: Float, b: Float, c: Float, d: Float
    static let identity = M2(a: 1, b: 0, c: 0, d: 1)
    static func rotation(_ t: Float) -> M2 { let c = cosf(t), s = sinf(t); return M2(a: c, b: s, c: -s, d: c) }
    @inline(__always) func mul(_ v: V2) -> V2 { V2(a * v.x + c * v.y, b * v.x + d * v.y) }
    @inline(__always) func mul(_ m: M2) -> M2 {
        M2(a: a * m.a + c * m.b, b: b * m.a + d * m.b, c: a * m.c + c * m.d, d: b * m.c + d * m.d)
    }
    var det: Float { a * d - b * c }
    var inverse: M2 { let k = 1 / det; return M2(a: d * k, b: -b * k, c: -c * k, d: a * k) }
    static func * (l: M2, r: Float) -> M2 { M2(a: l.a * r, b: l.b * r, c: l.c * r, d: l.d * r) }
    static func + (l: M2, r: M2) -> M2 { M2(a: l.a + r.a, b: l.b + r.b, c: l.c + r.c, d: l.d + r.d) }
}

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}
func hex(_ h: UInt32, _ a: CGFloat = 1) -> NSColor {
    color(CGFloat((h >> 16) & 255) / 255, CGFloat((h >> 8) & 255) / 255, CGFloat(h & 255) / 255, a)
}

// MARK: - Deterministic RNG (splitmix64)

struct RNG {
    var s: UInt64
    init(_ seed: UInt64) { s = seed }
    mutating func next() -> UInt64 {
        s &+= 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func float() -> Float { Float(next() >> 40) / 16_777_216.0 }
    mutating func range(_ a: Float, _ b: Float) -> Float { a + (b - a) * float() }
    mutating func chance(_ p: Float) -> Bool { float() < p }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}

@inline(__always) func frand(_ a: Float, _ b: Float) -> Float { Float.random(in: a...b) }

// MARK: - Images

func makeImage(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    draw(ctx)
    return ctx.makeImage()!
}

func savePNG(_ img: CGImage, to path: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    if let d = rep.representation(using: .png, properties: [:]) { try? d.write(to: URL(fileURLWithPath: path)) }
}

private var emojiCache: [String: SKTexture] = [:]

/// Apple Color Emoji rendered to a texture (items, pigeons, decorations).
func emojiTexture(_ s: String, size: CGFloat = 96) -> SKTexture {
    let key = "\(s)@\(size)"
    if let t = emojiCache[key] { return t }
    let px = Int(size * 1.25)
    let img = makeImage(px, px) { ctx in
        let g = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        let font = NSFont(name: "AppleColorEmoji", size: size) ?? NSFont.systemFont(ofSize: size)
        let a = NSAttributedString(string: s, attributes: [.font: font])
        let b = a.size()
        a.draw(at: NSPoint(x: (CGFloat(px) - b.width) / 2, y: (CGFloat(px) - b.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
    }
    let t = SKTexture(cgImage: img)
    emojiCache[key] = t
    return t
}

/// Cartoon lettering: fill with a thick dark outline.
func cartoonText(_ s: String, size: CGFloat, fill: NSColor = .white, stroke: NSColor = hex(0x221018), width: CGFloat = -5,
                 font name: String = "ChalkboardSE-Bold") -> NSAttributedString {
    let font = NSFont(name: name, size: size) ?? NSFont.boldSystemFont(ofSize: size)
    let p = NSMutableParagraphStyle()
    p.alignment = .center
    return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: fill, .strokeColor: stroke,
                                                      .strokeWidth: width, .paragraphStyle: p])
}

func label(_ s: String, size: CGFloat, fill: NSColor = .white, stroke: NSColor = hex(0x221018), width: CGFloat = -5) -> SKLabelNode {
    let l = SKLabelNode()
    l.attributedText = cartoonText(s, size: size, fill: fill, stroke: stroke, width: width)
    l.verticalAlignmentMode = .center
    l.horizontalAlignmentMode = .center
    l.numberOfLines = 0
    return l
}

/// Smooth closed curve through a ring of points (quadratic B-spline through the midpoints).
func smoothClosedPath(_ p: [V2]) -> CGPath {
    let path = CGMutablePath()
    let n = p.count
    guard n > 2 else { return path }
    path.move(to: ((p[n - 1] + p[0]) * 0.5).cg)
    for i in 0..<n {
        let a = p[i], b = p[(i + 1) % n]
        path.addQuadCurve(to: ((a + b) * 0.5).cg, control: a.cg)
    }
    path.closeSubpath()
    return path
}

/// Smooth open curve through points.
func smoothOpenPath(_ p: [V2]) -> CGPath {
    let path = CGMutablePath()
    guard p.count > 1 else { return path }
    path.move(to: p[0].cg)
    if p.count == 2 { path.addLine(to: p[1].cg); return path }
    for i in 1..<(p.count - 1) {
        path.addQuadCurve(to: ((p[i] + p[i + 1]) * 0.5).cg, control: p[i].cg)
    }
    path.addLine(to: p[p.count - 1].cg)
    return path
}

func radialTexture(_ size: Int, inner: CGColor, outer: CGColor, mid: CGFloat = 0.5) -> SKTexture {
    let img = makeImage(size, size) { ctx in
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let g = CGGradient(colorsSpace: cs, colors: [inner, outer] as CFArray, locations: [mid, 1])!
        let c = CGPoint(x: size / 2, y: size / 2)
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(size) / 2, options: [])
    }
    return SKTexture(cgImage: img)
}

// MARK: - SceneKit helpers

func mat(_ c: NSColor, rough: CGFloat = 0.6, metal: CGFloat = 0, emission: NSColor? = nil) -> SCNMaterial {
    let m = SCNMaterial()
    m.lightingModel = .physicallyBased
    m.diffuse.contents = c
    m.roughness.contents = rough
    m.metalness.contents = metal
    if let e = emission { m.emission.contents = e }
    return m
}

func sphere(_ r: CGFloat, _ m: SCNMaterial, seg: Int = 24) -> SCNNode {
    let s = SCNSphere(radius: r)
    s.segmentCount = seg
    s.firstMaterial = m
    return SCNNode(geometry: s)
}

func box(_ w: CGFloat, _ h: CGFloat, _ l: CGFloat, _ m: SCNMaterial, chamfer: CGFloat = 0) -> SCNNode {
    let b = SCNBox(width: w, height: h, length: l, chamferRadius: chamfer)
    b.firstMaterial = m
    return SCNNode(geometry: b)
}

func cyl(_ r: CGFloat, _ h: CGFloat, _ m: SCNMaterial) -> SCNNode {
    let c = SCNCylinder(radius: r, height: h)
    c.firstMaterial = m
    return SCNNode(geometry: c)
}

func cone(_ r0: CGFloat, _ r1: CGFloat, _ h: CGFloat, _ m: SCNMaterial) -> SCNNode {
    let c = SCNCone(topRadius: r1, bottomRadius: r0, height: h)
    c.firstMaterial = m
    return SCNNode(geometry: c)
}

extension SCNNode {
    @discardableResult func at(_ x: Float, _ y: Float, _ z: Float) -> SCNNode { simdPosition = V3(x, y, z); return self }
    @discardableResult func scaled(_ x: Float, _ y: Float, _ z: Float) -> SCNNode { simdScale = V3(x, y, z); return self }
    @discardableResult func add(_ c: SCNNode) -> SCNNode { addChildNode(c); return c }
}

/// Text drawn onto an image, for signs.
func textImage(_ s: String, size: CGFloat, color: NSColor, bg: NSColor?, width: Int, height: Int) -> CGImage {
    makeImage(width, height) { ctx in
        if let bg = bg { ctx.setFillColor(bg.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height)) }
        let g = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        let a = cartoonText(s, size: size, fill: color, stroke: .clear, width: 0)
        let r = a.boundingRect(with: NSSize(width: CGFloat(width) - 20, height: CGFloat(height)), options: [.usesLineFragmentOrigin])
        a.draw(with: NSRect(x: 10, y: (CGFloat(height) - r.height) / 2, width: CGFloat(width) - 20, height: r.height), options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
    }
}
