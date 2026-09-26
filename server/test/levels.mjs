// Prints the same per-level fingerprint as the Mac app's `--autotest --dumplevels=N`, so the two can be diffed:
// Mac and browser must build identical levels (they share online lobbies). node test/levels.mjs 40
// Also sanity-checks every level: the goal, checkpoints and ground enemies stand on something.
import { makeLevel } from '../public/js/levels.js';
import { World } from '../public/js/world.js';
const N = +(process.argv[2] || 40);
let bad = 0;
for (let i = 0; i < N; i++) {
  const L = makeLevel(i);
  let sx = 0, sy = 0; for (const s of L.solids) for (const p of s.pts) { sx += Math.round(p.x); sy += Math.round(p.y); }
  const kinds = L.enemies.map(e => ({ cube: 'c', pigeon: 'p', toaster: 't', boss: 'B' }[e.kind])).join('');
  let px = 0; for (const p of L.pickups) px += Math.round(p.pos.x) + Math.round(p.pos.y);
  let ex = 0; for (const e of L.enemies) ex += Math.round(e.pos.x);
  console.log(`LEVEL ${i + 1}|${L.name}|s${L.solids.length}:${sx}:${sy}|f${L.fans.length}|p${L.pickups.length}:${px}|e${kinds}:${ex}|k${L.checkpoints.length}|g${Math.trunc(L.goal.x)},${Math.trunc(L.goal.y)}|x${Math.trunc(L.maxX)}|signs${L.signs.length}`);
  const w = new World(); w.solids = L.solids;
  const probs = [];
  if (w.groundBelow(L.goal.x, L.goal.z, L.goal.y + 50) === null) probs.push('goal floats');
  for (const c of L.checkpoints) if (w.groundBelow(c.x, c.z, c.y + 50) === null) probs.push('checkpoint ' + c.x + ' floats');
  for (const e of L.enemies) if (e.kind !== 'pigeon' && w.groundBelow(e.pos.x, e.pos.z, e.pos.y) === null) probs.push('enemy ' + e.pos.x + ' floats');
  if (probs.length) { bad++; console.error(`  level ${i + 1}: ${probs.join(', ')}`); }
}
process.exit(bad ? 1 : 0);
