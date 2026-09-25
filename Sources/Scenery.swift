import SceneKit

/// Turns level data into SceneKit nodes: sky, distant hills, ground, platforms, props and signs.
enum Scenery {
    static func build(level: LevelData, into root: SCNNode, scene: SCNScene) {
        let th = level.theme
        scene.background.contents = makeImage(8, 512) { ctx in
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let g = CGGradient(colorsSpace: cs, colors: [th.skyBottom.cgColor, th.skyBottom.cgColor, th.skyTop.cgColor] as CFArray, locations: [0, 0.45, 1])!
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: 512), options: [])
        }
        scene.fogColor = th.skyBottom
        scene.fogStartDistance = 2600
        scene.fogEndDistance = 9000
        scene.fogDensityExponent = 1.4
        scene.lightingEnvironment.contents = scene.background.contents
        scene.lightingEnvironment.intensity = 0.8

        // backdrop: big soft hills, clouds
        var r = RNG(UInt64(level.name.count * 31 + 7))
        let hillM = Tex.tiled(Tex.hillGrass, sx: 4, sy: 2, tile: 1, rough: 0.95, tint: th.hillNear), hillF = Tex.tiled(Tex.hillGrass, sx: 3, sy: 2, tile: 1, rough: 1, tint: th.hillFar)
        var x = level.minX - 1500
        while x < level.maxX + 1500 {
            let far = r.chance(0.5)
            let rad = r.range(500, 1100)
            let h = sphere(CGFloat(rad), far ? hillF : hillM, seg: 32)
            h.simdScale = V3(1.4, r.range(0.35, 0.6), 1)
            h.simdPosition = V3(x, -250, far ? r.range(-3600, -2800) : r.range(-2200, -1300))
            h.castsShadow = false
            root.addChildNode(h)
            x += r.range(500, 900)
        }
        let cloudM = mat(.white, rough: 1, emission: NSColor(white: 0.35, alpha: 1))
        x = level.minX - 800
        while x < level.maxX + 800 {
            let cl = SCNNode()
            for k in 0..<5 {
                cl.add(sphere(CGFloat(r.range(60, 110)), cloudM, seg: 16)).at(Float(k) * 70 - 140, r.range(-20, 30), r.range(-30, 30))
            }
            cl.simdScale = V3(1, 0.6, 0.7)
            cl.castsShadow = false
            cl.simdPosition = V3(x, r.range(700, 1100), r.range(-2600, -900))
            cl.runAction(.repeatForever(.sequence([.moveBy(x: 300, y: 0, z: 0, duration: 30), .moveBy(x: -300, y: 0, z: 0, duration: 30)])))
            root.addChildNode(cl)
            x += r.range(600, 1200)
        }

        for s in level.solids where !s.hidden { root.addChildNode(solidNode(s, th)) }

        for f in level.fans {
            let w = CGFloat(f.hi.x - f.lo.x), d = CGFloat(f.hi.z - f.lo.z)
            let unit = SCNNode()
            unit.simdPosition = V3((f.lo.x + f.hi.x) / 2, -160, 0)
            unit.addChildNode(box(w, 40, d, mat(hex(0x6b7280), rough: 0.4, metal: 0.6), chamfer: 8))
            let blades = SCNNode()
            for k in 0..<4 {
                let b = box(w * 0.9, 4, 26, mat(hex(0x30343c), rough: 0.5, metal: 0.5))
                b.eulerAngles.y = CGFloat(k) * .pi / 4
                blades.addChildNode(b)
            }
            blades.simdPosition = V3(0, 24, 0)
            blades.runAction(.repeatForever(.rotateBy(x: 0, y: 12, z: 0, duration: 1)))
            unit.addChildNode(blades)
            root.addChildNode(unit)
            let ps = SCNParticleSystem()
            ps.birthRate = 90
            ps.particleLifeSpan = 1.3
            ps.particleVelocity = 800
            ps.particleVelocityVariation = 200
            ps.emittingDirection = SCNVector3(0, 1, 0)
            ps.spreadingAngle = 2
            ps.particleSize = 2.5
            ps.stretchFactor = 0.06
            ps.particleColor = NSColor(white: 1, alpha: 0.55)
            ps.blendMode = .additive
            ps.emitterShape = SCNBox(width: w, height: 1, length: d, chamferRadius: 0)
            ps.birthLocation = .volume
            let em = SCNNode()
            em.simdPosition = V3((f.lo.x + f.hi.x) / 2, -130, 0)
            em.addParticleSystem(ps)
            root.addChildNode(em)
        }

        for (e, p, s) in level.decor {
            let d = decorModel(e)
            d.simdPosition = p
            d.simdScale = V3(repeating: s)
            d.eulerAngles.y = CGFloat(r.range(0, 6.28))
            root.addChildNode(d)
        }
        for (t, p) in level.signs { root.addChildNode(sign(t, at: p)) }
    }

    static func solidNode(_ s: Solid, _ th: Theme) -> SCNNode {
        let holder = SCNNode()
        let midZ = (s.z0 + s.z1) / 2, depth = CGFloat(s.z1 - s.z0)
        switch s.kind {
        case .bouncy:
            let w = CGFloat(s.hi.x - s.lo.x), h = CGFloat(s.hi.y - s.lo.y)
            holder.simdPosition = V3((s.lo.x + s.hi.x) / 2, s.lo.y, midZ)
            holder.add(cyl(w / 2, h, mat(hex(0xff4f8b), rough: 0.35))).at(0, Float(h / 2), 0)
            let rim = SCNNode(geometry: { let t = SCNTorus(ringRadius: w / 2, pipeRadius: 5); t.firstMaterial = mat(.white, rough: 0.4); return t }())
            rim.simdPosition = V3(0, Float(h), 0)
            holder.addChildNode(rim)
            holder.add(cyl(w / 4, 1, mat(.white, rough: 0.4))).at(0, Float(h) + 0.6, 0)
            s.node = holder
            return holder
        case .mover:
            let w = CGFloat(s.hi.x - s.lo.x), h = CGFloat(s.hi.y - s.lo.y)
            let plank = box(w, h, depth, mat(hex(0x9c6b3e), rough: 0.8), chamfer: 5)
            plank.simdPosition = V3((s.lo.x + s.hi.x) / 2, (s.lo.y + s.hi.y) / 2, midZ)
            for k in 0..<3 {
                plank.add(box(w + 1, 3, 6, mat(hex(0x6e4726), rough: 0.9))).at(0, Float(h / 2) + 0.5, Float(k - 1) * Float(depth) * 0.3)
            }
            holder.addChildNode(plank)
            s.node = holder
            return holder
        default:
            let p = NSBezierPath()
            p.move(to: NSPoint(x: CGFloat(s.pts[0].x), y: CGFloat(s.pts[0].y)))
            for q in s.pts.dropFirst() { p.line(to: NSPoint(x: CGFloat(q.x), y: CGFloat(q.y))) }
            p.close()
            p.flatness = 0.1
            let shape = SCNShape(path: p, extrusionDepth: depth)
            shape.chamferRadius = 6
            let isPlat = s.kind == .platform
            let w = s.hi.x - s.lo.x, h = s.hi.y - s.lo.y, dz = s.z1 - s.z0
            let side: SCNMaterial
            if s.kind == .ice {
                side = Tex.tiled(Tex.ice, sx: w, sy: h, tile: 200, rough: 0.05)
            } else {
                side = Tex.tiled(isPlat ? th.platSideTex : th.sideTex, sx: w, sy: h, tile: isPlat ? 180 : 260)
            }
            let around = Tex.tiled(s.kind == .ice ? Tex.ice : (isPlat ? th.platSideTex : th.sideTex), sx: (w + h) * 2, sy: dz, tile: isPlat ? 180 : 260, rough: s.kind == .ice ? 0.05 : 0.9)
            shape.materials = [side, side, around, side, side]
            let n = SCNNode(geometry: shape)
            n.simdPosition = V3(0, 0, midZ)
            holder.addChildNode(n)
            // grass / carpet / ice along upward faces
            let cnt = s.pts.count
            for i in 0..<cnt where s.normals[i].y > 0.6 {
                let a = s.pts[i], b = s.pts[(i + 1) % cnt]
                let len = (b - a).len
                let img = s.kind == .ice ? Tex.ice : (isPlat ? th.platTopTex : th.topTex)
                let topM = Tex.tiled(img, sx: len + 4, sy: dz + 6, tile: s.kind == .ice ? 200 : 300, rough: s.kind == .ice ? 0.02 : 0.95)
                if s.kind == .ice { topM.metalness.contents = 0.1; topM.clearCoat.contents = 1 }
                let slab = box(CGFloat(len) + 4, 12, depth + 6, topM, chamfer: 5)
                let mid = (a + b) * 0.5
                slab.simdPosition = V3(mid.x, mid.y - 4, midZ)
                slab.eulerAngles.z = CGFloat(atan2f(b.y - a.y, b.x - a.x)) + (b.x < a.x ? .pi : 0)
                holder.addChildNode(slab)
                if abs(s.normals[i].y) > 0.98 && s.kind != .ice { props(on: holder, x0: min(a.x, b.x), x1: max(a.x, b.x), y: a.y, z0: s.z0, z1: s.z1, th: th, plat: isPlat) }
            }
            return holder
        }
    }

    private static let tuftProto: SCNNode = {
        let n = SCNNode()
        let g1 = mat(hex(0x3f9c34), rough: 0.9), g2 = mat(hex(0x62c44a), rough: 0.9)
        for k in 0..<5 {
            let a = Float(k) / 5 * 2 * .pi
            let blade = cone(2.2, 0, CGFloat(12 + k * 2), k % 2 == 0 ? g1 : g2)
            blade.simdPosition = V3(cosf(a) * 3, Float(6 + k), sinf(a) * 3)
            blade.eulerAngles = SCNVector3(CGFloat(sinf(a) * 0.35), 0, CGFloat(-cosf(a) * 0.35))
            n.addChildNode(blade)
        }
        n.castsShadow = false
        return n
    }()

    private static let fenceMat = Tex.tiled(Tex.wood, sx: 60, sy: 60, tile: 120, rough: 0.8, tint: hex(0xfff3e0))
    private static let cubicleMat = Tex.tiled(Tex.noise(128, base: SIMD3(0.55, 0.6, 0.72), amt: 0.15, grain: 16, seed: 81, speck: 2), sx: 100, sy: 100, tile: 60, rough: 1)

    /// Small props on a flat top: grass tufts, back fences, cubicle partitions.
    static func props(on n: SCNNode, x0: Float, x1: Float, y: Float, z0: Float, z1: Float, th: Theme, plat: Bool) {
        var r = RNG(UInt64(abs(x0) * 13 + abs(y) * 7 + 5))
        if th.props == 0 || th.props == 1 {
            let count = Int((x1 - x0) * (z1 - z0) / (th.props == 0 ? 9000 : 30000))
            for _ in 0..<min(count, 260) {
                let t = tuftProto.clone()
                t.simdPosition = V3(r.range(x0 + 8, x1 - 8), y + 1, r.range(z0 + 8, z1 - 8))
                t.simdScale = V3(repeating: r.range(0.7, 1.5))
                t.eulerAngles.y = CGFloat(r.range(0, 6.28))
                if th.props == 1 { t.opacity = 0.9; t.simdScale *= 0.7 }
                n.addChildNode(t)
            }
        }
        guard !plat, z0 < -300 else { return }
        let zb = z0 + 12
        if th.props == 0 {
            // white picket fence along the back
            var x = x0 + 30
            while x < x1 - 30 {
                let post = box(8, 70, 6, fenceMat, chamfer: 2)
                post.simdPosition = V3(x, y + 35, zb)
                n.addChildNode(post)
                x += 24
            }
            for ry in [22, 52] as [Float] {
                let rail = box(CGFloat(x1 - x0 - 60), 6, 4, fenceMat, chamfer: 1)
                rail.simdPosition = V3((x0 + x1) / 2, y + ry, zb - 5)
                n.addChildNode(rail)
            }
        } else if th.props == 2 {
            var x = x0 + 40
            while x < x1 - 160 {
                let panel = box(150, 110, 8, cubicleMat, chamfer: 3)
                panel.simdPosition = V3(x + 75, y + 55, zb)
                panel.add(box(152, 6, 10, mat(hex(0x9aa0aa), rough: 0.4, metal: 0.7))).at(0, 56, 0)
                n.addChildNode(panel)
                x += 190
            }
        } else if th.props == 1 {
            var x = x0 + r.range(50, 200)
            while x < x1 - 50 {
                let rock = sphere(CGFloat(r.range(25, 55)), Tex.tiled(Tex.sandstone, sx: 100, sy: 100, tile: 120), seg: 12)
                rock.simdScale = V3(r.range(1, 1.6), r.range(0.5, 0.9), 1)
                rock.simdPosition = V3(x, y + 5, zb + r.range(0, 20))
                n.addChildNode(rock)
                x += r.range(200, 450)
            }
        }
    }

    static func decorModel(_ e: String) -> SCNNode {
        let n = SCNNode()
        switch e {
        case "🌳":
            n.add(cyl(9, 90, mat(hex(0x7a4a2a), rough: 0.9))).at(0, 45, 0)
            let leaf = mat(hex(0x3faa4a), rough: 0.8)
            n.add(sphere(48, leaf)).at(0, 110, 0)
            n.add(sphere(34, leaf)).at(28, 90, 10)
            n.add(sphere(32, leaf)).at(-26, 95, -8)
        case "🌷", "🌻", "🌼":
            let petal = e == "🌷" ? hex(0xff4f7a) : e == "🌻" ? hex(0xffc629) : hex(0xffffff)
            n.add(cyl(1.5, 30, mat(hex(0x3a9a3a)))).at(0, 15, 0)
            for k in 0..<6 {
                let a = Float(k) / 6 * 2 * .pi
                n.add(sphere(5, mat(petal, rough: 0.6), seg: 10)).at(cosf(a) * 6, 31, sinf(a) * 6)
            }
            n.add(sphere(4, mat(hex(0x7a4a10)), seg: 10)).at(0, 31, 0)
        case "🍄":
            n.add(cyl(6, 20, mat(hex(0xf2ead8)))).at(0, 10, 0)
            let cap = n.add(sphere(18, mat(hex(0xe03a3a), rough: 0.4)))
            cap.at(0, 20, 0); cap.simdScale = V3(1, 0.6, 1)
            for k in 0..<5 { let a = Float(k) * 1.3; n.add(sphere(3, mat(.white), seg: 8)).at(cosf(a) * 11, 29, sinf(a) * 11) }
        case "🌿":
            let g = mat(hex(0x4fb84a), rough: 0.8)
            for k in 0..<4 { n.add(sphere(CGFloat(14 + k * 2), g, seg: 12)).at(Float(k - 2) * 12, 10, Float(k % 2) * 8) }
        case "🪨", "🐚", "🦴":
            let rk = n.add(sphere(20, mat(e == "🦴" ? hex(0xf0e8d8) : hex(0x9a948a), rough: 0.9), seg: 10))
            rk.simdScale = V3(1.3, 0.7, 1); rk.at(0, 8, 0)
        case "🌵":
            let g = mat(hex(0x3f9a4f), rough: 0.7)
            n.add(SCNNode(geometry: { let c = SCNCapsule(capRadius: 12, height: 110); c.firstMaterial = g; return c }())).at(0, 55, 0)
            let arm = n.add(SCNNode(geometry: { let c = SCNCapsule(capRadius: 8, height: 40); c.firstMaterial = g; return c }()))
            arm.at(18, 65, 0)
            n.add(SCNNode(geometry: { let c = SCNCapsule(capRadius: 8, height: 30); c.firstMaterial = g; return c }())).at(-17, 50, 0)
        case "🪴":
            n.add(cone(12, 16, 26, mat(hex(0xc0643a), rough: 0.8))).at(0, 13, 0)
            let g = mat(hex(0x3faa4a), rough: 0.7)
            for k in 0..<5 {
                let l = n.add(sphere(9, g, seg: 10))
                let a = Float(k) * 1.25
                l.at(cosf(a) * 9, 38 + Float(k % 2) * 8, sinf(a) * 9); l.simdScale = V3(0.6, 1.6, 0.6)
            }
        case "🗄️":
            n.add(box(40, 90, 40, mat(hex(0x9aa3b0), rough: 0.4, metal: 0.6), chamfer: 2)).at(0, 45, 0)
            for k in 0..<3 { n.add(box(16, 3, 2, mat(hex(0x333333)))).at(0, 20 + Float(k) * 28, 21) }
        case "🖨️":
            n.add(box(50, 28, 36, mat(hex(0xe8e8e8), rough: 0.5), chamfer: 4)).at(0, 14, 0)
            n.add(box(34, 2, 26, mat(.white))).at(0, 29, -4)
        case "📦":
            n.add(box(46, 40, 46, mat(hex(0xc8965a), rough: 0.9), chamfer: 1)).at(0, 20, 0)
            n.add(box(47, 6, 10, mat(hex(0xa0703a)))).at(0, 40, 0)
        case "🧯":
            n.add(cyl(9, 44, mat(hex(0xd62a2a), rough: 0.3))).at(0, 22, 0)
            n.add(cyl(4, 8, mat(hex(0x222222)))).at(0, 48, 0)
        default:
            n.add(sphere(12, mat(.gray)))
        }
        return n
    }

    static func sign(_ text: String, at p: V3) -> SCNNode {
        let n = SCNNode()
        n.simdPosition = p
        n.add(cyl(5, 90, mat(hex(0x8a5a2b), rough: 0.9))).at(0, 45, 0)
        let lines = text.split(separator: "\n").count
        let w: CGFloat = 250, h: CGFloat = CGFloat(40 + lines * 26)
        let face = SCNMaterial()
        face.diffuse.contents = textImage(text, size: 34, color: hex(0x4a2a12), bg: hex(0xe8c48a), width: 500, height: Int(h * 2))
        face.roughness.contents = 0.9
        face.lightingModel = .physicallyBased
        let wood = mat(hex(0xb8894e), rough: 0.9)
        let b = SCNBox(width: w, height: h, length: 8, chamferRadius: 3)
        b.materials = [face, wood, wood, wood, wood, wood]
        n.add(SCNNode(geometry: b)).at(0, 90 + Float(h) / 2, 0)
        n.eulerAngles.y = 0.12
        return n
    }

    static func flag(at p: V3) -> SCNNode {
        let n = SCNNode()
        n.simdPosition = p
        n.add(cyl(3.5, 170, mat(hex(0xdddddd), rough: 0.3, metal: 0.8))).at(0, 85, 0)
        n.add(sphere(7, mat(hex(0xffd23f), rough: 0.2, metal: 1))).at(0, 172, 0)
        let bp = NSBezierPath()
        bp.move(to: .zero); bp.line(to: NSPoint(x: 70, y: -22)); bp.line(to: NSPoint(x: 0, y: -44)); bp.close()
        let sh = SCNShape(path: bp, extrusionDepth: 2)
        sh.firstMaterial = mat(hex(0x9aa0aa), rough: 0.8)
        let cloth = SCNNode(geometry: sh)
        cloth.name = "cloth"
        cloth.simdPosition = V3(3, 70, 0)
        cloth.runAction(.repeatForever(.sequence([.rotateTo(x: 0, y: 0.25, z: 0, duration: 0.5), .rotateTo(x: 0, y: -0.15, z: 0, duration: 0.5)])))
        n.addChildNode(cloth)
        return n
    }

    static func raise(_ f: SCNNode, instant: Bool) {
        guard let cloth = f.childNode(withName: "cloth", recursively: false), cloth.childNodes.isEmpty else { return }
        cloth.geometry?.firstMaterial = mat(Player.red, rough: 0.6)
        var g = Googly(R: 9)
        g.attach(to: cloth)
        g.node?.simdPosition = V3(22, -22, 1.5)
        g.pupil?.simdPosition = V3(1, -3, 0)
        if instant { cloth.simdPosition.y = 160 } else { cloth.runAction(.move(to: SCNVector3(3, 160, 0), duration: 0.5)) }
    }

    static func toilet() -> SCNNode {
        let n = SCNNode()
        let gold = mat(hex(0xffc629), rough: 0.18, metal: 1)
        n.add(cone(22, 36, 42, gold)).at(0, 21, 0)
        n.add(cyl(26, 6, gold)).at(0, 3, 0)
        let seat = n.add(SCNNode(geometry: { let t = SCNTorus(ringRadius: 33, pipeRadius: 6); t.firstMaterial = gold; return t }()))
        seat.at(0, 44, 0)
        n.add(cyl(28, 2, mat(hex(0x4fb4ff), rough: 0.05, emission: hex(0x103050)))).at(0, 40, 0)
        n.add(box(64, 70, 24, gold, chamfer: 6)).at(0, 78, -34)
        n.add(box(70, 8, 30, gold, chamfer: 3)).at(0, 116, -34)
        n.add(box(14, 4, 4, gold, chamfer: 1)).at(26, 100, -20)
        let glow = SCNLight()
        glow.type = .omni
        glow.color = hex(0xffd860)
        glow.intensity = 900
        glow.attenuationStartDistance = 20
        glow.attenuationEndDistance = 420
        let gl = SCNNode()
        gl.light = glow
        gl.simdPosition = V3(0, 120, 60)
        n.addChildNode(gl)
        let ps = SCNParticleSystem()
        ps.birthRate = 12
        ps.particleLifeSpan = 1.4
        ps.particleVelocity = 40
        ps.emittingDirection = SCNVector3(0, 1, 0)
        ps.spreadingAngle = 60
        ps.particleSize = 4
        ps.particleColor = hex(0xfff3a0)
        ps.blendMode = .additive
        ps.emitterShape = SCNSphere(radius: 70)
        ps.birthLocation = .volume
        let em = SCNNode()
        em.simdPosition = V3(0, 70, 0)
        em.addParticleSystem(ps)
        n.addChildNode(em)
        let lbl = SCNPlane(width: 220, height: 40)
        let lm = SCNMaterial()
        lm.diffuse.contents = makeImage(880, 160) { ctx in
            let g = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = g
            let a = cartoonText("THE GOLDEN TOILET", size: 76, fill: hex(0xffe14d), width: -6)
            let s = a.size()
            a.draw(at: NSPoint(x: (880 - s.width) / 2, y: (160 - s.height) / 2))
            NSGraphicsContext.restoreGraphicsState()
        }
        lm.lightingModel = .constant
        lm.isDoubleSided = true
        lbl.firstMaterial = lm
        let ln = SCNNode(geometry: lbl)
        ln.simdPosition = V3(0, 175, 0)
        ln.constraints = [SCNBillboardConstraint()]
        n.addChildNode(ln)
        n.runAction(.repeatForever(.sequence([.rotateTo(x: 0, y: 0.25, z: 0, duration: 1.2, usesShortestUnitArc: true),
                                              .rotateTo(x: 0, y: -0.25, z: 0, duration: 1.2, usesShortestUnitArc: true)])))
        return n
    }
}
