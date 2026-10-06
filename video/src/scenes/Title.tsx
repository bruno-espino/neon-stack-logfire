import React from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import {C, mono, sans} from '../theme';
import {Atmosphere, Embers, Headline, Pill, progress} from '../components/kit';

export const Title: React.FC = () => {
  const frame = useCurrentFrame();
  const sub = progress(frame, 34, 20);
  return (
    <AbsoluteFill style={{background: C.bg}}>
      <Embers count={90} />
      <AbsoluteFill style={{padding: '0 160px', justifyContent: 'center', transform: `scale(${1 + frame * 0.0006})`}}>
        <div style={{opacity: progress(frame, 0, 14), display: 'flex', gap: 18, alignItems: 'center', marginBottom: 36}}>
          <span style={{fontFamily: sans, fontWeight: 700, fontSize: 34, color: C.text}}>Pydantic Logfire</span>
          <Pill color={C.ember}>SWIFT SDK · EXPERIMENTAL</Pill>
        </div>
        <Headline text="Observability for apps that draw 120 frames a second." size={118} delay={6} highlight={['120', 'frames']}
          style={{maxWidth: 1500}} />
        <div style={{marginTop: 48, fontFamily: mono, fontSize: 28, color: C.dim, opacity: sub, transform: `translateY(${(1 - sub) * 20}px)`}}>
          spans · frame timing · Xcode builds · CPU profiles · GPU captures — <span style={{color: C.text}}>one place</span>
        </div>
      </AbsoluteFill>
      <Atmosphere />
    </AbsoluteFill>
  );
};
