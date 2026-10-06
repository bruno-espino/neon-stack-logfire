import React from 'react';
import {AbsoluteFill, OffthreadVideo, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import data from '../data.json';
import {C, LEVELS, mono, sans} from '../theme';
import {Atmosphere, Headline, Kicker, Panel, Pill, pop, progress} from '../components/kit';

/** Real events from one Log Stack session, replayed at the pace they happened (sped up). */
const SPEED = 12;
const ROW = 58, VISIBLE = 9;

export const Live: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const events = data.events.filter((e) => e.span !== 'xcode.build.identity' && e.span !== 'app.state');
  const shown = events.filter((e) => frame >= 16 + e.t * SPEED);
  const scroll = Math.max(0, shown.length - VISIBLE);
  const legend = progress(frame, 200, 16);
  return (
    <AbsoluteFill style={{background: C.bg}}>
      <div style={{position: 'absolute', left: 130, top: 90, width: 470, height: 940, borderRadius: 22, overflow: 'hidden',
        border: `1px solid ${C.line}`, boxShadow: `0 0 80px rgba(255,106,26,0.25)`, opacity: progress(frame, 0, 14)}}>
        <OffthreadVideo src={staticFile('footage/log-stack.mp4')} muted startFrom={150} style={{width: 470, height: 940}} />
      </div>
      <div style={{position: 'absolute', left: 680, top: 100, right: 130}}>
        <Kicker index="05" label="LIVE" />
        <div style={{height: 20}} />
        <Headline text="Every game event is a log." size={76} delay={4} highlight={['log']} />
        <Panel style={{marginTop: 40, height: 650, padding: '24px 30px', overflow: 'hidden'}}>
          <div style={{display: 'flex', alignItems: 'center', gap: 14, fontFamily: mono, fontSize: 18, color: C.dim, letterSpacing: 2, marginBottom: 14}}>
            <span style={{width: 12, height: 12, borderRadius: 6, background: C.ok, opacity: 0.5 + 0.5 * Math.abs(Math.sin(frame / 8)),
              boxShadow: `0 0 12px ${C.ok}`}} />
            LIVE · service.name = neon-stack
          </div>
          <div style={{position: 'relative', height: ROW * VISIBLE, overflow: 'hidden'}}>
            <div style={{transform: `translateY(${-scroll * ROW}px)`}}>
              {shown.map((e, i) => {
                const s = pop(frame, fps, 16 + e.t * SPEED, 18);
                const level = LEVELS[e.level] ?? LEVELS[9];
                return (
                  <div key={i} style={{display: 'flex', alignItems: 'center', gap: 20, height: ROW, borderBottom: `1px solid ${C.line}`,
                    opacity: s, transform: `translateX(${(1 - s) * 40}px)`, background: s < 0.9 ? `${level.color}14` : 'transparent'}}>
                    <span style={{fontFamily: mono, fontSize: 18, color: C.faint, width: 150}}>{e.time}</span>
                    <span style={{width: 112}}><Pill color={level.color} size={16}>{level.name}</Pill></span>
                    <span style={{fontFamily: sans, fontWeight: 500, fontSize: 27, color: C.text, flex: 1}}>{e.message}</span>
                    <span style={{fontFamily: mono, fontSize: 16, color: C.faint}}>{e.span}</span>
                  </div>
                );
              })}
            </div>
          </div>
        </Panel>
        <div style={{display: 'flex', alignItems: 'center', gap: 14, marginTop: 26, opacity: legend, transform: `translateY(${(1 - legend) * 14}px)`}}>
          <span style={{fontFamily: sans, fontWeight: 700, fontSize: 26, color: C.text, marginRight: 8}}>Every piece is a log level:</span>
          {Object.values(LEVELS).map((l) => <Pill key={l.name} color={l.color} size={15}>{l.name}</Pill>)}
        </div>
      </div>
      <Atmosphere glow={0.45} />
    </AbsoluteFill>
  );
};
