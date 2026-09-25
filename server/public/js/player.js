// The hero: a jelly person. A shell of points is held together by 3D shape matching; a smooth mesh is
// skinned to those points, so every squash, stretch and wobble shows. Port of Player.swift.
import * as THREE from 'three';
import { V3, M3, Quat, extractRotation, clamp, wrapAngle, frand } from './util.js';
import { Googly } from './googly.js';

const SEGS = 12, RINGS = 7, N = SEGS * RINGS + 2;
const POINT_R = 7;
const HW = 36, HH = 52, HD = 33;
const DEG = Math.PI / 180;
export const EYE_SLOTS = [[70, 22, 13], [110, 22, 13], [90, 44, 8.5], [38, 2, 8], [142, -2, 9.5],
  [72, -30, 7], [112, -31, 7.5], [48, 40, 7], [132, 38, 6.5], [270, 18, 11]];
export const MAX_EYES = 10;
export const PLAYER_COLORS = [0xe8262f, 0x2f7df0, 0x2fbf4a, 0xffc21f];
export const PLAYER_NAMES = ['RED', 'BLU', 'GUS', 'SUNNY'];

function shape(lon, lat) {
  const dx = Math.cos(lat) * Math.cos(lon), dy = Math.sin(lat), dz = Math.cos(lat) * Math.sin(lon);
  const sp = a => Math.sign(a) * Math.pow(Math.abs(a), 0.78);
  const p = new V3(sp(dx) * HW, sp(dy) * HH, sp(dz) * HD);
  const k = 1 + 0.07 * (p.y / HH);
  p.x *= k; p.z *= k;
  return p;
}
const restNormal = p => new V3(p.x / (HW * HW), p.y / (HH * HH), p.z / (HD * HD)).norm;

let shadowTex = null;
function blobShadowTexture() {
  if (shadowTex) return shadowTex;
  if (typeof document === 'undefined') { shadowTex = new THREE.DataTexture(new Uint8Array([0, 0, 0, 100]), 1, 1); return shadowTex; }
  const c = document.createElement('canvas'); c.width = c.height = 128;
  const g = c.getContext('2d');
  const grd = g.createRadialGradient(64, 64, 0, 64, 64, 64);
  grd.addColorStop(0.2, 'rgba(0,0,0,0.5)'); grd.addColorStop(1, 'rgba(0,0,0,0)');
  g.fillStyle = grd; g.fillRect(0, 0, 128, 128);
  shadowTex = new THREE.CanvasTexture(c);
  return shadowTex;
}

const sphereGeo = new THREE.SphereGeometry(1, 16, 12);
const beadGeo = new THREE.SphereGeometry(5, 10, 8);
const handGeo = new THREE.SphereGeometry(8.5, 14, 10);
const whiteMat = new THREE.MeshStandardMaterial({ color: 0xffffff, roughness: 0.5 });
const shoeMat = new THREE.MeshStandardMaterial({ color: 0x2a2330, roughness: 0.4 });
const mouthMat = new THREE.MeshStandardMaterial({ color: 0x3a0508, roughness: 0.4 });

export class Player {
  static get N() { return N; }
  static get pointR() { return POINT_R; }

  constructor(color = PLAYER_COLORS[0]) {
    this.color = color;
    this.x = new Float64Array(N * 3); this.v = new Float64Array(N * 3);
    this.pred = new Float64Array(N * 3); this.rest = new Float64Array(N * 3);
    this.restScale = [1, 1, 1]; this.scaleTarget = [1, 1, 1];
    this.c = new V3(); this.cVel = new V3();
    this.G = M3.identity();
    this.rotQ = new Quat();
    this.yaw = 0;
    this.moveDir = new V3(1, 0, 0);
    this.grounded = false; this.coyote = 0; this.airTime = 0; this.peakFall = 0;
    this.charge = 0; this.charging = false; this.pounding = false;
    this.invuln = 0; this.ko = 0; this.mouthOpen = 0; this.hurtFace = 0; this.walkPhase = 0;
    this.aimTimer = 0; this.aimDir = new V3(1, 0, 0);
    this.inFan = false; this.flushing = -1; this.drawScale = 1;
    this.eyes = [];
    this.arms = [[], []]; this.armsPrev = [[], []];

    let k = 0;
    const setRest = (p) => { this.rest[k * 3] = p.x; this.rest[k * 3 + 1] = p.y; this.rest[k * 3 + 2] = p.z; k++; };
    setRest(shape(0, -Math.PI / 2));
    for (let r = 0; r < RINGS; r++) {
      const lat = -Math.PI / 2 + Math.PI * (r + 1) / (RINGS + 1);
      for (let s = 0; s < SEGS; s++) setRest(shape(s / SEGS * 2 * Math.PI + (r % 2 === 0 ? 0 : Math.PI / SEGS), lat));
    }
    setRest(shape(0, Math.PI / 2));
    this.aqqBase = null;
    this.buildSkins();
    this.buildNodes();
  }

  restV(i) { return new V3(this.rest[i * 3], this.rest[i * 3 + 1], this.rest[i * 3 + 2]); }
  pt(i) { return new V3(this.x[i * 3], this.x[i * 3 + 1], this.x[i * 3 + 2]); }

  skin(p) {
    const best = [];
    for (let i = 0; i < N; i++) best.push([this.restV(i).sub(p).len, i]);
    best.sort((a, b) => a[0] - b[0]);
    const b = best.slice(0, 4);
    let w = b.map(e => 1 / Math.max(0.5, e[0]));
    const s = w.reduce((a, c) => a + c, 0);
    w = w.map(x => x / s);
    const off = p.clone();
    for (let j = 0; j < 4; j++) off.subi(this.restV(b[j][1]).mul(w[j]));
    return { rest: p, off, idx: b.map(e => e[1]), w };
  }

  buildSkins() {
    const S = 30, Rn = 22;
    this.meshSkin = [this.skin(shape(0, -Math.PI / 2))];
    for (let r = 0; r < Rn; r++) {
      const lat = -Math.PI / 2 + Math.PI * (r + 1) / (Rn + 1);
      for (let s = 0; s < S; s++) this.meshSkin.push(this.skin(shape(s / S * 2 * Math.PI, lat)));
    }
    this.meshSkin.push(this.skin(shape(0, Math.PI / 2)));
    const top = this.meshSkin.length - 1;
    const v = (r, s) => 1 + r * S + (s % S);
    const idx = [];
    for (let s = 0; s < S; s++) idx.push(0, v(0, s + 1), v(0, s));
    for (let r = 0; r < Rn - 1; r++) for (let s = 0; s < S; s++) idx.push(v(r, s), v(r, s + 1), v(r + 1, s + 1), v(r, s), v(r + 1, s + 1), v(r + 1, s));
    for (let s = 0; s < S; s++) idx.push(v(Rn - 1, s), v(Rn - 1, s + 1), top);
    this.meshIndices = idx;
    this.slotSkin = []; this.slotNormals = [];
    for (const sl of EYE_SLOTS) { const p = shape(sl[0] * DEG, sl[1] * DEG); this.slotSkin.push(this.skin(p)); this.slotNormals.push(restNormal(p)); }
    const m = shape(90 * DEG, -6 * DEG);
    this.mouthSkin = this.skin(m); this.mouthNormal = restNormal(m);
    this.shoulderSkin = [this.skin(shape(180 * DEG, -8 * DEG)), this.skin(shape(0, -8 * DEG))];
    this.footSkin = [this.skin(shape(125 * DEG, -68 * DEG)), this.skin(shape(55 * DEG, -68 * DEG))];
  }

  /** Σ w x_k + G·off (see Player.swift). */
  skinned(s, out = new V3()) {
    const G = this.G, o = s.off;
    out.x = G[0] * o.x + G[3] * o.y + G[6] * o.z;
    out.y = G[1] * o.x + G[4] * o.y + G[7] * o.z;
    out.z = G[2] * o.x + G[5] * o.y + G[8] * o.z;
    for (let j = 0; j < 4; j++) { const i = s.idx[j] * 3, w = s.w[j]; out.x += this.x[i] * w; out.y += this.x[i + 1] * w; out.z += this.x[i + 2] * w; }
    return out;
  }

  buildNodes() {
    this.root = new THREE.Group();
    const geo = new THREE.BufferGeometry();
    this.posAttr = new THREE.BufferAttribute(new Float32Array(this.meshSkin.length * 3), 3);
    this.posAttr.setUsage(THREE.DynamicDrawUsage);
    geo.setAttribute('position', this.posAttr);
    geo.setIndex(this.meshIndices);
    this.bodyGeo = geo;
    const glow = new THREE.Color(this.color).multiplyScalar(0.18);
    this.glow = glow;
    this.bodyMat = new THREE.MeshPhysicalMaterial({ color: this.color, roughness: 0.28, metalness: 0, clearcoat: 0.7, clearcoatRoughness: 0.08, emissive: glow });
    this.bodyMesh = new THREE.Mesh(geo, this.bodyMat);
    this.bodyMesh.castShadow = true;
    this.bodyMesh.frustumCulled = false;
    this.root.add(this.bodyMesh);

    const sm = new THREE.MeshBasicMaterial({ map: blobShadowTexture(), transparent: true, depthWrite: false });
    this.shadow = new THREE.Mesh(new THREE.PlaneGeometry(90, 90), sm);
    this.shadow.rotation.x = -Math.PI / 2;
    this.shadow.renderOrder = -1;
    this.root.add(this.shadow);
    this.mouth = new THREE.Mesh(sphereGeo, mouthMat);
    this.root.add(this.mouth);
    const ringGeo = new THREE.TorusGeometry(55, 3, 8, 48);
    ringGeo.rotateX(-Math.PI / 2);
    this.chargeRing = new THREE.Mesh(ringGeo, new THREE.MeshStandardMaterial({ color: 0xffe14d, roughness: 0.3, emissive: 0x806000, transparent: true, opacity: 0 }));
    this.root.add(this.chargeRing);
    const armMat = new THREE.MeshStandardMaterial({ color: this.color, roughness: 0.35 });
    this.armBeads = [[], []]; this.hands = []; this.shoes = [];
    for (let a = 0; a < 2; a++) {
      for (let i = 0; i < 11; i++) { const b = new THREE.Mesh(beadGeo, armMat); b.castShadow = true; this.root.add(b); this.armBeads[a].push(b); }
      const h = new THREE.Mesh(handGeo, whiteMat); h.castShadow = true;
      this.root.add(h); this.hands.push(h);
    }
    for (let i = 0; i < 2; i++) {
      const s = new THREE.Group();
      const shoe = new THREE.Mesh(sphereGeo, shoeMat); shoe.scale.set(10, 7, 16); shoe.castShadow = true;
      const lace = new THREE.Mesh(sphereGeo, whiteMat); lace.scale.set(3.5, 1.75, 4.8); lace.position.set(0, 3.9, 5.6);
      s.add(shoe); s.add(lace);
      this.root.add(s); this.shoes.push(s);
    }
    this.limbs = [...this.armBeads[0], ...this.armBeads[1], ...this.hands, ...this.shoes];
  }

  // ---------------- eyes

  setEyes(n) { while (this.eyes.length > n) this.removeEye(); while (this.eyes.length < n) this.addEye(); }
  addEye() {
    if (this.eyes.length >= MAX_EYES) return;
    const slot = EYE_SLOTS[this.eyes.length];
    const g = new Googly(slot[2]);
    this.root.add(g.node);
    g.p = { x: frand(-3, 3), y: -3 };
    g.reset(this.eyeFrame(this.eyes.length)[0]);
    this.eyes.push(g);
    this.drawEyes();
  }
  removeEye() {
    const last = this.eyes.pop();
    if (!last) return null;
    this.root.remove(last.node);
    return this.eyeFrame(this.eyes.length)[0];
  }
  eyeFrame(i) {
    const k = Math.min(i, EYE_SLOTS.length - 1);
    return this.frame(this.skinned(this.slotSkin[k]), this.slotNormals[k], 1.5);
  }
  frame(p, n0, lift) {
    const n = M3.mulv(this.G, n0).norm;
    const up = M3.mulv(this.G, new V3(0, 1, 0)).norm;
    let r = up.cross(n);
    if (r.len < 1e-3) r = new V3(0, 0, 1).cross(n);
    r = r.norm;
    const u = n.cross(r);
    return [p.add(n.mul(lift)), n, r, u];
  }

  // ---------------- placement

  place(p) {
    this.restScale = [1, 1, 1]; this.scaleTarget = [1, 1, 1];
    this.G = M3.identity(); this.rotQ = new Quat();
    this.yaw = 0.5;
    for (let i = 0; i < N; i++) {
      this.x[i * 3] = p.x + this.rest[i * 3]; this.x[i * 3 + 1] = p.y + this.rest[i * 3 + 1]; this.x[i * 3 + 2] = p.z + this.rest[i * 3 + 2];
      this.v[i * 3] = this.v[i * 3 + 1] = this.v[i * 3 + 2] = 0;
    }
    this.c = p.clone(); this.cVel = new V3();
    this.pounding = false; this.charge = 0; this.charging = false; this.ko = 0; this.flushing = -1; this.drawScale = 1; this.invuln = 0;
    for (let a = 0; a < 2; a++) {
      const sh = this.skinned(this.shoulderSkin[a]);
      this.arms[a] = []; for (let k = 0; k < 7; k++) this.arms[a].push(new V3(sh.x, sh.y - k * 9, sh.z));
      this.armsPrev[a] = this.arms[a].map(q => q.clone());
    }
    this.eyes.forEach((e, i) => e.reset(this.eyeFrame(i)[0]));
  }

  get bottom() { let m = Infinity; for (let i = 0; i < N; i++) m = Math.min(m, this.x[i * 3 + 1]); return m - POINT_R; }
  get top() { let m = -Infinity; for (let i = 0; i < N; i++) m = Math.max(m, this.x[i * 3 + 1]); return m + POINT_R; }
  get upright() { return new V3(this.G[3], this.G[4], this.G[5]).norm.y; }

  // ---------------- physics

  /** ctl: {move:{x,y}, jump, squish}; pushes event objects {type, k?} */
  step(dt, ctl, world, events) {
    const x = this.x, v = this.v, pred = this.pred, rest = this.rest;
    const gravity = -1900;
    const floppy = this.ko > 0 || this.flushing >= 0;
    const rs = this.restScale, st = this.scaleTarget;
    for (let a = 0; a < 3; a++) {
      rs[a] += (st[a] - rs[a]) * Math.min(1, 14 * dt);
      st[a] += (1 - st[a]) * Math.min(1, 6 * dt);
    }
    if (this.charging) { st[0] = 1 + 0.42 * this.charge; st[1] = 1 - 0.46 * this.charge; st[2] = 1 + 0.42 * this.charge; }

    let ax = 0, ay = 0, az = 0;
    for (let i = 0; i < N; i++) { ax += v[i * 3]; ay += v[i * 3 + 1]; az += v[i * 3 + 2]; }
    ax /= N; ay /= N; az /= N;
    this.inFan = false;
    const tmp = new V3();
    for (let i = 0; i < N; i++) {
      let g = gravity;
      const f = world.fanForce(tmp.set(x[i * 3], x[i * 3 + 1], x[i * 3 + 2]));
      if (f > 0) { g += f; this.inFan = true; }
      if (this.pounding) g *= 1.6;
      v[i * 3 + 1] += g * dt;
    }
    const mv = ctl.move, moving = Math.hypot(mv.x, mv.y) > 0.1;
    if (!floppy) {
      const maxSpeed = this.charging ? 90 : 430;
      const accel = this.grounded ? 10 : 4.2;
      let dvx = (mv.x * maxSpeed - ax) * Math.min(1, accel * dt), dvz = (mv.y * maxSpeed - az) * Math.min(1, accel * dt);
      if (!moving && !this.grounded) { dvx *= 0.25; dvz *= 0.25; }
      if (moving) {
        this.moveDir = new V3(mv.x, 0, mv.y).norm;
        const want = clamp(Math.atan2(this.moveDir.x, this.moveDir.z), -1.35, 1.35);
        this.yaw += wrapAngle(want - this.yaw) * Math.min(1, 8 * dt);
      }
      for (let i = 0; i < N; i++) { v[i * 3] += dvx; v[i * 3 + 2] += dvz; }
    }
    if (!floppy && ctl.jump && (this.grounded || this.coyote > 0) && !this.charging) {
      for (let i = 0; i < N; i++) v[i * 3 + 1] = Math.max(v[i * 3 + 1], 0) + 760;
      this.scaleTarget = [0.78, 1.3, 0.78]; this.restScale = [0.9, 1.12, 0.9];
      this.coyote = 0; this.grounded = false;
      events.push({ type: 'jump' });
    }
    for (let i = 0; i < N * 3; i++) pred[i] = x[i] + v[i] * dt;

    // shape matching
    let cx = 0, cy = 0, cz = 0;
    for (let i = 0; i < N; i++) { cx += pred[i * 3]; cy += pred[i * 3 + 1]; cz += pred[i * 3 + 2]; }
    cx /= N; cy /= N; cz /= N;
    const R0 = this.restScale;
    const apq = M3.zero(), aqq = M3.zero();
    for (let i = 0; i < N; i++) {
      const qx = rest[i * 3] * R0[0], qy = rest[i * 3 + 1] * R0[1], qz = rest[i * 3 + 2] * R0[2];
      const px = pred[i * 3] - cx, py = pred[i * 3 + 1] - cy, pz = pred[i * 3 + 2] - cz;
      apq[0] += px * qx; apq[1] += py * qx; apq[2] += pz * qx;
      apq[3] += px * qy; apq[4] += py * qy; apq[5] += pz * qy;
      apq[6] += px * qz; apq[7] += py * qz; apq[8] += pz * qz;
      aqq[0] += qx * qx; aqq[1] += qy * qx; aqq[2] += qz * qx;
      aqq[3] += qx * qy; aqq[4] += qy * qy; aqq[5] += qz * qy;
      aqq[6] += qx * qz; aqq[7] += qy * qz; aqq[8] += qz * qz;
    }
    this.rotQ = extractRotation(apq, this.rotQ);
    let desired = Quat.axisAngle(new V3(0, 1, 0), this.yaw);
    if (moving && !this.charging && !floppy) desired = Quat.axisAngle(new V3(this.moveDir.z, 0, -this.moveDir.x), 0.2).mul(desired);
    const upK = floppy ? 0 : 0.07;
    const qGoal = upK > 0 ? this.rotQ.slerp(desired, upK) : this.rotQ;
    const Rm = qGoal.toM3();
    let lin = M3.mul(apq, M3.inverse(aqq));
    const det = M3.det(lin);
    if (det > 0.05) lin = M3.scale(lin, 1 / Math.cbrt(det)); else lin = Rm;
    const beta = floppy ? 0.5 : 0.3;
    const G = M3.add(M3.scale(lin, beta), M3.scale(Rm, 1 - beta));
    this.G = G;
    const stiff = floppy ? 0.06 : 0.2;
    for (let i = 0; i < N; i++) {
      const qx = rest[i * 3] * R0[0], qy = rest[i * 3 + 1] * R0[1], qz = rest[i * 3 + 2] * R0[2];
      const gx = cx + G[0] * qx + G[3] * qy + G[6] * qz;
      const gy = cy + G[1] * qx + G[4] * qy + G[7] * qz;
      const gz = cz + G[2] * qx + G[5] * qy + G[8] * qz;
      pred[i * 3] += (gx - pred[i * 3]) * stiff; pred[i * 3 + 1] += (gy - pred[i * 3 + 1]) * stiff; pred[i * 3 + 2] += (gz - pred[i * 3 + 2]) * stiff;
    }

    // collisions
    const wasGrounded = this.grounded;
    this.grounded = false;
    let bounced = false;
    const prevFall = -ay;
    const p = new V3();
    const contacts = [];
    const idt = 1 / dt;
    for (let i = 0; i < N; i++) {
      const i3 = i * 3;
      const vpx = (pred[i3] - x[i3]) * idt, vpy = (pred[i3 + 1] - x[i3 + 1]) * idt, vpz = (pred[i3 + 2] - x[i3 + 2]) * idt;
      contacts.length = 0;
      p.set(pred[i3], pred[i3 + 1], pred[i3 + 2]);
      world.resolve(p, POINT_R, contacts);
      pred[i3] = p.x; pred[i3 + 1] = p.y; pred[i3 + 2] = p.z;
      if (contacts.length === 0) { v[i3] = vpx; v[i3 + 1] = vpy; v[i3 + 2] = vpz; x[i3] = p.x; x[i3 + 1] = p.y; x[i3 + 2] = p.z; continue; }
      let nvx = (p.x - x[i3]) * idt, nvy = (p.y - x[i3 + 1]) * idt, nvz = (p.z - x[i3 + 2]) * idt;
      for (const ct of contacts) {
        const n = ct.n, sv = ct.solid.vel;
        const rx = nvx - sv.x, ry = nvy - sv.y, rz = nvz - sv.z;
        const vn = rx * n.x + ry * n.y + rz * n.z;
        let tx = rx - n.x * vn, ty = ry - n.y * vn, tz = rz - n.z * vn;
        const fr = ct.solid.kind === 'ice' ? ct.solid.friction : (moving && !floppy ? 0.02 : (floppy ? 0.06 : 0.16));
        tx *= 1 - fr; ty *= 1 - fr; tz *= 1 - fr;
        let vnOut = Math.max(vn, 0);
        if (ct.solid.kind === 'bouncy' && n.y > 0.5) {
          vnOut = Math.max(-((vpx - sv.x) * n.x + (vpy - sv.y) * n.y + (vpz - sv.z) * n.z) * 0.9, 1250);
          bounced = true;
          ct.solid.squash = 1;
        }
        nvx = sv.x + tx + n.x * vnOut; nvy = sv.y + ty + n.y * vnOut; nvz = sv.z + tz + n.z * vnOut;
        if (n.y > 0.55) this.grounded = true;
      }
      v[i3] = nvx; v[i3 + 1] = nvy; v[i3 + 2] = nvz;
      x[i3] = p.x; x[i3 + 1] = p.y; x[i3 + 2] = p.z;
    }
    if (bounced) {
      for (let i = 0; i < N; i++) v[i * 3 + 1] = Math.max(v[i * 3 + 1], 1250);
      this.scaleTarget = [0.7, 1.4, 0.7];
      this.grounded = false; this.pounding = false;
      events.push({ type: 'trampoline' });
    }
    const damp = 1 - 0.25 * dt;
    for (let i = 0; i < N * 3; i++) v[i] *= damp;

    let nx = 0, ny = 0, nz = 0;
    for (let i = 0; i < N; i++) { nx += x[i * 3]; ny += x[i * 3 + 1]; nz += x[i * 3 + 2]; }
    nx /= N; ny /= N; nz /= N;
    this.cVel.set((nx - this.c.x) * idt, (ny - this.c.y) * idt, (nz - this.c.z) * idt);
    this.c.set(nx, ny, nz);

    if (this.grounded) {
      if (!wasGrounded) {
        const impact = Math.max(prevFall, this.peakFall);
        if (this.pounding) { events.push({ type: 'poundLand' }); this.scaleTarget = [1.6, 0.45, 1.6]; this.pounding = false; }
        else if (impact > 250) {
          events.push({ type: 'land', k: impact });
          const k = Math.min(1, impact / 1400);
          this.scaleTarget = [1 + 0.45 * k, 1 - 0.4 * k, 1 + 0.45 * k];
        }
      }
      this.coyote = 0.1; this.airTime = 0; this.peakFall = 0;
    } else {
      this.coyote -= dt; this.airTime += dt; this.peakFall = Math.max(this.peakFall, -ay);
    }

    if (!floppy) {
      if (ctl.squish && this.grounded) { this.charging = true; this.charge = Math.min(1, this.charge + dt * 1.5); }
      else if (this.charging) {
        this.charging = false;
        if (this.charge > 0.2 && (this.grounded || this.coyote > 0)) {
          const k = this.charge;
          for (let i = 0; i < N; i++) v[i * 3 + 1] = Math.max(v[i * 3 + 1], 0) + 380 + 300 * k;
          this.restScale = [0.92, 1.12, 0.92]; this.scaleTarget = [0.75, 1.35, 0.75];
          this.grounded = false; this.coyote = 0;
          events.push({ type: 'superJump', k });
        }
        this.charge = 0;
      }
      if (ctl.squish && !this.grounded && !this.pounding && this.airTime > 0.12 && !this.charging) {
        this.pounding = true;
        for (let i = 0; i < N; i++) { v[i * 3] *= 0.3; v[i * 3 + 1] = Math.min(v[i * 3 + 1], -1300); v[i * 3 + 2] *= 0.3; }
        this.scaleTarget = [0.8, 1.2, 0.8];
        events.push({ type: 'pound' });
      }
    }
    const hs = Math.hypot(ax, az);
    if (this.grounded && hs > 60 && !this.charging) {
      const before = this.walkPhase;
      this.walkPhase += hs * dt * 0.035;
      if (Math.floor(before / Math.PI) !== Math.floor(this.walkPhase / Math.PI)) events.push({ type: 'step' });
    }
  }

  /** Keeps this body's points out of another jelly (an ellipsoid). Returns true if standing on it. */
  pushOut(o) {
    if (this.c.sub(o.c).len > 160 || o.flushing >= 0 || this.flushing >= 0) return false;
    let standing = false;
    const axr = 38, ayr = 54, azr = 35;
    const x = this.x, v = this.v;
    for (let i = 0; i < N; i++) {
      const dx = x[i * 3] - o.c.x, dy = x[i * 3 + 1] - o.c.y, dz = x[i * 3 + 2] - o.c.z;
      const qx = dx / axr, qy = dy / ayr, qz = dz / azr;
      const l = Math.hypot(qx, qy, qz);
      if (l >= 1 || l < 1e-4) continue;
      let gx = qx / axr, gy = qy / ayr, gz = qz / azr;
      const gl = Math.hypot(gx, gy, gz) || 1; gx /= gl; gy /= gl; gz /= gl;
      const tx = o.c.x + qx * axr / l, ty = o.c.y + qy * ayr / l, tz = o.c.z + qz * azr / l;
      x[i * 3] += (tx - x[i * 3]) * 0.5; x[i * 3 + 1] += (ty - x[i * 3 + 1]) * 0.5; x[i * 3 + 2] += (tz - x[i * 3 + 2]) * 0.5;
      const vn = (v[i * 3] - o.cVel.x) * gx + (v[i * 3 + 1] - o.cVel.y) * gy + (v[i * 3 + 2] - o.cVel.z) * gz;
      if (vn < 0) { v[i * 3] -= gx * vn * 0.8; v[i * 3 + 1] -= gy * vn * 0.8; v[i * 3 + 2] -= gz * vn * 0.8; }
      if (gy > 0.6) standing = true;
    }
    if (standing) { this.grounded = true; this.coyote = 0.1; }
    return standing;
  }

  translate(d) {
    for (let i = 0; i < N; i++) { this.x[i * 3] += d.x; this.x[i * 3 + 1] += d.y; this.x[i * 3 + 2] += d.z; }
    this.c.addi(d);
    for (let a = 0; a < 2; a++) { for (const q of this.arms[a]) q.addi(d); for (const q of this.armsPrev[a]) q.addi(d); }
  }

  shove(dv, spin = 0, axis = new V3(0, 0, 1)) {
    for (let i = 0; i < N; i++) {
      const rx = this.x[i * 3] - this.c.x, ry = this.x[i * 3 + 1] - this.c.y, rz = this.x[i * 3 + 2] - this.c.z;
      this.v[i * 3] += dv.x + (axis.y * rz - axis.z * ry) * spin;
      this.v[i * 3 + 1] += dv.y + (axis.z * rx - axis.x * rz) * spin;
      this.v[i * 3 + 2] += dv.z + (axis.x * ry - axis.y * rx) * spin;
    }
    this.pounding = false; this.charging = false; this.charge = 0;
  }

  bounceUp(vy) { for (let i = 0; i < N; i++) this.v[i * 3 + 1] = Math.max(this.v[i * 3 + 1], vy); }

  flushPose(center, s, a) {
    this.G = M3.scale(Quat.axisAngle(new V3(0, 1, 0), a).toM3(), s);
    this.c = center.clone(); this.cVel = new V3();
    for (let i = 0; i < N; i++) {
      const q = M3.mulv(this.G, this.restV(i));
      this.x[i * 3] = center.x + q.x; this.x[i * 3 + 1] = center.y + q.y; this.x[i * 3 + 2] = center.z + q.z;
      this.v[i * 3] = this.v[i * 3 + 1] = this.v[i * 3 + 2] = 0;
    }
    this.drawScale = s;
    this.grounded = false;
  }

  // ---------------- per-frame visuals

  frame(dt, world, t) {
    for (let a = 0; a < 2; a++) {
      const pts = this.arms[a], prev = this.armsPrev[a];
      if (pts.length !== 7) continue;
      const sh = this.skinned(this.shoulderSkin[a]);
      const side = M3.mulv(this.G, new V3(a === 0 ? -1 : 1, 0, 0)).norm;
      pts[0].copy(sh);
      const dt2 = dt * dt;
      for (let i = 1; i < 7; i++) {
        const vx = (pts[i].x - prev[i].x) * 0.9, vy = (pts[i].y - prev[i].y) * 0.9, vz = (pts[i].z - prev[i].z) * 0.9;
        prev[i].copy(pts[i]);
        pts[i].x += vx + side.x * 420 * dt2; pts[i].y += vy - 500 * dt2; pts[i].z += vz + side.z * 420 * dt2;
        if (this.aimTimer > 0 && a === 1) {
          const gx = sh.x + this.aimDir.x * i * 11, gy = sh.y + this.aimDir.y * i * 11, gz = sh.z + this.aimDir.z * i * 11;
          pts[i].x += (gx - pts[i].x) * 0.5; pts[i].y += (gy - pts[i].y) * 0.5; pts[i].z += (gz - pts[i].z) * 0.5;
        }
        if (this.flushing < 0 && this.ko <= 0 && !this.grounded && this.aimTimer <= 0) {
          const k = dt2 * 6;
          pts[i].x += side.x * 60 * k; pts[i].y += (260 + Math.sin(t * 18 + i + a * 3) * 120) * k; pts[i].z += side.z * 60 * k;
        }
      }
      for (let it = 0; it < 3; it++) {
        pts[0].copy(sh);
        for (let i = 1; i < 7; i++) {
          const dx = pts[i].x - pts[i - 1].x, dy = pts[i].y - pts[i - 1].y, dz = pts[i].z - pts[i - 1].z;
          const l = Math.hypot(dx, dy, dz);
          if (l > 1e-4) {
            const k = (l - 7) / l;
            if (i === 1) { pts[i].x -= dx * k; pts[i].y -= dy * k; pts[i].z -= dz * k; }
            else { pts[i].x -= dx * k * 0.5; pts[i].y -= dy * k * 0.5; pts[i].z -= dz * k * 0.5; pts[i - 1].x += dx * k * 0.5; pts[i - 1].y += dy * k * 0.5; pts[i - 1].z += dz * k * 0.5; }
          }
        }
      }
      const gy = world.groundBelow(this.c.x, this.c.z, this.c.y);
      if (gy !== null) for (let i = 1; i < 7; i++) if (pts[i].y < gy + 6) pts[i].y = gy + 6;
    }
    this.aimTimer -= dt;
    this.eyes.forEach((e, i) => { const f = this.eyeFrame(i); e.update(f[0], f[2], f[3], dt); });
    this.mouthOpen = Math.max(0, this.mouthOpen - dt * 3);
    this.hurtFace = Math.max(0, this.hurtFace - dt);
    this.invuln = Math.max(0, this.invuln - dt);
  }

  jolt() { for (const e of this.eyes) e.jolt(frand(-500, 500), frand(200, 700)); }

  drawEyes() {
    const m = new THREE.Matrix4();
    this.eyes.forEach((e, i) => {
      const [p, n, r, u] = this.eyeFrame(i);
      e.node.position.set(p.x, p.y, p.z);
      m.makeBasis(new THREE.Vector3(r.x, r.y, r.z), new THREE.Vector3(u.x, u.y, u.z), new THREE.Vector3(n.x, n.y, n.z));
      e.node.quaternion.setFromRotationMatrix(m);
      e.node.scale.setScalar(this.drawScale);
      e.drawPupil();
    });
  }

  draw(world, t) {
    const arr = this.posAttr.array, tmp = new V3();
    for (let i = 0; i < this.meshSkin.length; i++) {
      this.skinned(this.meshSkin[i], tmp);
      arr[i * 3] = tmp.x; arr[i * 3 + 1] = tmp.y; arr[i * 3 + 2] = tmp.z;
    }
    this.posAttr.needsUpdate = true;
    this.bodyGeo.computeVertexNormals();
    this.bodyMat.emissive.copy(this.ko > 0 ? new THREE.Color(0) : this.glow);
    this.drawEyes();

    const [mp, mn, mr, mu] = this.frame(this.skinned(this.mouthSkin), this.mouthNormal, 0);
    this.mouth.position.set(mp.x, mp.y, mp.z);
    const m = new THREE.Matrix4().makeBasis(new THREE.Vector3(mr.x, mr.y, mr.z), new THREE.Vector3(mu.x, mu.y, mu.z), new THREE.Vector3(mn.x, mn.y, mn.z));
    this.mouth.quaternion.setFromRotationMatrix(m);
    let mw = 11, mh = 3;
    if (this.hurtFace > 0 || this.ko > 0) { mw = 12; mh = 2.5 + Math.abs(Math.sin(t * 30)) * 2; }
    else if (this.mouthOpen > 0.05 || !this.grounded || this.charging) {
      const o = Math.max(this.mouthOpen, this.grounded ? 0.5 : 0.8);
      mw = this.charging ? 13 : 8; mh = 3 + 8 * o;
    }
    this.mouth.scale.set(mw * this.drawScale, mh * this.drawScale, 3 * this.drawScale);

    const limbs = this.drawScale >= 0.98;
    for (const l of this.limbs) l.visible = limbs;
    for (let a = 0; a < 2; a++) {
      const p = this.arms[a];
      if (p.length !== 7) continue;
      const beads = this.armBeads[a];
      for (let j = 0; j < beads.length; j++) {
        const f = j / (beads.length - 1) * 6;
        const i0 = Math.min(5, Math.floor(f)), tt = f - i0;
        beads[j].position.set(p[i0].x + (p[i0 + 1].x - p[i0].x) * tt, p[i0].y + (p[i0 + 1].y - p[i0].y) * tt, p[i0].z + (p[i0 + 1].z - p[i0].z) * tt);
      }
      this.hands[a].position.set(p[6].x, p[6].y, p[6].z);
    }
    const fx = Math.sin(this.yaw), fz = Math.cos(this.yaw);
    for (let i = 0; i < 2; i++) {
      const base = this.skinned(this.footSkin[i]);
      const ph = i === 0 ? Math.sin(this.walkPhase) : -Math.sin(this.walkPhase);
      const lift = this.grounded ? Math.max(0, ph) * 9 : 0;
      const fwd = 5 + (this.grounded ? ph * 6 : 0);
      this.shoes[i].position.set(base.x + fx * fwd, base.y - 3 + lift, base.z + fz * fwd);
      this.shoes[i].rotation.set(0, this.yaw, 0);
    }
    const gy = world.groundBelow(this.c.x, this.c.z, this.c.y);
    if (gy !== null) {
      const h = Math.max(0, this.bottom - gy), k = Math.max(0.2, 1 - h / 600);
      this.shadow.visible = true;
      this.shadow.position.set(this.c.x, gy + 1.5, this.c.z);
      this.shadow.scale.setScalar(k);
      this.shadow.material.opacity = k;
    } else this.shadow.visible = false;
    this.chargeRing.position.set(this.c.x, this.bottom + 4, this.c.z);
    this.chargeRing.material.opacity = this.charging ? 0.3 + this.charge * 0.7 : 0;
    this.chargeRing.visible = this.charging;
    this.chargeRing.scale.setScalar(1.3 - this.charge * 0.45 + Math.sin(t * 40) * 0.03 * this.charge);
    const flash = this.invuln > 0 && Math.floor(t * 16) % 2 === 0;
    this.bodyMesh.visible = !flash || this.drawScale < 1;
    if (flash) this.bodyMesh.visible = false;
  }
}
