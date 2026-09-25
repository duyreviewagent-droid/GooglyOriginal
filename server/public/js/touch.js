// On-screen controls for phones and tablets: a thumb stick on the left, action buttons on the right.
// They drive the same "WASD" player as the keyboard by feeding Input (analog move + virtual keys).
export const isTouch = () => matchMedia('(pointer: coarse)').matches || 'ontouchstart' in window;

export class TouchControls {
  constructor(input) {
    this.input = input;
    this.el = document.createElement('div');
    this.el.id = 'touch';
    this.el.innerHTML = `
      <div class="stick"><div class="knob"></div></div>
      <button class="tb jump" data-key="Space">JUMP</button>
      <button class="tb spit" data-key="KeyF">SPIT</button>
      <button class="tb squish" data-hold="KeyC">SQUISH</button>
      <button class="tb honk" data-key="KeyE">HONK</button>
      <button class="tb tele" data-key="KeyT">⚡ TELEPORT</button>
      <button class="tb pause" data-key="Escape">❚❚</button>`;
    document.body.append(this.el);
    this.stick = this.el.querySelector('.stick');
    this.knob = this.el.querySelector('.knob');
    this.tele = this.el.querySelector('.tele');
    this.stickId = null;
    const R = 60;
    const moveStick = e => {
      const r = this.stick.getBoundingClientRect();
      let dx = e.clientX - (r.left + r.width / 2), dy = e.clientY - (r.top + r.height / 2);
      const d = Math.hypot(dx, dy);
      if (d > R) { dx *= R / d; dy *= R / d; }
      this.knob.style.transform = `translate(${dx}px, ${dy}px)`;
      const m = Math.min(1, d / R) < 0.18 ? 0 : 1;
      input.touchMove.x = m * dx / R; input.touchMove.y = m * dy / R;
    };
    this.stick.addEventListener('pointerdown', e => { this.stickId = e.pointerId; this.stick.setPointerCapture(e.pointerId); moveStick(e); e.preventDefault(); });
    this.stick.addEventListener('pointermove', e => { if (e.pointerId === this.stickId) moveStick(e); });
    const release = e => {
      if (e.pointerId !== this.stickId) return;
      this.stickId = null; this.knob.style.transform = ''; input.touchMove.x = 0; input.touchMove.y = 0;
    };
    this.stick.addEventListener('pointerup', release);
    this.stick.addEventListener('pointercancel', release);
    for (const b of this.el.querySelectorAll('[data-key]')) {
      b.addEventListener('pointerdown', e => { e.preventDefault(); b.classList.add('down'); input.tap(b.dataset.key); });
      const up = () => b.classList.remove('down');
      b.addEventListener('pointerup', up); b.addEventListener('pointercancel', up); b.addEventListener('pointerleave', up);
    }
    for (const b of this.el.querySelectorAll('[data-hold]')) {
      b.addEventListener('pointerdown', e => { e.preventDefault(); b.classList.add('down'); b.setPointerCapture(e.pointerId); input.press(b.dataset.hold, true); });
      const up = () => { b.classList.remove('down'); input.press(b.dataset.hold, false); };
      b.addEventListener('pointerup', up); b.addEventListener('pointercancel', up);
    }
    this.el.addEventListener('contextmenu', e => e.preventDefault());
    this.show(false);
  }

  show(on) { this.el.style.display = on ? '' : 'none'; }

  /** Only while playing; the teleport button appears when you're far behind the leader. */
  update(game) {
    const playing = game.state === 'playing' && game.player?.flushing < 0;
    this.show(playing);
    if (!playing) { this.input.touchMove.x = 0; this.input.touchMove.y = 0; return; }
    const me = game.slots.find(s => s.scheme.id === 'keysA');
    this.tele.style.display = me && me.behind ? '' : 'none';
  }
}
