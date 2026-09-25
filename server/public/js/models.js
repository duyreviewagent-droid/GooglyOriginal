// 3D models: junk, enemies, decor, signs, flag, golden toilet, crown, shockwave.
// Ports of Things.swift, Scenery.swift (decor/sign/flag/toilet) and Game.makeCrown, built from
// SceneKit-style primitives (see helpers below). Geometries and materials are cached and shared.
import * as THREE from 'three';
import { Googly } from './googly.js';

const HAS_DOM = typeof document !== 'undefined';

// ------------------------------------------------------------------ primitive helpers (Util.swift)

const matCache = new Map();
/** SceneKit `mat()`: physically based colour material (cached by parameters). */
export function mat(color, rough = 0.6, metal = 0, emission = null) {
  const key = `${color}|${rough}|${metal}|${emission}`;
  let m = matCache.get(key);
  if (!m) {
    m = new THREE.MeshStandardMaterial({ color, roughness: rough, metalness: metal });
    if (emission !== null) m.emissive.setHex(emission);
    matCache.set(key, m);
  }
  return m;
}

const geoCache = new Map();
function cachedGeo(key, make) {
  let g = geoCache.get(key);
  if (!g) { g = make(); geoCache.set(key, g); }
  return g;
}

export function sphereGeo(r, seg = 24) {
  return cachedGeo(`s${r}|${seg}`, () => new THREE.SphereGeometry(r, seg, Math.max(6, Math.round(seg * 0.75))));
}
/** SCNCylinder(radius, height). */
export function cylGeo(r, h, seg = 32) { return cachedGeo(`c${r}|${h}|${seg}`, () => new THREE.CylinderGeometry(r, r, h, seg)); }
/** SCNCone(topRadius: r1, bottomRadius: r0, height). */
export function coneGeo(r0, r1, h) { return cachedGeo(`k${r0}|${r1}|${h}`, () => new THREE.CylinderGeometry(r1, r0, h, 28)); }
/** SCNCapsule(capRadius, height) — height is the total height. */
export function capsuleGeo(r, h) { return cachedGeo(`p${r}|${h}`, () => new THREE.CapsuleGeometry(r, Math.max(0, h - 2 * r), 8, 20)); }
/** SCNTorus(ringRadius, pipeRadius): lies in the XZ plane like SceneKit. */
export function torusGeo(R, r, radial = 16, tubular = 48) {
  return cachedGeo(`t${R}|${r}|${radial}|${tubular}`, () => new THREE.TorusGeometry(R, r, radial, tubular).rotateX(-Math.PI / 2));
}
/** SCNTube(innerRadius, outerRadius, height), centred, axis along Y. */
export function tubeGeo(ri, ro, h) {
  return cachedGeo(`u${ri}|${ro}|${h}`, () => new THREE.LatheGeometry([
    new THREE.Vector2(ri, -h / 2), new THREE.Vector2(ro, -h / 2), new THREE.Vector2(ro, h / 2),
    new THREE.Vector2(ri, h / 2), new THREE.Vector2(ri, -h / 2)], 40));
}

/**
 * SCNBox(width, height, length, chamferRadius) — rounded box with the same face groups as
 * THREE.BoxGeometry (+X, -X, +Y, -Y, +Z, -Z). `worldUV` replaces the per-face 0..1 UVs with
 * face-plane coordinates in world units (so one tiled material fits boxes of any size).
 */
export function roundedBoxGeo(w, h, d, chamfer = 0, worldUV = false) {
  const key = `b${w}|${h}|${d}|${chamfer}|${worldUV}`;
  return cachedGeo(key, () => makeRoundedBox(w, h, d, chamfer, worldUV));
}

function makeRoundedBox(w, h, d, chamfer, worldUV) {
  const half = [w / 2, h / 2, d / 2];
  const r = Math.max(0, Math.min(chamfer, half[0], half[1], half[2]));
  if (r <= 1e-4) {
    const g = new THREE.BoxGeometry(w, h, d);
    if (worldUV) applyWorldUV(g, 2);
    return g;
  }
  const s = 3, n = 2 * s + 1;
  const g = new THREE.BoxGeometry(w, h, d, n, n, n);
  const pos = g.attributes.position, nor = g.attributes.normal, uv = g.attributes.uv;
  const p = [0, 0, 0], inner = [0, 0, 0], orig = [0, 0, 0];
  const per = (n + 1) * (n + 1);
  const UV_AXES = [[2, 1], [2, 1], [0, 2], [0, 2], [0, 1], [0, 1]]; // face -> [u axis, v axis]
  // keep per-face 0..1 UVs proportional to the remapped (non-uniform) grid
  const fixUV = (i) => {
    const [au, av] = UV_AXES[Math.floor(i / per)];
    const t = [0, 0];
    [au, av].forEach((ax, k) => {
      const tO = (orig[ax] + half[ax]) / (2 * half[ax]), tN = (p[ax] + half[ax]) / (2 * half[ax]);
      const cur = k === 0 ? uv.getX(i) : uv.getY(i);
      t[k] = Math.abs(cur - tO) < 1e-4 ? tN : 1 - tN;
    });
    uv.setXY(i, t[0], t[1]);
  };
  for (let i = 0; i < pos.count; i++) {
    p[0] = orig[0] = pos.getX(i); p[1] = orig[1] = pos.getY(i); p[2] = orig[2] = pos.getZ(i);
    for (let a = 0; a < 3; a++) {
      const H = half[a];
      const idx = Math.round((p[a] / (2 * H) + 0.5) * n);
      let c;
      if (idx <= s) c = -H + r * (idx / s);
      else if (idx >= n - s) c = H - r * ((n - idx) / s);
      else c = p[a];
      p[a] = c;
      inner[a] = Math.min(Math.max(c, -(H - r)), H - r);
    }
    fixUV(i);
    let dx = p[0] - inner[0], dy = p[1] - inner[1], dz = p[2] - inner[2];
    const l = Math.hypot(dx, dy, dz);
    if (l > 1e-9) {
      dx /= l; dy /= l; dz /= l;
      pos.setXYZ(i, inner[0] + dx * r, inner[1] + dy * r, inner[2] + dz * r);
      nor.setXYZ(i, dx, dy, dz);
    } else {
      pos.setXYZ(i, p[0], p[1], p[2]);
    }
  }
  if (worldUV) applyWorldUV(g, n);
  g.computeBoundingSphere();
  g.computeBoundingBox();
  return g;
}

function applyWorldUV(g, n) {
  const pos = g.attributes.position, uv = g.attributes.uv;
  const per = (n + 1) * (n + 1);
  for (let i = 0; i < pos.count; i++) {
    const face = Math.floor(i / per); // 0 +X, 1 -X, 2 +Y, 3 -Y, 4 +Z, 5 -Z
    const x = pos.getX(i), y = pos.getY(i), z = pos.getZ(i);
    if (face < 2) uv.setXY(i, z, y);
    else if (face < 4) uv.setXY(i, x, z);
    else uv.setXY(i, x, y);
  }
}

const mesh = (geo, m) => new THREE.Mesh(geo, m);
export const sphere = (r, m, seg = 24) => mesh(sphereGeo(r, seg), m);
export const box = (w, h, l, m, chamfer = 0) => mesh(roundedBoxGeo(w, h, l, chamfer), m);
export const cyl = (r, h, m) => mesh(cylGeo(r, h), m);
export const cone = (r0, r1, h, m) => mesh(coneGeo(r0, r1, h), m);
export const capsule = (r, h, m) => mesh(capsuleGeo(r, h), m);
export const torus = (R, r, m, radial, tubular) => mesh(torusGeo(R, r, radial, tubular), m);

/** Adds child at (x, y, z) and returns it (SCNNode.add(...).at(...)). */
function add(parent, child, x = 0, y = 0, z = 0) { child.position.set(x, y, z); parent.add(child); return child; }

export function setShadows(obj, cast = true, receive = false) {
  obj.traverse(o => { if (o.isMesh || o.isInstancedMesh) { o.castShadow = cast; o.receiveShadow = receive; } });
  return obj;
}

/** SCNShape of a closed polygon extruded `depth` along Z, centred on z = 0. */
function extrudedPolygon(pts, depth) {
  const sh = new THREE.Shape(pts.map(([x, y]) => new THREE.Vector2(x, y)));
  return new THREE.ExtrudeGeometry(sh, { depth, bevelEnabled: false }).translate(0, 0, -depth / 2);
}

function makeCanvas(w, h) {
  if (!HAS_DOM) return null;
  const c = document.createElement('canvas');
  c.width = w; c.height = h;
  return c;
}
function canvasTexture(c) {
  const t = c ? new THREE.CanvasTexture(c) : new THREE.DataTexture(new Uint8Array([200, 160, 110, 255]), 1, 1);
  t.colorSpace = THREE.SRGBColorSpace;
  t.anisotropy = 8;
  t.needsUpdate = true;
  return t;
}
const FONT = '"Chalkboard SE", "Comic Sans MS", "Marker Felt", sans-serif';

// ------------------------------------------------------------------ animations (SCNAction stand-ins)

const anims = new Set();
/** Registers per-frame animation `fn(dt)` for obj; dropped once obj has been in a scene graph and is removed. */
function animate(obj, fn) { anims.add({ obj, fn, seen: false }); }

/** Ping-pong rotateTo sequence on one axis: legs = [[target, duration], ...] repeated forever. */
function rotateLoop(obj, axis, legs) {
  let leg = 0, t = 0, from = obj.rotation[axis];
  animate(obj, dt => {
    t += dt;
    for (let guard = 0; guard < 8 && t >= legs[leg][1]; guard++) {
      t -= legs[leg][1];
      from = legs[leg][0];
      leg = (leg + 1) % legs.length;
    }
    const [target, dur] = legs[leg];
    obj.rotation[axis] = from + (target - from) * Math.min(1, t / dur);
  });
}

export function tickModels(dt) {
  for (const a of anims) {
    if (a.obj.parent) a.seen = true;
    else if (a.seen) { anims.delete(a); continue; }
    a.fn(dt);
    if (a.done) anims.delete(a);
  }
}

// ------------------------------------------------------------------ junk (Things.swift Junk.model)

const junkProtos = new Map();
export const JUNK_KINDS = ['duck', 'toast', 'fish', 'banana', 'sock', 'cheese', 'melon', 'bowling', 'chicken', 'pea'];

export function junkModel(kind) {
  let p = junkProtos.get(kind);
  if (!p) { p = buildJunk(kind); setShadows(p, true); junkProtos.set(kind, p); }
  return p.clone();
}

function buildJunk(kind) {
  const n = new THREE.Group();
  n.name = `junk-${kind}`;
  const dark = mat(0x111111, 0.3);
  switch (kind) {
    case 'duck': {
      const y = mat(0xffd21f, 0.25);
      add(n, sphere(12, y)).scale.set(1.25, 0.9, 1);
      add(n, sphere(8, y), 7, 11, 0);
      add(n, cone(4, 1, 8, mat(0xff8a00, 0.4)), 15, 10, 0).rotation.z = -Math.PI / 2;
      add(n, sphere(1.6, dark), 10, 14, 5);
      add(n, sphere(1.6, dark), 10, 14, -5);
      add(n, sphere(5, y), -12, 5, 0).scale.set(1.2, 0.8, 1);
      break;
    }
    case 'toast':
      add(n, box(26, 24, 7, mat(0xb8732f, 0.8), 3.5));
      add(n, box(20, 18, 7.4, mat(0xf1d49a, 0.9), 2), 0, -1, 0);
      break;
    case 'fish': {
      const b = mat(0x6a9fc9, 0.25);
      add(n, sphere(10, b)).scale.set(1.6, 0.85, 0.55);
      const tail = add(n, cone(8, 0, 12, b), -19, 0, 0);
      tail.rotation.z = -Math.PI / 2; tail.scale.set(1, 1, 0.35);
      add(n, sphere(2.5, mat(0xffffff, 0.3)), 10, 3, 4.5);
      add(n, sphere(1.4, dark), 10.5, 3, 5.8);
      break;
    }
    case 'banana': {
      const y = mat(0xffe135, 0.5);
      for (let k = 0; k < 7; k++) {
        const a = (k - 3) * 0.3;
        add(n, sphere(5.5 - Math.abs(k - 3) * 0.6, y), Math.sin(a) * 18, -Math.cos(a) * 12 + 6, 0);
      }
      add(n, sphere(2, mat(0x5a3a10)), Math.sin(0.9) * 18, -Math.cos(0.9) * 12 + 6, 0);
      break;
    }
    case 'sock': {
      const w = mat(0xf2f2ee, 0.9), r = mat(0xd62a3a, 0.9);
      add(n, capsule(6, 26, w), 0, 6, 0);
      add(n, capsule(6, 20, w), 5, -7, 0).rotation.z = Math.PI / 2;
      add(n, cyl(6.3, 3, r), 0, 12, 0);
      add(n, cyl(6.3, 3, r), 0, 5, 0);
      break;
    }
    case 'cheese': {
      add(n, cyl(19, 14, mat(0xffc93c, 0.6)));
      for (const [x, z] of [[6, 19], [-8, 17.5], [15, 10]]) add(n, sphere(3.5, mat(0xe0a520, 0.7)), x, 0, z);
      add(n, cyl(19.2, 3, mat(0xd8342c, 0.5)), 0, -5.5, 0);
      break;
    }
    case 'melon': {
      add(n, sphere(19, mat(0x2f8f3a, 0.35))).scale.set(1.1, 1, 1);
      for (let k = 0; k < 5; k++) {
        const s = add(n, torus(19, 1.2, mat(0x1a5a22), 8, 48));
        s.rotation.order = 'YXZ'; // SceneKit euler order
        s.rotation.set(Math.PI / 2, k * 0.63, 0);
        s.scale.set(1.1, 1, 1);
      }
      break;
    }
    case 'bowling':
      add(n, sphere(18, mat(0x1c2e6e, 0.12)));
      for (const [x, y] of [[-4, 10], [4, 10], [0, 3]]) add(n, sphere(3, mat(0x050505)), x, y, 15);
      break;
    case 'chicken': {
      const w = mat(0xfafafa, 0.7);
      add(n, sphere(13, w)).scale.set(1.2, 1, 1);
      add(n, sphere(8, w), 10, 13, 0);
      for (let k = 0; k < 3; k++) add(n, sphere(3, mat(0xe02020)), 8 + k * 3, 21, 0);
      add(n, cone(3.5, 0, 7, mat(0xffb020)), 18, 13, 0).rotation.z = -Math.PI / 2;
      add(n, sphere(3, mat(0xe02020)), 15, 8, 0);
      add(n, sphere(1.5, dark), 13, 15, 5);
      add(n, sphere(1.5, dark), 13, 15, -5);
      break;
    }
    case 'pea':
    default:
      add(n, sphere(7, mat(0x7ccf3a, 0.4)));
  }
  return n;
}

// ------------------------------------------------------------------ enemies (Things.swift Enemy.build)

const ENEMY_R = { cube: 30, pigeon: 22, toaster: 32, boss: 105 };

export function buildEnemy(kind) {
  const body = new THREE.Group();
  body.name = `enemy-${kind}`;
  const eyes = [], wings = [];
  const r = ENEMY_R[kind] ?? 30;
  const browMat = mat(0x1a1a22, 0.5);

  const eye = (R, x, y, z, yaw = 0) => {
    const g = new Googly(R);
    g.node.position.set(x, y, z);
    g.node.quaternion.setFromAxisAngle(new THREE.Vector3(0, 1, 0), yaw);
    body.add(g.node);
    eyes.push(g);
  };
  const brows = (y, x, z, len, thick) => {
    for (const s of [-1, 1]) {
      const b = add(body, box(len, thick, thick, browMat, thick * 0.4), s * x, y, z);
      b.rotation.z = -s * 0.4;
    }
  };
  const frown = (y, z, w, thick) => {
    for (const s of [-1, 1]) {
      const b = add(body, box(w, thick, thick, browMat, thick * 0.4), s * w * 0.42, y - w * 0.12, z);
      b.rotation.z = s * -0.35;
    }
  };

  switch (kind) {
    case 'toaster': {
      const chrome = mat(0xd6dbe4, 0.18, 1);
      add(body, box(72, 54, 44, chrome, 14), 0, 2, 0);
      for (const dx of [-14, 14]) add(body, box(22, 6, 30, mat(0x1a1c20), 2), dx, 27, 0);
      add(body, box(10, 16, 8, mat(0x222222), 2), 38, 6, 0);
      for (const dx of [-22, 22]) add(body, box(8, 10, 8, mat(0x333333)), dx, -28, 0);
      eye(10, -13, 5, 22.5);
      eye(10, 13, 5, 22.5);
      brows(19, 13, 24, 18, 3.5);
      frown(-12, 23, 14, 3);
      break;
    }
    case 'pigeon': {
      const grey = mat(0x8d93a3, 0.7), dark = mat(0x5c6272, 0.7);
      add(body, sphere(18, grey)).scale.set(1.3, 1, 1);
      add(body, sphere(11, dark), 18, 12, 0);
      add(body, sphere(9, mat(0x5aa37a, 0.3)), 12, 4, 0);
      add(body, cone(3.5, 0.5, 9, mat(0xe8a33a)), 30, 11, 0).rotation.z = -Math.PI / 2;
      add(body, box(18, 3, 14, dark, 1), -26, 2, 0).rotation.z = 0.3;
      for (const s of [-1, 1]) {
        const pivot = new THREE.Object3D();
        pivot.position.set(0, 6, s * 14);
        const w = add(pivot, sphere(12, dark), 0, 0, s * 14);
        w.scale.set(1.3, 0.25, 1.4);
        body.add(pivot);
        wings.push(pivot);
      }
      eye(6, 21, 15, 9, 0.3);
      eye(6, 21, 15, -9, Math.PI - 0.3);
      break;
    }
    case 'cube':
    case 'boss':
    default: {
      const boss = kind === 'boss';
      const s = r * 2;
      add(body, box(s, s, s, mat(boss ? 0x5b4a78 : 0x8f9bb3, 0.45), s * 0.12));
      const f = r + 0.5;
      eye(boss ? 27 : 10, -r * 0.36, r * 0.18, f);
      eye(boss ? 27 : 10, r * 0.36, r * 0.18, f);
      brows(r * 0.18 + (boss ? 36 : 14), r * 0.36, f + 2, boss ? 60 : 22, boss ? 9 : 4);
      frown(-r * 0.35, f + 1, boss ? 50 : 18, boss ? 8 : 3.5);
      if (boss) {
        const tieGeo = cachedGeo('bossTie', () => extrudedPolygon([[-12, 0], [12, 0], [18, -55], [0, -72], [-18, -55]], 6));
        add(body, mesh(tieGeo, mat(0xd62a3a, 0.4)), 0, -r * 0.5 + 20, f + 3);
        const gold = mat(0xffc629, 0.25, 1);
        const crown = new THREE.Group();
        add(crown, cyl(45, 26, gold));
        for (let k = 0; k < 6; k++) {
          const a = k / 6 * 2 * Math.PI;
          add(crown, cone(10, 0, 26, gold), Math.cos(a) * 38, 25, Math.sin(a) * 38);
          add(crown, sphere(5, mat(0xe0115f, 0.1)), Math.cos(a) * 45, 0, Math.sin(a) * 45);
        }
        crown.position.set(10, r + 12, 0);
        crown.rotation.z = -0.18;
        body.add(crown);
      }
    }
  }
  setShadows(body, true);
  return { body, eyes, wings };
}

/** Stun stars: three little emissive spheres on a ring of radius 28 (caller positions it at r + 18 and spins it ~6 rad/s). */
export function makeStars() {
  const s = new THREE.Group();
  s.name = 'stars';
  const m = mat(0xffe14d, 0.6, 0, 0xffc000);
  for (let i = 0; i < 3; i++) {
    const a = i * 2.09;
    add(s, sphere(5, m, 8), Math.cos(a) * 28, 0, Math.sin(a) * 28);
  }
  return s;
}

/** Thin glowing ring behind an eye pickup: vertical, in the XY plane. */
export function makeEyeHalo() {
  const h = torus(22, 1.5, mat(0xfff6a0, 0.6, 0, 0xfff6a0), 8, 48);
  h.rotation.x = Math.PI / 2; // SceneKit torus is horizontal; rotated upright like the Swift halo
  h.name = 'halo';
  return h;
}

// ------------------------------------------------------------------ decor (Scenery.decorModel)

const EMOJI_DECOR = {
  '🌳': 'tree', '🌷': 'flower-pink', '🌻': 'flower-sun', '🌼': 'flower-white', '🍄': 'mushroom', '🌿': 'bush',
  '🪨': 'rock', '🌵': 'cactus', '🦴': 'bone', '🐚': 'shell', '🪴': 'plant', '🗄️': 'cabinet', '🗄': 'cabinet',
  '🖨️': 'printer', '🖨': 'printer', '📦': 'box', '🧯': 'extinguisher',
};
const decorProtos = new Map();

export function decorModel(kind) {
  kind = EMOJI_DECOR[kind] ?? kind;
  let p = decorProtos.get(kind);
  if (!p) { p = buildDecor(kind); setShadows(p, true); decorProtos.set(kind, p); }
  return p.clone();
}

function buildDecor(e) {
  const n = new THREE.Group();
  n.name = `decor-${e}`;
  switch (e) {
    case 'tree': {
      add(n, cyl(9, 90, mat(0x7a4a2a, 0.9)), 0, 45, 0);
      const leaf = mat(0x3faa4a, 0.8);
      add(n, sphere(48, leaf), 0, 110, 0);
      add(n, sphere(34, leaf), 28, 90, 10);
      add(n, sphere(32, leaf), -26, 95, -8);
      break;
    }
    case 'flower-pink': case 'flower-sun': case 'flower-white': {
      const petal = e === 'flower-pink' ? 0xff4f7a : e === 'flower-sun' ? 0xffc629 : 0xffffff;
      add(n, cyl(1.5, 30, mat(0x3a9a3a)), 0, 15, 0);
      for (let k = 0; k < 6; k++) {
        const a = k / 6 * 2 * Math.PI;
        add(n, sphere(5, mat(petal, 0.6), 10), Math.cos(a) * 6, 31, Math.sin(a) * 6);
      }
      add(n, sphere(4, mat(0x7a4a10), 10), 0, 31, 0);
      break;
    }
    case 'mushroom': {
      add(n, cyl(6, 20, mat(0xf2ead8)), 0, 10, 0);
      add(n, sphere(18, mat(0xe03a3a, 0.4)), 0, 20, 0).scale.set(1, 0.6, 1);
      for (let k = 0; k < 5; k++) { const a = k * 1.3; add(n, sphere(3, mat(0xffffff), 8), Math.cos(a) * 11, 29, Math.sin(a) * 11); }
      break;
    }
    case 'bush': {
      const g = mat(0x4fb84a, 0.8);
      for (let k = 0; k < 4; k++) add(n, sphere(14 + k * 2, g, 12), (k - 2) * 12, 10, (k % 2) * 8);
      break;
    }
    case 'rock': case 'shell': case 'bone':
      add(n, sphere(20, mat(e === 'bone' ? 0xf0e8d8 : 0x9a948a, 0.9), 10), 0, 8, 0).scale.set(1.3, 0.7, 1);
      break;
    case 'cactus': {
      const g = mat(0x3f9a4f, 0.7);
      add(n, capsule(12, 110, g), 0, 55, 0);
      add(n, capsule(8, 40, g), 18, 65, 0);
      add(n, capsule(8, 30, g), -17, 50, 0);
      break;
    }
    case 'plant': {
      add(n, cone(12, 16, 26, mat(0xc0643a, 0.8)), 0, 13, 0);
      const g = mat(0x3faa4a, 0.7);
      for (let k = 0; k < 5; k++) {
        const a = k * 1.25;
        add(n, sphere(9, g, 10), Math.cos(a) * 9, 38 + (k % 2) * 8, Math.sin(a) * 9).scale.set(0.6, 1.6, 0.6);
      }
      break;
    }
    case 'cabinet':
      add(n, box(40, 90, 40, mat(0x9aa3b0, 0.4, 0.6), 2), 0, 45, 0);
      for (let k = 0; k < 3; k++) add(n, box(16, 3, 2, mat(0x333333)), 0, 20 + k * 28, 21);
      break;
    case 'printer':
      add(n, box(50, 28, 36, mat(0xe8e8e8, 0.5), 4), 0, 14, 0);
      add(n, box(34, 2, 26, mat(0xffffff)), 0, 29, -4);
      break;
    case 'box':
      add(n, box(46, 40, 46, mat(0xc8965a, 0.9), 1), 0, 20, 0);
      add(n, box(47, 6, 10, mat(0xa0703a)), 0, 40, 0);
      break;
    case 'extinguisher':
      add(n, cyl(9, 44, mat(0xd62a2a, 0.3)), 0, 22, 0);
      add(n, cyl(4, 8, mat(0x222222)), 0, 48, 0);
      break;
    default:
      add(n, sphere(12, mat(0x808080)));
  }
  return n;
}

// ------------------------------------------------------------------ sign (Scenery.sign)

function wrapLines(ctx, text, maxW) {
  const out = [];
  for (const para of text.split('\n')) {
    const words = para.split(' ');
    let line = '';
    for (const w of words) {
      const t = line ? line + ' ' + w : w;
      if (line && ctx.measureText(t).width > maxW) { out.push(line); line = w; } else line = t;
    }
    out.push(line);
  }
  return out;
}

export function makeSign(text) {
  const n = new THREE.Group();
  n.name = 'sign';
  add(n, cyl(5, 90, mat(0x8a5a2b, 0.9)), 0, 45, 0);
  const lines = text.split('\n').length;
  const w = 250, h = 40 + lines * 26;
  const W = 500, H = Math.round(h * 2);
  const c = makeCanvas(W, H);
  if (c) {
    const ctx = c.getContext('2d');
    ctx.fillStyle = '#e8c48a';
    ctx.fillRect(0, 0, W, H);
    ctx.font = `bold 34px ${FONT}`;
    ctx.fillStyle = '#4a2a12';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    const ls = wrapLines(ctx, text, W - 20);
    const lh = 34 * 1.25;
    const y0 = H / 2 - (ls.length - 1) * lh / 2;
    ls.forEach((l, i) => ctx.fillText(l, W / 2, y0 + i * lh));
  }
  const face = new THREE.MeshStandardMaterial({ map: canvasTexture(c), roughness: 0.9 });
  const wood = mat(0xb8894e, 0.9);
  // BoxGeometry groups: +X, -X, +Y, -Y, +Z (front face), -Z
  const board = new THREE.Mesh(roundedBoxGeo(w, h, 8, 3), [wood, wood, wood, wood, face, wood]);
  add(n, board, 0, 90 + h / 2, 0);
  n.rotation.y = 0.12;
  setShadows(n, true);
  return n;
}

// ------------------------------------------------------------------ flag (Scenery.flag / raise)

const clothGeo = () => cachedGeo('flagCloth', () => extrudedPolygon([[0, 0], [70, -22], [0, -44]], 2));

export function makeFlag() {
  const n = new THREE.Group();
  n.name = 'flag';
  add(n, cyl(3.5, 170, mat(0xdddddd, 0.3, 0.8)), 0, 85, 0);
  add(n, sphere(7, mat(0xffd23f, 0.2, 1)), 0, 172, 0);
  const cloth = add(n, mesh(clothGeo(), mat(0x9aa0aa, 0.8)), 3, 70, 0);
  cloth.name = 'cloth';
  rotateLoop(cloth, 'y', [[0.25, 0.5], [-0.15, 0.5]]);
  n.userData.cloth = cloth;
  setShadows(n, true);
  return n;
}

export function raiseFlag(flag, instant) {
  const cloth = flag.userData.cloth ?? flag.getObjectByName('cloth');
  if (!cloth || cloth.userData.raised) return;
  cloth.userData.raised = true;
  cloth.material = mat(0xe8262f, 0.6);
  const g = new Googly(9);
  g.node.position.set(22, -22, 1.5);
  g.pupil.position.set(1, -3, 0);
  cloth.add(g.node);
  cloth.userData.eye = g;
  if (instant) { cloth.position.y = 160; return; }
  const from = cloth.position.clone(), to = new THREE.Vector3(3, 160, 0);
  let t = 0;
  const a = { obj: cloth, seen: false, fn: dt => {
    t = Math.min(0.5, t + dt);
    cloth.position.lerpVectors(from, to, t / 0.5);
    if (t >= 0.5) a.done = true;
  } };
  anims.add(a);
}

// ------------------------------------------------------------------ golden toilet (Scenery.toilet)

function sparkleSprite() {
  const c = makeCanvas(32, 32);
  if (!c) return null;
  const ctx = c.getContext('2d');
  const g = ctx.createRadialGradient(16, 16, 0, 16, 16, 16);
  g.addColorStop(0, 'rgba(255,255,255,1)');
  g.addColorStop(0.4, 'rgba(255,255,255,0.6)');
  g.addColorStop(1, 'rgba(255,255,255,0)');
  ctx.fillStyle = g;
  ctx.fillRect(0, 0, 32, 32);
  return canvasTexture(c);
}

export function makeToilet() {
  const n = new THREE.Group();
  n.name = 'toilet';
  const gold = mat(0xffc629, 0.18, 1);
  add(n, cone(22, 36, 42, gold), 0, 21, 0);
  add(n, cyl(26, 6, gold), 0, 3, 0);
  add(n, torus(33, 6, gold, 16, 48), 0, 44, 0);
  add(n, cyl(28, 2, mat(0x4fb4ff, 0.05, 0, 0x103050)), 0, 40, 0);
  add(n, box(64, 70, 24, gold, 6), 0, 78, -34);
  add(n, box(70, 8, 30, gold, 3), 0, 116, -34);
  add(n, box(14, 4, 4, gold, 1), 26, 100, -20);
  setShadows(n, true);

  const light = new THREE.PointLight(0xffd860, 15000, 420, 2);
  light.position.set(0, 120, 60);
  n.add(light);
  n.userData.light = light;

  // sparkles: ~12/s, 1.4 s life, drifting up from a 70-radius sphere around y = 70
  const N = 24, base = new THREE.Color(0xfff3a0);
  const geo = new THREE.BufferGeometry();
  const P = new Float32Array(N * 3), C = new Float32Array(N * 3);
  geo.setAttribute('position', new THREE.BufferAttribute(P, 3));
  geo.setAttribute('color', new THREE.BufferAttribute(C, 3));
  const pm = new THREE.PointsMaterial({
    size: 7, vertexColors: true, transparent: true, depthWrite: false, blending: THREE.AdditiveBlending,
    map: sparkleSprite(), sizeAttenuation: true,
  });
  const pts = new THREE.Points(geo, pm);
  pts.position.set(0, 70, 0);
  pts.frustumCulled = false;
  n.add(pts);
  const parts = Array.from({ length: N }, () => ({ age: 1e9, life: 1.4, x: 0, y: 0, z: 0, vx: 0, vy: 0, vz: 0 }));
  let acc = 0;
  animate(pts, dt => {
    acc += dt * 12;
    for (const q of parts) {
      if (q.age >= q.life && acc >= 1) {
        acc -= 1;
        // uniform point in a sphere of radius 70
        let x, y, z;
        do { x = Math.random() * 2 - 1; y = Math.random() * 2 - 1; z = Math.random() * 2 - 1; } while (x * x + y * y + z * z > 1);
        q.x = x * 70; q.y = y * 70; q.z = z * 70;
        const th = Math.random() * Math.PI * 2, sp = Math.random() * (60 * Math.PI / 180);
        q.vx = Math.sin(sp) * Math.cos(th) * 40; q.vy = Math.cos(sp) * 40; q.vz = Math.sin(sp) * Math.sin(th) * 40;
        q.age = 0;
      }
    }
    acc = Math.min(acc, 2);
    parts.forEach((q, i) => {
      q.age += dt;
      let k = 0;
      if (q.age < q.life) {
        q.x += q.vx * dt; q.y += q.vy * dt; q.z += q.vz * dt;
        const t = q.age / q.life;
        k = Math.min(1, t * 6) * (1 - t);
      }
      P[i * 3] = q.x; P[i * 3 + 1] = q.y; P[i * 3 + 2] = q.z;
      C[i * 3] = base.r * k; C[i * 3 + 1] = base.g * k; C[i * 3 + 2] = base.b * k;
    });
    geo.attributes.position.needsUpdate = true;
    geo.attributes.color.needsUpdate = true;
  });

  // billboard label
  const c = makeCanvas(880, 160);
  if (c) {
    const ctx = c.getContext('2d');
    ctx.font = `bold 76px ${FONT}`;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.lineJoin = 'round';
    ctx.lineWidth = 76 * 0.06 * 2;
    ctx.strokeStyle = '#221018';
    ctx.strokeText('THE GOLDEN TOILET', 440, 82, 860);
    ctx.fillStyle = '#ffe14d';
    ctx.fillText('THE GOLDEN TOILET', 440, 82, 860);
  }
  const lbl = new THREE.Sprite(new THREE.SpriteMaterial({ map: canvasTexture(c), transparent: true, depthWrite: false }));
  lbl.scale.set(220, 40, 1);
  lbl.position.set(0, 175, 0);
  lbl.name = 'label';
  n.add(lbl);

  rotateLoop(n, 'y', [[0.25, 1.2], [-0.25, 1.2]]);
  return n;
}

// ------------------------------------------------------------------ crown (Game.makeCrown)

export function makeCrown() {
  const gold = mat(0xffc629, 0.2, 1);
  const c = new THREE.Group();
  c.name = 'crown';
  add(c, mesh(tubeGeo(17, 20, 14), gold));
  for (let k = 0; k < 5; k++) {
    const a = k / 5 * 2 * Math.PI;
    add(c, cone(6, 0, 16, gold), Math.cos(a) * 18.5, 14, Math.sin(a) * 18.5);
    add(c, sphere(3, mat(0xe0115f, 0.1), 8), Math.cos(a + 0.6) * 20, 0, Math.sin(a + 0.6) * 20);
  }
  setShadows(c, false);
  return c;
}

// ------------------------------------------------------------------ shockwave (Things.swift Shockwave)

const shockMat = mat(0xfff0c0, 0.5, 0, 0xffa040);
/** Horizontal ring whose pipe stays 7 units thick; setRadius(r) rebuilds the torus when r moves by > 4. */
export function makeShockwave() {
  let built = 20;
  const m = new THREE.Mesh(new THREE.TorusGeometry(built, 7, 8, 64).rotateX(-Math.PI / 2), shockMat);
  m.name = 'shockwave';
  const setRadius = r => {
    if (Math.abs(r - built) <= 4) { const k = r / built; m.scale.set(k, 1, k); return; }
    built = r;
    m.geometry.dispose();
    m.geometry = new THREE.TorusGeometry(Math.max(1, r), 7, 8, 64).rotateX(-Math.PI / 2);
    m.scale.set(1, 1, 1);
  };
  return { mesh: m, setRadius };
}
