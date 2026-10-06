import React from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import data from '../data.json';
import {C, mono} from '../theme';
import {Atmosphere, Headline, Kicker, Panel, progress} from '../components/kit';

const K = '#ff7ab6', T = '#ffb547', S = '#8be28b', F = '#7cc4ff', D = '#7d6d65', P = C.text;
type Tok = [string, string];
/** The real API from docs/swift-sdk.md, trimmed to fit a slide. */
const LINES: Tok[][] = [
  [['import', K], [' LogfireSwift', P]],
  [],
  [['let', K], [' telemetry = ', P], ['try', K], [' Logfire', T], ['.', P], ['development', F], ['(serviceName: ', P], ['"neon-stack"', S], [')', P]],
  [],
  [['telemetry', P], ['.', P], ['withSpan', F], ['(', P], ['"game.load"', S], [') {', P]],
  [['    loadLevel', F], ['(', P], ['1', T], [')', P]],
  [['}', P]],
  [],
  [['// every frame, after the GPU finishes', D]],
  [['frames', P], ['.', P], ['record', F], ['(commandBuffer: cb, context: render)', P]],
];
const lineText = (l: Tok[]) => l.map((t) => t[0]).join('');
const starts: number[] = [];
LINES.forEach((_, i) => starts.push(i ? starts[i - 1] + lineText(LINES[i - 1]).length + 4 : 0));

const SPANS = [
  {name: 'game.load', at: 112, len: 140, color: C.amber},
  ...Array.from({length: 6}).map((_, i) => ({name: 'game.performance.window', at: 168 + i * 11, len: 26, color: C.ember})),
];

export const Code: React.FC = () => {
  const frame = useCurrentFrame();
  const typed = Math.max(0, (frame - 24) * 1.9);
  const term = progress(frame, 160, 14);
  return (
    <AbsoluteFill style={{background: C.bg, padding: '110px 130px'}}>
      <Kicker index="02" label="THE SDK" />
      <div style={{height: 22}} />
      <Headline text="A few lines of Swift." size={84} delay={4} highlight={['Swift']} />
      <div style={{display: 'flex', gap: 40, marginTop: 50}}>
        <Panel style={{flex: '0 0 1000px', padding: '36px 44px', opacity: progress(frame, 8, 14)}}>
          <div style={{display: 'flex', gap: 10, marginBottom: 26}}>
            {[C.bad, C.amber, C.ok].map((c) => <span key={c} style={{width: 14, height: 14, borderRadius: 7, background: c, opacity: 0.8}} />)}
            <span style={{fontFamily: mono, fontSize: 18, color: C.faint, marginLeft: 16}}>NeonStackApp.swift</span>
          </div>
          {LINES.map((line, i) => {
            let left = Math.max(0, typed - starts[i]);
            const cursor = typed >= starts[i] && typed < starts[i] + lineText(line).length + 4;
            return (
              <div key={i} style={{fontFamily: mono, fontSize: 25, lineHeight: '42px', height: 42, whiteSpace: 'pre'}}>
                {line.map(([text, color], j) => {
                  const shown = text.slice(0, Math.max(0, Math.floor(left)));
                  left -= text.length;
                  return <span key={j} style={{color}}>{shown}</span>;
                })}
                {cursor && frame % 16 < 10 && <span style={{background: C.ember, display: 'inline-block', width: 13, height: 28, verticalAlign: 'middle'}} />}
              </div>
            );
          })}
        </Panel>
        <div style={{flex: 1, display: 'flex', flexDirection: 'column', gap: 24}}>
          <Panel style={{padding: '26px 30px', flex: 1, opacity: progress(frame, 100, 12)}}>
            <div style={{fontFamily: mono, fontSize: 18, color: C.dim, letterSpacing: 3, marginBottom: 22}}>
              <span style={{color: C.ember}}>●</span> LIVE IN LOGFIRE</div>
            {SPANS.map((s, i) => {
              const p = progress(frame, s.at, 16);
              if (frame < s.at) return null;
              return (
                <div key={i} style={{display: 'flex', alignItems: 'center', gap: 14, height: 34, opacity: p}}>
                  <span style={{fontFamily: mono, fontSize: 16, color: C.text, width: 250, whiteSpace: 'nowrap', overflow: 'hidden'}}>{s.name}</span>
                  <div style={{height: 12, borderRadius: 4, background: s.color, width: s.len * p, boxShadow: `0 0 14px ${s.color}`,
                    marginLeft: i === 0 ? 0 : (i - 1) * 9}} />
                </div>
              );
            })}
          </Panel>
          <Panel style={{padding: '22px 30px', opacity: term, transform: `translateY(${(1 - term) * 20}px)`}}>
            <div style={{fontFamily: mono, fontSize: 19, color: C.text}}><span style={{color: C.ember}}>$</span> logfire-apple build</div>
            <div style={{fontFamily: mono, fontSize: 17, color: C.ok, marginTop: 10, opacity: progress(frame, 185, 10)}}>
              ✓ build {data.build.id.slice(0, 8)} · {data.build.duration}s · {data.build.errors} errors → Logfire</div>
          </Panel>
        </div>
      </div>
      <Atmosphere glow={0.4} />
    </AbsoluteFill>
  );
};
