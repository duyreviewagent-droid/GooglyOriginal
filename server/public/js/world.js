// Level collision: convex prisms (a CCW polygon in XY extruded between z0 and z1), fans, movers.
// A straight port of World.swift.
import { V3, clamp } from './util.js';

export class Solid {
  /** @param {{x:number,y:number}[]} pts  @param {'ground'|'platform'|'bouncy'|'ice'|'mover'} kind */
  constructor(pts, z0, z1, kind) {
    this.pts = pts.map(p => ({ x: p.x, y: p.y }));
    this.z0 = z0; this.z1 = z1;
    this.kind = kind;
    this.vel = new V3();
    this.friction = kind === 'ice' ? 0.004 : 0.2;
    this.amp = new V3(); this.speed = 0; this.phase = 0; this.base = []; this.baseZ = [0, 0];
    this.node = null;
    this.hidden = false;
    this.squash = 0;
    this.recompute();
  }
  recompute() {
    const n = this.pts.length;
    this.normals = [];
    let lx = Infinity, ly = Infinity, hx = -Infinity, hy = -Infinity;
    for (let i = 0; i < n; i++) {
      const a = this.pts[i], b = this.pts[(i + 1) % n];
      const nx = b.y - a.y, ny = a.x - b.x, l = Math.hypot(nx, ny) || 1;
      this.normals.push({ x: nx / l, y: ny / l });
      lx = Math.min(lx, a.x); ly = Math.min(ly, a.y); hx = Math.max(hx, a.x); hy = Math.max(hy, a.y);
    }
    this.lo = new V3(lx, ly, this.z0); this.hi = new V3(hx, hy, this.z1);
  }
  get top() { return this.hi.y; }

  /** Sphere vs prism: returns [nx, ny, nz, depth] or null. Allocation-free on the miss path. */
  collide(px, py, pz, r) {
    const lo = this.lo, hi = this.hi;
    if (px + r < lo.x || px - r > hi.x || py + r < lo.y || py - r > hi.y || pz + r < this.z0 || pz - r > this.z1) return null;
    const pts = this.pts, nr = this.normals, n = pts.length;
    let maxD = -Infinity, idx = 0;
    for (let i = 0; i < n; i++) {
      const d = (px - pts[i].x) * nr[i].x + (py - pts[i].y) * nr[i].y;
      if (d > maxD) { maxD = d; idx = i; }
    }
    if (maxD > r) return null;
    const inside2 = maxD <= 0, insideZ = pz > this.z0 && pz < this.z1;
    if (inside2 && insideZ) {
      const d2 = -maxD, dz0 = pz - this.z0, dz1 = this.z1 - pz;
      if (d2 <= Math.min(dz0, dz1)) return [nr[idx].x, nr[idx].y, 0, d2 + r];
      return dz0 < dz1 ? [0, 0, -1, dz0 + r] : [0, 0, 1, dz1 + r];
    }
    let cx = px, cy = py;
    if (!inside2) {
      let best = Infinity;
      for (let i = 0; i < n; i++) {
        const a = pts[i], b = pts[(i + 1) % n];
        const abx = b.x - a.x, aby = b.y - a.y;
        const t = clamp(((px - a.x) * abx + (py - a.y) * aby) / Math.max(1e-6, abx * abx + aby * aby), 0, 1);
        const qx = a.x + abx * t, qy = a.y + aby * t;
        const d = (px - qx) ** 2 + (py - qy) ** 2;
        if (d < best) { best = d; cx = qx; cy = qy; }
      }
    }
    const cz = clamp(pz, this.z0, this.z1);
    const dx = px - cx, dy = py - cy, dz = pz - cz;
    const d = Math.hypot(dx, dy, dz);
    if (d >= r) return null;
    if (d < 1e-5) return [nr[idx].x, nr[idx].y, 0, r];
    return [dx / d, dy / d, dz / d, r - d];
  }

  contains(p) {
    if (p.x < this.lo.x || p.x > this.hi.x || p.y < this.lo.y || p.y > this.hi.y || p.z < this.z0 || p.z > this.z1) return false;
    for (let i = 0; i < this.pts.length; i++) {
      if ((p.x - this.pts[i].x) * this.normals[i].x + (p.y - this.pts[i].y) * this.normals[i].y > 0) return false;
    }
    return true;
  }

  /** Height of the upper surface at (x, z), if the prism covers that column. */
  surfaceY(x, z) {
    if (x < this.lo.x || x > this.hi.x || z < this.z0 || z > this.z1) return null;
    let best = null;
    const n = this.pts.length;
    for (let i = 0; i < n; i++) {
      if (this.normals[i].y <= 0.05) continue;
      const a = this.pts[i], b = this.pts[(i + 1) % n];
      const x0 = Math.min(a.x, b.x), x1 = Math.max(a.x, b.x);
      if (x < x0 - 0.01 || x > x1 + 0.01 || x1 - x0 <= 1e-4) continue;
      const y = a.y + (b.y - a.y) * (x - a.x) / (b.x - a.x);
      if (best === null || y > best) best = y;
    }
    return best;
  }
}

export class World {
  constructor() {
    this.solids = [];
    this.fans = [];        // {lo: V3, hi: V3, power}
    this.killY = -700;
    this.minX = -400; this.maxX = 8000;
    this.time = 0;
  }
  moveMovers(dt) {
    this.time += dt;
    for (const s of this.solids) {
      if (s.kind === 'mover') {
        const ox = s.pts[0].x, oy = s.pts[0].y, oz = s.z0;
        const k = Math.sin(this.time * s.speed + s.phase);
        const off = s.amp.mul(k);
        s.pts = s.base.map(p => ({ x: p.x + off.x, y: p.y + off.y }));
        s.z0 = s.baseZ[0] + off.z; s.z1 = s.baseZ[1] + off.z;
        const idt = 1 / Math.max(dt, 1e-4);
        s.vel.set((s.pts[0].x - ox) * idt, (s.pts[0].y - oy) * idt, (s.z0 - oz) * idt);
        s.recompute();
        if (s.node) s.node.position.set(off.x, off.y, off.z);
      } else if (s.kind === 'bouncy') {
        s.squash = Math.max(0, s.squash - dt * 2.5);
        if (s.node) s.node.scale.set(1, 1 - 0.45 * Math.sin(s.squash * Math.PI * 3) * s.squash, 1);
      }
    }
  }
  /** Pushes a sphere (p: V3, mutated) out of every solid; appends {n: V3, solid} contacts. */
  resolve(p, r, contacts) {
    for (const s of this.solids) {
      const c = s.collide(p.x, p.y, p.z, r);
      if (c) {
        p.x += c[0] * c[3]; p.y += c[1] * c[3]; p.z += c[2] * c[3];
        if (contacts) contacts.push({ n: new V3(c[0], c[1], c[2]), solid: s });
      }
    }
  }
  solidAt(p) { return this.solids.some(s => s.contains(p)); }
  groundBelow(x, z, y) {
    let best = null;
    for (const s of this.solids) {
      const h = s.surfaceY(x, z);
      if (h !== null && h <= y + 1 && (best === null || h > best)) best = h;
    }
    return best;
  }
  fanForce(p) {
    let f = 0;
    for (const fan of this.fans) {
      if (p.x > fan.lo.x && p.x < fan.hi.x && p.y > fan.lo.y && p.y < fan.hi.y && p.z > fan.lo.z && p.z < fan.hi.z) {
        const t = (p.y - fan.lo.y) / (fan.hi.y - fan.lo.y);
        f += fan.power * (1 - t * 0.6);
      }
    }
    return f;
  }
}
