import React from 'react';
import {AbsoluteFill, Img, OffthreadVideo, staticFile, useCurrentFrame} from 'remotion';
import {C, mono, sans} from '../theme';
import {Atmosphere, Headline, Kicker, Panel, Pill, progress} from '../components/kit';
import type {ReelProps} from './Presentation';

type Input = 'rotate' | 'hold' | 'drop';
type ReplayRow =
  | {kind: 'span'; startFrame: number; action: Input}
  | {kind: 'log'; startFrame: number; name: 'game.line_clear' | 'game.log_burned'; message: string};

const inputs: Record<Input, {key: string; label: string; color: string}> = {
  rotate: {key: '↑', label: 'Rotate', color: '#7cc4ff'},
  hold: {key: 'C', label: 'Swap piece', color: '#e04dff'},
  drop: {key: 'SPACE', label: 'Hard drop', color: C.ember},
};
const replay: ReplayRow[] = [
  {kind: 'span', startFrame: 25, action: 'rotate'},
  {kind: 'span', startFrame: 52, action: 'hold'},
  {kind: 'span', startFrame: 84, action: 'rotate'},
  {kind: 'span', startFrame: 115, action: 'drop'},
  {kind: 'log', startFrame: 121, name: 'game.line_clear', message: 'cleared 4 lines'},
  {kind: 'span', startFrame: 154, action: 'rotate'},
  {kind: 'span', startFrame: 188, action: 'drop'},
  {kind: 'log', startFrame: 194, name: 'game.log_burned', message: 'log burned 3 rows'},
  {kind: 'span', startFrame: 226, action: 'hold'},
  {kind: 'span', startFrame: 263, action: 'drop'},
];
const rowHeight = 61;

export const InputTrace: React.FC<ReelProps & {duration: number}> = ({footage}) => {
  const frame = useCurrentFrame();
  const shown = replay.filter(row => row.startFrame <= frame);
  const activeInput = shown.reduce<Input | null>((latest, row) => row.kind === 'span' ? row.action : latest, null);
  const scroll = Math.max(0, shown.length - 8) * rowHeight;
  return <AbsoluteFill style={{background: C.bg, padding: '80px 115px'}}>
    <Kicker index="03" label="GAMEPLAY → LOGFIRE" />
    <Headline text="Your inputs. Their traces. One view." size={77} delay={4} highlight={['inputs.', 'traces.']} style={{marginTop: 25}} />
    <div style={{display: 'flex', gap: 48, marginTop: 35, alignItems: 'center'}}>
      <Panel style={{width: 365, height: 730, overflow: 'hidden', flexShrink: 0}} glow={`${C.ember}33`}>
        {footage
          ? <OffthreadVideo src={staticFile('footage/log-stack.mp4')} muted startFrom={90} style={{width: '100%', height: '100%', objectFit: 'cover'}} />
          : <Img src={staticFile('log-stack.jpg')} style={{width: '100%', height: '100%', objectFit: 'cover'}} />}
      </Panel>
      <div style={{flex: 1, minWidth: 0}}>
        <div style={{display: 'flex', gap: 20, marginBottom: 25}}>
          {Object.entries(inputs).map(([action, input]) => {
            const active = action === activeInput;
            return <Panel key={action} style={{padding: '15px 22px', flex: 1, borderColor: active ? input.color : C.line}} glow={active ? `${input.color}33` : undefined}>
              <div style={{fontFamily: mono, fontSize: 30, color: active ? input.color : C.dim}}>{input.key}</div>
              <div style={{fontFamily: sans, fontSize: 20, color: C.dim, marginTop: 7}}>{input.label}</div>
            </Panel>;
          })}
        </div>
        <Panel style={{height: 550, padding: '24px 28px', overflow: 'hidden'}}>
          <div style={{fontFamily: mono, fontSize: 19, color: C.dim, display: 'flex', gap: 15, alignItems: 'center', marginBottom: 23}}>
            <span style={{width: 10, height: 10, borderRadius: 5, background: C.ok, boxShadow: `0 0 12px ${C.ok}`}} />
            neon-stack · session + build context
          </div>
          <div style={{height: rowHeight * 8, overflow: 'hidden'}}>
            <div style={{transform: `translateY(${-scroll}px)`}}>
              {shown.map(row => {
                const p = progress(frame, row.startFrame, 12);
                const color = row.kind === 'span' ? inputs[row.action].color : C.ok;
                const name = row.kind === 'span' ? `game.${row.action}` : row.name;
                return <div key={row.startFrame} style={{height: rowHeight, display: 'flex', alignItems: 'center', gap: 17, borderBottom: `1px solid ${C.line}`, paddingLeft: row.kind === 'log' ? 37 : 0, opacity: p, transform: `translateX(${(1 - p) * 25}px)`}}>
                  <Pill color={color} size={15}>{row.kind === 'span' ? 'SPAN' : 'LOG'}</Pill>
                  <span style={{fontFamily: mono, fontSize: 24, color: C.text, flex: 1}}>{row.kind === 'log' ? '↳ ' : ''}{name}</span>
                  {row.kind === 'span'
                    ? <div style={{width: 100, height: 8, borderRadius: 4, background: C.line}}><div style={{width: `${p * 100}%`, height: '100%', background: color, borderRadius: 4}} /></div>
                    : <span style={{fontFamily: sans, fontSize: 22, color: C.dim}}>{row.message}</span>}
                </div>;
              })}
            </div>
          </div>
        </Panel>
        <div style={{fontFamily: mono, fontSize: 18, color: C.dim, marginTop: 20}}>Illustrated input replay · shipped span names · feedback logs</div>
      </div>
    </div>
    <Atmosphere glow={0.4} />
  </AbsoluteFill>;
};
