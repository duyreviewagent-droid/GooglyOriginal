import SpriteKit

/// The hero: a red jelly person made of a ring of points held together by shape matching,
/// with noodle arms, little shoes and a varying number of googly eyes.
final class Player {
    static let N = 22
    static let pointR: Float = 7
    static let halfW: Float = 36, halfH: Float = 52
    /// Where extra eyes go, in the rest frame (x, y, radius). The first two are the originals.
    static let eyeSlots: [(Float, Float, Float)] = [(-14, 22, 14), (14, 22, 14), (0, 42, 9), (-25, 2, 8), (26, 0, 10),
                                                    (-12, -26, 7), (16, -27, 8), (-27, 34, 7), (29, 32, 6.5), (1, 60, 7)]
    static let maxEyes = 10

    var x = [V2](repeating: .zero, count: N)
    var v = [V2](repeating: .zero, count: N)
    private var pred = [V2](repeating: .zero, count: N)
    private var rest = [V2](repeating: .zero, count: N)
    var restScale = V2(1, 1)
    var scaleTarget = V2(1, 1)
    var c = V2(0, 0)
    var cVel = V2(0, 0)
    var G = M2.identity
    var angle: Float = 0

    var grounded = false
    var coyote: Float = 0
    var groundSolid: Solid?
    var airTime: Float = 0
    var peakFall: Float = 0
    var facing: Float = 1
    var charge: Float = 0
    var charging = false
    var pounding = false
    var invuln: Float = 0
    var ko: Float = 0
    var mouthOpen: Float = 0
    var hurtFace: Float = 0
    var walkPhase: Float = 0
    var aimTimer: Float = 0
    var aimDir = V2(1, 0)
    var inFan = false
    var flushing: Float = -1
    var uprightStrength: Float = 1
    var drawScale: Float = 1

    var eyes: [Googly] = []
    var arms: [[V2]] = [[], []]
    private var armsPrev: [[V2]] = [[], []]

    // nodes
    let root = SKNode()
    private let shadow = SKShapeNode(ellipseOf: CGSize(width: 80, height: 16))
    private let body = SKShapeNode()
    private let shine = SKShapeNode()
    private let blush = SKNode()
    private let mouth = SKShapeNode()
    private let armNodes = [SKShapeNode(), SKShapeNode()]
    private let hands = [SKShapeNode(circleOfRadius: 8), SKShapeNode(circleOfRadius: 8)]
    private let shoes = [SKShapeNode(ellipseOf: CGSize(width: 30, height: 15)), SKShapeNode(ellipseOf: CGSize(width: 30, height: 15))]
    private let chargeRing = SKShapeNode(circleOfRadius: 62)
    private var eyeLayer = SKNode()

    static let red = hex(0xe8262f)
    static let darkRed = hex(0x7a0d16)

    init() {
        for i in 0..<Player.N {
            let t = Float(i) / Float(Player.N) * 2 * .pi
            // superellipse bean, a little wider at the head
            let cx = cosf(t), sy = sinf(t)
            let e: Float = 0.7
            var px = copysignf(powf(abs(cx), e), cx) * Player.halfW
            let py = copysignf(powf(abs(sy), e), sy) * Player.halfH
            px *= 1 + 0.06 * (py / Player.halfH)
            rest[i] = V2(px, py)
        }
        buildNodes()
    }

    private func buildNodes() {
        root.zPosition = 50
        shadow.fillColor = hex(0x000000, 0.22)
        shadow.strokeColor = .clear
        shadow.zPosition = -3
        root.addChild(shadow)
        for a in armNodes {
            a.strokeColor = Player.red
            a.lineWidth = 9
            a.lineCap = .round
            a.lineJoin = .round
            a.fillColor = .clear
            a.zPosition = -1
            root.addChild(a)
        }
        for h in hands {
            h.fillColor = .white
            h.strokeColor = hex(0x333333)
            h.lineWidth = 2
            h.zPosition = -0.5
            root.addChild(h)
        }
        for s in shoes {
            s.fillColor = hex(0x2a2330)
            s.strokeColor = hex(0x100c12)
            s.lineWidth = 2
            s.zPosition = -0.8
            let lace = SKShapeNode(ellipseOf: CGSize(width: 10, height: 4))
            lace.fillColor = hex(0xffffff, 0.8)
            lace.strokeColor = .clear
            lace.position = CGPoint(x: 3, y: 4)
            s.addChild(lace)
            root.addChild(s)
        }
        body.fillColor = Player.red
        body.strokeColor = Player.darkRed
        body.lineWidth = 4
        body.lineJoin = .round
        body.zPosition = 0
        root.addChild(body)
        shine.fillColor = hex(0xffffff, 0.28)
        shine.strokeColor = .clear
        shine.zPosition = 0.5
        root.addChild(shine)
        for sx in [-1, 1] as [CGFloat] {
            let b = SKShapeNode(ellipseOf: CGSize(width: 14, height: 7))
            b.fillColor = hex(0xff8a9a, 0.55)
            b.strokeColor = .clear
            b.position = CGPoint(x: sx * 24, y: 8)
            blush.addChild(b)
        }
        blush.zPosition = 0.6
        root.addChild(blush)
        mouth.fillColor = hex(0x3a0508)
        mouth.strokeColor = hex(0x3a0508)
        mouth.lineWidth = 3
        mouth.lineCap = .round
        mouth.zPosition = 1
        root.addChild(mouth)
        eyeLayer.zPosition = 2
        root.addChild(eyeLayer)
        chargeRing.strokeColor = hex(0xffe14d, 0.8)
        chargeRing.lineWidth = 5
        chargeRing.fillColor = .clear
        chargeRing.zPosition = -2
        chargeRing.alpha = 0
        root.addChild(chargeRing)
    }

    // MARK: Eyes

    func setEyes(_ n: Int) {
        while eyes.count > n { removeEye() }
        while eyes.count < n { addEye() }
    }

    func addEye() {
        guard eyes.count < Player.maxEyes else { return }
        let slot = Player.eyeSlots[eyes.count]
        var g = Googly(R: slot.2)
        g.attach(to: eyeLayer, z: CGFloat(eyes.count) * 0.01)
        g.p = V2(frand(-3, 3), -3)
        let e = eyePos(eyes.count)
        g.reset(e)
        eyes.append(g)
    }

    /// Takes the newest eye off and returns where it was.
    @discardableResult func removeEye() -> V2? {
        guard let last = eyes.popLast() else { return nil }
        last.node?.removeFromParent()
        return eyePos(eyes.count)
    }

    func eyePos(_ i: Int) -> V2 {
        let s = Player.eyeSlots[min(i, Player.eyeSlots.count - 1)]
        return c + G.mul(V2(s.0, s.1) * restScale)
    }

    // MARK: Placement

    func place(at p: V2) {
        restScale = V2(1, 1); scaleTarget = restScale
        G = .identity; angle = 0
        for i in 0..<Player.N { x[i] = p + rest[i]; v[i] = .zero }
        c = p
        cVel = .zero
        pounding = false; charge = 0; charging = false; ko = 0; flushing = -1; drawScale = 1; invuln = 0
        for a in 0..<2 {
            let sh = shoulder(a)
            arms[a] = (0..<6).map { sh + V2(Float(a == 0 ? -1 : 1) * Float($0) * 4, -Float($0) * 9) }
            armsPrev[a] = arms[a]
        }
        for i in eyes.indices { eyes[i].reset(eyePos(i)) }
    }

    private func shoulder(_ a: Int) -> V2 { c + G.mul(V2(a == 0 ? -30 : 30, -4) * restScale) }

    var bottom: Float { x.reduce(Float.infinity) { min($0, $1.y) } - Player.pointR }
    var top: Float { x.reduce(-Float.infinity) { max($0, $1.y) } + Player.pointR }

    // MARK: Physics

    struct Controls {
        var move: Float = 0
        var jump = false
        var squish = false
    }

    enum Event { case jump, superJump(Float), land(Float), pound, poundLand, trampoline, step, fan }

    /// Advances one substep. Returns sound-worthy events.
    func step(_ dt: Float, _ ctl: Controls, _ world: World, events: inout [Event]) {
        let N = Player.N
        let gravity: Float = -1900
        let floppy = ko > 0 || flushing >= 0

        // rest-shape squash & stretch
        restScale += (scaleTarget - restScale) * min(1, 14 * dt)
        scaleTarget += (V2(1, 1) - scaleTarget) * min(1, 6 * dt)
        if charging { scaleTarget = V2(1 + 0.42 * charge, 1 - 0.46 * charge) }

        // forces
        var avg = V2(0, 0)
        for i in 0..<N { avg += v[i] }
        avg /= Float(N)
        inFan = false
        for i in 0..<N {
            var g = gravity
            let f = world.fanForce(x[i])
            if f > 0 { g += f; inFan = true }
            if pounding { g *= 1.6 }
            v[i].y += g * dt
        }
        if !floppy {
            let maxSpeed: Float = charging ? 90 : 430
            let target = ctl.move * maxSpeed
            let accel: Float = grounded ? 10 : 4.2
            var dvx = (target - avg.x) * min(1, accel * dt)
            if ctl.move == 0 && !grounded { dvx *= 0.25 }
            if ctl.move != 0 { facing = ctl.move > 0 ? 1 : -1 }
            for i in 0..<N { v[i].x += dvx }
        }

        // jump
        if !floppy && ctl.jump && (grounded || coyote > 0) && !charging {
            for i in 0..<N { v[i].y = max(v[i].y, 0) + 760 }
            scaleTarget = V2(0.78, 1.3)
            restScale = V2(0.9, 1.12)
            coyote = 0
            grounded = false
            events.append(.jump)
        }

        // predict
        for i in 0..<N { pred[i] = x[i] + v[i] * dt }

        // shape matching
        var cm = V2(0, 0)
        for i in 0..<N { cm += pred[i] }
        cm /= Float(N)
        var apq = M2(a: 0, b: 0, c: 0, d: 0), aqq = M2(a: 0, b: 0, c: 0, d: 0)
        for i in 0..<N {
            let q = rest[i] * restScale
            let p = pred[i] - cm
            apq.a += p.x * q.x; apq.c += p.x * q.y
            apq.b += p.y * q.x; apq.d += p.y * q.y
            aqq.a += q.x * q.x; aqq.c += q.x * q.y
            aqq.b += q.y * q.x; aqq.d += q.y * q.y
        }
        let theta = atan2f(apq.b - apq.c, apq.a + apq.d)
        angle = theta
        var lean: Float = 0
        if !floppy {
            lean = -ctl.move * 0.2
            if charging { lean = 0 }
        }
        let upK: Float = floppy ? 0 : (0.07 * uprightStrength)
        let thetaG = theta + wrapAngle(lean - theta) * upK
        let R = M2.rotation(thetaG)
        var lin = apq.mul(aqq.inverse)
        let det = lin.det
        if det > 0.05 { lin = lin * (1 / sqrtf(det)) } else { lin = R }
        let beta: Float = floppy ? 0.5 : 0.3
        let Gm = lin * beta + R * (1 - beta)
        G = Gm
        let stiff: Float = floppy ? 0.06 : 0.2
        for i in 0..<N {
            let goal = cm + Gm.mul(rest[i] * restScale)
            pred[i] += (goal - pred[i]) * stiff
        }

        // collisions
        let wasGrounded = grounded
        grounded = false
        groundSolid = nil
        var contacts: [Contact] = []
        var bounced = false
        let prevFall = -avg.y
        for i in 0..<N {
            let vPre = (pred[i] - x[i]) / dt
            contacts.removeAll(keepingCapacity: true)
            world.resolve(&pred[i], Player.pointR, contacts: &contacts)
            if contacts.isEmpty { v[i] = vPre; x[i] = pred[i]; continue }
            var nv = (pred[i] - x[i]) / dt
            for ct in contacts {
                let n = ct.n
                let sv = ct.solid.vel
                let rel = nv - sv
                let vn = dot(rel, n)
                var vt = rel - n * vn
                let movingOnIt = ctl.move != 0 && !floppy
                let fr = ct.solid.kind == .ice ? ct.solid.friction : (movingOnIt ? 0.02 : (floppy ? 0.06 : 0.16))
                vt *= 1 - fr
                var vnOut = max(vn, 0)
                if ct.solid.kind == .bouncy && n.y > 0.5 {
                    let pre = -dot(vPre - sv, n)
                    vnOut = max(pre * 0.9, 1250)
                    bounced = true
                    ct.solid.squash = 1
                }
                nv = sv + vt + n * vnOut
                if n.y > 0.55 {
                    grounded = true
                    groundSolid = ct.solid
                }
            }
            v[i] = nv
            x[i] = pred[i]
        }
        if bounced {
            for i in 0..<N { v[i].y = max(v[i].y, 1250) }
            scaleTarget = V2(0.7, 1.4)
            grounded = false
            pounding = false
            events.append(.trampoline)
        }
        for i in 0..<N { v[i] *= 1 - 0.25 * dt }

        // centre
        var nc = V2(0, 0)
        for i in 0..<N { nc += x[i] }
        nc /= Float(N)
        cVel = (nc - c) / dt
        c = nc

        if grounded {
            if !wasGrounded {
                let impact = max(prevFall, peakFall)
                if pounding {
                    events.append(.poundLand)
                    scaleTarget = V2(1.6, 0.45)
                    pounding = false
                } else if impact > 250 {
                    events.append(.land(impact))
                    let k = min(1, impact / 1400)
                    scaleTarget = V2(1 + 0.45 * k, 1 - 0.4 * k)
                }
            }
            coyote = 0.1
            airTime = 0
            peakFall = 0
        } else {
            coyote -= dt
            airTime += dt
            peakFall = max(peakFall, -avg.y)
        }

        // squish charge & release (super jump) / ground pound in the air
        if !floppy {
            if ctl.squish && grounded {
                charging = true
                charge = min(1, charge + dt * 1.5)
            } else if charging {
                charging = false
                if charge > 0.2 && (grounded || coyote > 0) {
                    let k = charge
                    for i in 0..<N { v[i].y = max(v[i].y, 0) + 380 + 300 * k }
                    restScale = V2(0.92, 1.12)
                    scaleTarget = V2(0.75, 1.35)
                    grounded = false
                    coyote = 0
                    events.append(.superJump(k))
                }
                charge = 0
            }
            if ctl.squish && !grounded && !pounding && airTime > 0.12 && !charging {
                pounding = true
                for i in 0..<N { v[i] = V2(v[i].x * 0.3, min(v[i].y, -1300)) }
                scaleTarget = V2(0.8, 1.2)
                events.append(.pound)
            }
        }
        if grounded && abs(avg.x) > 60 && !charging {
            let before = walkPhase
            walkPhase += abs(avg.x) * dt * 0.035
            if floorf(before / .pi) != floorf(walkPhase / .pi) { events.append(.step) }
        }
    }

    /// Being flushed: the body is posed directly, spinning and shrinking into the bowl.
    func flushPose(center: V2, scale s: Float, angle a: Float) {
        G = M2.rotation(a) * s
        c = center
        cVel = .zero
        angle = a
        for i in 0..<Player.N { x[i] = center + G.mul(rest[i]); v[i] = .zero }
        drawScale = s
        grounded = false
    }

    /// Adds a velocity to every point, plus a spin.
    func shove(_ dv: V2, spin: Float = 0) {
        for i in 0..<Player.N {
            v[i] += dv + (x[i] - c).perp * spin
        }
        pounding = false
        charging = false
        charge = 0
    }

    // MARK: Per-frame visuals

    func frame(_ dt: Float, world: World, t: Float) {
        // arms: verlet noodles hanging from the shoulders
        for a in 0..<2 {
            var pts = arms[a], prev = armsPrev[a]
            guard pts.count == 6 else { continue }
            let sh = shoulder(a)
            pts[0] = sh
            let side: Float = a == 0 ? -1 : 1
            let aimSide = (aimDir.x >= 0) == (a == 1)
            for i in 1..<pts.count {
                let vel = (pts[i] - prev[i]) * 0.9
                prev[i] = pts[i]
                pts[i] += vel + V2(side * 180, -700) * dt * dt
                if aimTimer > 0 && aimSide {
                    let goal = sh + aimDir * Float(i) * 11
                    pts[i] += (goal - pts[i]) * 0.5
                }
                if flushing < 0 && ko <= 0 && !grounded && aimTimer <= 0 {
                    // flail upward when flying
                    pts[i] += V2(side * 60, 260 + sinf(t * 18 + Float(i) + side) * 120) * dt * dt * 6
                }
            }
            for _ in 0..<3 {
                pts[0] = sh
                for i in 1..<pts.count {
                    let d = pts[i] - pts[i - 1]
                    let l = d.len
                    if l > 1e-4 {
                        let corr = d * ((l - 10) / l)
                        if i == 1 { pts[i] -= corr } else { pts[i] -= corr * 0.5; pts[i - 1] += corr * 0.5 }
                    }
                }
            }
            arms[a] = pts; armsPrev[a] = prev
        }
        aimTimer -= dt

        // eyes
        for i in eyes.indices { eyes[i].update(eyePos(i), dt: dt) }

        mouthOpen = max(0, mouthOpen - dt * 3)
        hurtFace = max(0, hurtFace - dt)
        invuln = max(0, invuln - dt)
    }

    func jolt() {
        for i in eyes.indices { eyes[i].jolt(V2(frand(-500, 500), frand(200, 700))) }
    }

    func draw(world: World, t: Float) {
        body.path = smoothClosedPath(x)
        // highlight: a smaller copy of the outline shifted up-left
        var hl: [V2] = []
        hl.reserveCapacity(Player.N)
        for i in 0..<Player.N { hl.append(c + (x[i] - c) * 0.55 + G.mul(V2(-11, 18))) }
        shine.path = smoothClosedPath(hl)
        shine.alpha = 0.9

        let blushPos = c + G.mul(V2(0, 4) * restScale)
        blush.position = blushPos.cg
        blush.zRotation = CGFloat(angle)

        // mouth
        let mc = c + G.mul(V2(0, -4) * restScale)
        let mx = G.mul(V2(1, 0)), my = G.mul(V2(0, 1))
        let mp = CGMutablePath()
        let w: Float = 11
        if hurtFace > 0 || ko > 0 {
            // wobbly grimace
            mp.move(to: (mc - mx * w).cg)
            for k in 1...6 {
                let f = Float(k) / 6
                mp.addLine(to: (mc - mx * w + mx * (2 * w * f) + my * (k % 2 == 0 ? 3 : -3)).cg)
            }
            mouth.fillColor = .clear
        } else if mouthOpen > 0.05 || !grounded || charging {
            let o = max(mouthOpen, grounded ? 0.5 : 0.8)
            let h = 4 + 10 * o
            let ww = charging ? w * 1.2 : w * 0.7
            mp.addEllipse(in: CGRect(x: -CGFloat(ww), y: -CGFloat(h) / 2, width: CGFloat(ww * 2), height: CGFloat(h)),
                          transform: CGAffineTransform(a: CGFloat(mx.x), b: CGFloat(mx.y), c: CGFloat(my.x), d: CGFloat(my.y),
                                                       tx: CGFloat(mc.x), ty: CGFloat(mc.y)))
            mouth.fillColor = hex(0x3a0508)
        } else {
            mp.move(to: (mc - mx * w + my * 3).cg)
            mp.addQuadCurve(to: (mc + mx * w + my * 3).cg, control: (mc - my * 8).cg)
            mouth.fillColor = .clear
        }
        mouth.path = mp

        // eyes
        for i in eyes.indices { eyes[i].draw(at: eyePos(i), scale: drawScale) }
        let limbs: CGFloat = drawScale < 0.98 ? 0 : 1
        for n in armNodes { n.alpha = limbs }
        for n in hands { n.alpha = limbs }
        for n in shoes { n.alpha = limbs }

        // arms, hands
        for a in 0..<2 where arms[a].count > 1 {
            armNodes[a].path = smoothOpenPath(arms[a])
            hands[a].position = arms[a].last!.cg
        }

        // shoes at the bottom-left and bottom-right of the body
        let bl = x[Int(Double(Player.N) * 0.68)], br = x[Int(Double(Player.N) * 0.82)]
        let lift = grounded ? max(0, sinf(walkPhase)) * 9 : 0, lift2 = grounded ? max(0, -sinf(walkPhase)) * 9 : 0
        let down = G.mul(V2(0, -1))
        shoes[0].position = (bl + down * 2 + V2(facing * 5, lift)).cg
        shoes[1].position = (br + down * 2 + V2(facing * 5, lift2)).cg
        for s in shoes {
            s.xScale = CGFloat(facing)
            s.zRotation = CGFloat(angle * 0.5)
        }

        // shadow on the ground below
        if let gy = world.groundBelow(c.x, c.y) {
            let h = max(0, bottom - gy)
            let k = max(0.2, 1 - h / 500)
            shadow.position = CGPoint(x: CGFloat(c.x), y: CGFloat(gy + 2))
            shadow.setScale(CGFloat(k))
            shadow.alpha = CGFloat(k)
        } else { shadow.alpha = 0 }

        chargeRing.position = c.cg
        chargeRing.alpha = charging ? CGFloat(0.3 + charge * 0.7) : 0
        chargeRing.setScale(CGFloat(1.3 - charge * 0.45 + sinf(t * 40) * 0.03 * charge))

        let flash = invuln > 0 && Int(t * 16) % 2 == 0
        root.alpha = flash ? 0.45 : 1
        body.fillColor = ko > 0 ? hex(0xb8242c) : Player.red
    }
}
