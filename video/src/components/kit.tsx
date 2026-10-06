import React from 'react';
import {AbsoluteFill, interpolate, random, spring, useCurrentFrame, useVideoConfig, Easing} from 'remotion';
import {C, mono, sans, fire} from '../theme';

export const ease = Easing.bezier(0.16, 1, 0.3, 1);

/** 0 → 1 between two frames with an expo-out curve. */
export const progress = (frame: number, from: number, length: number) =>
  interpolate(frame, [from, from + length], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: ease});

export const pop = (frame: number, fps: number, delay = 0, damping = 14) =>
  spring({frame: frame - delay, fps, config: {damping, mass: 0.6, stiffness: 140}});

/** Fades a whole scene in and out so cuts never pop. */
export const SceneFade: React.FC<{duration: number; children: React.ReactNode; out?: number; inn?: number}> = ({
  duration, children, out = 10, inn = 8,
}) => {
  const frame = useCurrentFrame();
  const opacity = Math.min(progress(frame, 0, inn), 1 - progress(frame, duration - out, out));
  return <AbsoluteFill style={{opacity}}>{children}</AbsoluteFill>;
};

/** Sparks drifting up, like the campfire under the game board. Deterministic per frame. */
export const Embers: React.FC<{count?: number; intensity?: number; seed?: string}> = ({count = 70, intensity = 1, seed = 'e'}) => {
  const frame = useCurrentFrame();
  const {width, height} = useVideoConfig();
  return (
    <AbsoluteFill style={{pointerEvents: 'none'}}>
      {Array.from({length: count}).map((_, i) => {
        const speed = 0.6 + random(`${seed}s${i}`) * 1.6;
        const life = (height + 200) / speed;
        const t = (frame + random(`${seed}o${i}`) * life) % life;
        const y = height + 60 - t * speed;
        const x = random(`${seed}x${i}`) * width + Math.sin((frame + i * 37) / (28 + i % 9)) * 24;
        const size = 2 + random(`${seed}r${i}`) * 4;
        const fade = Math.min(1, y / height) * (0.4 + 0.6 * Math.abs(Math.sin((frame + i * 13) / 9)));
        return (
          <div key={i} style={{
            position: 'absolute', left: x, top: y, width: size, height: size, borderRadius: size,
            background: random(`${seed}c${i}`) > 0.5 ? C.amber : C.ember,
            boxShadow: `0 0 ${size * 4}px ${C.ember}`, opacity: fade * intensity,
          }} />
        );
      })}
    </AbsoluteFill>
  );
};

/** Warm floor glow, vignette and a little film grain, shared by every scene. */
export const Atmosphere: React.FC<{glow?: number}> = ({glow = 1}) => {
  const frame = useCurrentFrame();
  const flicker = 0.85 + 0.15 * Math.sin(frame * 0.37) * Math.sin(frame * 0.11 + 1);
  return (
    <AbsoluteFill style={{pointerEvents: 'none'}}>
      <AbsoluteFill style={{background: `radial-gradient(120% 60% at 50% 115%, rgba(255,90,20,${0.35 * glow * flicker}), transparent 70%)`}} />
      <AbsoluteFill style={{background: 'radial-gradient(ellipse at center, transparent 55%, rgba(0,0,0,0.65))'}} />
      <AbsoluteFill style={{
        opacity: 0.06, mixBlendMode: 'overlay',
        backgroundImage: `url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='160' height='160'><filter id='n'><feTurbulence type='fractalNoise' baseFrequency='0.9' seed='${frame % 8}'/></filter><rect width='100%' height='100%' filter='url(%23n)'/></svg>")`,
      }} />
    </AbsoluteFill>
  );
};

/** Small mono label above a headline: "02 — THE PROBLEM". */
export const Kicker: React.FC<{index: string; label: string; delay?: number; color?: string}> = ({index, label, delay = 0, color = C.ember}) => {
  const frame = useCurrentFrame();
  const p = progress(frame, delay, 18);
  return (
    <div style={{display: 'flex', alignItems: 'center', gap: 16, fontFamily: mono, fontSize: 22, letterSpacing: 4,
      color: C.dim, opacity: p, transform: `translateX(${(1 - p) * -30}px)`}}>
      <span style={{color}}>{index}</span>
      <span style={{width: 48 * p, height: 2, background: color}} />
      <span>{label}</span>
    </div>
  );
};

/** Headline whose words rise out of a blur one after another. */
export const Headline: React.FC<{text: string; delay?: number; size?: number; stagger?: number; highlight?: string[]; style?: React.CSSProperties}> = ({
  text, delay = 0, size = 96, stagger = 3, highlight = [], style,
}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  return (
    <div style={{fontFamily: sans, fontWeight: 800, fontSize: size, lineHeight: 1.02, letterSpacing: -size * 0.035,
      color: C.text, display: 'flex', flexWrap: 'wrap', columnGap: size * 0.26, ...style}}>
      {text.split(' ').map((word, i) => {
        const s = pop(frame, fps, delay + i * stagger, 16);
        const hot = highlight.includes(word.replace(/[.,!?]/g, ''));
        return (
          <span key={i} style={{display: 'inline-block', opacity: s, filter: `blur(${(1 - s) * 12}px)`,
            transform: `translateY(${(1 - s) * size * 0.5}px)`,
            ...(hot ? {backgroundImage: fire, WebkitBackgroundClip: 'text', backgroundClip: 'text', color: 'transparent'} : {})}}>
            {word}
          </span>
        );
      })}
    </div>
  );
};

export const Panel: React.FC<{children: React.ReactNode; style?: React.CSSProperties; glow?: string}> = ({children, style, glow}) => (
  <div style={{background: `linear-gradient(180deg, ${C.panelHi}, ${C.panel})`, border: `1px solid ${C.line}`, borderRadius: 20,
    boxShadow: `0 30px 80px rgba(0,0,0,0.55)${glow ? `, 0 0 60px ${glow}` : ''}`, ...style}}>{children}</div>
);

export const Pill: React.FC<{color: string; children: React.ReactNode; size?: number}> = ({color, children, size = 18}) => (
  <span style={{fontFamily: mono, fontWeight: 700, fontSize: size, letterSpacing: 1.5, color, padding: `${size * 0.2}px ${size * 0.55}px`,
    border: `1.5px solid ${color}`, borderRadius: 8, background: `${color}1f`, whiteSpace: 'nowrap'}}>{children}</span>
);

export const count = (frame: number, from: number, length: number, a: number, b: number) =>
  interpolate(frame, [from, from + length], [a, b], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: ease});

/** A bright bar that sweeps across on a cut, like a span drawn in fast-forward. */
export const SpanWipe: React.FC = () => {
  const frame = useCurrentFrame();
  const x = interpolate(frame, [0, 14], [-0.3, 1.3], {extrapolateRight: 'clamp', easing: Easing.inOut(Easing.cubic)});
  const opacity = interpolate(frame, [0, 3, 11, 14], [0, 1, 1, 0], {extrapolateRight: 'clamp'});
  return (
    <AbsoluteFill style={{pointerEvents: 'none', opacity}}>
      <div style={{position: 'absolute', top: '50%', left: `${x * 100 - 40}%`, width: '40%', height: 4, marginTop: -2,
        background: fire, boxShadow: `0 0 40px 10px ${C.ember}`, borderRadius: 4}} />
    </AbsoluteFill>
  );
};
