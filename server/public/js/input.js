// Keyboard, mouse and gamepads, snapshotted once per frame with edge detection.
export class Input {
  constructor(canvas) {
    this.held = new Set(); this.pressed = new Set(); this._pressed = new Set();
    this.typed = []; this._typed = [];
    this.mouse = { x: 0, y: 0 }; this.mouseHeld = false; this.mouseClicked = false; this._clicked = false;
    this.rightClicked = false; this._right = false; this.scroll = 0; this._scroll = 0; this.mouseMovedRecently = 0; this._moved = false;
    this.enabled = true;
    this.pads = []; this.padPrev = [];
    const block = new Set(['Space', 'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'Tab', 'Slash', 'Quote']);
    addEventListener('keydown', e => {
      if (e.target && (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA')) return;
      if (e.metaKey || e.ctrlKey) return;
      if (block.has(e.code)) e.preventDefault();
      if (!this.enabled) return;
      if (!this.held.has(e.code)) this._pressed.add(e.code);
      this.held.add(e.code);
      if (e.key && e.key.length === 1) this._typed.push(e.key);
    });
    addEventListener('keyup', e => this.held.delete(e.code));
    addEventListener('blur', () => { this.held.clear(); this.mouseHeld = false; });
    canvas.addEventListener('mousemove', e => { this.mouse.x = e.clientX; this.mouse.y = e.clientY; this._moved = true; });
    canvas.addEventListener('mousedown', e => {
      this.mouse.x = e.clientX; this.mouse.y = e.clientY; this._moved = true;
      if (e.button === 2) this._right = true; else { this.mouseHeld = true; this._clicked = true; }
    });
    addEventListener('mouseup', e => { if (e.button !== 2) this.mouseHeld = false; });
    canvas.addEventListener('contextmenu', e => e.preventDefault());
    canvas.addEventListener('wheel', e => { this._scroll += -e.deltaY * 0.01; e.preventDefault(); }, { passive: false });
  }
  beginFrame(dt) {
    this.pressed = this._pressed; this._pressed = new Set();
    this.typed = this._typed; this._typed = [];
    this.mouseClicked = this._clicked; this._clicked = false;
    this.rightClicked = this._right; this._right = false;
    this.scroll = this._scroll; this._scroll = 0;
    if (this._moved) { this.mouseMovedRecently = 4; this._moved = false; } else this.mouseMovedRecently = Math.max(0, this.mouseMovedRecently - dt);
    // gamepads
    const list = (navigator.getGamepads ? [...navigator.getGamepads()] : []).filter(Boolean);
    this.padPrev = this.pads;
    this.pads = list.map(g => {
      const b = i => !!(g.buttons[i] && (g.buttons[i].pressed || g.buttons[i].value > 0.4));
      let sx = g.axes[0] || 0, sy = g.axes[1] || 0;
      if (Math.hypot(sx, sy) < 0.2) { sx = (b(15) ? 1 : 0) - (b(14) ? 1 : 0); sy = (b(13) ? 1 : 0) - (b(12) ? 1 : 0); }
      return { id: g.index, stick: { x: sx, y: sy }, a: b(0), b: b(1), x: b(2), y: b(3), lb: b(4), rb: b(5), lt: b(6), rt: b(7), menu: b(9) };
    });
  }
  isHeld(...codes) { return codes.some(c => this.held.has(c)); }
  wasPressed(...codes) { return codes.some(c => this.pressed.has(c)); }
  padHeld(i, btn) { return !!(this.pads[i] && this.pads[i][btn]); }
  padPressed(i, btn) { return !!(this.pads[i] && this.pads[i][btn] && !(this.padPrev[i] && this.padPrev[i][btn])); }
  anyPadPressed(btn) { return this.pads.some((_, i) => this.padPressed(i, btn)); }
  clear() { this.held.clear(); this._pressed.clear(); this.mouseHeld = false; }
}

/** Which device a player uses (same layouts as the Mac app). */
export const Schemes = {
  keysA: { id: 'keysA', label: 'KEYBOARD · WASD', join: 'SPACE', teleport: 'T', hint: 'WASD move · SPACE jump · SHIFT squish · CLICK/F spit · E honk' },
  keysB: { id: 'keysB', label: 'KEYBOARD · ARROWS', join: '/', teleport: 'ENTER', hint: 'ARROWS move · / jump · R-SHIFT squish · . spit · , honk' },
  pad: i => ({ id: 'pad' + i, pad: i, label: 'CONTROLLER ' + (i + 1), join: 'Ⓐ', teleport: 'Ⓨ', hint: 'stick move · Ⓐ jump · Ⓑ/LT squish · Ⓧ/RT spit · RB honk' }),
  remote: seat => ({ id: 'remote' + seat, remote: true, label: 'ONLINE', join: '', teleport: 'T', hint: '' }),
};

export function joinPressed(scheme, input) {
  if (scheme.id === 'keysA') return input.wasPressed('Space');
  if (scheme.id === 'keysB') return input.wasPressed('Slash');
  if (scheme.pad !== undefined) return input.padPressed(scheme.pad, 'a');
  return false;
}

export function readActions(scheme, input, solo) {
  const a = { move: { x: 0, y: 0 }, squish: false, jumpPressed: false, fire: false, fireHeld: false, mouseAim: false, honk: false, teleport: false };
  if (scheme.id === 'keysA') {
    if (input.isHeld('KeyA') || (solo && input.isHeld('ArrowLeft'))) a.move.x -= 1;
    if (input.isHeld('KeyD') || (solo && input.isHeld('ArrowRight'))) a.move.x += 1;
    if (input.isHeld('KeyW') || (solo && input.isHeld('ArrowUp'))) a.move.y -= 1;
    if (input.isHeld('KeyS') || (solo && input.isHeld('ArrowDown'))) a.move.y += 1;
    a.squish = input.isHeld('ShiftLeft', 'KeyC') || (solo && input.isHeld('ShiftRight'));
    a.jumpPressed = input.wasPressed('Space');
    a.fire = input.mouseClicked || input.wasPressed('KeyF', 'KeyJ');
    a.fireHeld = input.mouseHeld;
    a.mouseAim = input.mouseClicked || input.mouseHeld;
    a.honk = input.wasPressed('KeyE', 'KeyH') || input.rightClicked;
    a.teleport = input.wasPressed('KeyT');
  } else if (scheme.id === 'keysB') {
    if (input.isHeld('ArrowLeft')) a.move.x -= 1;
    if (input.isHeld('ArrowRight')) a.move.x += 1;
    if (input.isHeld('ArrowUp')) a.move.y -= 1;
    if (input.isHeld('ArrowDown')) a.move.y += 1;
    a.squish = input.isHeld('ShiftRight');
    a.jumpPressed = input.wasPressed('Slash');
    a.fire = input.wasPressed('Period');
    a.honk = input.wasPressed('Comma');
    a.teleport = input.wasPressed('Enter');
  } else if (scheme.pad !== undefined) {
    const i = scheme.pad, p = input.pads[i];
    if (p) {
      a.move = Math.hypot(p.stick.x, p.stick.y) < 0.2 ? { x: 0, y: 0 } : { x: p.stick.x, y: p.stick.y };
      a.squish = p.b || p.lt;
      a.jumpPressed = input.padPressed(i, 'a');
      a.fire = input.padPressed(i, 'x') || input.padPressed(i, 'rt');
      a.fireHeld = p.x || p.rt;
      a.honk = input.padPressed(i, 'rb') || input.padPressed(i, 'lb');
      a.teleport = input.padPressed(i, 'y');
    }
  }
  const l = Math.hypot(a.move.x, a.move.y);
  if (l > 1) { a.move.x /= l; a.move.y /= l; }
  return a;
}
