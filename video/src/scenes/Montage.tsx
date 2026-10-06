import React from 'react';
import {AbsoluteFill, OffthreadVideo, staticFile, useCurrentFrame} from 'remotion';
import data from '../data.json';
import {C, mono, sans} from '../theme';
import {Atmosphere, count, progress} from '../components/kit';

const CLIPS: {src: string; name: string; note: string; start: number; shift?: number; portrait?: boolean}[] = [
  {src: 'footage/flappy-log.mp4', name: 'FLAPPY LOG', note: 'up to 4M GPU particles', start: 90, shift: 18},
  {src: 'footage/log-roll.mp4', name: 'LOG ROLL', note: '3D maze · per-shader GPU cost', start: 300},
  {src: 'footage/log-stack-burn.mp4', name: 'LOG STACK', note: 'every piece is a log', start: 0, portrait: true},
];

const STATS = [
  {value: data.totals.n, label: 'records'},
  {value: data.totals.builds, label: 'builds'},
  {value: data.totals.sessions, label: 'game sessions'},
  {value: data.totals.services, label: 'services'},
];

export const Montage: React.FC = () => {
  const frame = useCurrentFrame();
  const stats = progress(frame, 60, 16);
  return (
    <AbsoluteFill style={{background: C.bg}}>
      <div style={{position: 'absolute', inset: 0, display: 'flex', gap: 10}}>
        {CLIPS.map((clip, i) => {
          const p = progress(frame, i * 8, 22);
          return (
            <div key={clip.name} style={{flex: 1, position: 'relative', overflow: 'hidden', clipPath: `inset(${(1 - p) * 100}% 0 0 0)`}}>
              <OffthreadVideo src={staticFile(clip.src)} muted startFrom={clip.start}
                style={{position: 'absolute', height: '100%', left: '50%', transform: `translateX(${-50 + (clip.shift ?? 0)}%) scale(${1.15 - 0.1 * p})`,
                  filter: 'brightness(0.72)', ...(clip.portrait ? {width: '100%', height: 'auto', top: '-20%'} : {})}} />
              <div style={{position: 'absolute', left: 40, top: 60, opacity: progress(frame, 14 + i * 8, 14)}}>
                <div style={{fontFamily: sans, fontWeight: 800, fontSize: 46, color: C.text, letterSpacing: 2}}>{clip.name}</div>
                <div style={{fontFamily: mono, fontSize: 18, color: C.amber, marginTop: 6}}>{clip.note}</div>
              </div>
            </div>
          );
        })}
      </div>
      <AbsoluteFill style={{background: 'linear-gradient(0deg, rgba(10,7,6,0.97) 0%, rgba(10,7,6,0.6) 32%, transparent 55%)'}} />
      <div style={{position: 'absolute', left: 130, right: 130, bottom: 90, display: 'flex', justifyContent: 'space-between', alignItems: 'flex-end',
        opacity: stats, transform: `translateY(${(1 - stats) * 30}px)`}}>
        {STATS.map((s, i) => (
          <div key={s.label}>
            <div style={{fontFamily: sans, fontWeight: 800, fontSize: 110, color: C.text, letterSpacing: -4, fontVariantNumeric: 'tabular-nums', lineHeight: 1}}>
              {Math.round(count(frame, 60 + i * 6, 50, 0, s.value)).toLocaleString('en-US')}</div>
            <div style={{fontFamily: mono, fontSize: 20, color: C.dim, letterSpacing: 3, marginTop: 8}}>{s.label.toUpperCase()}</div>
          </div>
        ))}
        <div style={{fontFamily: mono, fontSize: 18, color: C.faint, textAlign: 'right'}}>three games, one project<br />last 3 days · bruno/mac-observer</div>
      </div>
      <Atmosphere glow={0.3} />
    </AbsoluteFill>
  );
};
