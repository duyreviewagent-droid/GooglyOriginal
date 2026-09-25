import Cocoa
import SpriteKit

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
        window.title = "Googly"
        window.collectionBehavior = [.fullScreenPrimary]
        window.minSize = NSSize(width: 900, height: 560)
        window.acceptsMouseMovedEvents = true
        window.center()
        view = GameView(frame: frame)
        let shot = arg("--shot")
        if shot != nil || args.contains("--autotest") { SaveData.disabled = true }
        game = Game(view: view, muted: args.contains("--mute"))
        window.contentView = view
        window.delegate = self
        if args.contains("--autotest") { exit(game.autotest() ? 0 : 1) }
        if shot != nil {
            view.inputEnabled = false
            game.ignoreInput = true
            window.orderFrontRegardless()
        } else {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            NSApp.activate(ignoringOtherApps: true)
        }
        if args.contains("--stats") { view.showsFPS = true; view.showsNodeCount = true }
        devHooks()
    }

    /// Flags for automated screenshots while developing.
    private func devHooks() {
        if let l = arg("--level").flatMap(Int.init) ?? (args.contains("--play") ? 1 : nil) {
            game.startLevel(max(0, min(2, l - 1)), fresh: true)
        }
        if let e = arg("--eyes").flatMap(Int.init) { game.player.setEyes(e) }
        if let x = arg("--x").flatMap(Float.init) {
            let y = game.world.groundBelow(x, 3000) ?? 0
            game.player.place(at: V2(x, y + 70))
            game.camPos = V2(x, y + 200)
        }
        if args.contains("--junk") { game.inventory = Junk.allCases.filter { $0 != .pea } + [.duck, .duck, .toast] }
        if args.contains("--demo") { game.demo = true }
        if args.contains("--nohelp") { game.hud.layout(game.scene.size) }
        if args.contains("--pause") { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.game.state = .paused; self.game.hud.showPause() } }
        if let path = arg("--shot") {
            let delay = Double(arg("--delay") ?? "4") ?? 4
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if let tex = self.view.texture(from: self.game.scene), let img = tex.cgImage() as CGImage? {
                    savePNG(img, to: path)
                } else {
                    NSLog("Googly: snapshot failed")
                }
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
        appMenu.addItem(withTitle: "About Googly", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Googly", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Googly", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
