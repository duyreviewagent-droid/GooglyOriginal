import SpriteKit

/// A convex solid in the level. Points are counter-clockwise.
final class Solid {
    enum Kind { case ground, platform, bouncy, ice, mover }
    var pts: [V2]
    var normals: [V2] = []
    var lo = V2(0, 0), hi = V2(0, 0)
    let kind: Kind
    var vel = V2(0, 0)
    var friction: Float
    var bounce: Float
    // movers
    var origin = V2(0, 0), amp = V2(0, 0), speed: Float = 0, phase: Float = 0, base: [V2] = []
    var node: SKNode?
    /// Trampoline squash animation, 0…1.
    var squash: Float = 0

    init(_ pts: [V2], kind: Kind) {
        self.pts = pts
        self.kind = kind
        friction = kind == .ice ? 0.004 : 0.2
        bounce = kind == .bouncy ? 1 : 0
        recompute()
    }

    func recompute() {
        normals = (0..<pts.count).map { i in
            let a = pts[i], b = pts[(i + 1) % pts.count]
            return V2(b.y - a.y, a.x - b.x).norm
        }
        lo = pts.reduce(V2(.infinity, .infinity)) { simd_min($0, $1) }
        hi = pts.reduce(V2(-.infinity, -.infinity)) { simd_max($0, $1) }
    }

    var top: Float { hi.y }

    /// Circle vs convex polygon. Returns push-out normal and depth.
    @inline(__always) func collide(_ p: V2, _ r: Float) -> (V2, Float)? {
        if p.x + r < lo.x || p.x - r > hi.x || p.y + r < lo.y || p.y - r > hi.y { return nil }
        var maxD: Float = -.infinity, idx = 0
        let n = pts.count
        for i in 0..<n {
            let d = dot(p - pts[i], normals[i])
            if d > maxD { maxD = d; idx = i }
        }
        if maxD > r { return nil }
        if maxD <= 0 { return (normals[idx], r - maxD) }
        // outside: nearest point on the boundary
        var best: Float = .infinity, bp = V2(0, 0)
        for i in 0..<n {
            let a = pts[i], b = pts[(i + 1) % n]
            let ab = b - a
            let t = clampf(dot(p - a, ab) / max(1e-6, dot(ab, ab)), 0, 1)
            let q = a + ab * t
            let d = simd_length_squared(p - q)
            if d < best { best = d; bp = q }
        }
        let d = sqrtf(best)
        if d >= r || d < 1e-5 { return d < 1e-5 ? (normals[idx], r) : nil }
        return ((p - bp) / d, r - d)
    }

    func contains(_ p: V2) -> Bool {
        if p.x < lo.x || p.x > hi.x || p.y < lo.y || p.y > hi.y { return false }
        for i in 0..<pts.count where dot(p - pts[i], normals[i]) > 0 { return false }
        return true
    }
}

struct Contact { var n: V2; var solid: Solid }

/// Region that blows things upwards.
struct Fan { var lo: V2; var hi: V2; var power: Float }

final class World {
    var solids: [Solid] = []
    var fans: [Fan] = []
    var killY: Float = -700
    var minX: Float = -400, maxX: Float = 8000
    var time: Float = 0

    func moveMovers(_ dt: Float) {
        time += dt
        for s in solids where s.kind == .mover {
            let old = s.pts[0]
            let off = s.amp * sinf(time * s.speed + s.phase)
            s.pts = s.base.map { $0 + off }
            s.vel = (s.pts[0] - old) / max(dt, 1e-4)
            s.recompute()
            s.node?.position = off.cg
        }
        for s in solids where s.kind == .bouncy {
            s.squash = max(0, s.squash - dt * 2.5)
            s.node?.yScale = CGFloat(1 - 0.35 * sinf(s.squash * .pi * 3) * s.squash)
        }
    }

    /// Pushes a circle out of every solid. Returns the contacts it made.
    @inline(__always) func resolve(_ p: inout V2, _ r: Float, contacts: inout [Contact]) {
        for s in solids {
            if let (n, d) = s.collide(p, r) {
                p += n * d
                contacts.append(Contact(n: n, solid: s))
            }
        }
    }

    func solidAt(_ p: V2) -> Bool { solids.contains { $0.contains(p) } }

    /// Height of the highest surface under x at or below y (for shadows and spawning).
    func groundBelow(_ x: Float, _ y: Float) -> Float? {
        var best: Float? = nil
        for s in solids where x >= s.lo.x && x <= s.hi.x && s.lo.y <= y {
            // walk down from y until inside
            var yy = min(y, s.hi.y + 1)
            var hit: Float? = nil
            for _ in 0..<40 {
                if s.contains(V2(x, yy)) { hit = yy; break }
                yy -= 6
                if yy < s.lo.y { break }
            }
            if let h = hit, best == nil || h > best! { best = h }
        }
        return best
    }

    func fanForce(_ p: V2) -> Float {
        var f: Float = 0
        for fan in fans where p.x > fan.lo.x && p.x < fan.hi.x && p.y > fan.lo.y && p.y < fan.hi.y {
            let t = (p.y - fan.lo.y) / (fan.hi.y - fan.lo.y)
            f += fan.power * (1 - t * 0.6)
        }
        return f
    }
}

/// A googly eye: a black pupil rattling freely inside a white disc.
struct Googly {
    var R: Float
    var r: Float
    var p = V2(0, -3)
    var pv = V2(0, 0)
    var lastE = V2(0, 0), lastVE = V2(0, 0)
    var primed = false
    var node: SKNode?
    var pupil: SKNode?

    init(R: Float, pupil: Float? = nil) {
        self.R = R
        self.r = pupil ?? R * 0.52
    }

    mutating func reset(_ e: V2) { lastE = e; lastVE = .zero; primed = true }

    mutating func update(_ E: V2, dt: Float, gravity: Float = -2400) {
        guard dt > 0 else { return }
        if !primed { reset(E) }
        let ve = (E - lastE) / dt
        var ae = (ve - lastVE) / dt
        let am = ae.len
        if am > 60000 { ae *= 60000 / am }
        lastE = E; lastVE = ve
        let sub = 3
        let h = dt / Float(sub)
        for _ in 0..<sub {
            pv += (V2(0, gravity) - ae) * h
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

    func makeNode(outline: CGFloat = 2.5) -> (SKNode, SKNode) {
        let white = SKShapeNode(circleOfRadius: CGFloat(R))
        white.fillColor = .white
        white.strokeColor = hex(0x1a0a0a)
        white.lineWidth = outline
        white.isAntialiased = true
        let shade = SKShapeNode(circleOfRadius: CGFloat(R) * 0.82)
        shade.fillColor = hex(0xd9dce6, 0.55)
        shade.strokeColor = .clear
        shade.position = CGPoint(x: CGFloat(R) * 0.1, y: -CGFloat(R) * 0.12)
        white.addChild(shade)
        let hi = SKShapeNode(circleOfRadius: CGFloat(R) * 0.8)
        hi.fillColor = .white
        hi.strokeColor = .clear
        hi.position = CGPoint(x: -CGFloat(R) * 0.06, y: CGFloat(R) * 0.06)
        white.addChild(hi)
        let pupil = SKShapeNode(circleOfRadius: CGFloat(r))
        pupil.fillColor = hex(0x111111)
        pupil.strokeColor = .clear
        let glint = SKShapeNode(circleOfRadius: CGFloat(r) * 0.28)
        glint.fillColor = .white
        glint.strokeColor = .clear
        glint.position = CGPoint(x: -CGFloat(r) * 0.35, y: CGFloat(r) * 0.35)
        pupil.addChild(glint)
        white.addChild(pupil)
        return (white, pupil)
    }

    mutating func attach(to parent: SKNode, z: CGFloat, outline: CGFloat = 2.5) {
        let (w, p) = makeNode(outline: outline)
        w.zPosition = z
        parent.addChild(w)
        node = w; pupil = p
    }

    func draw(at e: V2, scale: Float = 1) {
        node?.position = e.cg
        node?.setScale(CGFloat(scale))
        pupil?.position = p.cg
    }
}
