import SceneKit

/// A convex prism: a counter-clockwise polygon in XY, extruded between z0 and z1.
final class Solid {
    enum Kind { case ground, platform, bouncy, ice, mover }
    var pts: [V2]
    var normals: [V2] = []
    var z0: Float, z1: Float
    var lo = V3(0, 0, 0), hi = V3(0, 0, 0)
    let kind: Kind
    var vel = V3(0, 0, 0)
    var friction: Float
    // movers
    var amp = V3(0, 0, 0), speed: Float = 0, phase: Float = 0, base: [V2] = [], baseZ: (Float, Float) = (0, 0)
    var node: SCNNode?
    /// Invisible barriers are collision only.
    var hidden = false
    /// Trampoline squash animation, 0…1.
    var squash: Float = 0

    init(_ pts: [V2], z0: Float, z1: Float, kind: Kind) {
        self.pts = pts
        self.z0 = z0; self.z1 = z1
        self.kind = kind
        friction = kind == .ice ? 0.004 : 0.2
        recompute()
    }

    func recompute() {
        normals = (0..<pts.count).map { i in
            let a = pts[i], b = pts[(i + 1) % pts.count]
            return V2(b.y - a.y, a.x - b.x).norm
        }
        let l2 = pts.reduce(V2(.infinity, .infinity)) { simd_min($0, $1) }
        let h2 = pts.reduce(V2(-.infinity, -.infinity)) { simd_max($0, $1) }
        lo = V3(l2.x, l2.y, z0); hi = V3(h2.x, h2.y, z1)
    }

    var top: Float { hi.y }

    /// Sphere vs prism. Returns push-out normal and depth.
    @inline(__always) func collide(_ p: V3, _ r: Float) -> (V3, Float)? {
        if p.x + r < lo.x || p.x - r > hi.x || p.y + r < lo.y || p.y - r > hi.y || p.z + r < z0 || p.z - r > z1 { return nil }
        let q = V2(p.x, p.y)
        var maxD: Float = -.infinity, idx = 0
        let n = pts.count
        for i in 0..<n {
            let d = dot(q - pts[i], normals[i])
            if d > maxD { maxD = d; idx = i }
        }
        if maxD > r { return nil }
        let inside2 = maxD <= 0
        let insideZ = p.z > z0 && p.z < z1
        if inside2 && insideZ {
            let d2 = -maxD, dz0 = p.z - z0, dz1 = z1 - p.z
            if d2 <= min(dz0, dz1) { return (V3(normals[idx].x, normals[idx].y, 0), d2 + r) }
            return dz0 < dz1 ? (V3(0, 0, -1), dz0 + r) : (V3(0, 0, 1), dz1 + r)
        }
        var cp2 = q
        if !inside2 {
            var best: Float = .infinity
            for i in 0..<n {
                let a = pts[i], b = pts[(i + 1) % n]
                let ab = b - a
                let t = clampf(dot(q - a, ab) / max(1e-6, dot(ab, ab)), 0, 1)
                let c = a + ab * t
                let d = simd_length_squared(q - c)
                if d < best { best = d; cp2 = c }
            }
        }
        let cp = V3(cp2.x, cp2.y, clampf(p.z, z0, z1))
        let dv = p - cp
        let d = dv.len
        if d >= r { return nil }
        if d < 1e-5 { return (V3(normals[idx].x, normals[idx].y, 0), r) }
        return (dv / d, r - d)
    }

    func contains(_ p: V3) -> Bool {
        if p.x < lo.x || p.x > hi.x || p.y < lo.y || p.y > hi.y || p.z < z0 || p.z > z1 { return false }
        let q = V2(p.x, p.y)
        for i in 0..<pts.count where dot(q - pts[i], normals[i]) > 0 { return false }
        return true
    }

    /// Height of the upper surface at (x, z), if the prism covers that column.
    func surfaceY(_ x: Float, _ z: Float) -> Float? {
        guard x >= lo.x, x <= hi.x, z >= z0, z <= z1 else { return nil }
        var best: Float? = nil
        let n = pts.count
        for i in 0..<n where normals[i].y > 0.05 {
            let a = pts[i], b = pts[(i + 1) % n]
            let x0 = min(a.x, b.x), x1 = max(a.x, b.x)
            guard x >= x0 - 0.01, x <= x1 + 0.01, x1 - x0 > 1e-4 else { continue }
            let y = a.y + (b.y - a.y) * (x - a.x) / (b.x - a.x)
            if best == nil || y > best! { best = y }
        }
        return best
    }
}

struct Contact { var n: V3; var solid: Solid }

/// Region that blows things upwards.
struct Fan { var lo: V3; var hi: V3; var power: Float }

final class World {
    var solids: [Solid] = []
    var fans: [Fan] = []
    var killY: Float = -700
    var minX: Float = -400, maxX: Float = 8000
    var time: Float = 0

    func moveMovers(_ dt: Float) {
        time += dt
        for s in solids where s.kind == .mover {
            let oldX = s.pts[0].x, oldY = s.pts[0].y, oldZ = s.z0
            let off = s.amp * sinf(time * s.speed + s.phase)
            s.pts = s.base.map { $0 + V2(off.x, off.y) }
            s.z0 = s.baseZ.0 + off.z; s.z1 = s.baseZ.1 + off.z
            s.vel = V3(s.pts[0].x - oldX, s.pts[0].y - oldY, s.z0 - oldZ) / max(dt, 1e-4)
            s.recompute()
            s.node?.simdPosition = off
        }
        for s in solids where s.kind == .bouncy {
            s.squash = max(0, s.squash - dt * 2.5)
            s.node?.simdScale = V3(1, 1 - 0.45 * sinf(s.squash * .pi * 3) * s.squash, 1)
        }
    }

    /// Pushes a sphere out of every solid. Records the contacts it made.
    @inline(__always) func resolve(_ p: inout V3, _ r: Float, contacts: inout [Contact]) {
        for s in solids {
            if let (n, d) = s.collide(p, r) {
                p += n * d
                contacts.append(Contact(n: n, solid: s))
            }
        }
    }

    func solidAt(_ p: V3) -> Bool { solids.contains { $0.contains(p) } }

    /// Highest surface under (x, z) at or below y.
    func groundBelow(_ x: Float, _ z: Float, _ y: Float) -> Float? {
        var best: Float? = nil
        for s in solids {
            if let h = s.surfaceY(x, z), h <= y + 1, best == nil || h > best! { best = h }
        }
        return best
    }

    func fanForce(_ p: V3) -> Float {
        var f: Float = 0
        for fan in fans where p.x > fan.lo.x && p.x < fan.hi.x && p.y > fan.lo.y && p.y < fan.hi.y && p.z > fan.lo.z && p.z < fan.hi.z {
            let t = (p.y - fan.lo.y) / (fan.hi.y - fan.lo.y)
            f += fan.power * (1 - t * 0.6)
        }
        return f
    }
}

/// A googly eye: a black pupil disc rattling around inside a white disc. The eye node's local
/// +Z is its outward normal; the pupil moves in the node's local XY plane.
struct Googly {
    var R: Float
    var r: Float
    var p = V2(0, -3)
    var pv = V2(0, 0)
    var lastE = V3(0, 0, 0), lastVE = V3(0, 0, 0)
    var primed = false
    var node: SCNNode?
    var pupil: SCNNode?

    init(R: Float, pupil: Float? = nil) {
        self.R = R
        self.r = pupil ?? R * 0.52
    }

    mutating func reset(_ e: V3) { lastE = e; lastVE = .zero; primed = true }

    /// E is the eye centre in world space, u and v its in-plane axes.
    mutating func update(_ E: V3, u: V3, v: V3, dt: Float, gravity: Float = -2400) {
        guard dt > 0 else { return }
        if !primed { reset(E) }
        let ve = (E - lastE) / dt
        var ae = (ve - lastVE) / dt
        let am = ae.len
        if am > 60000 { ae *= 60000 / am }
        lastE = E; lastVE = ve
        let a3 = V3(0, gravity, 0) - ae
        let a = V2(dot3(a3, u), dot3(a3, v))
        let sub = 3
        let h = dt / Float(sub)
        for _ in 0..<sub {
            pv += a * h
            pv *= 1 - 1.2 * h
            p += pv * h
            let maxD = R - r
            let d = p.len
            if d > maxD {
                let n = p / d
                p = n * maxD
                let vn = dot(pv, n)
                if vn > 0 {
                    pv -= n * vn * 1.5
                    pv *= 0.97
                }
            }
        }
    }

    /// Kicks the pupil (for surprise moments).
    mutating func jolt(_ k: V2) { pv += k }

    static let whiteMat: SCNMaterial = { let m = mat(.white, rough: 0.35); return m }()
    static let pupilMat: SCNMaterial = { let m = mat(hex(0x0d0d0d), rough: 0.15); return m }()
    static let rimMat: SCNMaterial = mat(hex(0x1a0a0a), rough: 0.5)

    func makeNode() -> (SCNNode, SCNNode) {
        let eye = SCNNode()
        let rim = cyl(CGFloat(R) * 1.06, CGFloat(R) * 0.14, Googly.rimMat)
        rim.eulerAngles.x = .pi / 2
        eye.addChildNode(rim)
        let white = cyl(CGFloat(R), CGFloat(R) * 0.18, Googly.whiteMat)
        white.eulerAngles.x = .pi / 2
        white.simdPosition = V3(0, 0, R * 0.03)
        eye.addChildNode(white)
        // clear plastic dome
        let dome = SCNSphere(radius: CGFloat(R))
        dome.segmentCount = 20
        let dm = SCNMaterial()
        dm.lightingModel = .physicallyBased
        dm.diffuse.contents = NSColor(white: 1, alpha: 0.06)
        dm.roughness.contents = 0.05
        dm.transparency = 0.25
        dm.blendMode = .add
        dm.writesToDepthBuffer = false
        dome.firstMaterial = dm
        let domeNode = SCNNode(geometry: dome)
        domeNode.simdScale = V3(1, 1, 0.28)
        domeNode.simdPosition = V3(0, 0, R * 0.08)
        eye.addChildNode(domeNode)
        let pupil = cyl(CGFloat(r), CGFloat(R) * 0.1, Googly.pupilMat)
        pupil.eulerAngles.x = .pi / 2
        let holder = SCNNode()
        holder.addChildNode(pupil)
        pupil.simdPosition = V3(0, 0, R * 0.17)
        let glint = sphere(CGFloat(r) * 0.22, mat(.white, rough: 0.2, emission: NSColor(white: 0.6, alpha: 1)), seg: 8)
        glint.simdScale = V3(1, 1, 0.3)
        glint.simdPosition = V3(-r * 0.35, r * 0.35, R * 0.24)
        holder.addChildNode(glint)
        eye.addChildNode(holder)
        return (eye, holder)
    }

    mutating func attach(to parent: SCNNode) {
        let (w, p) = makeNode()
        parent.addChildNode(w)
        node = w; pupil = p
    }

    func drawPupil() { pupil?.simdPosition = V3(p.x, p.y, 0) }
}
