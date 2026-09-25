import AppKit
import SpriteKit

enum Key {
    static let a: UInt16 = 0, s: UInt16 = 1, d: UInt16 = 2, f: UInt16 = 3, h: UInt16 = 4, c: UInt16 = 8, w: UInt16 = 13, e: UInt16 = 14
    static let r: UInt16 = 15, one: UInt16 = 18, two: UInt16 = 19, three: UInt16 = 20, p: UInt16 = 35, j: UInt16 = 38, k: UInt16 = 40
    static let ret: UInt16 = 36, m: UInt16 = 46, q: UInt16 = 12, tab: UInt16 = 48, space: UInt16 = 49, esc: UInt16 = 53, enter: UInt16 = 76
    static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
}

/// Keyboard and mouse state. SpriteKit runs its update on the main thread, same as events.
final class InputState {
    private(set) var held: Set<UInt16> = []
    private var pressed: Set<UInt16> = []
    var mouseView = CGPoint.zero
    var mouseHeld = false
    var mouseClicked = false
    var rightClicked = false
    var mouseMovedRecently: Float = 0

    func down(_ k: UInt16) { if !held.contains(k) { pressed.insert(k) }; held.insert(k) }
    func up(_ k: UInt16) { held.remove(k) }
    func isHeld(_ k: UInt16...) -> Bool { k.contains { held.contains($0) } }
    func wasPressed(_ k: UInt16...) -> Bool { k.contains { pressed.contains($0) } }
    func anyPressed() -> Bool { !pressed.isEmpty || mouseClicked }
    func endFrame() { pressed.removeAll(); mouseClicked = false; rightClicked = false }
    func clear() { held.removeAll(); pressed.removeAll(); mouseHeld = false }
}

final class GameView: SKView {
    let input = InputState()
    var inputEnabled = true

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with e: NSEvent) {
        if e.modifierFlags.contains(.command) || !inputEnabled { super.keyDown(with: e); return }
        input.down(e.keyCode)
    }
    override func keyUp(with e: NSEvent) { input.up(e.keyCode) }
    override func flagsChanged(with e: NSEvent) {}

    private func track(_ e: NSEvent) {
        input.mouseView = convert(e.locationInWindow, from: nil)
        input.mouseMovedRecently = 3
    }
    override func mouseDown(with e: NSEvent) {
        guard inputEnabled else { return }
        track(e); input.mouseHeld = true; input.mouseClicked = true
    }
    override func mouseUp(with e: NSEvent) { input.mouseHeld = false }
    override func mouseMoved(with e: NSEvent) { track(e) }
    override func mouseDragged(with e: NSEvent) { track(e) }
    override func rightMouseDown(with e: NSEvent) { guard inputEnabled else { return }; track(e); input.rightClicked = true }
    override func rightMouseDragged(with e: NSEvent) { track(e) }
    override func resignFirstResponder() -> Bool { input.clear(); return super.resignFirstResponder() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
}
