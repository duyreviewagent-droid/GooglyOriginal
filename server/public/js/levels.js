// Level layouts — an exact port of Levels.swift (same order of pickups/enemies, same RNG), so a browser
// and a Mac can share an online lobby: network ids are indexes into these lists.
import { V3, RNG } from './util.js';
import { Solid } from './world.js';

export const GROUND_HALF = 330, PLAT_HALF = 170;
export const LEVEL_NAMES = ['The Backyard of Destiny', 'The Desert of Mild Inconvenience', 'Cube Corp HQ'];

export class LevelData {
  constructor(theme) {
    this.theme = theme;
    this.name = ''; this.subtitle = '';
    this.solids = []; this.fans = [];
    this.pickups = [];     // {what: 'eye' | junk name, pos}
    this.enemies = [];     // {kind, pos}
    this.checkpoints = []; this.signs = []; this.decor = [];
    this.goal = new V3(); this.goalHidden = false;
    this.start = new V3(0, 80, 0);
    this.minX = -300; this.maxX = 8000;
    this.bossTrigger = null;
    this.rng = new RNG(99);
  }
  ground(x0, x1, y = 0, ice = false) {
    const h = GROUND_HALF;
    this.solids.push(new Solid([{ x: x0, y: y - 700 }, { x: x1, y: y - 700 }, { x: x1, y }, { x: x0, y }], -h, h, ice ? 'ice' : 'ground'));
  }
  plat(x0, top, w, h = 34) {
    const d = Math.min(PLAT_HALF, Math.max(70, w * 0.6));
    this.solids.push(new Solid([{ x: x0, y: top - h }, { x: x0 + w, y: top - h }, { x: x0 + w, y: top }, { x: x0, y: top }], -d, d, 'platform'));
  }
  wall(x0, x1, top) {
    const h = GROUND_HALF + 200;
    this.solids.push(new Solid([{ x: x0, y: -700 }, { x: x1, y: -700 }, { x: x1, y: top }, { x: x0, y: top }], -h, h, 'ground'));
    const b = new Solid([{ x: x0, y: top }, { x: x1, y: top }, { x: x1, y: top + 1600 }, { x: x0, y: top + 1600 }], -h, h, 'ground');
    b.hidden = true;
    this.solids.push(b);
  }
  ramp(x0, x1, y0, y1) {
    const base = Math.min(y0, y1) - 700, h = GROUND_HALF;
    this.solids.push(new Solid([{ x: x0, y: base }, { x: x1, y: base }, { x: x1, y: y1 }, { x: x0, y: y0 }], -h, h, 'ground'));
  }
  tramp(x, top, w = 120) {
    this.solids.push(new Solid([{ x, y: top - 22 }, { x: x + w, y: top - 22 }, { x: x + w, y: top }, { x, y: top }], -w / 2, w / 2, 'bouncy'));
  }
  mover(x0, top, w, { dx = 0, dy = 0, dz = 0, speed = 1, phase = 0 } = {}) {
    const d = 110;
    const s = new Solid([{ x: x0, y: top - 26 }, { x: x0 + w, y: top - 26 }, { x: x0 + w, y: top }, { x: x0, y: top }], -d, d, 'mover');
    s.base = s.pts.map(p => ({ ...p }));
    s.baseZ = [-d, d];
    s.amp = new V3(dx, dy, dz);
    s.speed = speed; s.phase = phase; s.friction = 0.2;
    this.solids.push(s);
  }
  fan(x0, x1, bottom, top, power = 3600) {
    const h = (x1 - x0) / 2 + 20;
    this.fans.push({ lo: new V3(x0, bottom, -h), hi: new V3(x1, top, h), power });
  }
  item(j, x, y, z = 0) { this.pickups.push({ what: j, pos: new V3(x, y, z) }); }
  row(j, x0, y, n, gap = 55, z = 0) { for (let i = 0; i < n; i++) this.item(j, x0 + i * gap, y, z); }
  arc(j, x0, y, n, gap = 50, h = 90) {
    for (let i = 0; i < n; i++) { const t = i / Math.max(1, n - 1); this.item(j, x0 + i * gap, y + Math.sin(t * Math.PI) * h); }
  }
  eye(x, y, z = 0) { this.pickups.push({ what: 'eye', pos: new V3(x, y, z) }); }
  enemy(kind, x, groundY) {
    const r = kind === 'cube' ? 30 : kind === 'toaster' ? 32 : kind === 'boss' ? 105 : 22;
    const z = kind === 'boss' ? 0 : this.rng.range(-140, 140);
    this.enemies.push({ kind, pos: new V3(x, groundY + r + (kind === 'pigeon' ? 0 : 2), z) });
  }
  check(x, y) { this.checkpoints.push(new V3(x, y, -120)); }
  sign(s, x, y = 0) { this.signs.push({ text: s, pos: new V3(x, y, -250) }); }
  deco(x0, x1, y, every = 120, seed = 1) {
    const r = new RNG(seed + Math.floor(Math.abs(x0) * 7));
    let x = x0 + r.range(20, every);
    while (x < x1 - 20) {
      const e = this.theme.decor[r.int(this.theme.decor.length)];
      const side = r.chance(0.5) ? 1 : -1;
      const z = side * r.range(250, GROUND_HALF - 25);
      this.decor.push({ kind: e, pos: new V3(x, y, z), scale: r.range(0.7, 1.4) });
      x += r.range(every * 0.5, every * 1.3);
    }
  }
}

const THEMES = {
  backyard: { skyTop: 0x5fb8ff, skyBottom: 0xd8f1ff, ground: 0x8a5a36, groundEdge: 0x5a3820, groundTop: 0x5cc94a, platform: 0xb07a48,
    platformTop: 0x74d65e, hillFar: 0x9fd9a0, hillNear: 0x6cc070,
    decorOrder: ['flower-pink', 'flower-sun', 'flower-white', 'mushroom', 'tree', 'bush', 'rock'],
    music: 0, topTex: 'grass', sideTex: 'dirt', platTopTex: 'grass', platSideTex: 'wood', props: 0 },
  desert: { skyTop: 0xff9d5c, skyBottom: 0xffe6a6, ground: 0xd9a35f, groundEdge: 0x9a6a33, groundTop: 0xf2c77e, platform: 0xb9854a,
    platformTop: 0xe8b96c, hillFar: 0xf0bf86, hillNear: 0xe0a568, decorOrder: ['cactus', 'cactus', 'rock', 'bone', 'cactus', 'shell'],
    music: 1, topTex: 'sand', sideTex: 'sandstone', platTopTex: 'sand', platSideTex: 'wood', props: 1 },
  office: { skyTop: 0x3f6fb8, skyBottom: 0xf2c9a0, ground: 0x8a90a6, groundEdge: 0x4b5263, groundTop: 0x3d6fb0, platform: 0x8d6e52,
    platformTop: 0xc9a27a, hillFar: 0x9aa4d6, hillNear: 0x7f8cc4, decorOrder: ['plant', 'cabinet', 'printer', 'plant', 'box', 'extinguisher'],
    music: 2, topTex: 'carpet', sideTex: 'concrete', platTopTex: 'wood', platSideTex: 'concrete', props: 2 },
};
// the decor list order must match the Mac app's emoji lists (RNG picks by index)
for (const t of Object.values(THEMES)) t.decor = t.decorOrder;

export function makeLevel(i) { return i === 1 ? desert() : i === 2 ? office() : backyard(); }

function backyard() {
  const L = new LevelData(THEMES.backyard);
  L.name = LEVEL_NAMES[0]; L.subtitle = 'Level 1';
  L.minX = -300; L.maxX = 7700;
  L.ground(-600, 1500);
  L.deco(-500, 1500, 0);
  L.sign('WASD to wobble around\nSPACE to jump', 120);
  L.row('duck', 330, 90, 5);
  L.plat(780, 100, 220);
  L.arc('duck', 800, 150, 4, 55, 40);
  L.sign('Hold SHIFT to squish.\nLet go to go BOING.', 1150);
  L.eye(1340, 330);
  L.ground(1500, 2700, 210);
  L.deco(1520, 2700, 210, 120, 2);
  L.sign('CLICK to spit stuff you\npicked up at the mouse.', 1640, 210);
  L.row('toast', 1800, 290, 4);
  L.enemy('cube', 2250, 210);
  L.row('duck', 2400, 290, 3);
  L.sign('SHIFT in the air\n= BUTT SLAM', 2560, 210);
  L.ground(2860, 4250);
  L.deco(2880, 4250, 0, 120, 3);
  L.check(3000, 0);
  L.tramp(3300, 14);
  L.sign('Trampoline.\nLegally a hat.', 3150);
  L.plat(3420, 560, 320);
  L.item('melon', 3500, 620); L.eye(3640, 630);
  L.row('fish', 3450, 110, 4);
  L.enemy('pigeon', 3900, 380);
  L.enemy('cube', 3950, 0);
  L.row('sock', 4000, 90, 3);
  L.enemy('pigeon', 4300, 420);
  L.ground(4250, 5200);
  L.deco(4270, 5200, 0, 120, 4);
  L.enemy('cube', 4600, 0);
  L.enemy('cube', 4950, 0);
  L.plat(4700, 110, 160);
  L.arc('chicken', 4720, 170, 3, 60, 30);
  L.plat(5290, 40, 110, 30);
  L.sign("Mind the gap\n(it's rude)", 5080);
  L.ground(5470, 7700);
  L.deco(5490, 6400, 0, 120, 5);
  L.check(5600, 0);
  L.row('banana', 5700, 90, 3);
  L.enemy('toaster', 6150, 0);
  L.sign('Toasters: grumpy,\nbut generous', 5900);
  L.ramp(6400, 6700, 0, 150);
  L.ground(6700, 7700, 150);
  L.deco(6720, 7700, 150, 120, 6);
  L.enemy('cube', 6950, 150);
  L.row('cheese', 6800, 230, 2, 80);
  L.goal = new V3(7400, 150, 0);
  L.wall(7700, 8000, 420);
  return L;
}

function desert() {
  const L = new LevelData(THEMES.desert);
  L.name = LEVEL_NAMES[1]; L.subtitle = 'Level 2';
  L.minX = -300; L.maxX = 8400;
  L.ground(-600, 1200);
  L.deco(-500, 1200, 0);
  L.sign("It's a dry heat.", 150);
  L.row('banana', 350, 90, 3);
  L.row('fish', 700, 90, 3);
  L.enemy('cube', 950, 0);
  L.mover(1250, 20, 160, { dx: 110, speed: 1.3 });
  L.ground(1620, 2850);
  L.deco(1640, 2850, 0, 120, 11);
  L.check(1720, 0);
  L.enemy('cube', 2050, 0);
  L.enemy('cube', 2350, 0);
  L.enemy('toaster', 2650, 0);
  L.row('cheese', 1900, 90, 2, 90);
  L.item('bowling', 2200, 100);
  L.sign('This fan is\nload-bearing', 2760);
  L.fan(2870, 3090, -700, 620, 3500);
  L.plat(3120, 470, 480);
  L.eye(3350, 560);
  L.row('sock', 3200, 540, 3);
  L.enemy('pigeon', 3500, 700);
  L.ground(3600, 5000);
  L.deco(3620, 4550, 0, 120, 12);
  L.check(3700, 0);
  L.enemy('pigeon', 3950, 380);
  L.enemy('pigeon', 4300, 400);
  L.row('duck', 3850, 90, 6, 60);
  L.sign('Going up!\n(probably)', 4450);
  L.mover(4600, 190, 150, { dy: 190, speed: 1.1 });
  L.ground(4800, 6000, 390);
  L.deco(4820, 6000, 390, 120, 13);
  L.enemy('cube', 5100, 390);
  L.enemy('cube', 5350, 390);
  L.enemy('toaster', 5700, 390);
  L.row('melon', 5000, 470, 2, 200);
  L.row('chicken', 5450, 470, 3);
  L.ground(6280, 8400);
  L.deco(6300, 8400, 0, 120, 14);
  L.check(6400, 0);
  L.tramp(6700, 14);
  L.plat(6600, 520, 90);
  L.eye(6645, 600);
  L.enemy('pigeon', 6900, 380);
  L.enemy('cube', 7050, 0);
  L.enemy('pigeon', 7300, 420);
  L.enemy('cube', 7600, 0);
  L.enemy('toaster', 7800, 0);
  L.row('banana', 7000, 90, 3);
  L.goal = new V3(8150, 0, 0);
  L.wall(8400, 8700, 300);
  return L;
}

function office() {
  const L = new LevelData(THEMES.office);
  L.name = LEVEL_NAMES[2]; L.subtitle = 'Level 3';
  L.minX = -300; L.maxX = 8200;
  L.ground(-600, 1500);
  L.deco(-500, 1500, 0);
  L.sign('CUBE CORP\nThinking inside the box since 1987', 150);
  L.row('toast', 350, 90, 4);
  L.enemy('cube', 900, 0);
  L.enemy('cube', 1200, 0);
  L.ground(1500, 2350, 0, true);
  L.sign('CAUTION: WET FLOOR\n(extremely)', 1420);
  L.enemy('cube', 1900, 0);
  L.row('duck', 1600, 90, 8, 70);
  L.ground(2350, 3150);
  L.plat(2450, 100, 180, 100);
  L.plat(2700, 195, 180, 195);
  L.plat(2950, 290, 200, 290);
  L.check(2400, 0);
  L.enemy('toaster', 2800, 0);
  L.ground(3150, 4450, 290);
  L.deco(3170, 4450, 290, 120, 21);
  L.enemy('cube', 3500, 290);
  L.enemy('cube', 3800, 290);
  L.enemy('pigeon', 3700, 650);
  L.row('bowling', 3300, 370, 2, 300);
  L.row('cheese', 3950, 370, 3);
  L.ramp(4450, 4700, 290, 0);
  L.ground(4700, 4850);
  L.sign('Air vent.\nDo not ride.', 4760);
  L.fan(4860, 5100, -700, 560, 3500);
  L.plat(5110, 340, 420);
  L.eye(5320, 420);
  L.ground(5530, 8200);
  L.deco(5550, 6500, 0, 120, 22);
  L.check(5650, 0);
  L.enemy('toaster', 5950, 0);
  L.enemy('toaster', 6250, 0);
  L.row('melon', 5800, 90, 2, 250);
  L.row('chicken', 6050, 90, 3);
  L.sign("CEO'S OFFICE\nknock first", 6550);
  L.bossTrigger = 6750;
  L.enemy('boss', 7500, 0);
  L.goal = new V3(7400, 0, 0);
  L.goalHidden = true;
  L.wall(8200, 8500, 420);
  return L;
}
