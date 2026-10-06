import React from 'react';
import {AbsoluteFill, useCurrentFrame, useVideoConfig} from 'remotion';
import data from '../data.json';
import {C, mono, sans} from '../theme';
import {Atmosphere, Headline, Kicker, Panel, count, pop, progress} from '../components/kit';

const CHECKS = [
  {label: 'GPU time per frame', value: 'steady', ok: true},
  {label: 'Draw encoding', value: '0.5 ms', ok: true},
  {label: 'Memory', value: 'flat', ok: true},
  {label: 'Main thread', value: '100% CPU', ok: false},
];

const Compare: React.FC<{label: string; before: number; after: number; unit: string; max: number; good: 'up' | 'down'; at: number}> = ({
  label, before, after, unit, max, good, at,
}) => {
  const frame = useCurrentFrame();
  const v = count(frame, at + 10, 40, before, after);
  const color = good === 'up' ? (v > 90 ? C.ok : C.amber) : (v < 50 ? C.ok : C.amber);
  return (
    <div style={{opacity: progress(frame, at, 12), marginBottom: 34}}>
      <div style={{display: 'flex', justifyContent: 'space-between', alignItems: 'baseline'}}>
        <span style={{fontFamily: mono, fontSize: 20, color: C.dim, letterSpacing: 3}}>{label}</span>
        <span style={{fontFamily: mono, fontSize: 20, color: C.faint}}>before {before}{unit}</span>
      </div>
      <div style={{display: 'flex', alignItems: 'center', gap: 24, marginTop: 6}}>
        <span style={{fontFamily: sans, fontWeight: 800, fontSize: 104, color, width: 290, letterSpacing: -4, fontVariantNumeric: 'tabular-nums'}}>
          {Math.round(v)}<span style={{fontSize: 40, color: C.dim}}>{unit}</span></span>
        <div style={{flex: 1, height: 18, background: C.line, borderRadius: 9}}>
          <div style={{height: 18, width: `${(v / max) * 100}%`, background: color, borderRadius: 9, boxShadow: `0 0 18px ${color}`}} />
        </div>
      </div>
    </div>
  );
};

export const Fix: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const diag = progress(frame, 96, 16);
  return (
    <AbsoluteFill style={{background: C.bg, padding: '100px 130px'}}>
      <Kicker index="04" label="THE FIX" />
      <div style={{height: 20}} />
      <Headline text="Rule things out in minutes, not days." size={80} delay={4} highlight={['minutes']} />
      <div style={{display: 'flex', gap: 60, marginTop: 90}}>
        <div style={{flex: '0 0 720px'}}>
          {CHECKS.map((c, i) => {
            const s = pop(frame, fps, 28 + i * 16);
            const color = c.ok ? C.ok : C.bad;
            const blink = !c.ok && frame > 80 ? 0.6 + 0.4 * Math.abs(Math.sin(frame / 5)) : 1;
            return (
              <Panel key={c.label} style={{display: 'flex', alignItems: 'center', gap: 22, padding: '20px 28px', marginBottom: 16,
                opacity: s, transform: `translateX(${(1 - s) * -40}px)`, borderColor: c.ok ? C.line : C.bad}} glow={c.ok ? undefined : `${C.bad}44`}>
                <span style={{width: 40, height: 40, borderRadius: 20, background: `${color}22`, border: `2px solid ${color}`, color,
                  display: 'flex', alignItems: 'center', justifyContent: 'center', fontFamily: sans, fontWeight: 800, fontSize: 22, opacity: blink}}>
                  {c.ok ? '✓' : '!'}</span>
                <span style={{fontFamily: sans, fontWeight: 500, fontSize: 32, color: C.text, flex: 1}}>{c.label}</span>
                <span style={{fontFamily: mono, fontSize: 24, color}}>{c.value}</span>
              </Panel>
            );
          })}
          <div style={{fontFamily: mono, fontSize: 23, color: C.dim, marginTop: 30, lineHeight: 1.7, opacity: diag,
            transform: `translateY(${(1 - diag) * 16}px)`}}>
            Cause: SwiftUI redrew the whole UI <span style={{color: C.text}}>120×/sec</span>.<br />
            Fix: refresh only when what it shows changes.
          </div>
        </div>
        <div style={{flex: 1, paddingTop: 10}}>
          <Compare label="FPS AFTER 15 RESTARTS" before={data.fix.fpsBefore} after={data.fix.fpsAfter} unit="" max={120} good="up" at={110} />
          <Compare label="CPU" before={data.fix.cpuBefore} after={data.fix.cpuAfter} unit="%" max={100} good="down" at={135} />
        </div>
      </div>
      <Atmosphere glow={0.4} />
    </AbsoluteFill>
  );
};
