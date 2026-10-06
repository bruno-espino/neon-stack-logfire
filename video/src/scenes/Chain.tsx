import React from 'react';
import {AbsoluteFill, interpolate, Easing, useCurrentFrame} from 'remotion';
import data from '../data.json';
import {C, mono, sans} from '../theme';
import {Atmosphere, Headline, Kicker, Panel, Pill, progress} from '../components/kit';

const W = 580, GAP = 130, X0 = 130, TOP = 360;

const Stat: React.FC<{value: string; label: string; color?: string}> = ({value, label, color = C.text}) => (
  <div>
    <div style={{fontFamily: sans, fontWeight: 800, fontSize: 54, color, letterSpacing: -2, fontVariantNumeric: 'tabular-nums'}}>{value}</div>
    <div style={{fontFamily: mono, fontSize: 16, color: C.dim, letterSpacing: 1.5}}>{label}</div>
  </div>
);

const Row: React.FC<{label: string; value: number; max: number; text: string; color: string; p: number}> = ({label, value, max, text, color, p}) => (
  <div style={{marginBottom: 12}}>
    <div style={{display: 'flex', justifyContent: 'space-between', fontFamily: mono, fontSize: 16, color: C.text, marginBottom: 6}}>
      <span style={{whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', maxWidth: 380}}>{label}</span>
      <span style={{color: C.dim}}>{text}</span>
    </div>
    <div style={{height: 8, background: C.line, borderRadius: 4}}>
      <div style={{height: 8, width: `${(value / max) * 100 * p}%`, background: color, borderRadius: 4, boxShadow: `0 0 10px ${color}`}} />
    </div>
  </div>
);

export const Chain: React.FC = () => {
  const frame = useCurrentFrame();
  const total = 5 * W + 4 * GAP;
  const pan = interpolate(frame, [70, 320], [0, total - 1920 + 2 * X0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: Easing.inOut(Easing.cubic)});
  const reveal = (i: number) => progress(frame, 30 + i * 52, 22);
  const perf = data.perf;
  const cards: {tag: string; title: string; service: string; color: string; body: (p: number) => React.ReactNode}[] = [
    {tag: 'BUILD', title: 'Xcode build', service: 'logfire-apple-build', color: C.amber, body: () => (
      <>
        <div style={{display: 'flex', gap: 46}}>
          <Stat value={`${data.build.duration}s`} label="DURATION" />
          <Stat value={`${data.build.errors}`} label="ERRORS" color={C.ok} />
          <Stat value={`${data.build.warnings}`} label="WARNINGS" color={C.ok} />
        </div>
        <div style={{fontFamily: mono, fontSize: 17, color: C.dim, marginTop: 26, lineHeight: 1.7}}>
          scheme <span style={{color: C.text}}>{data.build.scheme}</span> · {data.build.configuration}<br />
          git <span style={{color: C.text}}>{data.build.commit}</span> · host {data.build.host}
        </div>
      </>)},
    {tag: 'RUN', title: 'Scripted play-test', service: 'logfire-apple-run', color: C.pink, body: () => (
      <>
        <div style={{fontFamily: mono, fontSize: 18, color: C.text, marginBottom: 22}}>{data.run.scenario}</div>
        <div style={{display: 'flex', gap: 46, alignItems: 'flex-end'}}>
          <Stat value="PASSED" label="PHASE" color={C.ok} />
          <Stat value={`${data.run.duration}s`} label="RUN TIME" />
        </div>
        <div style={{fontFamily: mono, fontSize: 17, color: C.dim, marginTop: 22}}>
          {data.run.exportedSpans} spans exported · {data.run.failedSpans} dropped</div>
      </>)},
    {tag: 'FRAMES', title: 'Frame windows', service: 'neon-stack · FrameRecorder', color: C.ember, body: (p) => (
      <>
        <div style={{display: 'flex', gap: 46}}>
          <Stat value={Math.round(perf[0].fps).toString()} label="FPS" color={C.ok} />
          <Stat value={`${Math.round(Math.min(...perf.map((x) => x.gpu)))}–${Math.round(Math.max(...perf.map((x) => x.gpu)))}ms`} label="GPU P95" color={C.amber} />
        </div>
        <svg width={500} height={120} style={{marginTop: 18}}>
          {perf.map((x, i) => {
            const h = (x.gpu / 32) * 110 * p;
            return <rect key={i} x={i * 55} y={115 - h} width={40} height={h} rx={5} fill={C.ember} opacity={0.85} />;
          })}
        </svg>
        <div style={{fontFamily: mono, fontSize: 15, color: C.faint}}>GPU time per 5-second window</div>
      </>)},
    {tag: 'CPU', title: 'CPU profile', service: 'xctrace · Time Profiler', color: '#7cc4ff', body: (p) => (
      <>
        <div style={{display: 'flex', gap: 46, marginBottom: 18}}>
          <Stat value={data.profile.samples.toLocaleString('en-US')} label="SAMPLES" />
          <Stat value={`${data.profile.mainThreadMs}ms`} label="MAIN THREAD" color="#7cc4ff" />
        </div>
        {data.cpu.slice(0, 4).map((f) => <Row key={f.fn} label={f.fn} value={f.ms} max={data.cpu[0].ms} text={`${f.ms}ms`} color="#7cc4ff" p={p} />)}
      </>)},
    {tag: 'GPU', title: 'Per-shader cost', service: 'GPU capture replay', color: '#e04dff', body: (p) => (
      <>
        <div style={{fontFamily: mono, fontSize: 16, color: C.dim, marginBottom: 18}}>Apple M4 · share of frame GPU time</div>
        {data.gpu.slice(0, 5).map((g) => <Row key={g.label} label={g.label} value={g.cost} max={1} text={`${Math.round(g.cost * 100)}%`} color="#e04dff" p={p} />)}
      </>)},
  ];
  const pulse = (frame * 9) % (total + 200);
  return (
    <AbsoluteFill style={{background: C.bg}}>
      <div style={{position: 'absolute', left: 130, top: 100}}>
        <Kicker index="03" label="CORRELATION" />
        <div style={{height: 20}} />
        <Headline text="One build ID connects everything." size={80} delay={4} highlight={['everything']} />
      </div>
      <div style={{position: 'absolute', left: X0 - pan, top: TOP, width: total, height: 600}}>
        <div style={{position: 'absolute', top: 300, left: 0, height: 3, width: total * progress(frame, 30, 260), background: C.line}} />
        <div style={{position: 'absolute', top: 296, left: pulse - 200, width: 200, height: 11, borderRadius: 6,
          background: `linear-gradient(90deg, transparent, ${C.ember})`, boxShadow: `0 0 20px ${C.ember}`, opacity: progress(frame, 40, 20)}} />
        {cards.map((card, i) => {
          const p = reveal(i);
          return (
            <div key={card.tag} style={{position: 'absolute', left: i * (W + GAP), top: 0, width: W, opacity: p,
              transform: `translateY(${(1 - p) * 60}px) scale(${0.94 + 0.06 * p})`}}>
              <Panel style={{padding: '30px 34px', height: 580}} glow={`${card.color}22`}>
                <div style={{display: 'flex', justifyContent: 'space-between', alignItems: 'center'}}>
                  <Pill color={card.color}>{card.tag}</Pill>
                  <span style={{fontFamily: mono, fontSize: 15, color: C.faint}}>{card.service}</span>
                </div>
                <div style={{fontFamily: sans, fontWeight: 700, fontSize: 40, color: C.text, margin: '22px 0 26px'}}>{card.title}</div>
                {card.body(progress(frame, 44 + i * 52, 30))}
                <div style={{position: 'absolute', bottom: 26, left: 34, fontFamily: mono, fontSize: 15, color: C.faint}}>
                  build.id <span style={{color: card.color}}>{data.build.id.slice(0, 8)}</span>
                </div>
              </Panel>
            </div>
          );
        })}
      </div>
      <Atmosphere glow={0.35} />
    </AbsoluteFill>
  );
};
