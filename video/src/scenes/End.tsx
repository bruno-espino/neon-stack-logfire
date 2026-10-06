import React from 'react';
import {AbsoluteFill, interpolate, useCurrentFrame} from 'remotion';
import {C, fire, mono, sans} from '../theme';
import {Atmosphere, Embers, Pill, progress} from '../components/kit';

export const End: React.FC = () => {
  const frame = useCurrentFrame();
  const word = progress(frame, 6, 30);
  const line = progress(frame, 34, 18);
  const credit = progress(frame, 70, 18);
  const out = interpolate(frame, [150, 180], [1, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  return (
    <AbsoluteFill style={{background: C.bg, opacity: out}}>
      <Embers count={130} intensity={1.2} seed="end" />
      <AbsoluteFill style={{justifyContent: 'center', alignItems: 'center', flexDirection: 'column'}}>
        <div style={{fontFamily: sans, fontWeight: 800, fontSize: 210, letterSpacing: -10 + 6 * (1 - word), lineHeight: 1.2, padding: '0 20px 10px',
          backgroundImage: fire, WebkitBackgroundClip: 'text', backgroundClip: 'text', color: 'transparent',
          opacity: word, filter: `blur(${(1 - word) * 20}px) drop-shadow(0 0 40px rgba(255,106,26,0.45))`, transform: `scale(${0.9 + 0.1 * word})`}}>
          Logfire</div>
        <div style={{fontFamily: sans, fontWeight: 500, fontSize: 52, color: C.text, marginTop: 20, opacity: line,
          transform: `translateY(${(1 - line) * 20}px)`}}>
          See every frame your app draws.</div>
        <div style={{marginTop: 46, display: 'flex', gap: 14, opacity: line}}>
          <Pill color={C.ember}>SWIFT SDK</Pill><Pill color={C.amber}>XCODE BUILDS</Pill><Pill color="#7cc4ff">CPU PROFILES</Pill><Pill color="#e04dff">GPU CAPTURES</Pill>
        </div>
      </AbsoluteFill>
      <div style={{position: 'absolute', bottom: 70, width: '100%', textAlign: 'center', fontFamily: mono, fontSize: 20, color: C.dim, opacity: credit}}>
        Experimental · internal preview  ·  games, instrumentation &amp; this video built with Claude Code
      </div>
      <Atmosphere glow={1.2} />
    </AbsoluteFill>
  );
};
