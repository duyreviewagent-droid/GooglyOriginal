// A googly eye: a black pupil disc rattling around inside a white disc — port of World.swift `Googly`.
// The eye node's local +Z is its outward normal; the pupil moves in the node's local XY plane.
import * as THREE from 'three';

const whiteMat = new THREE.MeshStandardMaterial({ color: 0xffffff, roughness: 0.35 });
const pupilMat = new THREE.MeshStandardMaterial({ color: 0x0d0d0d, roughness: 0.15 });
const rimMat = new THREE.MeshStandardMaterial({ color: 0x1a0a0a, roughness: 0.5 });
const glintMat = new THREE.MeshStandardMaterial({ color: 0xffffff, roughness: 0.2, emissive: 0x999999 });
// clear plastic dome: faint additive sheen, no depth writes
const domeMat = new THREE.MeshStandardMaterial({
  color: 0xffffff, roughness: 0.05, transparent: true, opacity: 0.08,
  blending: THREE.AdditiveBlending, depthWrite: false,
});

const unitCyl = new THREE.CylinderGeometry(1, 1, 1, 32);
const domeGeo = new THREE.SphereGeometry(1, 20, 14);
const glintGeo = new THREE.SphereGeometry(1, 8, 6);

export class Googly {
  constructor(R, r = R * 0.52) {
    this.R = R;
    this.r = r;
    this.p = { x: 0, y: -3 };
    this.pv = { x: 0, y: 0 };
    this.lastE = { x: 0, y: 0, z: 0 };
    this.lastVE = { x: 0, y: 0, z: 0 };
    this.primed = false;
    const [node, pupil] = this.makeNode();
    this.node = node;
    this.pupil = pupil;
  }

  makeNode() {
    const R = this.R, r = this.r;
    const eye = new THREE.Group();
    eye.name = 'googly';
    const rim = new THREE.Mesh(unitCyl, rimMat);
    rim.scale.set(R * 1.06, R * 0.14, R * 1.06);
    rim.rotation.x = Math.PI / 2;
    eye.add(rim);
    const white = new THREE.Mesh(unitCyl, whiteMat);
    white.scale.set(R, R * 0.18, R);
    white.rotation.x = Math.PI / 2;
    white.position.set(0, 0, R * 0.03);
    eye.add(white);
    const dome = new THREE.Mesh(domeGeo, domeMat);
    dome.scale.set(R, R, R * 0.28);
    dome.position.set(0, 0, R * 0.08);
    dome.renderOrder = 2;
    eye.add(dome);
    const holder = new THREE.Object3D();
    const pupil = new THREE.Mesh(unitCyl, pupilMat);
    pupil.scale.set(r, R * 0.1, r);
    pupil.rotation.x = Math.PI / 2;
    pupil.position.set(0, 0, R * 0.17);
    holder.add(pupil);
    const glint = new THREE.Mesh(glintGeo, glintMat);
    glint.scale.set(r * 0.22, r * 0.22, r * 0.22 * 0.3);
    glint.position.set(-r * 0.35, r * 0.35, R * 0.24);
    holder.add(glint);
    eye.add(holder);
    for (const m of [rim, white, pupil]) m.castShadow = true;
    return [eye, holder];
  }

  reset(E) {
    this.lastE = { x: E.x, y: E.y, z: E.z };
    this.lastVE = { x: 0, y: 0, z: 0 };
    this.primed = true;
  }

  /** E is the eye centre in world space, u and v its in-plane axes. */
  update(E, u, v, dt, gravity = -2400) {
    if (!(dt > 0)) return;
    if (!this.primed) this.reset(E);
    const L = this.lastE, LV = this.lastVE;
    const vex = (E.x - L.x) / dt, vey = (E.y - L.y) / dt, vez = (E.z - L.z) / dt;
    let aex = (vex - LV.x) / dt, aey = (vey - LV.y) / dt, aez = (vez - LV.z) / dt;
    const am = Math.hypot(aex, aey, aez);
    if (am > 60000) { const k = 60000 / am; aex *= k; aey *= k; aez *= k; }
    this.lastE = { x: E.x, y: E.y, z: E.z };
    this.lastVE = { x: vex, y: vey, z: vez };
    const a3x = -aex, a3y = gravity - aey, a3z = -aez;
    const ax = a3x * u.x + a3y * u.y + a3z * u.z;
    const ay = a3x * v.x + a3y * v.y + a3z * v.z;
    const sub = 3, h = dt / sub;
    const p = this.p, pv = this.pv;
    const maxD = this.R - this.r;
    for (let i = 0; i < sub; i++) {
      pv.x += ax * h; pv.y += ay * h;
      const damp = 1 - 1.2 * h;
      pv.x *= damp; pv.y *= damp;
      p.x += pv.x * h; p.y += pv.y * h;
      const d = Math.hypot(p.x, p.y);
      if (d > maxD) {
        const nx = p.x / d, ny = p.y / d;
        p.x = nx * maxD; p.y = ny * maxD;
        const vn = pv.x * nx + pv.y * ny;
        if (vn > 0) {
          pv.x -= nx * vn * 1.5; pv.y -= ny * vn * 1.5;
          pv.x *= 0.97; pv.y *= 0.97;
        }
      }
    }
  }

  /** Kicks the pupil (for surprise moments). */
  jolt(kx, ky) { this.pv.x += kx; this.pv.y += ky; }

  drawPupil() { this.pupil.position.set(this.p.x, this.p.y, 0); }
}
