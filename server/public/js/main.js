// Boots the browser version of GooglyOriginal.
import * as THREE from 'three';
import { GameAudio } from './audio.js';
import { Input } from './input.js';
import { HUD } from './hud.js';
import { Game } from './game.js';

const canvas = document.getElementById('game');
const Q = new URLSearchParams(location.search);
const lowq = Q.has('lowq');
const renderer = new THREE.WebGLRenderer({ canvas, antialias: !lowq, powerPreference: 'high-performance' });
renderer.setPixelRatio(lowq ? 0.5 : Math.min(devicePixelRatio, 2));
renderer.shadowMap.enabled = !lowq;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;
renderer.toneMapping = THREE.NeutralToneMapping;
renderer.toneMappingExposure = 1.0;
renderer.outputColorSpace = THREE.SRGBColorSpace;
const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(42, innerWidth / innerHeight, 5, 14000);
function resize() {
  renderer.setSize(innerWidth, innerHeight, false);
  camera.aspect = innerWidth / innerHeight;
  camera.updateProjectionMatrix();
}
addEventListener('resize', resize);
resize();

const audio = new GameAudio();
const input = new Input(canvas);
const unlock = () => audio.unlock();
addEventListener('pointerdown', unlock);
addEventListener('keydown', unlock);

let game;
try {
  game = new Game({ renderer, scene, camera, audio, input, hudClass: HUD, hudRoot: document.getElementById('hud') });
} catch (e) {
  document.getElementById('boot').innerHTML = '<b>Could not start the game.</b><br>' + String(e && e.stack || e).replace(/</g, '&lt;');
  throw e;
}
window.googly = game;
document.getElementById('boot').remove();

// headless test runs (?shim=1) get a timer loop because requestAnimationFrame doesn't fire there
const shim = new URLSearchParams(location.search).has('shim');
const nextFrame = shim ? f => setTimeout(() => f(performance.now()), 33) : f => requestAnimationFrame(f);
let last = performance.now();
function frame(now) {
  const dt = (now - last) / 1000; last = now;
  try { game.tick(dt); } catch (e) { console.error(e); window.__err = String(e && e.stack || e); showError(window.__err); }
  nextFrame(frame);
}
nextFrame(frame);
function showError(msg) {
  let el = document.getElementById('err');
  if (!el) { el = document.createElement('pre'); el.id = 'err'; el.style.cssText = 'position:fixed;left:8px;bottom:8px;max-width:90vw;max-height:40vh;overflow:auto;background:#300;color:#fbb;font:11px monospace;padding:8px;z-index:99;white-space:pre-wrap'; document.body.append(el); }
  el.textContent = msg;
}

// autosave when leaving the page
addEventListener('pagehide', () => { if (game.state === 'playing' || game.state === 'paused') game.storeRun(); });
