import SpriteKit

/// Turns level data into nodes: sky, parallax hills, ground, platforms, props and signs.
enum Scenery {
    static func build(level: LevelData, world: World, into root: SKNode, far: SKNode, near: SKNode, sky: SKSpriteNode) {
        let th = level.theme
        far.removeAllChildren()
        near.removeAllChildren()
        sky.texture = SKTexture(cgImage: makeImage(8, 256) { ctx in
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let g = CGGradient(colorsSpace: cs, colors: [th.skyBottom.cgColor, th.skyTop.cgColor] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: 256), options: [])
        })

        // far hills, clouds, sun
        let span0 = level.minX * 0.2 - 2500, span1 = level.maxX * 0.2 + 2500
        far.addChild(hills(span0, span1, base: 60, amp: 110, freq: 0.0021, seed: 3, color: th.hillFar))
        let sun = SKSpriteNode(texture: radialTexture(128, inner: hex(0xfffbe0, 0.95).cgColor, outer: hex(0xfff3b0, 0).cgColor, mid: 0.35))
        sun.size = CGSize(width: 260, height: 260)
        sun.position = CGPoint(x: CGFloat(level.minX * 0.2 + 500), y: 380)
        sun.zPosition = -2
        far.addChild(sun)
        var r = RNG(UInt64(level.name.count * 31 + 7))
        var cx = span0
        while cx < span1 {
            let c = SKSpriteNode(texture: emojiTexture("☁️", size: 128))
            let s = r.range(120, 230)
            c.size = CGSize(width: CGFloat(s * 1.2), height: CGFloat(s))
            c.alpha = CGFloat(r.range(0.7, 0.95))
            c.position = CGPoint(x: CGFloat(cx), y: CGFloat(r.range(300, 620)))
            c.zPosition = -1
            let drift = CGFloat(r.range(8, 25))
            c.run(.repeatForever(.sequence([.moveBy(x: drift * 10, y: 0, duration: 20), .moveBy(x: -drift * 10, y: 0, duration: 20)])))
            far.addChild(c)
            cx += r.range(350, 700)
        }
        let n0 = level.minX * 0.45 - 2000, n1 = level.maxX * 0.45 + 2000
        near.addChild(hills(n0, n1, base: -40, amp: 90, freq: 0.0035, seed: 9, color: th.hillNear))

        // solids
        for s in level.solids { root.addChild(solidNode(s, th)) }

        // fans (air vents)
        for f in level.fans {
            let w = CGFloat(f.hi.x - f.lo.x)
            let base = SKShapeNode(rectOf: CGSize(width: w, height: 60), cornerRadius: 8)
            base.fillColor = hex(0x6b7280); base.strokeColor = hex(0x30343c); base.lineWidth = 4
            base.position = CGPoint(x: CGFloat(f.lo.x) + w / 2, y: -170)
            base.zPosition = 4
            for k in 0..<Int(w / 60) {
                let blade = SKLabelNode(text: "✳️")
                blade.fontSize = 44
                blade.verticalAlignmentMode = .center
                blade.position = CGPoint(x: -w / 2 + 40 + CGFloat(k) * 60, y: 0)
                blade.run(.repeatForever(.rotate(byAngle: -12, duration: 1)))
                base.addChild(blade)
            }
            root.addChild(base)
            let height = CGFloat(f.hi.y) + 170
            for k in 0..<18 {
                let streak = SKSpriteNode(color: hex(0xffffff, 0.45), size: CGSize(width: 3, height: CGFloat.random(in: 30...80)))
                let x = CGFloat(f.lo.x) + CGFloat.random(in: 10...(w - 10))
                streak.position = CGPoint(x: x, y: -140)
                streak.zPosition = 3
                let dur = Double.random(in: 0.7...1.2)
                streak.run(.sequence([.wait(forDuration: Double(k) * 0.08),
                                      .repeatForever(.sequence([.moveTo(y: -140, duration: 0), .fadeAlpha(to: 0.6, duration: 0),
                                                                .group([.moveBy(x: 0, y: height, duration: dur), .fadeOut(withDuration: dur)])]))]))
                root.addChild(streak)
            }
        }

        for (e, p, s) in level.decor {
            let d = SKSpriteNode(texture: emojiTexture(e, size: 96))
            d.size = CGSize(width: CGFloat(s), height: CGFloat(s))
            d.anchorPoint = CGPoint(x: 0.5, y: 0.12)
            d.position = p.cg
            d.zPosition = 5
            root.addChild(d)
        }
        for (t, p) in level.signs { root.addChild(sign(t, at: p)) }
    }

    static func hills(_ x0: Float, _ x1: Float, base: Float, amp: Float, freq: Float, seed: Float, color: NSColor) -> SKShapeNode {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: CGFloat(x0), y: -3000))
        var x = x0
        while x <= x1 {
            let y = base + amp * (0.6 * sinf(x * freq + seed) + 0.3 * sinf(x * freq * 2.3 + seed * 2) + 0.15 * sinf(x * freq * 5.1 + seed * 3))
            path.addLine(to: CGPoint(x: CGFloat(x), y: CGFloat(y)))
            x += 30
        }
        path.addLine(to: CGPoint(x: CGFloat(x1), y: -3000))
        path.closeSubpath()
        let n = SKShapeNode(path: path)
        n.fillColor = color
        n.strokeColor = .clear
        return n
    }

    static func solidNode(_ s: Solid, _ th: Theme) -> SKNode {
        let path = CGMutablePath()
        path.addLines(between: s.pts.map { $0.cg })
        path.closeSubpath()
        let holder = SKNode()
        holder.zPosition = 10
        switch s.kind {
        case .bouncy:
            let w = CGFloat(s.hi.x - s.lo.x), h = CGFloat(s.hi.y - s.lo.y)
            holder.position = CGPoint(x: CGFloat(s.lo.x) + w / 2, y: CGFloat(s.lo.y))
            let pad = SKShapeNode(rect: CGRect(x: -w / 2, y: 0, width: w, height: h), cornerRadius: h / 2)
            pad.fillColor = hex(0xff4f8b); pad.strokeColor = hex(0x8a1540); pad.lineWidth = 4
            for k in 0..<Int(w / 26) {
                let dot = SKShapeNode(circleOfRadius: 4)
                dot.fillColor = .white; dot.strokeColor = .clear
                dot.position = CGPoint(x: -w / 2 + 16 + CGFloat(k) * 26, y: h / 2)
                pad.addChild(dot)
            }
            holder.addChild(pad)
            s.node = holder
            return holder
        case .mover:
            let n = SKShapeNode(path: path)
            n.fillColor = hex(0x9c6b3e); n.strokeColor = hex(0x4a2e16); n.lineWidth = 4
            let top = SKShapeNode()
            let tp = CGMutablePath()
            tp.move(to: CGPoint(x: CGFloat(s.lo.x) + 4, y: CGFloat(s.hi.y) - 3)); tp.addLine(to: CGPoint(x: CGFloat(s.hi.x) - 4, y: CGFloat(s.hi.y) - 3))
            top.path = tp; top.strokeColor = hex(0xd9a066); top.lineWidth = 5; top.lineCap = .round
            n.addChild(top)
            for bx in [s.lo.x + 12, s.hi.x - 12] {
                let bolt = SKShapeNode(circleOfRadius: 4)
                bolt.fillColor = hex(0x3a3a3a); bolt.strokeColor = .clear
                bolt.position = CGPoint(x: CGFloat(bx), y: CGFloat((s.lo.y + s.hi.y) / 2))
                n.addChild(bolt)
            }
            holder.addChild(n)
            s.node = holder
            return holder
        default:
            let isPlat = s.kind == .platform
            let n = SKShapeNode(path: path)
            n.fillColor = s.kind == .ice ? hex(0xbfe6ff) : isPlat ? th.platform : th.ground
            n.strokeColor = s.kind == .ice ? hex(0x6fa8d6) : th.groundEdge
            n.lineWidth = 4
            n.lineJoin = .round
            holder.addChild(n)
            // dirt speckles
            if !isPlat && s.kind != .ice {
                var r = RNG(UInt64(abs(s.lo.x) + 3))
                let area = (s.hi.x - s.lo.x) * min(400, s.hi.y - s.lo.y)
                for _ in 0..<Int(area / 9000) {
                    let p = V2(r.range(s.lo.x + 10, s.hi.x - 10), r.range(max(s.lo.y, s.hi.y - 420), s.hi.y - 30))
                    guard s.contains(p) else { continue }
                    let d = SKShapeNode(ellipseOf: CGSize(width: CGFloat(r.range(8, 22)), height: CGFloat(r.range(5, 12))))
                    d.fillColor = th.groundEdge.withAlphaComponent(0.35); d.strokeColor = .clear
                    d.position = p.cg
                    holder.addChild(d)
                }
            }
            // grass / carpet / shine along upward faces
            let n2 = s.pts.count
            for i in 0..<n2 where s.normals[i].y > 0.6 {
                let a = s.pts[i], b = s.pts[(i + 1) % n2]
                let e = SKShapeNode()
                let ep = CGMutablePath()
                ep.move(to: CGPoint(x: CGFloat(a.x), y: CGFloat(a.y) - 5)); ep.addLine(to: CGPoint(x: CGFloat(b.x), y: CGFloat(b.y) - 5))
                e.path = ep
                e.strokeColor = s.kind == .ice ? hex(0xffffff, 0.9) : isPlat ? th.platformTop : th.groundTop
                e.lineWidth = s.kind == .ice ? 6 : 14
                e.lineCap = .round
                holder.addChild(e)
                if s.kind == .ice {
                    for k in stride(from: min(a.x, b.x) + 40, to: max(a.x, b.x) - 40, by: 140) {
                        let gl = SKShapeNode(rectOf: CGSize(width: 50, height: 4), cornerRadius: 2)
                        gl.fillColor = hex(0xffffff, 0.7); gl.strokeColor = .clear
                        gl.position = CGPoint(x: CGFloat(k), y: CGFloat(a.y) - 22)
                        gl.zRotation = 0.15
                        holder.addChild(gl)
                    }
                }
            }
            return holder
        }
    }

    static func sign(_ text: String, at p: V2) -> SKNode {
        let n = SKNode()
        n.position = p.cg
        n.zPosition = 8
        let l = SKLabelNode()
        l.attributedText = cartoonText(text, size: 17, fill: hex(0x4a2a12), stroke: .clear, width: 0)
        l.numberOfLines = 0
        l.verticalAlignmentMode = .center
        l.horizontalAlignmentMode = .center
        let f = l.calculateAccumulatedFrame()
        let w = f.width + 30, h = f.height + 22
        let postH: CGFloat = 70
        let post = SKShapeNode(rectOf: CGSize(width: 12, height: postH + h / 2))
        post.fillColor = hex(0x8a5a2b); post.strokeColor = hex(0x4a2e16); post.lineWidth = 2
        post.position = CGPoint(x: 0, y: (postH + h / 2) / 2)
        n.addChild(post)
        let board = SKShapeNode(rectOf: CGSize(width: w, height: h), cornerRadius: 8)
        board.fillColor = hex(0xe8c48a); board.strokeColor = hex(0x6b4220); board.lineWidth = 4
        board.position = CGPoint(x: 0, y: postH + h / 2)
        n.addChild(board)
        l.position = board.position
        n.addChild(l)
        return n
    }

    static func flag(at p: V2) -> SKNode {
        let n = SKNode()
        n.position = p.cg
        n.zPosition = 9
        let pole = SKShapeNode(rectOf: CGSize(width: 7, height: 170), cornerRadius: 3)
        pole.fillColor = hex(0xdddddd); pole.strokeColor = hex(0x555555); pole.lineWidth = 2
        pole.position = CGPoint(x: 0, y: 85)
        n.addChild(pole)
        let knob = SKShapeNode(circleOfRadius: 7)
        knob.fillColor = hex(0xffd23f); knob.strokeColor = hex(0x8a6a00)
        knob.position = CGPoint(x: 0, y: 172)
        n.addChild(knob)
        let cloth = SKShapeNode()
        let cp = CGMutablePath()
        cp.move(to: .zero); cp.addLine(to: CGPoint(x: 70, y: -22)); cp.addLine(to: CGPoint(x: 0, y: -44)); cp.closeSubpath()
        cloth.path = cp
        cloth.fillColor = hex(0x9aa0aa); cloth.strokeColor = hex(0x555a63); cloth.lineWidth = 3
        cloth.position = CGPoint(x: 4, y: 70)
        cloth.name = "cloth"
        cloth.run(.repeatForever(.sequence([.scaleX(to: 0.9, duration: 0.4), .scaleX(to: 1, duration: 0.4)])))
        n.addChild(cloth)
        return n
    }

    static func raise(_ f: SKNode, instant: Bool) {
        guard let cloth = f.childNode(withName: "cloth") as? SKShapeNode, cloth.userData == nil else { return }
        cloth.userData = ["up": true]
        cloth.fillColor = Player.red
        cloth.strokeColor = Player.darkRed
        var g = Googly(R: 9)
        let (w, _) = g.makeNode(outline: 2)
        w.position = CGPoint(x: 22, y: -22)
        cloth.addChild(w)
        g.node = w
        if instant { cloth.position.y = 160 } else { cloth.run(.moveTo(y: 160, duration: 0.5)) }
    }

    static func toilet() -> SKNode {
        let n = SKNode()
        n.zPosition = 20
        let glow = SKSpriteNode(texture: radialTexture(128, inner: hex(0xfff2a0, 0.8).cgColor, outer: hex(0xfff2a0, 0).cgColor, mid: 0.2))
        glow.size = CGSize(width: 320, height: 320)
        glow.position = CGPoint(x: 0, y: 70)
        glow.run(.repeatForever(.sequence([.scale(to: 1.15, duration: 0.8), .scale(to: 0.95, duration: 0.8)])))
        n.addChild(glow)
        let t = SKSpriteNode(texture: emojiTexture("🚽", size: 128))
        t.size = CGSize(width: 150, height: 150)
        t.anchorPoint = CGPoint(x: 0.5, y: 0.06)
        t.color = hex(0xffc629)
        t.colorBlendFactor = 0.65
        n.addChild(t)
        let l = label("THE GOLDEN TOILET", size: 18, fill: hex(0xffe14d))
        l.position = CGPoint(x: 0, y: 185)
        n.addChild(l)
        let arrow = label("⬇︎", size: 30, fill: hex(0xffe14d))
        arrow.position = CGPoint(x: 0, y: 160)
        arrow.run(.repeatForever(.sequence([.moveBy(x: 0, y: -10, duration: 0.4), .moveBy(x: 0, y: 10, duration: 0.4)])))
        n.addChild(arrow)
        for k in 0..<5 {
            let s = SKLabelNode(text: "✨")
            s.fontSize = 22
            s.position = CGPoint(x: CGFloat.random(in: -70...70), y: CGFloat.random(in: 20...140))
            s.run(.repeatForever(.sequence([.wait(forDuration: Double(k) * 0.3), .fadeOut(withDuration: 0.5), .fadeIn(withDuration: 0.5)])))
            n.addChild(s)
        }
        return n
    }

    static func speechBubble(_ text: String) -> SKNode {
        let n = SKNode()
        let l = SKLabelNode()
        l.attributedText = cartoonText(text, size: 20, fill: hex(0x1d1016), stroke: .clear, width: 0)
        l.verticalAlignmentMode = .center
        l.horizontalAlignmentMode = .center
        let f = l.calculateAccumulatedFrame()
        let w = max(60, f.width + 26), h = f.height + 18
        let path = CGMutablePath()
        path.addRoundedRect(in: CGRect(x: -w / 2, y: 14, width: w, height: h), cornerWidth: 14, cornerHeight: 14)
        path.move(to: CGPoint(x: -10, y: 15)); path.addLine(to: CGPoint(x: 0, y: 0)); path.addLine(to: CGPoint(x: 12, y: 15))
        let b = SKShapeNode(path: path)
        b.fillColor = .white
        b.strokeColor = hex(0x1d1016)
        b.lineWidth = 3
        n.addChild(b)
        let cover = SKShapeNode(rect: CGRect(x: -9, y: 13, width: 20, height: 5))
        cover.fillColor = .white; cover.strokeColor = .clear
        n.addChild(cover)
        l.position = CGPoint(x: 0, y: 14 + h / 2)
        n.addChild(l)
        n.setScale(0.2)
        n.run(.scale(to: 1, duration: 0.12))
        return n
    }
}
