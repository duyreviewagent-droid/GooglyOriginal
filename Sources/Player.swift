import SceneKit

/// The hero: a red jelly person. A shell of points is held together by 3D shape matching; a
/// smooth mesh is skinned to those points, so every squash, stretch and wobble shows. He has noodle
/// arms, little shoes and a varying number of googly eyes.
final class Player {
    static let segs = 12, rings = 7
    static let N = segs * rings + 2
    static let pointR: Float = 7
    static let halfW: Float = 36, halfH: Float = 52, halfD: Float = 33
    /// Eye slots on the body surface: (longitude°, latitude°, radius). Longitude 90° is the face.
    static let eyeSlots: [(Float, Float, Float)] = [(70, 22, 13), (110, 22, 13), (90, 44, 8.5), (38, 2, 8), (142, -2, 9.5),
                                                    (72, -30, 7), (112, -31, 7.5), (48, 40, 7), (132, 38, 6.5), (270, 18, 11)]
    static let maxEyes = 10

    var x = [V3](repeating: .zero, count: N)
    var v = [V3](repeating: .zero, count: N)
    private var pred = [V3](repeating: .zero, count: N)
    private var rest = [V3](repeating: .zero, count: N)
    var restScale = V3(1, 1, 1)
    var scaleTarget = V3(1, 1, 1)
    var c = V3(0, 0, 0)
    var cVel = V3(0, 0, 0)
    var G = M3(1)
    var rotQ = simd_quatf(angle: 0, axis: V3(0, 1, 0))
    var yaw: Float = 0
    var moveDir = V3(1, 0, 0)

    var grounded = false
    var coyote: Float = 0
    var airTime: Float = 0
    var peakFall: Float = 0
    var charge: Float = 0
    var charging = false
    var pounding = false
    var invuln: Float = 0
    var ko: Float = 0
    var mouthOpen: Float = 0
    var hurtFace: Float = 0
    var walkPhase: Float = 0
    var aimTimer: Float = 0
    var aimDir = V3(1, 0, 0)
    var inFan = false
    var flushing: Float = -1
    var drawScale: Float = 1
    var upright: Float { simd_dot(G.columns.1.norm, V3(0, 1, 0)) }

    var eyes: [Googly] = []
    var arms: [[V3]] = [[], []]
    private var armsPrev: [[V3]] = [[], []]

    // skinning
    private struct Skin { var rest: V3; var off: V3; var idx: (Int, Int, Int, Int); var w: (Float, Float, Float, Float) }
    private var meshSkin: [Skin] = []
    private var meshIndices: [Int32] = []
    private var slotSkin: [Skin] = []
    private var slotNormals: [V3] = []
    private var mouthSkin: Skin!
    private var mouthNormal = V3(0, 0, 1)
    private var shoulderSkin: [Skin] = []
    private var footSkin: [Skin] = []

    // nodes
    let root = SCNNode()
    private let bodyNode = SCNNode()
    private let bodyMat: SCNMaterial
    private let shadow: SCNNode
    private let mouthNode: SCNNode
    private var armBeads: [[SCNNode]] = [[], []]
    private var hands: [SCNNode] = []
    private var shoes: [SCNNode] = []
    private let chargeRing: SCNNode

    static let red = hex(0xe8262f)
    static let darkRed = hex(0x7a0d16)
    /// Player colours: red, blue, green, yellow.
    static let colors: [NSColor] = [hex(0xe8262f), hex(0x2f7df0), hex(0x2fbf4a), hex(0xffc21f)]
    static let colorNames = ["RED", "BLU", "GUS", "SUNNY"]
    let color: NSColor
    private let glow: NSColor

    static func shape(_ lon: Float, _ lat: Float) -> V3 {
        let d = V3(cosf(lat) * cosf(lon), sinf(lat), cosf(lat) * sinf(lon))
        let e: Float = 0.78
        func sp(_ a: Float) -> Float { copysignf(powf(abs(a), e), a) }
        var p = V3(sp(d.x) * halfW, sp(d.y) * halfH, sp(d.z) * halfD)
        let k = 1 + 0.07 * (p.y / halfH)
        p.x *= k; p.z *= k
        return p
    }
    static func restNormal(_ p: V3) -> V3 { V3(p.x / (halfW * halfW), p.y / (halfH * halfH), p.z / (halfD * halfD)).norm }

    init(color: NSColor = Player.red) {
        self.color = color
        glow = color.blended(withFraction: 0.82, of: .black) ?? hex(0x3a0206)
        var k = 0
        rest[k] = Player.shape(0, -.pi / 2); k += 1
        for r in 0..<Player.rings {
            let lat = -Float.pi / 2 + Float.pi * Float(r + 1) / Float(Player.rings + 1)
            for s in 0..<Player.segs {
                let lon = Float(s) / Float(Player.segs) * 2 * .pi + (r % 2 == 0 ? 0 : .pi / Float(Player.segs))
                rest[k] = Player.shape(lon, lat); k += 1
            }
        }
        rest[k] = Player.shape(0, .pi / 2)

        bodyMat = SCNMaterial()
        bodyMat.lightingModel = .physicallyBased
        bodyMat.diffuse.contents = color
        bodyMat.roughness.contents = 0.28
        bodyMat.metalness.contents = 0
        bodyMat.clearCoat.contents = 0.7
        bodyMat.clearCoatRoughness.contents = 0.08
        bodyMat.emission.contents = glow

        let sm = SCNMaterial()
        sm.diffuse.contents = radialTexture(128, inner: NSColor(white: 0, alpha: 0.5).cgColor, outer: NSColor(white: 0, alpha: 0).cgColor, mid: 0.2)
        sm.lightingModel = .constant
        sm.writesToDepthBuffer = false
        let sp = SCNPlane(width: 90, height: 90)
        sp.firstMaterial = sm
        shadow = SCNNode(geometry: sp)
        shadow.eulerAngles.x = -.pi / 2
        shadow.renderingOrder = -5
        mouthNode = sphere(1, mat(hex(0x3a0508), rough: 0.4))
        let ring = SCNTorus(ringRadius: 55, pipeRadius: 3)
        ring.firstMaterial = mat(hex(0xffe14d), rough: 0.3, emission: hex(0x806000))
        chargeRing = SCNNode(geometry: ring)
        buildSkins()
        buildNodes()
    }

    private func skin(_ p: V3) -> Skin {
        var best: [(Float, Int)] = []
        for i in 0..<Player.N { best.append((simd_length(rest[i] - p), i)) }
        best.sort { $0.0 < $1.0 }
        let b = Array(best.prefix(4))
        var w = b.map { 1 / max(0.5, $0.0) }
        let s = w.reduce(0, +)
        w = w.map { $0 / s }
        var off = p
        for k in 0..<4 { off -= rest[b[k].1] * w[k] }
        return Skin(rest: p, off: off, idx: (b[0].1, b[1].1, b[2].1, b[3].1), w: (w[0], w[1], w[2], w[3]))
    }

    private func buildSkins() {
        let S = 30, Rn = 22
        meshSkin.append(skin(Player.shape(0, -.pi / 2)))
        for r in 0..<Rn {
            let lat = -Float.pi / 2 + Float.pi * Float(r + 1) / Float(Rn + 1)
            for s in 0..<S { meshSkin.append(skin(Player.shape(Float(s) / Float(S) * 2 * .pi, lat))) }
        }
        meshSkin.append(skin(Player.shape(0, .pi / 2)))
        let top = Int32(meshSkin.count - 1)
        func v(_ r: Int, _ s: Int) -> Int32 { Int32(1 + r * S + (s % S)) }
        for s in 0..<S { meshIndices += [0, v(0, s + 1), v(0, s)] }
        for r in 0..<(Rn - 1) {
            for s in 0..<S {
                meshIndices += [v(r, s), v(r, s + 1), v(r + 1, s + 1), v(r, s), v(r + 1, s + 1), v(r + 1, s)]
            }
        }
        for s in 0..<S { meshIndices += [v(Rn - 1, s), v(Rn - 1, s + 1), top] }
        let deg = Float.pi / 180
        for sl in Player.eyeSlots {
            let p = Player.shape(sl.0 * deg, sl.1 * deg)
            slotSkin.append(skin(p))
            slotNormals.append(Player.restNormal(p))
        }
        let m = Player.shape(90 * deg, -6 * deg)
        mouthSkin = skin(m)
        mouthNormal = Player.restNormal(m)
        shoulderSkin = [skin(Player.shape(180 * deg, -8 * deg)), skin(Player.shape(0, -8 * deg))]
        footSkin = [skin(Player.shape(125 * deg, -68 * deg)), skin(Player.shape(55 * deg, -68 * deg))]
    }

    @inline(__always) private func skinned(_ s: Skin) -> V3 {
        // = c + G·rest + Σ w (x_k − (c + G·rest_k)), with Σ w = 1
        var p: V3 = G * s.off
        p += x[s.idx.0] * s.w.0
        p += x[s.idx.1] * s.w.1
        p += x[s.idx.2] * s.w.2
        p += x[s.idx.3] * s.w.3
        return p
    }

    private func buildNodes() {
        root.addChildNode(bodyNode)
        root.addChildNode(shadow)
        root.addChildNode(mouthNode)
        root.addChildNode(chargeRing)
        chargeRing.opacity = 0
        let armMat = mat(color, rough: 0.35)
        let glove = mat(.white, rough: 0.5)
        for a in 0..<2 {
            for _ in 0..<11 { let b = sphere(5, armMat, seg: 10); root.addChildNode(b); armBeads[a].append(b) }
            let h = sphere(8.5, glove, seg: 14)
            root.addChildNode(h)
            hands.append(h)
        }
        let shoeMat = mat(hex(0x2a2330), rough: 0.4)
        for _ in 0..<2 {
            let s = sphere(1, shoeMat, seg: 16)
            let lace = sphere(1, mat(.white, rough: 0.6), seg: 8)
            lace.simdScale = V3(0.35, 0.25, 0.3)
            lace.simdPosition = V3(0, 0.55, 0.35)
            s.addChildNode(lace)
            root.addChildNode(s)
            shoes.append(s)
        }
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
        g.attach(to: root)
        g.p = V2(frand(-3, 3), -3)
        g.reset(eyeFrame(eyes.count).0)
        eyes.append(g)
        drawEyes()
    }

    /// Takes the newest eye off and returns where it was.
    @discardableResult func removeEye() -> V3? {
        guard let last = eyes.popLast() else { return nil }
        last.node?.removeFromParentNode()
        return eyeFrame(eyes.count).0
    }

    /// Eye centre, outward normal, in-plane right and up.
    func eyeFrame(_ i: Int) -> (V3, V3, V3, V3) {
        let k = min(i, Player.eyeSlots.count - 1)
        return frame(skinned(slotSkin[k]), slotNormals[k], lift: 1.5)
    }

    private func frame(_ p: V3, _ n0: V3, lift: Float) -> (V3, V3, V3, V3) {
        let n = (G * n0).norm
        let upHint = (G * V3(0, 1, 0)).norm
        var r = simd_cross(upHint, n)
        if r.len < 1e-3 { r = simd_cross(V3(0, 0, 1), n) }
        r = r.norm
        let u = simd_cross(n, r)
        return (p + n * lift, n, r, u)
    }

    // MARK: Placement

    func place(at p: V3) {
        restScale = V3(1, 1, 1); scaleTarget = restScale
        G = M3(1)
        rotQ = simd_quatf(angle: 0, axis: V3(0, 1, 0))
        yaw = 0.5
        for i in 0..<Player.N { x[i] = p + rest[i]; v[i] = .zero }
        c = p
        cVel = .zero
        pounding = false; charge = 0; charging = false; ko = 0; flushing = -1; drawScale = 1; invuln = 0
        for a in 0..<2 {
            let sh = skinned(shoulderSkin[a])
            arms[a] = (0..<7).map { sh + V3(0, -Float($0) * 9, 0) }
            armsPrev[a] = arms[a]
        }
        for i in eyes.indices { eyes[i].reset(eyeFrame(i).0) }
    }

    var bottom: Float { x.reduce(Float.infinity) { min($0, $1.y) } - Player.pointR }
    var top: Float { x.reduce(-Float.infinity) { max($0, $1.y) } + Player.pointR }

    // MARK: Physics

    struct Controls {
        var move = V2(0, 0)     // world x, z
        var jump = false
        var squish = false
    }

    enum Event { case jump, superJump(Float), land(Float), pound, poundLand, trampoline, step }

    /// Advances one substep, appending sound-worthy events.
    func step(_ dt: Float, _ ctl: Controls, _ world: World, events: inout [Event]) {
        let N = Player.N
        let gravity: Float = -1900
        let floppy = ko > 0 || flushing >= 0

        restScale += (scaleTarget - restScale) * min(1, 14 * dt)
        scaleTarget += (V3(1, 1, 1) - scaleTarget) * min(1, 6 * dt)
        if charging { scaleTarget = V3(1 + 0.42 * charge, 1 - 0.46 * charge, 1 + 0.42 * charge) }

        var avg = V3(0, 0, 0)
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
        let moving = ctl.move.len > 0.1
        if !floppy {
            let maxSpeed: Float = charging ? 90 : 430
            let target = ctl.move * maxSpeed
            let accel: Float = grounded ? 10 : 4.2
            var dv = (target - avg.xz) * min(1, accel * dt)
            if !moving && !grounded { dv *= 0.25 }
            if moving {
                moveDir = V3(ctl.move.x, 0, ctl.move.y).norm
                let want = clampf(atan2f(moveDir.x, moveDir.z), -1.35, 1.35)
                yaw += wrapAngle(want - yaw) * min(1, 8 * dt)
            }
            for i in 0..<N { v[i].x += dv.x; v[i].z += dv.y }
        }

        if !floppy && ctl.jump && (grounded || coyote > 0) && !charging {
            for i in 0..<N { v[i].y = max(v[i].y, 0) + 760 }
            scaleTarget = V3(0.78, 1.3, 0.78)
            restScale = V3(0.9, 1.12, 0.9)
            coyote = 0
            grounded = false
            events.append(.jump)
        }

        for i in 0..<N { pred[i] = x[i] + v[i] * dt }

        // shape matching
        var cm = V3(0, 0, 0)
        for i in 0..<N { cm += pred[i] }
        cm /= Float(N)
        var apq = M3(0), aqq = M3(0)
        for i in 0..<N {
            let q = rest[i] * restScale
            let p = pred[i] - cm
            apq.columns.0 += p * q.x; apq.columns.1 += p * q.y; apq.columns.2 += p * q.z
            aqq.columns.0 += q * q.x; aqq.columns.1 += q * q.y; aqq.columns.2 += q * q.z
        }
        rotQ = extractRotation(apq, rotQ)
        var desired = simd_quatf(angle: yaw, axis: V3(0, 1, 0))
        if moving && !charging && !floppy {
            let axis = V3(moveDir.z, 0, -moveDir.x)
            desired = simd_quatf(angle: 0.2, axis: axis) * desired
        }
        let upK: Float = floppy ? 0 : 0.07
        let qGoal = upK > 0 ? simd_slerp(rotQ, desired, upK) : rotQ
        let Rm = M3(qGoal)
        var lin = apq * aqq.inverse
        let det = lin.determinant
        if det > 0.05 { lin = lin * (1 / cbrtf(det)) } else { lin = Rm }
        let beta: Float = floppy ? 0.5 : 0.3
        let Gm = lin * beta + Rm * (1 - beta)
        G = Gm
        let stiff: Float = floppy ? 0.06 : 0.2
        for i in 0..<N {
            let goal = cm + Gm * (rest[i] * restScale)
            pred[i] += (goal - pred[i]) * stiff
        }

        // collisions
        let wasGrounded = grounded
        grounded = false
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
                let vn = dot3(rel, n)
                var vt = rel - n * vn
                let fr = ct.solid.kind == .ice ? ct.solid.friction : (moving && !floppy ? 0.02 : (floppy ? 0.06 : 0.16))
                vt *= 1 - fr
                var vnOut = max(vn, 0)
                if ct.solid.kind == .bouncy && n.y > 0.5 {
                    vnOut = max(-dot3(vPre - sv, n) * 0.9, 1250)
                    bounced = true
                    ct.solid.squash = 1
                }
                nv = sv + vt + n * vnOut
                if n.y > 0.55 { grounded = true }
            }
            v[i] = nv
            x[i] = pred[i]
        }
        if bounced {
            for i in 0..<N { v[i].y = max(v[i].y, 1250) }
            scaleTarget = V3(0.7, 1.4, 0.7)
            grounded = false
            pounding = false
            events.append(.trampoline)
        }
        for i in 0..<N { v[i] *= 1 - 0.25 * dt }

        var nc = V3(0, 0, 0)
        for i in 0..<N { nc += x[i] }
        nc /= Float(N)
        cVel = (nc - c) / dt
        c = nc

        if grounded {
            if !wasGrounded {
                let impact = max(prevFall, peakFall)
                if pounding {
                    events.append(.poundLand)
                    scaleTarget = V3(1.6, 0.45, 1.6)
                    pounding = false
                } else if impact > 250 {
                    events.append(.land(impact))
                    let k = min(1, impact / 1400)
                    scaleTarget = V3(1 + 0.45 * k, 1 - 0.4 * k, 1 + 0.45 * k)
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

        if !floppy {
            if ctl.squish && grounded {
                charging = true
                charge = min(1, charge + dt * 1.5)
            } else if charging {
                charging = false
                if charge > 0.2 && (grounded || coyote > 0) {
                    let k = charge
                    for i in 0..<N { v[i].y = max(v[i].y, 0) + 380 + 300 * k }
                    restScale = V3(0.92, 1.12, 0.92)
                    scaleTarget = V3(0.75, 1.35, 0.75)
                    grounded = false
                    coyote = 0
                    events.append(.superJump(k))
                }
                charge = 0
            }
            if ctl.squish && !grounded && !pounding && airTime > 0.12 && !charging {
                pounding = true
                for i in 0..<N { v[i] = V3(v[i].x * 0.3, min(v[i].y, -1300), v[i].z * 0.3) }
                scaleTarget = V3(0.8, 1.2, 0.8)
                events.append(.pound)
            }
        }
        let hs = avg.xz.len
        if grounded && hs > 60 && !charging {
            let before = walkPhase
            walkPhase += hs * dt * 0.035
            if floorf(before / .pi) != floorf(walkPhase / .pi) { events.append(.step) }
        }
    }

    /// Moves the whole body without disturbing its shape or velocity.
    func translate(_ d: V3) {
        for i in 0..<Player.N { x[i] += d }
        c += d
        for a in 0..<2 { for k in arms[a].indices { arms[a][k] += d; armsPrev[a][k] += d } }
    }

    /// Adds a velocity to every point, plus a spin about `axis`.
    func shove(_ dv: V3, spin: Float = 0, axis: V3 = V3(0, 0, 1)) {
        for i in 0..<Player.N {
            v[i] += dv + simd_cross(axis, x[i] - c) * spin
        }
        pounding = false
        charging = false
        charge = 0
    }

    /// Keeps this body's points out of another jelly (treated as an ellipsoid). Returns true if standing on it.
    @discardableResult func pushOut(of o: Player) -> Bool {
        if simd_length(c - o.c) > 160 || o.flushing >= 0 || flushing >= 0 { return false }
        var standing = false
        let ax: Float = 38, ay: Float = 54, az: Float = 35
        for i in 0..<Player.N {
            let d = x[i] - o.c
            let q = V3(d.x / ax, d.y / ay, d.z / az)
            let l = q.len
            guard l < 1, l > 1e-4 else { continue }
            let n = V3(q.x / ax, q.y / ay, q.z / az).norm
            let target = o.c + V3(q.x * ax, q.y * ay, q.z * az) / l
            x[i] += (target - x[i]) * 0.5
            let rel = v[i] - o.cVel
            let vn = dot3(rel, n)
            if vn < 0 { v[i] -= n * vn * 0.8 }
            if n.y > 0.6 { standing = true }
        }
        if standing { grounded = true; coyote = 0.1 }
        return standing
    }

    /// Being flushed: posed directly, spinning and shrinking into the bowl.
    func flushPose(center: V3, scale s: Float, angle a: Float) {
        G = M3(simd_quatf(angle: a, axis: V3(0, 1, 0))) * s
        c = center
        cVel = .zero
        for i in 0..<Player.N { x[i] = center + G * rest[i]; v[i] = .zero }
        drawScale = s
        grounded = false
    }

    // MARK: Per-frame visuals

    func frame(_ dt: Float, world: World, t: Float) {
        for a in 0..<2 {
            var pts = arms[a], prev = armsPrev[a]
            guard pts.count == 7 else { continue }
            let sh = skinned(shoulderSkin[a])
            let side = (G * V3(a == 0 ? -1 : 1, 0, 0)).norm
            let aimSide = a == 1
            pts[0] = sh
            for i in 1..<pts.count {
                let vel = (pts[i] - prev[i]) * 0.9
                prev[i] = pts[i]
                pts[i] += vel + (side * 420 + V3(0, -500, 0)) * dt * dt
                if aimTimer > 0 && aimSide {
                    let goal = sh + aimDir * Float(i) * 11
                    pts[i] += (goal - pts[i]) * 0.5
                }
                if flushing < 0 && ko <= 0 && !grounded && aimTimer <= 0 {
                    pts[i] += (side * 60 + V3(0, 260 + sinf(t * 18 + Float(i) + Float(a) * 3) * 120, 0)) * dt * dt * 6
                }
            }
            for _ in 0..<3 {
                pts[0] = sh
                for i in 1..<pts.count {
                    let d = pts[i] - pts[i - 1]
                    let l = d.len
                    if l > 1e-4 {
                        let corr = d * ((l - 7) / l)
                        if i == 1 { pts[i] -= corr } else { pts[i] -= corr * 0.5; pts[i - 1] += corr * 0.5 }
                    }
                }
            }
            // hands don't go through the floor
            if let gy = world.groundBelow(c.x, c.z, c.y) {
                for i in 1..<pts.count where pts[i].y < gy + 6 { pts[i].y = gy + 6 }
            }
            arms[a] = pts; armsPrev[a] = prev
        }
        aimTimer -= dt
        for i in eyes.indices {
            let (e, _, u, vv) = eyeFrame(i)
            eyes[i].update(e, u: u, v: vv, dt: dt)
        }
        mouthOpen = max(0, mouthOpen - dt * 3)
        hurtFace = max(0, hurtFace - dt)
        invuln = max(0, invuln - dt)
    }

    func jolt() {
        for i in eyes.indices { eyes[i].jolt(V2(frand(-500, 500), frand(200, 700))) }
    }

    private func drawEyes() {
        for i in eyes.indices {
            let (e, n, r, u) = eyeFrame(i)
            guard let node = eyes[i].node else { continue }
            node.simdPosition = e
            node.simdOrientation = simd_quatf(M3(columns: (r, u, n)))
            node.simdScale = V3(repeating: drawScale)
            eyes[i].drawPupil()
        }
    }

    func draw(world: World, t: Float) {
        var verts = [V3](repeating: .zero, count: meshSkin.count)
        for i in 0..<meshSkin.count { verts[i] = skinned(meshSkin[i]) }
        var norms = [V3](repeating: .zero, count: verts.count)
        var k = 0
        while k < meshIndices.count {
            let a = Int(meshIndices[k]), b = Int(meshIndices[k + 1]), cc = Int(meshIndices[k + 2])
            let fn = simd_cross(verts[b] - verts[a], verts[cc] - verts[a])
            norms[a] += fn; norms[b] += fn; norms[cc] += fn
            k += 3
        }
        for i in norms.indices { norms[i] = norms[i].norm }
        let vs = SCNGeometrySource(vertices: verts.map { SCNVector3($0.x, $0.y, $0.z) })
        let ns = SCNGeometrySource(normals: norms.map { SCNVector3($0.x, $0.y, $0.z) })
        let el = SCNGeometryElement(indices: meshIndices, primitiveType: .triangles)
        let geo = SCNGeometry(sources: [vs, ns], elements: [el])
        geo.firstMaterial = bodyMat
        bodyNode.geometry = geo
        bodyMat.emission.contents = ko > 0 ? NSColor.black : glow

        drawEyes()

        let (mp, mn, mr, mu) = frame(skinned(mouthSkin), mouthNormal, lift: 0)
        mouthNode.simdPosition = mp
        mouthNode.simdOrientation = simd_quatf(M3(columns: (mr, mu, mn)))
        var mw: Float = 11, mh: Float = 3
        if hurtFace > 0 || ko > 0 { mw = 12; mh = 2.5 + abs(sinf(t * 30)) * 2 }
        else if mouthOpen > 0.05 || !grounded || charging {
            let o = max(mouthOpen, grounded ? 0.5 : 0.8)
            mw = charging ? 13 : 8
            mh = 3 + 8 * o
        }
        mouthNode.simdScale = V3(mw, mh, 3) * drawScale

        let limbs: CGFloat = drawScale < 0.98 ? 0 : 1
        for a in 0..<2 where arms[a].count == 7 {
            let p = arms[a]
            for (j, b) in armBeads[a].enumerated() {
                let f = Float(j) / Float(armBeads[a].count - 1) * Float(p.count - 1)
                let i0 = min(p.count - 2, Int(f)), tt = f - Float(i0)
                b.simdPosition = p[i0] + (p[i0 + 1] - p[i0]) * tt
                b.opacity = limbs
            }
            hands[a].simdPosition = p.last!
            hands[a].opacity = limbs
        }
        let fwd = V3(sinf(yaw), 0, cosf(yaw))
        for (i, s) in shoes.enumerated() {
            let base = skinned(footSkin[i])
            let ph = i == 0 ? sinf(walkPhase) : -sinf(walkPhase)
            let lift = grounded ? max(0, ph) * 9 : 0
            s.simdPosition = base + V3(0, -3 + lift, 0) + fwd * (5 + (grounded ? ph * 6 : 0))
            s.simdOrientation = simd_quatf(angle: yaw, axis: V3(0, 1, 0))
            s.simdScale = V3(10, 7, 16)
            s.opacity = limbs
        }

        if let gy = world.groundBelow(c.x, c.z, c.y) {
            let h = max(0, bottom - gy)
            let k = max(0.2, 1 - h / 600)
            shadow.simdPosition = V3(c.x, gy + 1.5, c.z)
            shadow.simdScale = V3(repeating: k)
            shadow.opacity = CGFloat(k)
        } else { shadow.opacity = 0 }

        chargeRing.simdPosition = V3(c.x, bottom + 4, c.z)
        chargeRing.opacity = charging ? CGFloat(0.3 + charge * 0.7) : 0
        chargeRing.simdScale = V3(repeating: 1.3 - charge * 0.45 + sinf(t * 40) * 0.03 * charge)

        let flash = invuln > 0 && Int(t * 16) % 2 == 0
        bodyNode.opacity = flash ? 0.45 : 1
    }
}
