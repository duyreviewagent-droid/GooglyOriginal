import SceneKit

/// Everything you can collect and then spit at things.
enum Junk: Int, CaseIterable, Codable {
    case duck, toast, fish, banana, sock, cheese, melon, bowling, chicken, pea

    var emoji: String {
        switch self {
        case .duck: return "🦆"
        case .toast: return "🍞"
        case .fish: return "🐟"
        case .banana: return "🍌"
        case .sock: return "🧦"
        case .cheese: return "🧀"
        case .melon: return "🍉"
        case .bowling: return "🎳"
        case .chicken: return "🐔"
        case .pea: return "🟢"
        }
    }
    var name: String {
        switch self {
        case .duck: return "rubber duck"
        case .toast: return "toast"
        case .fish: return "fish"
        case .banana: return "boomerang banana"
        case .sock: return "stinky sock"
        case .cheese: return "cheese wheel"
        case .melon: return "watermelon"
        case .bowling: return "bowling ball"
        case .chicken: return "chicken"
        case .pea: return "sad pea"
        }
    }
    var radius: Float {
        switch self {
        case .pea: return 7
        case .melon, .bowling, .cheese: return 19
        case .chicken: return 17
        default: return 15
        }
    }
    var damage: Float {
        switch self {
        case .pea: return 0.5
        case .fish, .cheese, .chicken: return 2
        case .melon: return 3
        case .bowling: return 5
        default: return 1
        }
    }
    var speed: Float {
        switch self {
        case .bowling: return 820
        case .melon: return 900
        case .pea: return 1250
        default: return 1100
        }
    }
    var gravityScale: Float {
        switch self {
        case .bowling: return 1.3
        case .banana: return 0.25
        case .pea: return 0.5
        case .sock: return 0.8
        default: return 1
        }
    }
    var bounce: Float {
        switch self {
        case .duck: return 0.75
        case .chicken: return 0.8
        case .bowling: return 0.15
        case .cheese: return 0.35
        case .toast: return 0.25
        default: return 0.45
        }
    }
    var recoil: Float {
        switch self {
        case .bowling: return 520
        case .melon: return 300
        case .cheese: return 220
        case .pea: return 20
        default: return 110
        }
    }
    var pierces: Bool { self == .bowling }

    private static var protos: [Junk: SCNNode] = [:]

    /// A little 3D model of the thing, about `radius` in size.
    func model() -> SCNNode {
        if let p = Junk.protos[self] { return p.clone() }
        let n = SCNNode()
        let dark = mat(hex(0x111111), rough: 0.3)
        switch self {
        case .duck:
            let y = mat(hex(0xffd21f), rough: 0.25)
            n.add(sphere(12, y)).scaled(1.25, 0.9, 1)
            n.add(sphere(8, y)).at(7, 11, 0)
            n.add(cone(4, 1, 8, mat(hex(0xff8a00), rough: 0.4))).at(15, 10, 0).eulerAngles.z = -.pi / 2
            n.add(sphere(1.6, dark)).at(10, 14, 5)
            n.add(sphere(1.6, dark)).at(10, 14, -5)
            n.add(sphere(5, y)).scaled(1.2, 0.8, 1).at(-12, 5, 0)
        case .toast:
            n.add(box(26, 24, 7, mat(hex(0xb8732f), rough: 0.8), chamfer: 3.5))
            n.add(box(20, 18, 7.4, mat(hex(0xf1d49a), rough: 0.9), chamfer: 2)).at(0, -1, 0)
        case .fish:
            let b = mat(hex(0x6a9fc9), rough: 0.25)
            n.add(sphere(10, b)).scaled(1.6, 0.85, 0.55)
            let tail = n.add(cone(8, 0, 12, b))
            tail.at(-19, 0, 0); tail.eulerAngles.z = -.pi / 2; tail.simdScale = V3(1, 1, 0.35)
            n.add(sphere(2.5, mat(.white, rough: 0.3))).at(10, 3, 4.5)
            n.add(sphere(1.4, dark)).at(10.5, 3, 5.8)
        case .banana:
            let y = mat(hex(0xffe135), rough: 0.5)
            for k in 0..<7 {
                let a = Float(k - 3) * 0.3
                n.add(sphere(CGFloat(5.5 - abs(Float(k - 3)) * 0.6), y)).at(sinf(a) * 18, -cosf(a) * 12 + 6, 0)
            }
            n.add(sphere(2, mat(hex(0x5a3a10)))).at(sinf(0.9) * 18, -cosf(0.9) * 12 + 6, 0)
        case .sock:
            let w = mat(hex(0xf2f2ee), rough: 0.9), r = mat(hex(0xd62a3a), rough: 0.9)
            n.add(SCNNode(geometry: { let c = SCNCapsule(capRadius: 6, height: 26); c.firstMaterial = w; return c }())).at(0, 6, 0)
            let foot = n.add(SCNNode(geometry: { let c = SCNCapsule(capRadius: 6, height: 20); c.firstMaterial = w; return c }()))
            foot.at(5, -7, 0); foot.eulerAngles.z = .pi / 2
            n.add(cyl(6.3, 3, r)).at(0, 12, 0)
            n.add(cyl(6.3, 3, r)).at(0, 5, 0)
        case .cheese:
            let y = mat(hex(0xffc93c), rough: 0.6)
            n.add(cyl(19, 14, y))
            for (x, z) in [(6, 19), (-8, 17.5), (15, 10)] as [(Float, Float)] {
                n.add(sphere(3.5, mat(hex(0xe0a520), rough: 0.7))).at(x, 0, z)
            }
            n.add(cyl(19.2, 3, mat(hex(0xd8342c), rough: 0.5))).at(0, -5.5, 0)
        case .melon:
            n.add(sphere(19, mat(hex(0x2f8f3a), rough: 0.35))).scaled(1.1, 1, 1)
            for k in 0..<5 {
                let s = n.add(SCNNode(geometry: { let t = SCNTorus(ringRadius: 19, pipeRadius: 1.2); t.firstMaterial = mat(hex(0x1a5a22)); return t }()))
                s.eulerAngles = SCNVector3(Float.pi / 2, Float(k) * 0.63, 0)
                s.simdScale = V3(1.1, 1, 1)
            }
        case .bowling:
            n.add(sphere(18, mat(hex(0x1c2e6e), rough: 0.12)))
            for (x, y) in [(-4, 10), (4, 10), (0, 3)] as [(Float, Float)] {
                n.add(sphere(3, mat(hex(0x050505)))).at(x, y, 15)
            }
        case .chicken:
            let w = mat(hex(0xfafafa), rough: 0.7)
            n.add(sphere(13, w)).scaled(1.2, 1, 1)
            n.add(sphere(8, w)).at(10, 13, 0)
            for k in 0..<3 { n.add(sphere(3, mat(hex(0xe02020)))).at(8 + Float(k) * 3, 21, 0) }
            n.add(cone(3.5, 0, 7, mat(hex(0xffb020)))).at(18, 13, 0).eulerAngles.z = -.pi / 2
            n.add(sphere(3, mat(hex(0xe02020)))).at(15, 8, 0)
            n.add(sphere(1.5, dark)).at(13, 15, 5)
            n.add(sphere(1.5, dark)).at(13, 15, -5)
        case .pea:
            n.add(sphere(7, mat(hex(0x7ccf3a), rough: 0.4)))
        }
        Junk.protos[self] = n
        return n.clone()
    }
}

final class Pickup {
    enum What { case junk(Junk), eye }
    var netID = -1
    var netTarget: V3?
    let what: What
    var pos: V3
    var vel = V3(0, 0, 0)
    var dynamic: Bool
    var delay: Float = 0
    var bob: Float = frand(0, 6)
    var spin: Float = 0
    var angle: Float = frand(0, 6)
    var life: Float = -1
    let node = SCNNode()
    var eye: Googly?
    var dead = false
    var r: Float

    init(_ w: What, at p: V3, dynamic: Bool = false) {
        what = w
        pos = p
        self.dynamic = dynamic
        switch w {
        case .junk(let j):
            r = j.radius
            node.addChildNode(j.model())
        case .eye:
            r = 14
            var g = Googly(R: 14)
            g.attach(to: node)
            let halo = SCNNode(geometry: { let t = SCNTorus(ringRadius: 22, pipeRadius: 1.5); t.firstMaterial = mat(hex(0xfff6a0), emission: hex(0xfff6a0)); return t }())
            halo.eulerAngles.x = .pi / 2
            node.addChildNode(halo)
            node.constraints = [SCNBillboardConstraint()]
            eye = g
        }
        node.simdPosition = p
    }

    func update(_ dt: Float, world: World) {
        delay -= dt
        if life > 0 { life -= dt; if life <= 0 { dead = true } }
        if dynamic {
            vel.y -= 1900 * dt
            vel.y += world.fanForce(pos) * dt
            var p = pos + vel * dt
            var cts: [Contact] = []
            world.resolve(&p, r, contacts: &cts)
            for ct in cts {
                let vn = dot3(vel, ct.n)
                if vn < 0 { vel -= ct.n * vn * 1.4 }
                vel.x *= 0.96; vel.z *= 0.96
                if ct.n.y > 0.5 { spin *= 0.9 }
            }
            pos = p
            angle += spin * dt
            if pos.y < world.killY { dead = true }
            node.simdPosition = pos
            if eye == nil { node.simdOrientation = simd_quatf(angle: angle, axis: V3(0.3, 1, 0.2).norm) }
        } else {
            bob += dt * 3
            angle += dt * 1.5
            node.simdPosition = pos + V3(0, sinf(bob) * 6, 0)
            if eye == nil { node.simdOrientation = simd_quatf(angle: angle, axis: V3(0, 1, 0)) }
        }
        if var g = eye, let en = g.node {
            let wp = en.presentation.simdWorldPosition
            g.update(wp, u: en.simdWorldRight, v: en.simdWorldUp, dt: dt)
            g.drawPupil()
            eye = g
        }
        if life > 0 && life < 2 { node.opacity = Int(life * 10) % 2 == 0 ? 0.3 : 1 }
    }
}

final class Projectile {
    let junk: Junk
    var pos: V3
    var vel: V3
    var hostile: Bool
    var age: Float = 0
    var spinAxis = V3(frand(-1, 1), frand(-1, 1), frand(-1, 1)).norm
    var angle: Float = 0
    var spin: Float
    var bounces = 0
    var hitIDs: Set<ObjectIdentifier> = []
    var dead = false
    var returning = false
    var owner = -1
    var netID = -1
    var netTarget: V3?
    let node = SCNNode()
    let isPoop: Bool
    var r: Float

    init(_ j: Junk, at p: V3, vel: V3, hostile: Bool = false, poop: Bool = false) {
        junk = j
        pos = p
        self.vel = vel
        self.hostile = hostile
        isPoop = poop
        r = poop ? 9 : j.radius
        spin = frand(-14, 14)
        if poop {
            let s = sphere(9, mat(hex(0xf4f1e6), rough: 0.3))
            s.simdScale = V3(1.1, 0.8, 1.1)
            s.add(sphere(4, mat(hex(0x8a8a80)))).at(2, 5, 3)
            node.addChildNode(s)
        } else {
            node.addChildNode(j.model())
        }
        node.simdPosition = p
    }
}

final class Enemy {
    enum Kind: Int { case cube, pigeon, toaster, boss }
    var netID = -1
    let kind: Kind
    var pos: V3
    var vel = V3(0, 0, 0)
    var r: Float
    var hp: Float
    let maxHP: Float
    var yaw: Float = 0
    var tumble: Float = 0
    var tumbleAxis = V3(1, 0, 0)
    var spin: Float = 0
    var timer: Float = frand(0.5, 1.8)
    var grounded = false
    var stun: Float = 0
    var hurtFlash: Float = 0
    var squash: Float = 0
    var dead = false
    var home: V3
    var eyes: [Googly] = []
    let node = SCNNode()
    let bodyNode = SCNNode()
    var stars: SCNNode?
    var wings: [SCNNode] = []
    var phase = 0
    var spawnedMinis = 0
    var awake = false

    init(_ k: Kind, at p: V3) {
        kind = k
        pos = p
        home = p
        switch k {
        case .cube: r = 30; hp = 3
        case .pigeon: r = 22; hp = 1
        case .toaster: r = 32; hp = 4
        case .boss: r = 105; hp = 40
        }
        maxHP = hp
        node.addChildNode(bodyNode)
        build()
        node.simdPosition = p
    }

    private func eye(_ R: Float, at p: V3, yaw: Float = 0) {
        var g = Googly(R: R)
        g.attach(to: bodyNode)
        g.node?.simdPosition = p
        g.node?.simdOrientation = simd_quatf(angle: yaw, axis: V3(0, 1, 0))
        eyes.append(g)
    }

    private func brows(y: Float, x: Float, z: Float, len: Float, thick: Float) {
        let m = mat(hex(0x1a1a22), rough: 0.5)
        for s in [-1, 1] as [Float] {
            let b = box(CGFloat(len), CGFloat(thick), CGFloat(thick), m, chamfer: CGFloat(thick) * 0.4)
            b.simdPosition = V3(s * x, y, z)
            b.eulerAngles.z = CGFloat(-s * 0.4)
            bodyNode.addChildNode(b)
        }
    }

    private func frown(y: Float, z: Float, w: Float, thick: Float) {
        let m = mat(hex(0x1a1a22), rough: 0.5)
        for s in [-1, 1] as [Float] {
            let b = box(CGFloat(w), CGFloat(thick), CGFloat(thick), m, chamfer: CGFloat(thick) * 0.4)
            b.simdPosition = V3(s * w * 0.42, y - w * 0.12, z)
            b.eulerAngles.z = CGFloat(s * -0.35)
            bodyNode.addChildNode(b)
        }
    }

    private func build() {
        switch kind {
        case .cube, .boss:
            let s = CGFloat(r * 2)
            let boss = kind == .boss
            bodyNode.addChildNode(box(s, s, s, mat(boss ? hex(0x5b4a78) : hex(0x8f9bb3), rough: 0.45), chamfer: s * 0.12))
            let f = r + 0.5
            eye(boss ? 27 : 10, at: V3(-r * 0.36, r * 0.18, f))
            eye(boss ? 27 : 10, at: V3(r * 0.36, r * 0.18, f))
            brows(y: r * 0.18 + (boss ? 36 : 14), x: r * 0.36, z: f + 2, len: boss ? 60 : 22, thick: boss ? 9 : 4)
            frown(y: -r * 0.35, z: f + 1, w: boss ? 50 : 18, thick: boss ? 8 : 3.5)
            if boss {
                let tie = SCNNode(geometry: { () -> SCNShape in
                    let p = NSBezierPath()
                    p.move(to: NSPoint(x: -12, y: 0)); p.line(to: NSPoint(x: 12, y: 0)); p.line(to: NSPoint(x: 18, y: -55))
                    p.line(to: NSPoint(x: 0, y: -72)); p.line(to: NSPoint(x: -18, y: -55)); p.close()
                    let sh = SCNShape(path: p, extrusionDepth: 6)
                    sh.firstMaterial = mat(hex(0xd62a3a), rough: 0.4)
                    return sh
                }())
                tie.simdPosition = V3(0, -r * 0.5 + 20, f + 3)
                bodyNode.addChildNode(tie)
                let gold = mat(hex(0xffc629), rough: 0.25, metal: 1)
                let crown = SCNNode()
                crown.add(cyl(45, 26, gold))
                for k in 0..<6 {
                    let a = Float(k) / 6 * 2 * .pi
                    crown.add(cone(10, 0, 26, gold)).at(cosf(a) * 38, 25, sinf(a) * 38)
                    crown.add(sphere(5, mat(hex(0xe0115f), rough: 0.1))).at(cosf(a) * 45, 0, sinf(a) * 45)
                }
                crown.simdPosition = V3(10, r + 12, 0)
                crown.eulerAngles.z = -0.18
                bodyNode.addChildNode(crown)
            }
        case .toaster:
            let chrome = mat(hex(0xd6dbe4), rough: 0.18, metal: 1)
            bodyNode.add(box(72, 54, 44, chrome, chamfer: 14)).at(0, 2, 0)
            for dx in [-14, 14] as [Float] { bodyNode.add(box(22, 6, 30, mat(hex(0x1a1c20)), chamfer: 2)).at(dx, 27, 0) }
            bodyNode.add(box(10, 16, 8, mat(hex(0x222222)), chamfer: 2)).at(38, 6, 0)
            for dx in [-22, 22] as [Float] { bodyNode.add(box(8, 10, 8, mat(hex(0x333333)))).at(dx, -28, 0) }
            eye(10, at: V3(-13, 5, 22.5))
            eye(10, at: V3(13, 5, 22.5))
            brows(y: 19, x: 13, z: 24, len: 18, thick: 3.5)
            frown(y: -12, z: 23, w: 14, thick: 3)
        case .pigeon:
            let grey = mat(hex(0x8d93a3), rough: 0.7), dark = mat(hex(0x5c6272), rough: 0.7)
            bodyNode.add(sphere(18, grey)).scaled(1.3, 1, 1)
            bodyNode.add(sphere(11, dark)).at(18, 12, 0)
            bodyNode.add(sphere(9, mat(hex(0x5aa37a), rough: 0.3))).at(12, 4, 0)
            let beak = bodyNode.add(cone(3.5, 0.5, 9, mat(hex(0xe8a33a))))
            beak.at(30, 11, 0); beak.eulerAngles.z = -.pi / 2
            let tail = bodyNode.add(box(18, 3, 14, dark, chamfer: 1))
            tail.at(-26, 2, 0); tail.eulerAngles.z = 0.3
            for s in [-1, 1] as [Float] {
                let pivot = SCNNode()
                pivot.simdPosition = V3(0, 6, s * 14)
                let w = sphere(12, dark)
                w.simdScale = V3(1.3, 0.25, 1.4)
                w.simdPosition = V3(0, 0, s * 14)
                pivot.addChildNode(w)
                bodyNode.addChildNode(pivot)
                wings.append(pivot)
            }
            eye(6, at: V3(21, 15, 9), yaw: 0.3)
            eye(6, at: V3(21, 15, -9), yaw: .pi - 0.3)
        }
    }

    func updateEyes(_ dt: Float) {
        for i in eyes.indices {
            guard let n = eyes[i].node else { continue }
            eyes[i].update(n.simdWorldPosition, u: n.simdWorldRight, v: n.simdWorldUp, dt: dt)
            eyes[i].drawPupil()
        }
    }

    func showStars(_ on: Bool) {
        if on && stars == nil {
            let s = SCNNode()
            for i in 0..<3 {
                let st = sphere(5, mat(hex(0xffe14d), emission: hex(0xffc000)), seg: 8)
                let a = Float(i) * 2.09
                st.simdPosition = V3(cosf(a) * 28, 0, sinf(a) * 28)
                s.addChildNode(st)
            }
            s.simdPosition = V3(0, r + 18, 0)
            s.runAction(.repeatForever(.rotateBy(x: 0, y: 6, z: 0, duration: 1)))
            node.addChildNode(s)
            stars = s
        } else if !on, let s = stars {
            s.removeFromParentNode()
            stars = nil
        }
    }
}

/// Confetti, dust, feathers, splats.
final class Particle {
    var pos: V3, vel: V3
    var life: Float, maxLife: Float
    var spin: Float
    var axis = V3(frand(-1, 1), frand(-1, 1), frand(-1, 1)).norm
    var angle: Float = 0
    var gravity: Float
    var drag: Float
    let node: SCNNode
    var shrink: Bool
    init(_ node: SCNNode, pos: V3, vel: V3, life: Float, gravity: Float = -900, spin: Float = 0, drag: Float = 0.5, shrink: Bool = true) {
        self.node = node; self.pos = pos; self.vel = vel; self.life = life; maxLife = life
        self.gravity = gravity; self.spin = spin; self.drag = drag; self.shrink = shrink
        node.simdPosition = pos
    }
}

/// An expanding ground ring from the boss's slam. Jump over it.
final class Shockwave {
    var center: V3
    var radius: Float = 20
    var life: Float = 1.2
    let node: SCNNode
    init(center: V3) {
        self.center = center
        let t = SCNTorus(ringRadius: 20, pipeRadius: 7)
        t.ringSegmentCount = 64
        t.firstMaterial = mat(hex(0xfff0c0), rough: 0.5, emission: hex(0xffa040))
        node = SCNNode(geometry: t)
        node.simdPosition = center
    }
}
