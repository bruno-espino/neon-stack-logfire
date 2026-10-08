import React from 'react';
import {AbsoluteFill, Img, interpolate, spring, useCurrentFrame, useVideoConfig, Easing} from 'remotion';
import {C, mono, fire} from '../theme';
import {progress} from './kit';

/** Springs a block in from below with a short blur, after `delay` frames. */
export const Rise: React.FC<{delay?: number; distance?: number; children: React.ReactNode; style?: React.CSSProperties}> = ({
  delay = 0, distance = 40, children, style,
}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const s = spring({frame: frame - delay, fps, config: {damping: 15, mass: 0.7, stiffness: 120}});
  return (
    <div style={{opacity: Math.min(1, s * 1.4), transform: `translateY(${(1 - s) * distance}px) scale(${0.97 + 0.03 * s})`,
      filter: `blur(${Math.max(0, 1 - s) * 8}px)`, ...style}}>{children}</div>
  );
};

/** Scene wrapper: a small push-in on entry and a drift with blur on exit, so cuts feel like camera moves. */
export const SceneMotion: React.FC<{duration: number; children: React.ReactNode}> = ({duration, children}) => {
  const frame = useCurrentFrame();
  const enter = progress(frame, 0, 18);
  const exit = interpolate(frame, [duration - 14, duration], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: Easing.in(Easing.cubic)});
  return (
    <AbsoluteFill style={{transform: `scale(${1.035 - 0.035 * enter - 0.02 * exit})`, filter: `blur(${exit * 6}px)`}}>
      {children}
    </AbsoluteFill>
  );
};

/** A fire-coloured rule that draws itself left to right. */
export const FireLine: React.FC<{delay?: number; width?: number; style?: React.CSSProperties}> = ({delay = 0, width = 420, style}) => {
  const frame = useCurrentFrame();
  const p = progress(frame, delay, 28);
  return <div style={{height: 4, width: width * p, borderRadius: 2, background: fire, boxShadow: `0 0 18px ${C.ember}`, ...style}} />;
};

/** Slow pan and zoom over a still, so posters never sit frozen on screen. */
export const KenBurns: React.FC<{src: string; from?: number; to?: number; x?: number; y?: number; style?: React.CSSProperties}> = ({
  src, from = 1.04, to = 1.14, x = 0, y = 0, style,
}) => {
  const frame = useCurrentFrame();
  const {durationInFrames} = useVideoConfig();
  const t = frame / durationInFrames;
  return <Img src={src} style={{width: '100%', height: '100%', objectFit: 'cover',
    transform: `scale(${from + (to - from) * t}) translate(${x * t}%, ${y * t}%)`, ...style}} />;
};

const SWIFT_KEYWORDS = new Set(['import', 'let', 'var', 'try', 'func', 'return', 'await']);
const SYNTAX = {keyword: '#ff7ab6', type: '#ffb547', string: '#8be28b', call: '#7cc4ff', comment: '#7d6d65', plain: C.text, flag: '#ffb547'};

/** Splits one line of Swift (or a shell command) into coloured tokens. */
export const highlight = (line: string): [string, string][] => {
  const tokens: [string, string][] = [];
  const pattern = /(\/\/.*$)|("[^"]*")|((?<=^|\s)--?[a-z][a-z-]*)|([A-Za-z_][A-Za-z0-9_]*)|(\s+)|(.)/g;
  for (const m of line.matchAll(pattern)) {
    const [text, comment, string, flag, word] = m;
    if (comment) tokens.push([text, SYNTAX.comment]);
    else if (string) tokens.push([text, SYNTAX.string]);
    else if (flag) tokens.push([text, SYNTAX.flag]);
    else if (word) {
      const next = line[(m.index ?? 0) + text.length];
      tokens.push([text, SWIFT_KEYWORDS.has(word) ? SYNTAX.keyword : /^[A-Z]/.test(word) ? SYNTAX.type : next === '(' ? SYNTAX.call : SYNTAX.plain]);
    } else tokens.push([text, SYNTAX.plain]);
  }
  return tokens;
};

/** Code that types itself in with syntax colours and a blinking cursor. */
export const TypedCode: React.FC<{code: string; delay?: number; speed?: number; fontSize?: number; lineHeight?: number; prompt?: string}> = ({
  code, delay = 0, speed = 1.8, fontSize = 27, lineHeight = 1.65, prompt,
}) => {
  const frame = useCurrentFrame();
  const lines = code.split('\n');
  const typed = Math.max(0, (frame - delay) * speed);
  let start = 0;
  const done = typed >= code.length + lines.length * 3;
  return (
    <div style={{fontFamily: mono, fontSize, lineHeight, whiteSpace: 'pre'}}>
      {lines.map((line, i) => {
        const lineStart = start;
        start += line.length + 3;
        let left = Math.max(0, typed - lineStart);
        const active = typed >= lineStart && typed < lineStart + line.length + 3;
        return (
          <div key={i} style={{minHeight: fontSize * lineHeight}}>
            {prompt && <span style={{color: C.ember}}>{prompt}</span>}
            {highlight(line).map(([text, color], j) => {
              const shown = text.slice(0, Math.max(0, Math.floor(left)));
              left -= text.length;
              return <span key={j} style={{color}}>{shown}</span>;
            })}
            {(active || (done && i === lines.length - 1)) && frame % 16 < 10 &&
              <span style={{display: 'inline-block', width: fontSize * 0.5, height: fontSize * 1.05, background: C.ember, verticalAlign: 'middle', marginLeft: 2}} />}
          </div>
        );
      })}
    </div>
  );
};
