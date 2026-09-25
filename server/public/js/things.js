// Junk, pickups, projectiles, enemies, particles — logic ported from Things.swift; meshes come from models.js.
import * as THREE from 'three';
import { V3, frand } from './util.js';
import { junkModel, buildEnemy, makeStars, makeEyeHalo, makeShockwave } from './models.js';
import { Googly } from './googly.js';

export const JUNK = ['duck', 'toast', 'fish', 'banana', 'sock', 'cheese', 'melon', 'bowling', 'chicken', 'pea'];   // index = Mac rawValue
export const JUNK_INFO = {
  duck:    { emoji: '🦆', name: 'rubber duck', r: 15, dmg: 1, speed: 1100, g: 1, bounce: 0.75, recoil: 110 },
  toast:   { emoji: '🍞', name: 'toast', r: 15, dmg: 1, speed: 1100, g: 1, bounce: 0.25, recoil: 110 },
  fish:    { emoji: '🐟', name: 'fish', r: 15, dmg: 2, speed: 1100, g: 1, bounce: 0.45, recoil: 110 },
  banana:  { emoji: '🍌', name: 'boomerang banana', r: 15, dmg: 1, speed: 1100, g: 0.25, bounce: 0.45, recoil: 110 },
  sock:    { emoji: '🧦', name: 'stinky sock', r: 15, dmg: 1, speed: 1100, g: 0.8, bounce: 0.45, recoil: 110 },
  cheese:  { emoji: '🧀', name: 'cheese wheel', r: 19, dmg: 2, speed: 1100, g: 1, bounce: 0.35, recoil: 220 },
  melon:   { emoji: '🍉', name: 'watermelon', r: 19, dmg: 3, speed: 900, g: 1, bounce: 0.45, recoil: 300 },
  bowling: { emoji: '🎳', name: 'bowling ball', r: 19, dmg: 5, speed: 820, g: 1.3, bounce: 0.15, recoil: 520 },
  chicken: { emoji: '🐔', name: 'chicken', r: 17, dmg: 2, speed: 1100, g: 1, bounce: 0.8, recoil: 110 },
  pea:     { emoji: '🟢', name: 'sad pea', r: 7, dmg: 0.5, speed: 1250, g: 0.5, bounce: 0.45, recoil: 20 },
};
export const ENEMY_KINDS = ['cube', 'pigeon', 'toaster', 'boss'];   // index = Mac rawValue

export class Pickup {
  /** @param {string} what 'eye' or a junk name */
  constructor(what, pos, dynamic = false) {
    this.what = what; this.pos = pos.clone(); this.vel = new V3(); this.dynamic = dynamic;
    this.delay = 0; this.bob = frand(0, 6); this.spin = 0; this.angle = frand(0, 6); this.life = -1;
    this.dead = false; this.netID = -1; this.netTarget = null;
    this.node = new THREE.Group();
    if (what === 'eye') {
      this.r = 14;
      this.eye = new Googly(14);
      this.node.add(this.eye.node);
      this.node.add(makeEyeHalo());
    } else {
      this.r = JUNK_INFO[what].r;
      this.eye = null;
      this.node.add(junkModel(what));
    }
    this.node.position.set(pos.x, pos.y, pos.z);
  }
  update(dt, world, camera) {
    this.delay -= dt;
    if (this.life > 0) { this.life -= dt; if (this.life <= 0) this.dead = true; }
    if (this.dynamic) {
      this.vel.y -= 1900 * dt;
      this.vel.y += world.fanForce(this.pos) * dt;
      const p = this.pos.add(this.vel.mul(dt));
      const cts = [];
      world.resolve(p, this.r, cts);
      for (const ct of cts) {
        const vn = this.vel.dot(ct.n);
        if (vn < 0) this.vel.subi(ct.n.mul(vn * 1.4));
        this.vel.x *= 0.96; this.vel.z *= 0.96;
        if (ct.n.y > 0.5) this.spin *= 0.9;
      }
      this.pos = p;
      this.angle += this.spin * dt;
      if (this.pos.y < world.killY) this.dead = true;
      this.node.position.set(this.pos.x, this.pos.y, this.pos.z);
      if (!this.eye) this.node.quaternion.setFromAxisAngle(new THREE.Vector3(0.3, 1, 0.2).normalize(), this.angle);
    } else {
      this.bob += dt * 3; this.angle += dt * 1.5;
      this.node.position.set(this.pos.x, this.pos.y + Math.sin(this.bob) * 6, this.pos.z);
      if (!this.eye) this.node.rotation.set(0, this.angle, 0);
    }
    if (this.eye) {
      if (camera) this.node.quaternion.copy(camera.quaternion);
      const wp = this.node.position;
      const u = new THREE.Vector3(1, 0, 0).applyQuaternion(this.node.quaternion), v = new THREE.Vector3(0, 1, 0).applyQuaternion(this.node.quaternion);
      this.eye.update(new V3(wp.x, wp.y, wp.z), new V3(u.x, u.y, u.z), new V3(v.x, v.y, v.z), dt);
      this.eye.drawPupil();
    }
    if (this.life > 0 && this.life < 2) this.node.visible = Math.floor(this.life * 10) % 2 !== 0;
  }
}

export class Projectile {
  constructor(junk, pos, vel, hostile = false, poop = false) {
    this.junk = junk; this.pos = pos.clone(); this.vel = vel.clone(); this.hostile = hostile; this.isPoop = poop;
    this.age = 0; this.spinAxis = new THREE.Vector3(frand(-1, 1), frand(-1, 1), frand(-1, 1)).normalize();
    this.angle = 0; this.spin = frand(-14, 14); this.bounces = 0; this.hitIDs = new Set(); this.dead = false;
    this.returning = false; this.owner = -1; this.netID = -1; this.netTarget = null;
    this.r = poop ? 9 : JUNK_INFO[junk].r;
    this.node = new THREE.Group();
    if (poop) {
      const s = new THREE.Mesh(new THREE.SphereGeometry(9, 12, 10), new THREE.MeshStandardMaterial({ color: 0xf4f1e6, roughness: 0.3 }));
      s.scale.set(1.1, 0.8, 1.1);
      const d = new THREE.Mesh(new THREE.SphereGeometry(4, 8, 6), new THREE.MeshStandardMaterial({ color: 0x8a8a80 }));
      d.position.set(2, 5, 3); s.add(d);
      this.node.add(s);
    } else this.node.add(junkModel(junk));
    this.node.position.set(pos.x, pos.y, pos.z);
  }
  info() { return JUNK_INFO[this.junk]; }
}

let enemySerial = 0;
export class Enemy {
  constructor(kind, pos) {
    this.kind = kind; this.pos = pos.clone(); this.vel = new V3(); this.home = pos.clone();
    this.serial = ++enemySerial;
    const t = { cube: [30, 3], pigeon: [22, 1], toaster: [32, 4], boss: [105, 40] }[kind];
    this.r = t[0]; this.hp = t[1]; this.maxHP = t[1];
    this.yaw = 0; this.tumble = 0; this.tumbleAxis = new V3(1, 0, 0); this.spin = 0;
    this.timer = frand(0.5, 1.8); this.grounded = false; this.stun = 0; this.hurtFlash = 0; this.squash = 0;
    this.dead = false; this.phase = 0; this.spawnedMinis = 0; this.awake = false; this.netID = -1;
    this.node = new THREE.Group();
    const built = buildEnemy(kind);
    this.body = built.body; this.eyes = built.eyes; this.wings = built.wings;
    this.node.add(this.body);
    this.node.position.set(pos.x, pos.y, pos.z);
    this.node.userData.enemy = this;
    this.node.traverse(o => { o.userData.enemy = this; });
    this.stars = null;
  }
  updateEyes(dt) {
    this.node.updateMatrixWorld(true);
    const wp = new THREE.Vector3(), q = new THREE.Quaternion();
    for (const e of this.eyes) {
      e.node.getWorldPosition(wp);
      e.node.getWorldQuaternion(q);
      const u = new THREE.Vector3(1, 0, 0).applyQuaternion(q), v = new THREE.Vector3(0, 1, 0).applyQuaternion(q);
      e.update(new V3(wp.x, wp.y, wp.z), new V3(u.x, u.y, u.z), new V3(v.x, v.y, v.z), dt);
      e.drawPupil();
    }
  }
  showStars(on, t) {
    if (on && !this.stars) { this.stars = makeStars(); this.stars.position.set(0, this.r + 18, 0); this.node.add(this.stars); }
    else if (!on && this.stars) { this.node.remove(this.stars); this.stars = null; }
    if (this.stars) this.stars.rotation.y = t * 6;
  }
  /** Pose the mesh from yaw/tumble/squash (shared by host and guests). */
  pose(t) {
    this.node.position.set(this.pos.x, this.pos.y, this.pos.z);
    const q = new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(0, 1, 0), this.yaw);
    if (Math.abs(this.tumble) > 0.001) {
      const tq = new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(this.tumbleAxis.x, this.tumbleAxis.y, this.tumbleAxis.z).normalize(), this.tumble);
      q.premultiply(tq);
    }
    this.body.quaternion.copy(q);
    const sq = this.squash;
    if (this.kind !== 'pigeon') this.body.scale.set(1 + sq * 0.18, 1 - sq * 0.18, 1 + sq * 0.18);
    this.body.visible = !(this.hurtFlash > 0 && Math.floor(t * 30) % 2 === 0);
    this.showStars(this.stun > 0 && this.kind !== 'boss', t);
    if (this.kind === 'pigeon' && this.wings.length === 2) {
      const flap = Math.sin(t * 22 + this.home.x) * 0.7;
      this.wings[0].rotation.x = -flap; this.wings[1].rotation.x = flap;
    }
  }
}

export class Particle {
  constructor(node, pos, vel, life, { gravity = -900, spin = 0, drag = 0.5, shrink = true, grow = 0 } = {}) {
    this.grow = grow;
    this.node = node; this.pos = pos.clone(); this.vel = vel.clone(); this.life = life; this.maxLife = life;
    this.gravity = gravity; this.spin = spin; this.drag = drag; this.shrink = shrink;
    this.axis = new THREE.Vector3(frand(-1, 1), frand(-1, 1), frand(-1, 1)).normalize(); this.angle = 0;
    node.position.set(pos.x, pos.y, pos.z);
  }
}

export class Shockwave {
  constructor(center) {
    this.center = center.clone(); this.radius = 20; this.life = 1.2;
    const sw = makeShockwave();
    this.mesh = sw.mesh; this.setRadius = sw.setRadius;
    this.node = this.mesh;
    this.node.position.set(center.x, center.y, center.z);
  }
}
