import SpriteKit

final class HUD {
    let root = SKNode()
    private var size = CGSize(width: 1440, height: 900)
    private let eyesRow = SKNode()
    private let ammoRow = SKNode()
    private let ammoLabel = SKLabelNode()
    private let scoreLabel = SKLabelNode()
    private let levelLabel = SKLabelNode()
    private let help = SKLabelNode()
    private let saved = SKLabelNode()
    private let toastLabel = SKLabelNode()
    private let bannerNode = SKNode()
    private let blind = SKSpriteNode()
    private let panel = SKNode()
    private let title = SKNode()
    private var titleEyes: [Googly] = []
    private let titleLogo = SKNode()
    private let bossNode = SKNode()
    private let bossFill = SKSpriteNode(color: hex(0xff4d6d), size: CGSize(width: 400, height: 18))
    private var shownEyes = -1, shownAmmo: [Junk] = [], shownScore = -1
    private var helpTime: Float = 0
    private var toastTime: Float = 0
    private var savedTime: Float = 0
    private var bannerTime: Float = 0
    private var logoY: CGFloat = 0, logoVel: CGFloat = 0

    init() {
        for n in [eyesRow, ammoRow, ammoLabel, scoreLabel, levelLabel, help, saved, toastLabel, bannerNode, bossNode] as [SKNode] {
            n.zPosition = 10
            root.addChild(n)
        }
        blind.texture = HUD.blindTexture
        blind.zPosition = -10
        blind.alpha = 0
        root.addChild(blind)
        panel.zPosition = 50
        root.addChild(panel)
        title.zPosition = 40
        root.addChild(title)
        for l in [ammoLabel, scoreLabel, levelLabel, help, saved, toastLabel] {
            l.verticalAlignmentMode = .center
        }
        scoreLabel.horizontalAlignmentMode = .right
        levelLabel.horizontalAlignmentMode = .right
        ammoLabel.horizontalAlignmentMode = .left
        help.attributedText = cartoonText("A/D move · SPACE jump · hold S squish, let go to BOING · S in air = butt slam · click / J spit · H honk · Esc pause",
                                          size: 16, fill: .white, width: -4)
        saved.attributedText = cartoonText("SAVED ✓", size: 18, fill: hex(0x9dff8a))
        saved.alpha = 0
        toastLabel.alpha = 0
        // boss bar
        let back = SKShapeNode(rectOf: CGSize(width: 408, height: 26), cornerRadius: 8)
        back.fillColor = hex(0x221018, 0.8); back.strokeColor = .white; back.lineWidth = 3
        bossNode.addChild(back)
        bossFill.anchorPoint = CGPoint(x: 0, y: 0.5)
        bossFill.position = CGPoint(x: -200, y: 0)
        bossNode.addChild(bossFill)
        let bl = label("MEGA CUBE", size: 18)
        bl.position = CGPoint(x: 0, y: 26)
        bossNode.addChild(bl)
        bossNode.isHidden = true
        buildTitle()
    }

    static let blindTexture: SKTexture = {
        SKTexture(cgImage: makeImage(1024, 1024) { ctx in
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let g = CGGradient(colorsSpace: cs, colors: [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.35), CGColor(gray: 0.02, alpha: 0.97), CGColor(gray: 0.02, alpha: 1)] as CFArray,
                               locations: [0, 0.05, 0.1, 1])!
            let c = CGPoint(x: 512, y: 512)
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: 512, options: [.drawsAfterEndLocation])
        })
    }()

    static let eyeIcon: SKTexture = {
        SKTexture(cgImage: makeImage(64, 64) { ctx in
            ctx.setFillColor(.white)
            ctx.fillEllipse(in: CGRect(x: 4, y: 4, width: 56, height: 56))
            ctx.setStrokeColor(CGColor(gray: 0.1, alpha: 1))
            ctx.setLineWidth(5)
            ctx.strokeEllipse(in: CGRect(x: 4, y: 4, width: 56, height: 56))
            ctx.setFillColor(CGColor(gray: 0.07, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: 18, y: 8, width: 30, height: 30))
            ctx.setFillColor(.white)
            ctx.fillEllipse(in: CGRect(x: 23, y: 26, width: 8, height: 8))
        })
    }()

    func layout(_ s: CGSize) {
        size = s
        let W = s.width / 2, H = s.height / 2
        eyesRow.position = CGPoint(x: -W + 36, y: H - 36)
        ammoRow.position = CGPoint(x: -W + 36, y: H - 84)
        ammoLabel.position = CGPoint(x: -W + 20, y: H - 118)
        scoreLabel.position = CGPoint(x: W - 24, y: H - 36)
        levelLabel.position = CGPoint(x: W - 24, y: H - 70)
        help.position = CGPoint(x: 0, y: -H + 26)
        saved.position = CGPoint(x: W - 70, y: -H + 60)
        toastLabel.position = CGPoint(x: 0, y: -H + 90)
        bannerNode.position = CGPoint(x: 0, y: H * 0.45)
        bossNode.position = CGPoint(x: 0, y: H - 50)
        title.position = .zero
        layoutTitle()
        help.setScale(min(1, s.width / 1300))
    }

    // MARK: per frame

    func update(_ g: Game, dt: Float) {
        let playing = g.state == .playing || g.state == .paused
        for n in [eyesRow, ammoRow, ammoLabel, scoreLabel, levelLabel] as [SKNode] { n.isHidden = !playing }
        if g.player.eyes.count != shownEyes { shownEyes = g.player.eyes.count; drawEyes(shownEyes) }
        if g.inventory != shownAmmo { shownAmmo = g.inventory; drawAmmo(g.inventory) }
        if g.score != shownScore {
            shownScore = g.score
            scoreLabel.attributedText = cartoonText("\(g.score)", size: 34, fill: hex(0xffe14d), width: -5)
            scoreLabel.run(.sequence([.scale(to: 1.12, duration: 0.05), .scale(to: 1, duration: 0.1)]))
        }
        if levelLabel.userData?["n"] as? Int != g.levelIndex {
            levelLabel.userData = ["n": g.levelIndex]
            levelLabel.attributedText = cartoonText(g.level.name, size: 17, fill: .white, width: -4)
        }
        if g.state == .playing { helpTime += dt }
        help.alpha = g.state == .paused ? 1 : g.state == .playing ? CGFloat(clampf(1.4 - (helpTime - 22) / 3, 0, 1)) : 0

        // blindness
        let eyes = g.player.eyes.count
        let wantBlind: CGFloat = playing && g.player.flushing < 0 ? (eyes == 0 ? 1 : eyes == 1 ? 0.55 : 0) : 0
        blind.alpha += (wantBlind - blind.alpha) * CGFloat(min(1, dt * 4))
        if blind.alpha > 0.01 {
            let camScale = root.xScale
            let sp = (g.player.c - V2(Float(g.cam.position.x), Float(g.cam.position.y))) / Float(camScale)
            blind.position = sp.cg
            let d = max(size.width, size.height) * (eyes == 0 ? 3.4 : 6.5)
            blind.size = CGSize(width: d, height: d)
        }

        toastTime -= dt
        toastLabel.alpha = CGFloat(clampf(toastTime * 2, 0, 1))
        savedTime -= dt
        saved.alpha = CGFloat(clampf(savedTime * 2, 0, 1))
        bannerTime -= dt
        bannerNode.alpha = CGFloat(clampf(bannerTime * 1.5, 0, 1))
    }

    private func drawEyes(_ n: Int) {
        eyesRow.removeAllChildren()
        if n == 0 {
            let l = label("NO EYES!", size: 24, fill: hex(0xff5a5a))
            l.horizontalAlignmentMode = .left
            l.position = CGPoint(x: -16, y: 0)
            l.run(.repeatForever(.sequence([.fadeAlpha(to: 0.4, duration: 0.3), .fadeAlpha(to: 1, duration: 0.3)])))
            eyesRow.addChild(l)
            return
        }
        for i in 0..<n {
            let s = SKSpriteNode(texture: HUD.eyeIcon)
            s.size = CGSize(width: 38, height: 38)
            s.position = CGPoint(x: CGFloat(i) * 34, y: 0)
            s.zRotation = CGFloat(Float.random(in: -0.6...0.6))
            eyesRow.addChild(s)
        }
        eyesRow.run(.sequence([.scale(to: 1.2, duration: 0.06), .scale(to: 1, duration: 0.12)]))
    }

    private func drawAmmo(_ inv: [Junk]) {
        ammoRow.removeAllChildren()
        let show = inv.suffix(9).reversed()
        if show.isEmpty {
            let p = SKSpriteNode(texture: emojiTexture(Junk.pea.emoji, size: 48))
            p.size = CGSize(width: 18, height: 18)
            ammoRow.addChild(p)
        }
        for (i, j) in show.enumerated() {
            let s = SKSpriteNode(texture: emojiTexture(j.emoji, size: 64))
            let sz: CGFloat = i == 0 ? 46 : 32
            s.size = CGSize(width: sz, height: sz)
            s.position = CGPoint(x: i == 0 ? 0 : CGFloat(i) * 34 + 14, y: i == 0 ? 0 : -4)
            ammoRow.addChild(s)
        }
        let text = inv.isEmpty ? "out of stuff — spitting peas" : "\(inv.count) thing\(inv.count == 1 ? "" : "s") · next: \(inv.last!.name)"
        ammoLabel.attributedText = cartoonText(text, size: 15, fill: .white, width: -4)
    }

    // MARK: messages

    func toast(_ s: String) {
        toastLabel.attributedText = cartoonText(s, size: 22, fill: .white)
        toastTime = 1.6
    }

    func flashSaved() { savedTime = 1.4 }

    func banner(_ top: String, _ sub: String) {
        bannerNode.removeAllChildren()
        let a = label(top, size: 30, fill: hex(0xffe14d))
        a.position = CGPoint(x: 0, y: 30)
        let b = label(sub, size: 54, fill: .white, width: -6)
        b.position = CGPoint(x: 0, y: -24)
        bannerNode.addChild(a); bannerNode.addChild(b)
        bannerNode.setScale(0.5)
        bannerNode.run(.scale(to: 1, duration: 0.18))
        bannerTime = 2.6
    }

    func bossBar(_ f: Float?) {
        guard let f = f else { bossNode.isHidden = true; return }
        bossNode.isHidden = false
        bossFill.size = CGSize(width: CGFloat(max(0, f)) * 400, height: 18)
    }

    // MARK: panels

    private func dim() -> SKSpriteNode {
        let d = SKSpriteNode(color: hex(0x10060c, 0.62), size: CGSize(width: size.width + 40, height: size.height + 40))
        d.zPosition = -1
        return d
    }

    func hidePanel() { panel.removeAllChildren() }

    func showPause() {
        panel.removeAllChildren()
        panel.addChild(dim())
        let t = label("PAUSED", size: 70, fill: hex(0xffe14d), width: -6)
        t.position = CGPoint(x: 0, y: 90)
        panel.addChild(t)
        let m = label("Esc — keep wobbling\nR — restart level\nQ — save & quit to title\nM — mute", size: 26)
        m.position = CGPoint(x: 0, y: -40)
        panel.addChild(m)
    }

    func showDone(level: LevelData, stats: (Int, Int, Int, Int, Int, Int, Float), last: Bool) {
        panel.removeAllChildren()
        panel.addChild(dim())
        let t = label("FLUSHED!", size: 76, fill: hex(0xffe14d), width: -6)
        t.position = CGPoint(x: 0, y: 170)
        t.run(.repeatForever(.sequence([.rotate(toAngle: 0.05, duration: 0.3), .rotate(toAngle: -0.05, duration: 0.3)])))
        panel.addChild(t)
        let s = label("\(level.name) complete", size: 28)
        s.position = CGPoint(x: 0, y: 100)
        panel.addChild(s)
        let secs = Int(stats.6)
        let body = """
        stuff collected: \(stats.3)
        things bonked: \(stats.2)
        eyes left: \(stats.4)  (+\(stats.4 * 200))
        times fell in a hole: \(stats.5)
        time: \(secs / 60):\(String(format: "%02d", secs % 60))
        level score: \(stats.0)
        """
        let b = label(body, size: 24, fill: .white, width: -4)
        b.position = CGPoint(x: 0, y: -40)
        panel.addChild(b)
        let go = label(last ? "ENTER — face the ending" : "ENTER — next level", size: 30, fill: hex(0x9dff8a))
        go.position = CGPoint(x: 0, y: -200)
        go.run(.repeatForever(.sequence([.fadeAlpha(to: 0.4, duration: 0.5), .fadeAlpha(to: 1, duration: 0.5)])))
        panel.addChild(go)
    }

    func showWin(score: Int) {
        panel.removeAllChildren()
        panel.addChild(dim())
        let t = label("YOU WIN!", size: 96, fill: hex(0xffe14d), width: -7)
        t.position = CGPoint(x: 0, y: 150)
        t.run(.repeatForever(.sequence([.scale(to: 1.08, duration: 0.4), .scale(to: 1, duration: 0.4)])))
        panel.addChild(t)
        let b = label("You defeated Cube Corp, flushed three golden toilets\nand are officially the googliest guy alive.\n\nfinal score: \(score)",
                      size: 28)
        b.position = CGPoint(x: 0, y: -10)
        panel.addChild(b)
        let c = label("a game by Vincent\n\nENTER — back to the title", size: 22, fill: hex(0x9dff8a))
        c.position = CGPoint(x: 0, y: -190)
        panel.addChild(c)
    }

    // MARK: title

    private func buildTitle() {
        let g = label("G", size: 150, fill: Player.red, stroke: hex(0x3a0508), width: -4)
        g.name = "G"
        let rest = label("GLY", size: 150, fill: Player.red, stroke: hex(0x3a0508), width: -4)
        rest.name = "GLY"
        titleLogo.addChild(g)
        titleLogo.addChild(rest)
        for _ in 0..<2 {
            var e = Googly(R: 50, pupil: 25)
            e.attach(to: titleLogo, z: 2, outline: 6)
            titleEyes.append(e)
        }
        title.addChild(titleLogo)
    }

    private func layoutTitle() {
        guard let g = titleLogo.childNode(withName: "G"), let r = titleLogo.childNode(withName: "GLY") else { return }
        let gw = g.frame.width, rw = r.frame.width
        let eyeW: CGFloat = 104
        let total = gw + eyeW * 2 + rw + 10
        var x = -total / 2
        g.position = CGPoint(x: x + gw / 2, y: 0); x += gw + 5
        titleEyes[0].node?.position = CGPoint(x: x + eyeW / 2, y: -8); x += eyeW
        titleEyes[1].node?.position = CGPoint(x: x + eyeW / 2, y: -8); x += eyeW + 5
        r.position = CGPoint(x: x + rw / 2, y: 0)
        titleLogo.position = CGPoint(x: 0, y: size.height * 0.22)
        logoY = titleLogo.position.y
    }

    func showTitle(save: SaveData) {
        title.isHidden = false
        title.children.filter { $0 !== titleLogo }.forEach { $0.removeFromParent() }
        let sub = label("a wobbly red guy with googly eyes", size: 26, fill: .white)
        sub.position = CGPoint(x: 0, y: size.height * 0.22 - 110)
        title.addChild(sub)
        var lines = ["SPACE — new game"]
        if let r = save.run { lines.append("ENTER — continue (\(LevelData.names[r.level]))") }
        if save.unlocked > 1 { lines.append("1–\(save.unlocked) — pick a level") }
        lines.append("M — mute · ⌘F — full screen")
        let m = label(lines.joined(separator: "\n"), size: 28, fill: hex(0xffe14d))
        m.position = CGPoint(x: 0, y: -size.height * 0.1)
        m.run(.repeatForever(.sequence([.scale(to: 1.04, duration: 0.6), .scale(to: 1, duration: 0.6)])))
        title.addChild(m)
        let c = label("move A/D · jump SPACE · squish S · spit CLICK · honk H", size: 18, fill: .white, width: -4)
        c.position = CGPoint(x: 0, y: -size.height / 2 + 60)
        title.addChild(c)
        let by = label("a game by Vincent" + (save.wins > 0 ? "  ·  🏆 × \(save.wins)" : ""), size: 16, fill: hex(0xffffff, 0.85), width: -3)
        by.position = CGPoint(x: 0, y: -size.height / 2 + 28)
        title.addChild(by)
    }

    func hideTitle() { title.isHidden = true; helpTime = 0 }

    /// Bouncy logo: a damped spring kicked every couple of seconds; the eyes ride it.
    func titleTick(_ dt: Float, time: Float) {
        guard !title.isHidden else { return }
        let target = size.height * 0.22
        if Int(time * 10) % 25 == 0 && logoVel == 0 { logoVel = 900 }
        logoVel += (target - titleLogo.position.y) * 180 * CGFloat(dt) - logoVel * 4 * CGFloat(dt)
        titleLogo.position.y += logoVel * CGFloat(dt)
        if abs(logoVel) < 4 && abs(titleLogo.position.y - target) < 0.5 { logoVel = 0; titleLogo.position.y = target }
        titleLogo.zRotation = CGFloat(sinf(time * 1.3) * 0.03)
        for i in titleEyes.indices {
            guard let n = titleEyes[i].node else { continue }
            let p = titleLogo.convert(n.position, to: title)
            titleEyes[i].update(V2(p), dt: dt, gravity: -2600)
            titleEyes[i].pupil?.position = titleEyes[i].p.cg
        }
    }
}
