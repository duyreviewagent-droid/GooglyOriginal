import SpriteKit

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
    /// How hard spitting it shoves you backwards.
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
}

final class Pickup {
    enum What { case junk(Junk), eye }
    let what: What
    var pos: V2
    var vel = V2(0, 0)
    var dynamic: Bool
    var delay: Float = 0
    var bob: Float = frand(0, 6)
    var spin: Float = 0
    var angle: Float = 0
    var life: Float = -1          // < 0: forever
    let node = SKNode()
    var eye: Googly?
    var dead = false
    var r: Float

    init(_ w: What, at p: V2, dynamic: Bool = false) {
        what = w
        pos = p
        self.dynamic = dynamic
        switch w {
        case .junk(let j):
            r = j.radius
            let s = SKSpriteNode(texture: emojiTexture(j.emoji, size: 64))
            let px = CGFloat(j.radius * 2.6)
            s.size = CGSize(width: px, height: px)
            node.addChild(s)
        case .eye:
            r = 14
            let glow = SKSpriteNode(texture: radialTexture(64, inner: hex(0xfff6a0, 0.7).cgColor, outer: hex(0xfff6a0, 0).cgColor, mid: 0.2))
            glow.size = CGSize(width: 70, height: 70)
            node.addChild(glow)
            var g = Googly(R: 14)
            g.attach(to: node, z: 1)
            g.node?.position = .zero
            eye = g
        }
        node.zPosition = 30
        node.position = p.cg
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
                let vn = dot(vel, ct.n)
                if vn < 0 { vel -= ct.n * vn * 1.4 }
                vel.x *= 0.96
                if ct.n.y > 0.5 { spin *= 0.9 }
            }
            pos = p
            angle += spin * dt
            if pos.y < world.killY { dead = true }
            node.position = pos.cg
            node.zRotation = CGFloat(angle)
        } else {
            bob += dt * 3
            node.position = CGPoint(x: CGFloat(pos.x), y: CGFloat(pos.y + sinf(bob) * 6))
            node.zRotation = CGFloat(sinf(bob * 0.7) * 0.15)
        }
        if var g = eye {
            // loose eyes also have googly pupils
            g.update(V2(node.position), dt: dt)
            g.pupil?.position = g.p.cg
            eye = g
        }
        if life > 0 && life < 2 { node.alpha = Int(life * 10) % 2 == 0 ? 0.3 : 1 }
    }
}

final class Projectile {
    let junk: Junk
    var pos: V2
    var vel: V2
    var hostile: Bool
    var age: Float = 0
    var angle: Float = 0
    var spin: Float
    var bounces = 0
    var hitIDs: Set<ObjectIdentifier> = []
    var dead = false
    var returning = false
    let node: SKSpriteNode
    let isPoop: Bool
    var r: Float

    init(_ j: Junk, at p: V2, vel: V2, hostile: Bool = false, poop: Bool = false) {
        junk = j
        pos = p
        self.vel = vel
        self.hostile = hostile
        isPoop = poop
        r = poop ? 9 : j.radius
        spin = frand(-14, 14)
        if poop {
            node = SKSpriteNode(texture: Projectile.poopTexture)
            node.size = CGSize(width: 22, height: 22)
        } else {
            node = SKSpriteNode(texture: emojiTexture(j.emoji, size: 64))
            let px = CGFloat(j.radius * 2.6)
            node.size = CGSize(width: px, height: px)
        }
        node.zPosition = 40
        node.position = p.cg
    }

    static let poopTexture: SKTexture = {
        SKTexture(cgImage: makeImage(48, 48) { ctx in
            ctx.setFillColor(hex(0xf4f1e6).cgColor)
            ctx.fillEllipse(in: CGRect(x: 6, y: 8, width: 36, height: 30))
            ctx.setFillColor(hex(0x9a9a8e).cgColor)
            ctx.fillEllipse(in: CGRect(x: 18, y: 18, width: 12, height: 10))
            ctx.setStrokeColor(hex(0x6a6a60).cgColor)
            ctx.setLineWidth(2)
            ctx.strokeEllipse(in: CGRect(x: 6, y: 8, width: 36, height: 30))
        })
    }()
}

final class Enemy {
    enum Kind { case cube, pigeon, toaster, boss }
    let kind: Kind
    var pos: V2
    var vel = V2(0, 0)
    var r: Float
    var hp: Float
    let maxHP: Float
    var angle: Float = 0
    var spin: Float = 0
    var timer: Float = frand(0.5, 1.8)
    var grounded = false
    var facing: Float = -1
    var stun: Float = 0
    var hurtFlash: Float = 0
    var squash: Float = 0
    var dead = false
    var home: V2
    var eyes: [Googly] = []
    let node = SKNode()
    let bodyNode = SKNode()
    var brow = SKShapeNode()
    var mouth = SKShapeNode()
    var stars: SKNode?
    var phase = 0
    var spawnedMinis = 0
    var awake = false

    init(_ k: Kind, at p: V2) {
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
        node.zPosition = 45
        node.addChild(bodyNode)
        build()
        node.position = p.cg
    }

    private func build() {
        switch kind {
        case .cube, .boss:
            let s = CGFloat(r * 2)
            let box = SKShapeNode(rectOf: CGSize(width: s, height: s), cornerRadius: s * 0.14)
            box.fillColor = kind == .boss ? hex(0x5b4a78) : hex(0x8f9bb3)
            box.strokeColor = kind == .boss ? hex(0x2a1f3d) : hex(0x3d4659)
            box.lineWidth = kind == .boss ? 7 : 4
            bodyNode.addChild(box)
            let top = SKShapeNode(rectOf: CGSize(width: s * 0.84, height: s * 0.2), cornerRadius: s * 0.08)
            top.fillColor = hex(0xffffff, 0.18)
            top.strokeColor = .clear
            top.position = CGPoint(x: 0, y: s * 0.32)
            bodyNode.addChild(top)
            if kind == .boss {
                // a tiny corporate necktie
                let tie = SKShapeNode()
                let tp = CGMutablePath()
                tp.move(to: CGPoint(x: -12, y: -40)); tp.addLine(to: CGPoint(x: 12, y: -40))
                tp.addLine(to: CGPoint(x: 18, y: -95)); tp.addLine(to: CGPoint(x: 0, y: -112)); tp.addLine(to: CGPoint(x: -18, y: -95))
                tp.closeSubpath()
                tie.path = tp
                tie.fillColor = hex(0xd62a3a); tie.strokeColor = hex(0x5a0d16); tie.lineWidth = 3
                bodyNode.addChild(tie)
                let crown = SKSpriteNode(texture: emojiTexture("👑", size: 96))
                crown.size = CGSize(width: 90, height: 90)
                crown.position = CGPoint(x: 10, y: CGFloat(r) + 30)
                crown.zRotation = -0.2
                bodyNode.addChild(crown)
            }
            addFace(eyeR: kind == .boss ? 26 : 10, eyeY: r * 0.22, eyeX: r * 0.36, mouthY: -r * 0.3, mouthW: r * 0.5)
        case .toaster:
            let body = SKShapeNode(rectOf: CGSize(width: 72, height: 54), cornerRadius: 18)
            body.fillColor = hex(0xc9ced8)
            body.strokeColor = hex(0x4a505c)
            body.lineWidth = 4
            body.position = CGPoint(x: 0, y: 2)
            bodyNode.addChild(body)
            for dx in [-14, 14] as [CGFloat] {
                let slot = SKShapeNode(rectOf: CGSize(width: 22, height: 6), cornerRadius: 3)
                slot.fillColor = hex(0x2a2d33); slot.strokeColor = .clear
                slot.position = CGPoint(x: dx, y: 27)
                bodyNode.addChild(slot)
            }
            let lever = SKShapeNode(rectOf: CGSize(width: 10, height: 16), cornerRadius: 3)
            lever.fillColor = hex(0x222222); lever.strokeColor = .clear
            lever.position = CGPoint(x: 38, y: 6)
            bodyNode.addChild(lever)
            let shine = SKShapeNode(rectOf: CGSize(width: 50, height: 8), cornerRadius: 4)
            shine.fillColor = hex(0xffffff, 0.5); shine.strokeColor = .clear
            shine.position = CGPoint(x: -4, y: 18)
            bodyNode.addChild(shine)
            for dx in [-22, 22] as [CGFloat] {
                let leg = SKShapeNode(rectOf: CGSize(width: 8, height: 10), cornerRadius: 2)
                leg.fillColor = hex(0x333333); leg.strokeColor = .clear
                leg.position = CGPoint(x: dx, y: -28)
                bodyNode.addChild(leg)
            }
            addFace(eyeR: 10, eyeY: 4, eyeX: 13, mouthY: -14, mouthW: 12)
        case .pigeon:
            let s = SKSpriteNode(texture: emojiTexture("🐦", size: 96))
            s.size = CGSize(width: 60, height: 60)
            s.name = "bird"
            bodyNode.addChild(s)
            var g = Googly(R: 8)
            g.attach(to: bodyNode, z: 2, outline: 1.5)
            g.node?.position = CGPoint(x: -10, y: 12)
            eyes.append(g)
        }
    }

    private func addFace(eyeR: Float, eyeY: Float, eyeX: Float, mouthY: Float, mouthW: Float) {
        for sx in [-1, 1] as [Float] {
            var g = Googly(R: eyeR)
            g.attach(to: bodyNode, z: 2, outline: kind == .boss ? 4 : 2)
            g.node?.position = CGPoint(x: CGFloat(sx * eyeX), y: CGFloat(eyeY))
            eyes.append(g)
        }
        // angry eyebrows
        let bp = CGMutablePath()
        let by = CGFloat(eyeY + eyeR + 3), bx = CGFloat(eyeX)
        bp.move(to: CGPoint(x: -bx - CGFloat(eyeR), y: by + CGFloat(eyeR) * 0.5)); bp.addLine(to: CGPoint(x: -bx * 0.25, y: by - 2))
        bp.move(to: CGPoint(x: bx + CGFloat(eyeR), y: by + CGFloat(eyeR) * 0.5)); bp.addLine(to: CGPoint(x: bx * 0.25, y: by - 2))
        brow.path = bp
        brow.strokeColor = hex(0x1a1a22)
        brow.lineWidth = kind == .boss ? 9 : 4
        brow.lineCap = .round
        brow.zPosition = 3
        bodyNode.addChild(brow)
        let mp = CGMutablePath()
        mp.move(to: CGPoint(x: -CGFloat(mouthW), y: CGFloat(mouthY)))
        mp.addQuadCurve(to: CGPoint(x: CGFloat(mouthW), y: CGFloat(mouthY)), control: CGPoint(x: 0, y: CGFloat(mouthY + mouthW * 0.7)))
        mouth.path = mp
        mouth.strokeColor = hex(0x1a1a22)
        mouth.lineWidth = kind == .boss ? 8 : 3.5
        mouth.lineCap = .round
        mouth.fillColor = .clear
        mouth.zPosition = 3
        bodyNode.addChild(mouth)
    }

    func updateEyes(_ dt: Float) {
        for i in eyes.indices {
            guard let n = eyes[i].node else { continue }
            let world = bodyNode.convert(n.position, to: node.parent ?? node)
            eyes[i].update(V2(world), dt: dt)
            // the pupil lives in the eye's local frame, which rotates with the body
            let local = rot(eyes[i].p, -Float(bodyNode.zRotation + node.zRotation))
            eyes[i].pupil?.position = local.cg
        }
    }

    func showStars(_ on: Bool) {
        if on && stars == nil {
            let s = SKNode()
            for i in 0..<3 {
                let st = SKLabelNode(text: "⭐️")
                st.fontSize = 18
                st.position = CGPoint(x: cos(Double(i) * 2.09) * 26, y: 0)
                s.addChild(st)
            }
            s.position = CGPoint(x: 0, y: CGFloat(r) + 16)
            s.run(.repeatForever(.rotate(byAngle: 6, duration: 1)))
            s.yScale = 0.4
            node.addChild(s)
            stars = s
        } else if !on, let s = stars {
            s.removeFromParent()
            stars = nil
        }
    }
}

/// Confetti, dust, feathers, splats.
final class Particle {
    var pos: V2, vel: V2
    var life: Float, maxLife: Float
    var spin: Float
    var gravity: Float
    var drag: Float
    let node: SKNode
    var shrink: Bool
    init(_ node: SKNode, pos: V2, vel: V2, life: Float, gravity: Float = -900, spin: Float = 0, drag: Float = 0.5, shrink: Bool = true) {
        self.node = node; self.pos = pos; self.vel = vel; self.life = life; maxLife = life
        self.gravity = gravity; self.spin = spin; self.drag = drag; self.shrink = shrink
        node.position = pos.cg
    }
}

/// A projectile shockwave rolling along the ground from the boss.
final class Shockwave {
    var x: Float, y: Float, dir: Float
    var life: Float = 1.0
    let node: SKSpriteNode
    init(x: Float, y: Float, dir: Float) {
        self.x = x; self.y = y; self.dir = dir
        node = SKSpriteNode(texture: emojiTexture("💨", size: 96))
        node.size = CGSize(width: 90, height: 70)
        node.xScale = CGFloat(-dir) * 1
        node.zPosition = 48
    }
}
