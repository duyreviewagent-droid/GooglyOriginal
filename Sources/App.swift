import Cocoa
import SceneKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var view: GameView!
    var game: Game!
    let args = CommandLine.arguments

    func arg(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        let w = CGFloat(Double(arg("--width") ?? "") ?? 1440), h = CGFloat(Double(arg("--height") ?? "") ?? 900)
        let frame = NSRect(x: 0, y: 0, width: w, height: h)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "GooglyOriginal"
        window.collectionBehavior = [.fullScreenPrimary]
        window.minSize = NSSize(width: 900, height: 560)
        window.acceptsMouseMovedEvents = true
        window.center()
        view = GameView(frame: frame, options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
        let shot = arg("--shot")
        if shot != nil || args.contains("--autotest") { SaveData.disabled = true }
        game = Game(view: view, muted: args.contains("--mute"))
        window.contentView = view
        window.delegate = self
        if args.contains("--autotest") { view.delegate = nil; view.isPlaying = false; exit(game.autotest() ? 0 : 1) }
        if shot != nil {
            let pressing = arg("--press") != nil
            view.inputEnabled = pressing
            game.ignoreInput = !pressing
            window.orderFrontRegardless()
        } else {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            NSApp.activate(ignoringOtherApps: true)
        }
        if args.contains("--stats") { view.showsStatistics = true }
        devHooks()
    }

    /// Flags for automated screenshots while developing. They run on the game thread's next frame.
    private func devHooks() {
        let arg2 = arg
        let g = game!
        let a = args
        let lvl = arg("--level").flatMap(Int.init) ?? (a.contains("--play") ? 1 : nil)
        let eyes = arg("--eyes").flatMap(Int.init)
        let x = arg("--x").flatMap(Float.init), z = arg("--z").flatMap(Float.init) ?? 0
        let dist = arg("--dist").flatMap(Float.init)
        let nPlayers = arg("--players").flatMap(Int.init) ?? 1
        g.later {
            if lvl != nil || nPlayers > 1 {
                for sc in [Scheme.keysA, .keysB, .pad(0), .pad(1)].prefix(max(1, min(4, nPlayers))) { g.join(sc) }
            }
            if let l = lvl { g.startLevel(max(0, min(2, l - 1)), fresh: true) }
            if let e = eyes { for s in g.slots { s.body.setEyes(e); g.setMask(s.body.root, 2) } }
            if let x = x {
                let y = g.world.groundBelow(x, z, 3000) ?? 0
                for (i, s) in g.slots.enumerated() { s.body.place(at: V3(x + Float(i % 2) * 90, y + 70, z + Float(i / 2) * 100 - 50)) }
                g.camTarget = g.player.c
            }
            if a.contains("--junk") { for s in g.slots { s.inventory = Junk.allCases.filter { $0 != .pea } + [.duck, .duck, .toast] } }
            if let sx = arg2("--straggle").flatMap(Float.init), g.slots.count > 1 {
                let s = g.slots.last!
                s.body.place(at: V3(sx, (g.world.groundBelow(sx, 0, 3000) ?? 0) + 70, 0))
            }
            if a.contains("--demo") { g.demo = true }
            if let d = dist { g.camDist = d }
        }
        if let f = arg("--online-host") {
            let n = arg("--autoplayers").flatMap(Int.init) ?? 2
            g.later { g.autoHost = true; g.autoCodeFile = f; g.autoPlayers = n; g.openOnline() }
        }
        if let f = arg("--online-join") { g.later { g.autoJoinFile = f; g.openOnline() } }
        // --press space@2,return@5 : simulated key presses for testing menus
        if let spec = arg("--press") {
            let names: [String: UInt16] = ["space": 49, "return": 36, "o": 31, "h": 4, "j": 38, "esc": 53, "c": 8, "1": 18]
            for part in spec.split(separator: ",") {
                let kv = part.split(separator: "@")
                guard kv.count == 2, let k = names[String(kv[0])], let t = Double(kv[1]) else { continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { self.view.input.down(k) }
                DispatchQueue.main.asyncAfter(deadline: .now() + t + 0.12) { self.view.input.up(k) }
            }
        }
        if a.contains("--pause") { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { g.later { g.state = .paused; g.hud.showPause() } } }
        if let path = arg("--shot") {
            let delay = Double(arg("--delay") ?? "4") ?? 4
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let img = self.view.snapshot()
                if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                } else { NSLog("GooglyOriginal: snapshot failed") }
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { if !SaveData.disabled { game?.saveNow() } }
    func windowDidResignKey(_ notification: Notification) { view?.input.clear() }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About GooglyOriginal", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide GooglyOriginal", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit GooglyOriginal", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(NSMenuItem(title: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f"))
        viewItem.submenu = viewMenu
        NSApp.mainMenu = main
    }
}

enum IconMaker {
    /// Renders the app icon into an .iconset folder (the build script turns it into AppIcon.icns).
    static func run(_ dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for s in [16, 32, 64, 128, 256, 512, 1024] {
            let img = draw(s)
            if s <= 512 { savePNG(img, to: "\(dir)/icon_\(s)x\(s).png") }
            if s >= 32 { savePNG(img, to: "\(dir)/icon_\(s / 2)x\(s / 2)@2x.png") }
        }
    }

    /// The red guy's face, eyes rolled in opposite directions, on a sky-blue tile.
    static func draw(_ size: Int) -> CGImage {
        makeImage(size, size) { ctx in
            let S = CGFloat(size)
            let inset = S * 0.08
            let rect = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: S * 0.2, cornerHeight: S * 0.2, transform: nil))
            ctx.clip()
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let bg = CGGradient(colorsSpace: cs, colors: [hex(0xd8f1ff).cgColor, hex(0x5fb8ff).cgColor] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: inset), end: CGPoint(x: 0, y: S - inset), options: [])
            ctx.setFillColor(hex(0x5cc94a).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: S, height: S * 0.22))
            // body
            let body = CGRect(x: S * 0.22, y: S * 0.16, width: S * 0.56, height: S * 0.7)
            ctx.setFillColor(Player.red.cgColor)
            ctx.addPath(CGPath(roundedRect: body, cornerWidth: S * 0.25, cornerHeight: S * 0.28, transform: nil))
            ctx.fillPath()
            ctx.setStrokeColor(Player.darkRed.cgColor)
            ctx.setLineWidth(S * 0.018)
            ctx.addPath(CGPath(roundedRect: body, cornerWidth: S * 0.25, cornerHeight: S * 0.28, transform: nil))
            ctx.strokePath()
            ctx.setFillColor(hex(0xffffff, 0.25).cgColor)
            ctx.fillEllipse(in: CGRect(x: S * 0.3, y: S * 0.6, width: S * 0.18, height: S * 0.16))
            // eyes
            for (cx, px, py) in [(0.4, -0.05, -0.06), (0.61, 0.06, 0.03)] as [(CGFloat, CGFloat, CGFloat)] {
                let r = S * 0.11
                let c = CGPoint(x: S * cx, y: S * 0.58)
                ctx.setFillColor(.white)
                ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                ctx.setStrokeColor(hex(0x1a0a0a).cgColor)
                ctx.setLineWidth(S * 0.012)
                ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                let pr = r * 0.52
                let pc = CGPoint(x: c.x + S * px, y: c.y + S * py)
                ctx.setFillColor(hex(0x111111).cgColor)
                ctx.fillEllipse(in: CGRect(x: pc.x - pr, y: pc.y - pr, width: pr * 2, height: pr * 2))
                ctx.setFillColor(.white)
                ctx.fillEllipse(in: CGRect(x: pc.x - pr * 0.55, y: pc.y + pr * 0.1, width: pr * 0.5, height: pr * 0.5))
            }
            // mouth
            ctx.setFillColor(hex(0x3a0508).cgColor)
            ctx.fillEllipse(in: CGRect(x: S * 0.44, y: S * 0.33, width: S * 0.12, height: S * 0.1))
            ctx.restoreGState()
        }
    }
}
