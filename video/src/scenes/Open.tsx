import React from 'react';
import {AbsoluteFill, interpolate, useCurrentFrame} from 'remotion';
import data from '../data.json';
import {C, mono, sans, fire} from '../theme';
import {progress, Atmosphere} from '../components/kit';

const SERVICE: Record<string, string> = {
  'logfire-apple-build': C.amber, 'logfire-apple-run': C.pink, 'neon-stack': C.ember,
};

/** Cold open: a real trace from one build draws itself, then collapses into a line of fire. */
export const Open: React.FC = () => {
  const frame = useCurrentFrame();
  const spans = data.spans;
  const total = Math.max(...spans.map((s) => s.start + s.duration));
  const collapse = progress(frame, 100, 24);
  const flash = interpolate(frame, [118, 126, 150], [0, 1, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  const rowH = 40, top = 210, left = 560, width = 1220;
  const zoom = 1 + frame * 0.0009;
  return (
    <AbsoluteFill style={{background: C.bg}}>
      <AbsoluteFill style={{transform: `scale(${zoom})`}}>
        <div style={{position: 'absolute', left: 120, top: 120, fontFamily: mono, fontSize: 22, color: C.dim, letterSpacing: 2,
          opacity: progress(frame, 2, 12) * (1 - collapse)}}>
          <span style={{color: C.ember}}>●</span>&nbsp; trace · build.id = {data.build.id.slice(0, 8 + Math.min(28, Math.floor(frame / 2)))}
        </div>
        {[0, 0.25, 0.5, 0.75, 1].map((f) => (
          <div key={f} style={{position: 'absolute', left: left + f * width, top: 170, bottom: 120, width: 1, background: C.line,
            opacity: (1 - collapse) * progress(frame, 0, 20)}}>
            <div style={{fontFamily: mono, fontSize: 16, color: C.faint, marginLeft: 8}}>{(f * total).toFixed(0)}s</div>
          </div>
        ))}
        {spans.map((s, i) => {
          const appear = progress(frame, 4 + i * 4, 14);
          const y = top + i * rowH;
          const targetY = 540;
          const yy = y + (targetY - y) * collapse;
          const x = left + (s.start / total) * width;
          const w = Math.max(10, (s.duration / total) * width) * appear;
          const color = SERVICE[s.service] ?? C.ember;
          return (
            <React.Fragment key={i}>
              <div style={{position: 'absolute', left: 120, top: yy - 4, fontFamily: mono, fontSize: 19, color: C.text,
                opacity: appear * (1 - collapse), transform: `translateX(${(1 - appear) * -20}px)`, whiteSpace: 'nowrap'}}>
                <span style={{color}}>▍</span>{s.name}
              </div>
              <div style={{position: 'absolute', left: x * (1 - collapse) + 0 * collapse, top: yy + 2, height: 16 * (1 - collapse) + 4 * collapse,
                width: w + (1920 - w) * collapse, borderRadius: 4, background: color,
                boxShadow: `0 0 ${10 + 30 * collapse}px ${color}`, opacity: appear}} />
            </React.Fragment>
          );
        })}
      </AbsoluteFill>
      <AbsoluteFill style={{background: fire, opacity: flash * 0.9, mixBlendMode: 'screen'}} />
      <AbsoluteFill style={{justifyContent: 'center', alignItems: 'center', opacity: interpolate(frame, [124, 134], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'})}}>
        <div style={{fontFamily: sans, fontWeight: 800, fontSize: 40, letterSpacing: 18, color: '#fff'}}>THIS IS ONE BUILD.</div>
      </AbsoluteFill>
      <Atmosphere glow={0.6} />
    </AbsoluteFill>
  );
};
