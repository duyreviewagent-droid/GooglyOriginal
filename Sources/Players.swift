import SceneKit
import SpriteKit
import GameController

/// Which device a player uses.
enum Scheme: Equatable {
    case keysA          // WASD · Space jump · Shift squish · click / F spit · E honk · T teleport
    case keysB          // arrows · / jump · right Shift squish · . spit · , honk · Return teleport
    case pad(Int)       // game controller
    case remote(Int)    // an online player on another Mac (seat number)

    var label: String {
        switch self {
        case .keysA: return "KEYBOARD · WASD"
        case .keysB: return "KEYBOARD · ARROWS"
        case .pad(let i): return "CONTROLLER \(i + 1)"
        case .remote: return "ONLINE"
        }
    }
    var isRemote: Bool { if case .remote = self { return true }; return false }
    var joinHint: String {
        switch self {
        case .keysA: return "SPACE"
        case .keysB: return "/"
        case .pad: return "Ⓐ"
        case .remote: return ""
        }
    }
    var teleportHint: String {
        switch self {
        case .keysA: return "T"
        case .keysB: return "RETURN"
        case .pad: return "Ⓨ"
        case .remote: return "T"
        }
    }
    var controlsHint: String {
        switch self {
        case .keysA: return "WASD move · SPACE jump · SHIFT squish · CLICK/F spit · E honk · T teleport"
        case .keysB: return "ARROWS move · / jump · R-SHIFT squish · . spit · , honk · RETURN teleport"
        case .pad: return "stick move · Ⓐ jump · Ⓑ/LT squish · Ⓧ/RT spit · RB honk · Ⓨ teleport"
        case .remote: return ""
        }
    }
}

/// Buttons one player pressed or holds this frame.
struct Actions {
    var ctl = Player.Controls()
    var jumpPressed = false
    var fire = false
    var fireHeld = false
    var mouseAim = false
    var honk = false
    var teleport = false
    var pause = false
}

/// One joined player: their jelly body plus everything that belongs to them.
final class Slot {
    let index: Int
    let scheme: Scheme
    let body: Player
    var inventory: [Junk] = []
    var fireCooldown: Float = 0, honkCooldown: Float = 0, jumpBuffer: Float = 0
    var quipCooldown: Float = 0, idleTime: Float = 0
    var bubble: SKNode?
    var bubbleLife: Float = 0
    var voicePitch: Float
    var bonks = 0, collected = 0, falls = 0, teleports = 0
    var flushOrder = -1
    var demoHold: Float = 0, demoBack: Float = 0
    var aimPoint: V3?
    let tag = SKNode()
    private let tagLabel = SKLabelNode()
    private let tagBack: SKShapeNode
    let prompt = SKNode()
    var behind = false
    /// Where this player last stood on solid ground (teleports and respawns go here, not mid-air).
    var lastSafe = V3(0, 80, 0)
    var blindDrift = V2(0, 0)

    /// Online name ("Vincent"); local players are just P1–P4.
    var netName: String?
    /// Online bookkeeping: counters so presses sent over the network are never lost or doubled.
    var placeCount = 0
    var jumpCount = 0, lastJumpSeen = 0
    var remote = RemoteInput()
    var netTarget: V3?
    var lastCtl = Player.Controls()
    var netVel = V3(0, 0, 0)

    var name: String { netName ?? "P\(index + 1)" }
    var color: NSColor { Player.colors[index] }

    init(index: Int, scheme: Scheme) {
        self.index = index
        self.scheme = scheme
        body = Player(color: Player.colors[index])
        voicePitch = [1.18, 0.92, 1.05, 1.35][index]
        tagBack = roundRect(46, 24, r: 12, fill: NSColor(white: 0, alpha: 0.55), stroke: Player.colors[index], line: 2)
        tag.addChild(tagBack)
        tagLabel.fontName = uiFont
        tagLabel.fontSize = 14
        tagLabel.fontColor = .white
        tagLabel.verticalAlignmentMode = .center
        tagLabel.text = "P\(index + 1)"
        tag.addChild(tagLabel)
        let pb = roundRect(190, 30, r: 15, fill: hex(0xffd84a, 0.95), stroke: hex(0x3a2a00), line: 2)
        prompt.addChild(pb)
        let pl = lbl("⚡ \(scheme.teleportHint) = TELEPORT", size: 14, color: hex(0x2a1a00))
        prompt.addChild(pl)
        prompt.position = CGPoint(x: 0, y: 34)
        prompt.isHidden = true
        tag.addChild(prompt)
    }

    func setTag(_ text: String) {
        if tagLabel.text != text {
            tagLabel.text = text
            tagBack.path = CGPath(roundedRect: CGRect(x: -max(46, tagLabel.frame.width + 20) / 2, y: -12, width: max(46, tagLabel.frame.width + 20), height: 24),
                                  cornerWidth: 12, cornerHeight: 12, transform: nil)
        }
    }
}

/// Reads keyboards and controllers into per-scheme actions.
enum Devices {
    static func pads() -> [GCController] {
        GCController.controllers().filter { $0.extendedGamepad != nil }.sorted { $0.playerIndex.rawValue < $1.playerIndex.rawValue }
    }

    /// Whether the device's "join" button went down this frame.
    static func joinPressed(_ s: Scheme, input: InputState, pads: [PadState]) -> Bool {
        switch s {
        case .keysA: return input.wasPressed(Key.space)
        case .keysB: return input.wasPressed(Key.slash)
        case .pad(let i): return i < pads.count && pads[i].pressed(.a)
        case .remote: return false
        }
    }

    static func actions(_ s: Scheme, input: InputState, pads: [PadState], solo: Bool) -> Actions {
        var a = Actions()
        switch s {
        case .keysA:
            if input.isHeld(Key.a) || (solo && input.isHeld(Key.left)) { a.ctl.move.x -= 1 }
            if input.isHeld(Key.d) || (solo && input.isHeld(Key.right)) { a.ctl.move.x += 1 }
            if input.isHeld(Key.w) || (solo && input.isHeld(Key.up)) { a.ctl.move.y -= 1 }
            if input.isHeld(Key.s) || (solo && input.isHeld(Key.down)) { a.ctl.move.y += 1 }
            a.ctl.squish = input.isHeld(Key.shift, Key.c) || (solo && input.isHeld(Key.rshift))
            a.jumpPressed = input.wasPressed(Key.space)
            a.fire = input.mouseClicked || input.wasPressed(Key.f, Key.j)
            a.fireHeld = input.mouseHeld
            a.mouseAim = input.mouseClicked || input.mouseHeld
            a.honk = input.wasPressed(Key.e, Key.h) || input.rightClicked
            a.teleport = input.wasPressed(Key.t)
            a.pause = input.wasPressed(Key.esc)
        case .keysB:
            if input.isHeld(Key.left) { a.ctl.move.x -= 1 }
            if input.isHeld(Key.right) { a.ctl.move.x += 1 }
            if input.isHeld(Key.up) { a.ctl.move.y -= 1 }
            if input.isHeld(Key.down) { a.ctl.move.y += 1 }
            a.ctl.squish = input.isHeld(Key.rshift)
            a.jumpPressed = input.wasPressed(Key.slash)
            a.fire = input.wasPressed(Key.period)
            a.honk = input.wasPressed(Key.comma)
            a.teleport = input.wasPressed(Key.ret)
            a.pause = input.wasPressed(Key.esc)
        case .pad(let i):
            guard i < pads.count else { return a }
            let p = pads[i]
            var m = p.stick
            if m.len < 0.2 { m = .zero }
            a.ctl.move = V2(m.x, -m.y)
            a.ctl.squish = p.held(.b) || p.held(.lt)
            a.jumpPressed = p.pressed(.a)
            a.fire = p.pressed(.x) || p.pressed(.rt)
            a.fireHeld = p.held(.x) || p.held(.rt)
            a.honk = p.pressed(.rb) || p.pressed(.lb)
            a.teleport = p.pressed(.y)
            a.pause = p.pressed(.menu)
        case .remote:
            break
        }
        if a.ctl.move.len > 1 { a.ctl.move = a.ctl.move.norm }
        return a
    }
}

/// Snapshot of one controller, with edge detection.
struct PadState {
    enum B: Int, CaseIterable { case a, b, x, y, lb, rb, lt, rt, menu }
    var stick = V2(0, 0)
    var now: Set<B> = [], before: Set<B> = []
    func held(_ b: B) -> Bool { now.contains(b) }
    func pressed(_ b: B) -> Bool { now.contains(b) && !before.contains(b) }

    static func read(_ c: GCController, previous: PadState?) -> PadState {
        var s = PadState()
        s.before = previous?.now ?? []
        guard let g = c.extendedGamepad else { return s }
        var st = V2(g.leftThumbstick.xAxis.value, g.leftThumbstick.yAxis.value)
        if st.len < 0.2 {
            let dx: Float = (g.dpad.right.isPressed ? 1 : 0) - (g.dpad.left.isPressed ? 1 : 0)
            let dy: Float = (g.dpad.up.isPressed ? 1 : 0) - (g.dpad.down.isPressed ? 1 : 0)
            st = V2(dx, dy)
        }
        s.stick = st
        if g.buttonA.isPressed { s.now.insert(.a) }
        if g.buttonB.isPressed { s.now.insert(.b) }
        if g.buttonX.isPressed { s.now.insert(.x) }
        if g.buttonY.isPressed { s.now.insert(.y) }
        if g.leftShoulder.isPressed { s.now.insert(.lb) }
        if g.rightShoulder.isPressed { s.now.insert(.rb) }
        if g.leftTrigger.value > 0.4 { s.now.insert(.lt) }
        if g.rightTrigger.value > 0.4 { s.now.insert(.rt) }
        if g.buttonMenu.isPressed { s.now.insert(.menu) }
        return s
    }
}

/// The latest input and body state a guest sent to the host (or the host sent about another player).
struct RemoteInput {
    var move = V2(0, 0)
    var squish = false
    var jump = 0, fire = 0, honk = 0, teleport = 0
    var aim: V3?
    var pos: V3?, vel = V3(0, 0, 0), yaw: Float = 0
    var placeAck = 0
    var seenJump = 0, seenFire = 0, seenHonk = 0, seenTeleport = 0
}
