import {loadFont as loadInter} from '@remotion/google-fonts/InterTight';
import {loadFont as loadMono} from '@remotion/google-fonts/JetBrainsMono';

export const sans = loadInter('normal', {weights: ['400', '500', '700', '800'], subsets: ['latin']}).fontFamily;
export const mono = loadMono('normal', {weights: ['400', '500', '700'], subsets: ['latin']}).fontFamily;

export const FPS = 30;
/** One bar at 120 BPM. Scenes start on bar lines so music drops in cleanly later. */
export const BAR = 60;
export const BEAT = 15;

export const C = {
  bg: '#0a0706',
  panel: '#140f0d',
  panelHi: '#1c1512',
  line: '#2c211c',
  text: '#f6eee8',
  dim: '#9b8b82',
  faint: '#5d4f48',
  ember: '#ff6a1a',
  amber: '#ffb547',
  pink: '#ff4d8d',
  ok: '#4fd98b',
  bad: '#ff5148',
};

export const fire = `linear-gradient(90deg, ${C.amber}, ${C.ember} 45%, ${C.pink})`;

/** Logfire levels, with the same colours the game uses for its pieces. */
export const LEVELS: Record<number, {name: string; color: string}> = {
  1: {name: 'TRACE', color: '#9e99bd'},
  5: {name: 'DEBUG', color: '#40d1e6'},
  9: {name: 'INFO', color: '#5999ff'},
  10: {name: 'NOTICE', color: '#4dd98c'},
  13: {name: 'WARN', color: '#ffc738'},
  17: {name: 'ERROR', color: '#ff524d'},
  21: {name: 'FATAL', color: '#e04dff'},
};
