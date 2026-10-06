import React from 'react';
import {AbsoluteFill, OffthreadVideo, interpolate, staticFile, useCurrentFrame} from 'remotion';
import data from '../data.json';
import {C, mono, sans} from '../theme';
import {Atmosphere, Headline, Kicker, Panel, progress} from '../components/kit';

/** FPS after each restart, from 120 at the first game to the measured 45 at game 15. */
const fpsAt = (game: number) => 120 - (120 - data.fix.fpsBefore) * Math.pow((game - 1) / (data.fix.games - 1), 0.8);

export const Problem: React.FC = () => {
  const frame = useCurrentFrame();
  const game = Math.min(data.fix.games, 1 + Math.floor(Math.max(0, frame - 30) / 8));
  const fps = fpsAt(game);
  const hue = interpolate(fps, [45, 120], [0, 1]);
  const color = hue > 0.6 ? C.ok : hue > 0.3 ? C.amber : C.bad;
  const freeze = frame > 170;
  const shake = frame > 150 && frame < 170 ? Math.sin(frame * 3) * 6 : 0;
  return (
    <AbsoluteFill style={{background: C.bg}}>
      <AbsoluteFill style={{transform: `scale(${1.08 + frame * 0.0005}) translateX(${shake}px)`,
        filter: `saturate(${freeze ? 0.2 : 0.8}) brightness(${freeze ? 0.35 : 0.55})`}}>
        <OffthreadVideo src={staticFile('footage/log-roll.mp4')} muted startFrom={60} />
      </AbsoluteFill>
      <AbsoluteFill style={{background: 'linear-gradient(90deg, rgba(10,7,6,0.95) 0%, rgba(10,7,6,0.6) 45%, transparent 75%)'}} />
      <AbsoluteFill style={{padding: '0 140px', justifyContent: 'center'}}>
        <Kicker index="01" label="THE BUG" />
        <div style={{height: 30}} />
        <Headline text="Every time you lost, the game got slower." size={92} delay={8} highlight={['slower']} style={{maxWidth: 900}} />
        <div style={{marginTop: 40, fontFamily: mono, fontSize: 26, color: C.dim, opacity: progress(frame, 120, 16), maxWidth: 820, lineHeight: 1.5}}>
          GPU? Shaders? A leak? <span style={{color: C.text}}>Guessing is slow.</span>
        </div>
      </AbsoluteFill>
      <div style={{position: 'absolute', right: 120, top: 150, opacity: progress(frame, 20, 14)}}>
        <Panel style={{padding: '28px 36px', width: 470}} glow={`${color}33`}>
          <div style={{fontFamily: mono, fontSize: 20, color: C.dim, letterSpacing: 3}}>LOG ROLL · RESTART #{game}</div>
          <div style={{display: 'flex', alignItems: 'baseline', gap: 14, marginTop: 6}}>
            <span style={{fontFamily: sans, fontWeight: 800, fontSize: 150, color, letterSpacing: -6, fontVariantNumeric: 'tabular-nums'}}>
              {Math.round(fps)}</span>
            <span style={{fontFamily: mono, fontSize: 30, color: C.dim}}>FPS</span>
          </div>
          <svg width={398} height={110} style={{marginTop: 8}}>
            {Array.from({length: data.fix.games}).map((_, i) => {
              const h = (fpsAt(i + 1) / 120) * 100;
              const on = i < game;
              return <rect key={i} x={i * 27} y={110 - h} width={20} height={h} rx={4}
                fill={on ? (fpsAt(i + 1) > 90 ? C.ok : fpsAt(i + 1) > 65 ? C.amber : C.bad) : C.line} opacity={on ? 0.95 : 0.6} />;
            })}
          </svg>
          <div style={{fontFamily: mono, fontSize: 16, color: C.faint, marginTop: 10}}>measured: 120 → {data.fix.fpsBefore} fps after {data.fix.games} restarts</div>
        </Panel>
      </div>
      {freeze && (
        <AbsoluteFill style={{justifyContent: 'flex-end', alignItems: 'flex-end', padding: 120}}>
          <div style={{fontFamily: sans, fontWeight: 800, fontSize: 64, color: C.text, opacity: progress(frame, 172, 10),
            transform: `scale(${1.3 - 0.3 * progress(frame, 172, 12)})`}}>
            So we asked <span style={{color: C.ember}}>Logfire.</span>
          </div>
        </AbsoluteFill>
      )}
      <Atmosphere glow={0.5} />
    </AbsoluteFill>
  );
};
