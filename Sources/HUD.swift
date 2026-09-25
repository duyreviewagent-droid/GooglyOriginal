import SpriteKit

// Styled after GooglyGamble: Avenir Next Heavy/DemiBold UI, Futura Condensed ExtraBold titles with a
// hard drop shadow, dark translucent rounded panels with thin coloured borders.
let uiFont = "AvenirNext-Heavy"
let uiFontMed = "AvenirNext-DemiBold"
let titleFont = "Futura-CondensedExtraBold"

func lbl(_ s: String, size: CGFloat, color: NSColor = .white, font: String = uiFont, align: SKLabelHorizontalAlignmentMode = .center) -> SKLabelNode {
    let l = SKLabelNode(fontNamed: font)
    l.text = s
    l.fontSize = size
    l.fontColor = color
    l.horizontalAlignmentMode = align
    l.verticalAlignmentMode = .center
    return l
}

func roundRect(_ w: CGFloat, _ h: CGFloat, r: CGFloat = 12, fill: NSColor, stroke: NSColor = .clear, line: CGFloat = 0) -> SKShapeNode {
    let s = SKShapeNode(rectOf: CGSize(width: w, height: h), cornerRadius: r)
    s.fillColor = fill
    s.strokeColor = stroke
    s.lineWidth = line
    return s
}

/// Big title text with a hard offset shadow.
func shadowTitle(_ s: String, size: CGFloat, color: NSColor, shadow: NSColor, offset: CGFloat? = nil) -> SKNode {
    let n = SKNode()
    let o = offset ?? size * 0.06
    let sh = lbl(s, size: size, color: shadow, font: titleFont)
    sh.position = CGPoint(x: o, y: -o)
    n.addChild(sh)
    n.addChild(lbl(s, size: size, color: color, font: titleFont))
    return n
}

/// A pill showing a key and what it does, like GooglyGamble's buttons.
func keyPill(_ key: String, _ what: String, color: NSColor = hex(0x1f8a4c)) -> SKNode {
    let n = SKNode()
    let k = lbl(key, size: 18, color: .white)
    let t = lbl(what, size: 18, color: .white, font: uiFontMed)
    let kw: CGFloat = max(44, k.frame.width + 24)
    let tw: CGFloat = t.frame.width
    let w: CGFloat = kw + tw + 34
    n.addChild(roundRect(w, 46, r: 12, fill: color, stroke: NSColor(white: 1, alpha: 0.85), line: 2))
    let kb = roundRect(kw, 30, r: 8, fill: NSColor(white: 0, alpha: 0.3))
    let kx: CGFloat = -w / 2 + 8 + kw / 2
    kb.position = CGPoint(x: kx, y: 0)
    n.addChild(kb)
    k.position = kb.position
    n.addChild(k)
    let tx: CGFloat = -w / 2 + 18 + kw + tw / 2
    t.position = CGPoint(x: tx, y: 0)
    n.addChild(t)
    return n
}

final class HUD {
    let root = SKNode()
    /// World-anchored labels (name tags, popups, speech bubbles) projected from 3D.
    let world = SKNode()
    private var size = CGSize(width: 1440, height: 900)
    private let cards = SKNode()
    private let board = SKNode()
    private let scoreBox = SKNode()
    private let scoreLabel = lbl("0", size: 34, color: hex(0xffd84a))
    private let scoreTitle = lbl("TEAM SCORE", size: 11, color: NSColor(white: 1, alpha: 0.7), font: uiFontMed)
    private let levelLabel = lbl("", size: 13, color: NSColor(white: 1, alpha: 0.75), font: uiFontMed)
    private let help = lbl("", size: 14, color: NSColor(white: 1, alpha: 0.8), font: uiFontMed)
    private let saved = lbl("SAVED ✓", size: 16, color: hex(0x9dff8a))
    private let toastNode = SKNode()
    private let bannerNode = SKNode()
    private let blind = SKSpriteNode()
    private let panel = SKNode()
    private let title = SKNode()
    private let joinRow = SKNode()
    private let countdown = SKNode()
    private let onlinePanel = SKNode()
    private var onlineKey = ""
    private var titlePills: [SKNode] = []
    private var titleEyes: [FlatEye] = []
    private let titleLogo = SKNode()
    private let bossNode = SKNode()
    private let bossFill = SKSpriteNode(color: hex(0xff4d6d), size: CGSize(width: 400, height: 14))
    private var cardKey = "", boardKey = "", shownScore = -1, helpKey = "", joinKey = ""
    private var helpTime: Float = 0
    private var toastTime: Float = 0
    private var savedTime: Float = 0
    private var bannerTime: Float = 0
    private var logoVel: CGFloat = 0

    init() {
        for n in [world, cards, board, scoreBox, help, saved, toastNode, bannerNode, bossNode] as [SKNode] { root.addChild(n) }
        world.zPosition = 5
        cards.zPosition = 10; board.zPosition = 10; scoreBox.zPosition = 10
        blind.texture = HUD.blindTexture
        blind.zPosition = 2
        blind.alpha = 0
        root.addChild(blind)
        panel.zPosition = 50
        root.addChild(panel)
        title.zPosition = 40
        root.addChild(title)
        toastNode.zPosition = 30
        saved.alpha = 0
        scoreBox.addChild(roundRect(220, 74, fill: NSColor(white: 0, alpha: 0.55), stroke: hex(0xffd84a, 0.5), line: 1.5))
        scoreTitle.position = CGPoint(x: 0, y: 22)
        scoreBox.addChild(scoreTitle)
        scoreLabel.position = CGPoint(x: 0, y: -2)
        scoreBox.addChild(scoreLabel)
        levelLabel.position = CGPoint(x: 0, y: -26)
        scoreBox.addChild(levelLabel)
        bossNode.addChild(roundRect(420, 44, r: 10, fill: NSColor(white: 0, alpha: 0.6), stroke: hex(0xff4d6d, 0.7), line: 1.5))
        let bl = lbl("MEGA CUBE · CHIEF EXECUTIVE CUBE", size: 11, color: hex(0xffb3c0), font: uiFontMed)
        bl.position = CGPoint(x: 0, y: 10)
        bossNode.addChild(bl)
        let bb = SKSpriteNode(color: NSColor(white: 1, alpha: 0.12), size: CGSize(width: 400, height: 14))
        bb.anchorPoint = CGPoint(x: 0, y: 0.5); bb.position = CGPoint(x: -200, y: -8)
        bossNode.addChild(bb)
        bossFill.anchorPoint = CGPoint(x: 0, y: 0.5)
        bossFill.position = CGPoint(x: -200, y: -8)
        bossNode.addChild(bossFill)
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
        cards.position = CGPoint(x: -W + 16, y: H - 14)
        board.position = CGPoint(x: W - 16, y: H - 14)
        scoreBox.position = CGPoint(x: 0, y: H - 50)
        bossNode.position = CGPoint(x: 0, y: H - 118)
        help.position = CGPoint(x: 0, y: -H + 16)
        saved.position = CGPoint(x: W - 60, y: -H + 40)
        toastNode.position = CGPoint(x: 0, y: -H + 90)
        bannerNode.position = CGPoint(x: 0, y: H * 0.42)
        layoutTitle()
        cardKey = ""; boardKey = ""; joinKey = ""
    }

    // MARK: per frame

    func update(_ g: Game, dt: Float) {
        let playing = g.state == .playing || g.state == .paused
        for n in [cards, board, scoreBox] as [SKNode] { n.isHidden = !playing }
        if playing {
            drawCards(g)
            drawBoard(g)
        }
        if g.score != shownScore {
            shownScore = g.score
            scoreLabel.text = "\(g.score)"
            scoreLabel.run(.sequence([.scale(to: 1.12, duration: 0.05), .scale(to: 1, duration: 0.1)]))
        }
        levelLabel.text = g.level.name.uppercased()
        scoreTitle.text = g.slots.count > 1 ? "TEAM SCORE" : "SCORE"
        if g.state == .playing { helpTime += dt }
        let hk = g.slots.map { $0.scheme.controlsHint }.joined(separator: "   |   ")
        if hk != helpKey {
            helpKey = hk
            help.text = g.slots.count == 1 ? hk.replacingOccurrences(of: " · T teleport", with: "") + " · scroll zoom · Esc pause" : hk
            help.fontSize = g.slots.count > 2 ? 11 : 14
            help.setScale(1)
            help.setScale(min(1, (size.width - 40) / max(1, help.frame.width)))
        }
        help.alpha = g.state == .paused ? 1 : g.state == .playing ? CGFloat(clampf(1.4 - (helpTime - 22) / 3, 0, 1)) : 0

        // blindness only makes sense on a solo screen
        let solo = g.slots.count == 1
        let eyes = g.player.eyes.count
        let wantBlind: CGFloat = playing && solo && g.player.flushing < 0 ? (eyes == 0 ? 1 : eyes == 1 ? 0.35 : 0) : 0
        blind.alpha += (wantBlind - blind.alpha) * CGFloat(min(1, dt * 4))
        if blind.alpha > 0.01, let sp = g.project(g.player.c) {
            blind.position = sp
            let d = max(size.width, size.height) * (eyes == 0 ? 3.4 : 8)
            blind.size = CGSize(width: d, height: d)
        }
        toastTime -= dt
        toastNode.alpha = CGFloat(clampf(toastTime * 2, 0, 1))
        savedTime -= dt
        saved.alpha = CGFloat(clampf(savedTime * 2, 0, 1))
        bannerTime -= dt
        bannerNode.alpha = CGFloat(clampf(bannerTime * 1.5, 0, 1))
    }

    /// One card per player: colour stripe, name, eyes, ammo.
    private func drawCards(_ g: Game) {
        let key = g.slots.map { "\($0.index):\($0.body.eyes.count):\($0.inventory.count):\($0.inventory.last?.rawValue ?? -1):\($0.body.ko > 0)" }.joined(separator: ",")
        guard key != cardKey else { return }
        cardKey = key
        cards.removeAllChildren()
        let w: CGFloat = 250, h: CGFloat = 88
        for (k, s) in g.slots.enumerated() {
            let c = SKNode()
            c.position = CGPoint(x: w / 2 + CGFloat(k % 2) * (w + 10), y: -h / 2 - CGFloat(k / 2) * (h + 10))
            c.addChild(roundRect(w, h, fill: NSColor(white: 0, alpha: 0.55), stroke: s.color.withAlphaComponent(0.8), line: 2))
            let stripe = roundRect(8, h - 16, r: 4, fill: s.color)
            stripe.position = CGPoint(x: -w / 2 + 12, y: 0)
            c.addChild(stripe)
            let n = lbl("\(s.name) · \(Player.colorNames[s.index])", size: 15, color: s.color.blended(withFraction: 0.35, of: .white) ?? s.color, align: .left)
            n.position = CGPoint(x: -w / 2 + 26, y: h / 2 - 18)
            c.addChild(n)
            if s.body.ko > 0 {
                let ko = lbl("K.O.", size: 15, color: hex(0xff6b6b), align: .right)
                ko.position = CGPoint(x: w / 2 - 12, y: h / 2 - 18)
                c.addChild(ko)
            }
            let e = s.body.eyes.count
            if e == 0 {
                let l = lbl("NO EYES!", size: 14, color: hex(0xff6b6b), align: .left)
                l.position = CGPoint(x: -w / 2 + 26, y: 2)
                c.addChild(l)
            }
            for i in 0..<e {
                let sp = SKSpriteNode(texture: HUD.eyeIcon)
                sp.size = CGSize(width: 22, height: 22)
                sp.position = CGPoint(x: -w / 2 + 38 + CGFloat(i) * 20, y: 2)
                sp.zRotation = CGFloat((Float(i) * 1.7).truncatingRemainder(dividingBy: 1.2) - 0.6)
                c.addChild(sp)
            }
            let inv = s.inventory
            if let next = inv.last {
                let sp = SKSpriteNode(texture: emojiTexture(next.emoji, size: 64))
                sp.size = CGSize(width: 26, height: 26)
                sp.position = CGPoint(x: -w / 2 + 40, y: -h / 2 + 20)
                c.addChild(sp)
            }
            let t = lbl(inv.isEmpty ? "out of stuff · spitting peas" : "×\(inv.count) · next: \(inv.last!.name)", size: 12,
                        color: NSColor(white: 1, alpha: 0.8), font: uiFontMed, align: .left)
            t.position = CGPoint(x: -w / 2 + (inv.isEmpty ? 26 : 58), y: -h / 2 + 20)
            c.addChild(t)
            cards.addChild(c)
        }
    }

    /// Race standings: who's closest to the golden toilet.
    private func drawBoard(_ g: Game) {
        let ranked = g.slots.sorted { $0.body.c.x > $1.body.c.x }
        let span = max(1, g.level.goal.x - g.level.start.x)
        func frac(_ s: Slot) -> Float { clampf((s.body.c.x - g.level.start.x) / span, 0, 1) }
        let key = ranked.map { "\($0.index):\(Int(frac($0) * 50))" }.joined(separator: ",") + "\(g.leader?.index ?? -1)"
        guard key != boardKey else { return }
        boardKey = key
        board.removeAllChildren()
        let w: CGFloat = 300, rowH: CGFloat = 34
        let h = 44 + rowH * CGFloat(ranked.count)
        let bg = roundRect(w, h, fill: NSColor(white: 0, alpha: 0.55), stroke: NSColor(white: 1, alpha: 0.25), line: 1.5)
        bg.position = CGPoint(x: -w / 2, y: -h / 2)
        board.addChild(bg)
        let multi = g.slots.count > 1
        let t = lbl(multi ? "RACE TO THE GOLDEN TOILET" : "DISTANCE TO THE GOLDEN TOILET", size: 12, color: hex(0xffd84a), font: uiFontMed)
        t.position = CGPoint(x: -w / 2, y: -20)
        board.addChild(t)
        for (r, s) in ranked.enumerated() {
            let y = -44 - CGFloat(r) * rowH - rowH / 2 + 6
            let lead = multi && s === g.leader
            if lead {
                let hl = roundRect(w - 16, rowH - 4, r: 8, fill: s.color.withAlphaComponent(0.3))
                hl.position = CGPoint(x: -w / 2, y: y)
                board.addChild(hl)
            }
            let rk = lbl("\(r + 1)", size: 15, color: NSColor(white: 1, alpha: 0.7))
            rk.position = CGPoint(x: -w + 22, y: y)
            board.addChild(rk)
            let dot = SKShapeNode(circleOfRadius: 8)
            dot.fillColor = s.color; dot.strokeColor = .white; dot.lineWidth = 1.5
            dot.position = CGPoint(x: -w + 44, y: y)
            board.addChild(dot)
            let nm = lbl(s.name + (lead ? " 👑" : ""), size: 15, align: .left)
            nm.position = CGPoint(x: -w + 58, y: y)
            board.addChild(nm)
            let f = CGFloat(frac(s))
            let barW: CGFloat = 120
            let bb = SKSpriteNode(color: NSColor(white: 1, alpha: 0.15), size: CGSize(width: barW, height: 8))
            bb.anchorPoint = CGPoint(x: 0, y: 0.5); bb.position = CGPoint(x: -barW - 50, y: y)
            board.addChild(bb)
            let bf = SKSpriteNode(color: s.color, size: CGSize(width: max(2, barW * f), height: 8))
            bf.anchorPoint = CGPoint(x: 0, y: 0.5); bf.position = bb.position
            board.addChild(bf)
            let pc = lbl("\(Int(f * 100))%", size: 13, color: hex(0x8dffa0), align: .right)
            pc.position = CGPoint(x: -14, y: y)
            board.addChild(pc)
        }
    }

    // MARK: messages

    func toast(_ s: String) {
        toastNode.removeAllChildren()
        let l = lbl(s, size: 18)
        toastNode.addChild(roundRect(l.frame.width + 44, 42, r: 21, fill: NSColor(white: 0, alpha: 0.65), stroke: NSColor(white: 1, alpha: 0.4), line: 1.5))
        toastNode.addChild(l)
        toastTime = 1.8
    }

    func flashSaved() { savedTime = 1.4 }

    func banner(_ top: String, _ sub: String) {
        bannerNode.removeAllChildren()
        let a = lbl(top, size: 18, color: hex(0xffd84a), font: uiFontMed)
        a.position = CGPoint(x: 0, y: 48)
        bannerNode.addChild(a)
        bannerNode.addChild(shadowTitle(sub.uppercased(), size: 64, color: .white, shadow: hex(0x0b1d3a)))
        bannerNode.setScale(0.5)
        bannerNode.run(.scale(to: 1, duration: 0.18))
        bannerTime = 2.6
    }

    func bossBar(_ f: Float?) {
        guard let f = f else { bossNode.isHidden = true; return }
        bossNode.isHidden = false
        bossFill.size = CGSize(width: CGFloat(max(0, f)) * 400, height: 14)
    }

    // MARK: panels

    private func dim() -> SKSpriteNode {
        let d = SKSpriteNode(color: hex(0x0b0610, 0.6), size: CGSize(width: size.width + 40, height: size.height + 40))
        d.zPosition = -2
        return d
    }

    private func box(_ w: CGFloat, _ h: CGFloat, accent: NSColor) -> SKShapeNode {
        let b = roundRect(w, h, r: 22, fill: NSColor(white: 0.03, alpha: 0.82), stroke: accent.withAlphaComponent(0.7), line: 2)
        b.zPosition = -1
        return b
    }

    func hidePanel() { panel.removeAllChildren() }

    func showPause() {
        panel.removeAllChildren()
        panel.addChild(dim())
        panel.addChild(box(520, 400, accent: hex(0xffd84a)))
        let t = shadowTitle("PAUSED", size: 72, color: hex(0xffd84a), shadow: hex(0x3a2a00))
        t.position = CGPoint(x: 0, y: 130)
        panel.addChild(t)
        for (i, (k, w)) in [("ESC", "keep wobbling"), ("R", "restart level"), ("Q", "save & quit to title"), ("M", "mute")].enumerated() {
            let p = keyPill(k, w, color: i == 0 ? hex(0x1f8a4c) : hex(0x2b2f3a))
            p.position = CGPoint(x: 0, y: 40 - CGFloat(i) * 58)
            panel.addChild(p)
        }
    }

    func showDone(level: LevelData, got: Int, slots: [Slot], time: Float, last: Bool, waiting: Bool = false) {
        panel.removeAllChildren()
        panel.addChild(dim())
        let h: CGFloat = 330 + CGFloat(slots.count) * 40
        panel.addChild(box(660, h, accent: hex(0x8dffa0)))
        let t = shadowTitle("FLUSHED!", size: 84, color: hex(0xffd84a), shadow: hex(0x3a2a00))
        t.position = CGPoint(x: 0, y: h / 2 - 70)
        t.run(.repeatForever(.sequence([.rotate(toAngle: 0.04, duration: 0.3), .rotate(toAngle: -0.04, duration: 0.3)])))
        panel.addChild(t)
        let secs = Int(time)
        let s = lbl("\(level.name.uppercased()) COMPLETE · \(secs / 60):\(String(format: "%02d", secs % 60)) · +\(got) POINTS", size: 16,
                    color: NSColor(white: 1, alpha: 0.85), font: uiFontMed)
        s.position = CGPoint(x: 0, y: h / 2 - 135)
        panel.addChild(s)
        for (k, hd) in ["STUFF", "BONKS", "EYES", "FALLS"].enumerated() {
            let l = lbl(hd, size: 12, color: hex(0xffd84a), font: uiFontMed)
            l.position = CGPoint(x: -60 + CGFloat(k) * 92, y: h / 2 - 175)
            panel.addChild(l)
        }
        let order = slots.sorted { ($0.flushOrder < 0 ? 99 : $0.flushOrder) < ($1.flushOrder < 0 ? 99 : $1.flushOrder) }
        for (i, sl) in order.enumerated() {
            let y = h / 2 - 212 - CGFloat(i) * 40
            let row = roundRect(600, 34, r: 8, fill: sl.color.withAlphaComponent(i == 0 && slots.count > 1 ? 0.35 : 0.15))
            row.position = CGPoint(x: 0, y: y)
            panel.addChild(row)
            let name = lbl((i == 0 && slots.count > 1 ? "👑 " : "") + sl.name + " " + Player.colorNames[sl.index], size: 15, align: .left)
            name.position = CGPoint(x: -285, y: y)
            panel.addChild(name)
            for (k, v) in [sl.collected, sl.bonks, sl.body.eyes.count, sl.falls].enumerated() {
                let l = lbl("\(v)", size: 16, color: hex(0x8dffa0))
                l.position = CGPoint(x: -60 + CGFloat(k) * 92, y: y)
                panel.addChild(l)
            }
        }
        let go = waiting ? lbl("waiting for the host…", size: 18, color: hex(0xffd84a)) : keyPill("ENTER", last ? "face the ending" : "next level")
        go.position = CGPoint(x: 0, y: -h / 2 + 44)
        go.run(.repeatForever(.sequence([.fadeAlpha(to: 0.6, duration: 0.5), .fadeAlpha(to: 1, duration: 0.5)])))
        panel.addChild(go)
    }

    func showWin(score: Int, players: Int) {
        panel.removeAllChildren()
        panel.addChild(dim())
        panel.addChild(box(760, 440, accent: hex(0xffd84a)))
        let t = shadowTitle("YOU WIN!", size: 110, color: hex(0xffd84a), shadow: hex(0x3a2a00))
        t.position = CGPoint(x: 0, y: 120)
        t.run(.repeatForever(.sequence([.scale(to: 1.06, duration: 0.4), .scale(to: 1, duration: 0.4)])))
        panel.addChild(t)
        let who = players > 1 ? "Your googly gang" : "You"
        for (i, s) in ["\(who) fired the CEO of Cube Corp and flushed", "three golden toilets. Officially the googliest alive.", "", "FINAL SCORE  \(score)"].enumerated() {
            let l = lbl(s, size: i == 3 ? 28 : 19, color: i == 3 ? hex(0x8dffa0) : .white, font: i == 3 ? uiFont : uiFontMed)
            l.position = CGPoint(x: 0, y: 20 - CGFloat(i) * 32)
            panel.addChild(l)
        }
        let by = lbl("a game by Vincent", size: 14, color: NSColor(white: 1, alpha: 0.7), font: uiFontMed)
        by.position = CGPoint(x: 0, y: -150)
        panel.addChild(by)
        let go = keyPill("ENTER", "back to the title")
        go.position = CGPoint(x: 0, y: -190)
        panel.addChild(go)
    }

    // MARK: title

    private func buildTitle() {
        let shadow = hex(0x3a0508)
        let g = shadowTitle("G", size: 190, color: Player.red, shadow: shadow)
        g.name = "G"
        let rest = shadowTitle("GLY", size: 190, color: Player.red, shadow: shadow)
        rest.name = "GLY"
        titleLogo.addChild(g)
        titleLogo.addChild(rest)
        for _ in 0..<2 {
            let e = FlatEye(R: 58, r: 27)
            e.node.zPosition = 2
            titleLogo.addChild(e.node)
            titleEyes.append(e)
        }
        title.addChild(titleLogo)
        title.addChild(joinRow)
        title.addChild(countdown)
        title.addChild(onlinePanel)
    }

    private func layoutTitle() {
        guard let g = titleLogo.childNode(withName: "G"), let r = titleLogo.childNode(withName: "GLY") else { return }
        let gw = g.calculateAccumulatedFrame().width, rw = r.calculateAccumulatedFrame().width
        let eyeW: CGFloat = 122
        let total = gw + eyeW * 2 + rw + 16
        var x = -total / 2
        g.position = CGPoint(x: x + gw / 2, y: 0); x += gw + 8
        titleEyes[0].node.position = CGPoint(x: x + eyeW / 2, y: 0); x += eyeW
        titleEyes[1].node.position = CGPoint(x: x + eyeW / 2, y: 0); x += eyeW + 8
        r.position = CGPoint(x: x + rw / 2, y: 0)
        titleLogo.position = CGPoint(x: 0, y: size.height * 0.26)
        joinRow.position = CGPoint(x: 0, y: -size.height * 0.06)
        countdown.position = CGPoint(x: 0, y: -size.height * 0.06 - 118)
    }

    func showTitle(save: SaveData) {
        title.isHidden = false
        title.children.filter { $0 !== titleLogo && $0 !== joinRow && $0 !== countdown && $0 !== onlinePanel }.forEach { $0.removeFromParent() }
        onlinePanel.removeAllChildren()
        onlineKey = ""
        let sub = lbl("Wobbly jelly. Googly eyes. Up to four players. One golden toilet.", size: 22, font: uiFontMed)
        sub.position = CGPoint(x: 0, y: size.height * 0.26 - 130)
        let sb = roundRect(sub.frame.width + 40, 42, r: 21, fill: NSColor(white: 0, alpha: 0.45))
        sb.position = sub.position
        title.addChild(sb)
        title.addChild(sub)
        let by = lbl("a game by Vincent" + (save.wins > 0 ? "  ·  🏆 × \(save.wins)" : ""), size: 13, color: NSColor(white: 1, alpha: 0.8), font: uiFontMed)
        by.position = CGPoint(x: 0, y: -size.height / 2 + 22)
        title.addChild(by)
        let solo = keyPill("ENTER", "PLAY SOLO")
        solo.setScale(1.25)
        var pills: [SKNode] = [solo, keyPill("O", "play online", color: hex(0x7a3fd1))]
        if let r = save.run { pills.append(keyPill("C", "continue · \(LevelData.names[r.level])", color: hex(0x2b5fb8))) }
        if save.unlocked > 1 { pills.append(keyPill("1–\(save.unlocked)", "pick a level", color: hex(0x2b2f3a))) }
        pills.append(keyPill("M", "mute", color: hex(0x2b2f3a)))
        let gap: CGFloat = 16
        let tw = pills.reduce(0) { $0 + $1.calculateAccumulatedFrame().width } + gap * CGFloat(pills.count - 1)
        var x = -tw / 2
        for p in pills {
            let w = p.calculateAccumulatedFrame().width
            p.position = CGPoint(x: x + w / 2, y: -size.height / 2 + 84)
            x += w + gap
            title.addChild(p)
        }
        let coop = lbl("COUCH CO-OP (optional): friends on this Mac press their jump key to join · SPACE · / · Ⓐ", size: 14,
                       color: NSColor(white: 1, alpha: 0.9), font: uiFontMed)
        coop.position = CGPoint(x: 0, y: -size.height * 0.06 + 96)
        let cb = roundRect(coop.frame.width + 36, 32, r: 16, fill: NSColor(white: 0, alpha: 0.72))
        cb.position = coop.position
        title.addChild(cb)
        title.addChild(coop)
        titlePills = pills + [coop, cb]
        joinKey = ""
    }

    /// Online screens replace the join cards and key pills under the logo.
    func setOnlineMode(_ on: Bool) {
        joinRow.isHidden = on
        countdown.isHidden = on
        for p in titlePills { p.isHidden = on }
        onlinePanel.isHidden = !on
    }

    private func onlineBox(_ title: String, _ sub: String, h: CGFloat) -> SKNode {
        let n = SKNode()
        n.position = CGPoint(x: 0, y: -size.height * 0.1)
        n.addChild(roundRect(760, h, r: 22, fill: NSColor(white: 0.03, alpha: 0.82), stroke: hex(0x7a3fd1, 0.9), line: 2))
        let t = shadowTitle(title, size: 44, color: .white, shadow: hex(0x2a1050))
        t.position = CGPoint(x: 0, y: h / 2 - 44)
        n.addChild(t)
        let st = lbl(sub, size: 14, color: NSColor(white: 1, alpha: 0.75), font: uiFontMed)
        st.position = CGPoint(x: 0, y: h / 2 - 84)
        n.addChild(st)
        return n
    }

    func showOnline(status: String, lobbies: [[String: Any]], error: String, open: Bool) {
        let key = "o|\(status)|\(error)|\(open)|" + lobbies.map { "\($0.s("code"))\($0.i("n"))\($0.b("started"))" }.joined()
        guard key != onlineKey else { return }
        onlineKey = key
        onlinePanel.removeAllChildren()
        let rows = min(6, lobbies.count)
        let h: CGFloat = 250 + CGFloat(max(1, rows)) * 40
        let b = onlineBox("PLAY ONLINE", status, h: h)
        onlinePanel.addChild(b)
        let hp = keyPill("H", "host a lobby", color: open ? hex(0x1f8a4c) : hex(0x444444))
        hp.position = CGPoint(x: -150, y: h / 2 - 130)
        b.addChild(hp)
        let jp = keyPill("J", "join with a code", color: hex(0x2b5fb8))
        jp.position = CGPoint(x: 150, y: h / 2 - 130)
        b.addChild(jp)
        let lt = lbl("OPEN LOBBIES", size: 12, color: hex(0xffd84a), font: uiFontMed)
        lt.position = CGPoint(x: 0, y: h / 2 - 180)
        b.addChild(lt)
        if lobbies.isEmpty {
            let l = lbl(open ? "none right now — host one and send your friends the code" : "…", size: 14, color: NSColor(white: 1, alpha: 0.6), font: uiFontMed)
            l.position = CGPoint(x: 0, y: h / 2 - 212)
            b.addChild(l)
        }
        for (k, l) in lobbies.prefix(6).enumerated() {
            let y = h / 2 - 214 - CGFloat(k) * 40
            let row = roundRect(640, 34, r: 8, fill: NSColor(white: 1, alpha: 0.07))
            row.position = CGPoint(x: 0, y: y)
            b.addChild(row)
            let n = lbl("\(k + 1)", size: 15, color: hex(0xffd84a))
            n.position = CGPoint(x: -300, y: y); b.addChild(n)
            let c = lbl(l.s("code"), size: 18, color: .white, font: "Menlo-Bold")
            c.position = CGPoint(x: -230, y: y); b.addChild(c)
            let hname = lbl("\(l.s("host"))'s lobby", size: 15, font: uiFontMed, align: .left)
            hname.position = CGPoint(x: -170, y: y); b.addChild(hname)
            let info = lbl("\(l.i("n"))/4 · " + (l.b("started") ? "playing " : "waiting · ") + l.s("levelName"), size: 12, color: NSColor(white: 1, alpha: 0.7), font: uiFontMed, align: .right)
            info.position = CGPoint(x: 300, y: y); b.addChild(info)
        }
        if !error.isEmpty {
            let e = lbl(error, size: 15, color: hex(0xff8a8a))
            e.position = CGPoint(x: 0, y: -h / 2 - 26)
            b.addChild(e)
        }
        let esc = lbl("ESC — back   ·   solo & couch play are on the main title", size: 12, color: NSColor(white: 1, alpha: 0.6), font: uiFontMed)
        esc.position = CGPoint(x: 0, y: -h / 2 + 22)
        b.addChild(esc)
    }

    func showCodeEntry(_ code: String, status: String, error: String) {
        let key = "c|\(code)|\(status)|\(error)"
        guard key != onlineKey else { return }
        onlineKey = key
        onlinePanel.removeAllChildren()
        let h: CGFloat = 330
        let b = onlineBox("JOIN A LOBBY", "type your friend's 4-letter code", h: h)
        onlinePanel.addChild(b)
        let chars = Array(code)
        for i in 0..<4 {
            let x = CGFloat(i - 2) * 96 + 48
            let slotBox = roundRect(80, 96, r: 14, fill: NSColor(white: 1, alpha: 0.08), stroke: i == chars.count ? hex(0xffd84a) : NSColor(white: 1, alpha: 0.35), line: i == chars.count ? 3 : 1.5)
            slotBox.position = CGPoint(x: x, y: 0)
            b.addChild(slotBox)
            if i < chars.count {
                let l = shadowTitle(String(chars[i]), size: 64, color: hex(0xffd84a), shadow: hex(0x3a2a00))
                l.position = CGPoint(x: x, y: 0)
                b.addChild(l)
            }
        }
        let go = keyPill("ENTER", chars.count == 4 ? "join lobby" : "type 4 letters", color: chars.count == 4 ? hex(0x1f8a4c) : hex(0x444444))
        go.position = CGPoint(x: 0, y: -h / 2 + 50)
        b.addChild(go)
        let st = lbl(error.isEmpty ? status : error, size: 14, color: error.isEmpty ? NSColor(white: 1, alpha: 0.6) : hex(0xff8a8a), font: uiFontMed)
        st.position = CGPoint(x: 0, y: -h / 2 - 24)
        b.addChild(st)
    }

    func showLobby(code: String, slots: [Slot], host: Bool, level: Int, unlocked: Int, status: String, mySeat: Int) {
        let key = "l|\(code)|\(host)|\(level)|\(status)|" + slots.map { "\($0.index)\($0.name)" }.joined()
        guard key != onlineKey else { return }
        onlineKey = key
        onlinePanel.removeAllChildren()
        let h: CGFloat = 400
        let b = onlineBox("LOBBY", "tell your friends this code · up to 4 players · they can also join mid-game", h: h)
        b.position.y -= 20
        onlinePanel.addChild(b)
        let codeNode = shadowTitle(code.map { String($0) }.joined(separator: " "), size: 92, color: hex(0xffd84a), shadow: hex(0x3a2a00))
        codeNode.position = CGPoint(x: 0, y: h / 2 - 150)
        b.addChild(codeNode)
        for i in 0..<4 {
            let x = CGFloat(i) * 176 - 264
            let s = slots.first { $0.index == i }
            let col = Player.colors[i]
            let card = roundRect(160, 70, r: 14, fill: s != nil ? col.withAlphaComponent(0.4) : NSColor(white: 0, alpha: 0.4), stroke: s != nil ? col : NSColor(white: 1, alpha: 0.25), line: 2)
            card.position = CGPoint(x: x, y: -10)
            b.addChild(card)
            let n = lbl(s.map { $0.name + ($0.index == mySeat ? " (you)" : "") } ?? "waiting…", size: s != nil ? 16 : 13, color: s != nil ? .white : NSColor(white: 1, alpha: 0.5), font: s != nil ? uiFont : uiFontMed)
            n.position = CGPoint(x: x, y: 2)
            b.addChild(n)
            let r = lbl(i == 0 ? "HOST" : "P\(i + 1)", size: 11, color: col.blended(withFraction: 0.4, of: .white) ?? col, font: uiFontMed)
            r.position = CGPoint(x: x, y: -24)
            b.addChild(r)
        }
        if host {
            for k in 0..<3 {
                let ok = k < unlocked
                let p = keyPill("\(k + 1)", LevelData.names[k], color: k == level ? hex(0x7a3fd1) : ok ? hex(0x2b2f3a) : hex(0x1a1a1a))
                p.setScale(0.62)
                p.alpha = ok ? 1 : 0.4
                p.position = CGPoint(x: CGFloat(k - 1) * 240, y: -86)
                b.addChild(p)
            }
            let go = keyPill("ENTER", slots.count <= 1 ? "start — solo is fine" : "start with \(slots.count) players")
            go.position = CGPoint(x: 0, y: -h / 2 + 40)
            b.addChild(go)
        } else {
            let w = lbl("waiting for the host to start…", size: 18, color: hex(0xffd84a))
            w.position = CGPoint(x: 0, y: -h / 2 + 50)
            w.run(.repeatForever(.sequence([.fadeAlpha(to: 0.5, duration: 0.6), .fadeAlpha(to: 1, duration: 0.6)])))
            b.addChild(w)
        }
        let st = lbl(status + "   ·   ESC leave", size: 12, color: NSColor(white: 1, alpha: 0.6), font: uiFontMed)
        st.position = CGPoint(x: 0, y: -h / 2 - 22)
        b.addChild(st)
    }

    func showOnlineMenu(host: Bool) {
        panel.removeAllChildren()
        panel.addChild(box(560, 300, accent: hex(0x7a3fd1)))
        let t = shadowTitle("ONLINE", size: 64, color: .white, shadow: hex(0x2a1050))
        t.position = CGPoint(x: 0, y: 90)
        panel.addChild(t)
        let n = lbl("the game keeps going while this is open", size: 13, color: NSColor(white: 1, alpha: 0.7), font: uiFontMed)
        n.position = CGPoint(x: 0, y: 40)
        panel.addChild(n)
        let a = keyPill("ESC", "back to the game")
        a.position = CGPoint(x: 0, y: -10)
        panel.addChild(a)
        let q = keyPill("Q", host ? "end the lobby for everyone" : "leave the lobby", color: hex(0x9a2a2a))
        q.position = CGPoint(x: 0, y: -70)
        panel.addChild(q)
    }

    /// Four join slots, filled in as players press their jump button.
    func titleJoin(_ g: Game, countdownLeft: Float?) {
        let padCount = Devices.pads().count
        let schemes: [Scheme] = [.keysA, .keysB] + (0..<padCount).map { Scheme.pad($0) }
        let key = g.slots.map { "\($0.index)\($0.scheme.label)" }.joined() + "\(padCount)"
        if key != joinKey {
            joinKey = key
            joinRow.removeAllChildren()
            let w: CGFloat = 230, h: CGFloat = 150, gap: CGFloat = 18
            for i in 0..<4 {
                let c = SKNode()
                c.position = CGPoint(x: -1.5 * (w + gap) + CGFloat(i) * (w + gap), y: 0)
                let col = Player.colors[i]
                if i < g.slots.count {
                    let s = g.slots[i]
                    c.addChild(roundRect(w, h, r: 18, fill: col.withAlphaComponent(0.4), stroke: col, line: 3))
                    let t = shadowTitle("P\(i + 1) " + Player.colorNames[i], size: 44, color: .white, shadow: col.blended(withFraction: 0.6, of: .black)!)
                    t.position = CGPoint(x: 0, y: 28)
                    c.addChild(t)
                    let d = lbl(s.scheme.label, size: 13, color: NSColor(white: 1, alpha: 0.9), font: uiFontMed)
                    d.position = CGPoint(x: 0, y: -18)
                    c.addChild(d)
                    let r = lbl("READY!", size: 16, color: hex(0x8dffa0))
                    r.position = CGPoint(x: 0, y: -48)
                    c.addChild(r)
                } else {
                    c.addChild(roundRect(w, h, r: 18, fill: NSColor(white: 0, alpha: 0.5), stroke: NSColor(white: 1, alpha: 0.3), line: 2))
                    let t = lbl("P\(i + 1)", size: 30, color: col)
                    t.position = CGPoint(x: 0, y: 36)
                    c.addChild(t)
                    let free = schemes.filter { sc in !g.slots.contains { $0.scheme == sc } }
                    let l1 = lbl("PRESS JUMP TO JOIN", size: 13, color: hex(0xffd84a), font: uiFontMed)
                    l1.position = CGPoint(x: 0, y: 0)
                    c.addChild(l1)
                    for (k, sc) in free.prefix(2).enumerated() {
                        let l = lbl("\(sc.joinHint)  ·  \(sc.label)", size: 11, color: NSColor(white: 1, alpha: 0.8), font: uiFontMed)
                        l.position = CGPoint(x: 0, y: -26 - CGFloat(k) * 18)
                        c.addChild(l)
                    }
                    c.run(.repeatForever(.sequence([.fadeAlpha(to: 0.7, duration: 0.7), .fadeAlpha(to: 1, duration: 0.7)])))
                }
                joinRow.addChild(c)
            }
        }
        countdown.removeAllChildren()
        if let left = countdownLeft {
            let n = Int(ceilf(left))
            let t = lbl(g.slots.count <= 1 ? "PLAYING SOLO IN \(n)…  (ENTER = go now · friends press jump to join)" : "\(g.slots.count) PLAYERS · STARTING IN \(n)…  (ENTER = go now)",
                        size: 20, color: hex(0xffd84a))
            countdown.addChild(roundRect(t.frame.width + 50, 46, r: 23, fill: NSColor(white: 0, alpha: 0.6), stroke: hex(0xffd84a, 0.6), line: 1.5))
            countdown.addChild(t)
        }
    }

    func hideTitle() { title.isHidden = true; helpTime = 0 }

    /// Bouncy logo: a damped spring kicked every couple of seconds; the eyes ride it.
    func titleTick(_ dt: Float, time: Float) {
        guard !title.isHidden else { return }
        let target = size.height * 0.26
        if Int(time * 10) % 25 == 0 && logoVel == 0 { logoVel = 900 }
        logoVel += (target - titleLogo.position.y) * 180 * CGFloat(dt) - logoVel * 4 * CGFloat(dt)
        titleLogo.position.y += logoVel * CGFloat(dt)
        if abs(logoVel) < 4 && abs(titleLogo.position.y - target) < 0.5 { logoVel = 0; titleLogo.position.y = target }
        titleLogo.zRotation = CGFloat(sinf(time * 1.3) * 0.03)
        for e in titleEyes { e.update(V2(titleLogo.convert(e.node.position, to: title)), dt: dt) }
    }

    static func speechBubble(_ text: String, color: NSColor = hex(0x1d1016)) -> SKNode {
        let n = SKNode()
        let l = lbl(text, size: 17, color: hex(0x1d1016), font: uiFont)
        let w = max(60, l.frame.width + 28), h: CGFloat = 38
        let path = CGMutablePath()
        path.addRoundedRect(in: CGRect(x: -w / 2, y: 14, width: w, height: h), cornerWidth: 14, cornerHeight: 14)
        path.move(to: CGPoint(x: -10, y: 15)); path.addLine(to: CGPoint(x: 0, y: 0)); path.addLine(to: CGPoint(x: 12, y: 15))
        let b = SKShapeNode(path: path)
        b.fillColor = .white
        b.strokeColor = color
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

/// A flat googly eye for the title logo.
final class FlatEye {
    let node: SKShapeNode
    let pupil: SKShapeNode
    let R: Float, r: Float
    var p = V2(0, -10), pv = V2(0, 0), lastE = V2(0, 0), lastVE = V2(0, 0), primed = false

    init(R: Float, r: Float) {
        self.R = R; self.r = r
        node = SKShapeNode(circleOfRadius: CGFloat(R))
        node.fillColor = .white
        node.strokeColor = hex(0x3a0508)
        node.lineWidth = 9
        pupil = SKShapeNode(circleOfRadius: CGFloat(r))
        pupil.fillColor = hex(0x111111)
        pupil.strokeColor = .clear
        let glint = SKShapeNode(circleOfRadius: CGFloat(r) * 0.28)
        glint.fillColor = .white; glint.strokeColor = .clear
        glint.position = CGPoint(x: -CGFloat(r) * 0.35, y: CGFloat(r) * 0.35)
        pupil.addChild(glint)
        node.addChild(pupil)
    }

    func update(_ E: V2, dt: Float) {
        guard dt > 0 else { return }
        if !primed { lastE = E; primed = true }
        let ve = (E - lastE) / dt
        let ae = (ve - lastVE) / dt
        lastE = E; lastVE = ve
        pv += (V2(0, -2600) - ae) * dt
        pv *= 1 - 1.2 * dt
        p += pv * dt
        let maxD = R - r, d = p.len
        if d > maxD {
            let n = p / d
            p = n * maxD
            let vn = dot(pv, n)
            if vn > 0 { pv -= n * vn * 1.5 }
        }
        pupil.position = p.cg
    }
}
