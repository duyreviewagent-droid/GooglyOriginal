import AppKit
import SceneKit

enum Key {
    static let a: UInt16 = 0, s: UInt16 = 1, d: UInt16 = 2, f: UInt16 = 3, h: UInt16 = 4, c: UInt16 = 8, w: UInt16 = 13, e: UInt16 = 14
    static let r: UInt16 = 15, one: UInt16 = 18, two: UInt16 = 19, three: UInt16 = 20, p: UInt16 = 35, j: UInt16 = 38, k: UInt16 = 40
    static let ret: UInt16 = 36, m: UInt16 = 46, q: UInt16 = 12, tab: UInt16 = 48, space: UInt16 = 49, esc: UInt16 = 53, enter: UInt16 = 76
    static let shift: UInt16 = 56, rshift: UInt16 = 60, t: UInt16 = 17
    static let four: UInt16 = 21, five: UInt16 = 23, six: UInt16 = 22, o: UInt16 = 31, l: UInt16 = 37, backspace: UInt16 = 51, slash: UInt16 = 44, period: UInt16 = 47, comma: UInt16 = 43
    static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
}

/// Keyboard and mouse state. Events arrive on the main thread; the game reads it on SceneKit's
/// render thread, so everything goes through a lock and is snapshotted once per frame.
final class InputState {
    private let lock = NSLock()
    private var heldRaw: Set<UInt16> = []
    private var pressedRaw: Set<UInt16> = []
    private var mouseRaw = CGPoint.zero
    private var mouseHeldRaw = false
    private var clickedRaw = false, rightRaw = false
    private var scrollRaw: Float = 0
    private var movedRaw: Float = 0
    private var typedRaw: [Character] = []
    private(set) var typed: [Character] = []

    // frame snapshot
    private(set) var held: Set<UInt16> = []
    private(set) var pressed: Set<UInt16> = []
    private(set) var mouseView = CGPoint.zero
    private(set) var mouseHeld = false
    private(set) var mouseClicked = false
    private(set) var rightClicked = false
    private(set) var scroll: Float = 0
    private(set) var mouseMovedRecently: Float = 0

    func down(_ k: UInt16) { lock.lock(); if !heldRaw.contains(k) { pressedRaw.insert(k) }; heldRaw.insert(k); lock.unlock() }
    func up(_ k: UInt16) { lock.lock(); heldRaw.remove(k); lock.unlock() }
    func mouse(_ p: CGPoint, down: Bool? = nil, click: Bool = false, right: Bool = false) {
        lock.lock()
        mouseRaw = p
        movedRaw = 4
        if let d = down { mouseHeldRaw = d }
        if click { clickedRaw = true }
        if right { rightRaw = true }
        lock.unlock()
    }
    func addScroll(_ s: Float) { lock.lock(); scrollRaw += s; lock.unlock() }
    func type(_ s: String) { lock.lock(); typedRaw.append(contentsOf: s); lock.unlock() }

    func beginFrame() {
        lock.lock()
        held = heldRaw
        pressed = pressedRaw; pressedRaw.removeAll()
        mouseView = mouseRaw
        mouseHeld = mouseHeldRaw
        mouseClicked = clickedRaw; clickedRaw = false
        rightClicked = rightRaw; rightRaw = false
        scroll = scrollRaw; scrollRaw = 0
        typed = typedRaw; typedRaw.removeAll()
        if movedRaw > 0 { mouseMovedRecently = movedRaw; movedRaw = 0 } else { mouseMovedRecently = max(0, mouseMovedRecently - 1.0 / 60) }
        lock.unlock()
    }

    func isHeld(_ k: UInt16...) -> Bool { k.contains { held.contains($0) } }
    func wasPressed(_ k: UInt16...) -> Bool { k.contains { pressed.contains($0) } }
    func endFrame() { pressed.removeAll(); mouseClicked = false; rightClicked = false; scroll = 0 }
    func clear() {
        lock.lock(); heldRaw.removeAll(); pressedRaw.removeAll(); mouseHeldRaw = false; clickedRaw = false; lock.unlock()
        held.removeAll(); pressed.removeAll(); mouseHeld = false; mouseClicked = false
    }
}

final class GameView: SCNView {
    let input = InputState()
    var inputEnabled = true
    var onResize: ((CGSize) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with e: NSEvent) {
        if e.modifierFlags.contains(.command) || !inputEnabled { super.keyDown(with: e); return }
        input.down(e.keyCode)
        if let c = e.charactersIgnoringModifiers { input.type(c) }
    }
    override func keyUp(with e: NSEvent) { input.up(e.keyCode) }
    override func flagsChanged(with e: NSEvent) {
        guard inputEnabled else { return }
        if e.keyCode == Key.shift || e.keyCode == Key.rshift {
            if e.modifierFlags.contains(.shift) { input.down(e.keyCode) } else { input.up(Key.shift); input.up(Key.rshift) }
        }
    }
    private func loc(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }
    override func mouseDown(with e: NSEvent) { guard inputEnabled else { return }; input.mouse(loc(e), down: true, click: true) }
    override func mouseUp(with e: NSEvent) { input.mouse(loc(e), down: false) }
    override func mouseMoved(with e: NSEvent) { input.mouse(loc(e)) }
    override func mouseDragged(with e: NSEvent) { input.mouse(loc(e)) }
    override func rightMouseDown(with e: NSEvent) { guard inputEnabled else { return }; input.mouse(loc(e), right: true) }
    override func scrollWheel(with e: NSEvent) {
        guard inputEnabled else { return }
        input.addScroll(Float(e.scrollingDeltaY) * (e.hasPreciseScrollingDeltas ? 0.05 : 0.5))
    }
    override func resignFirstResponder() -> Bool { input.clear(); return super.resignFirstResponder() }
    override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); onResize?(s) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
}
