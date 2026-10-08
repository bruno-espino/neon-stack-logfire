import React from 'react';
import {AbsoluteFill, Img, Loop, OffthreadVideo, interpolate, interpolateColors, staticFile, useCurrentFrame, useVideoConfig, spring} from 'remotion';
import data from '../data.json';
import {C, fire, mono, sans} from '../theme';
import {Atmosphere, Embers, Headline, Kicker, Panel, Pill, count, progress} from '../components/kit';
import {FireLine, KenBurns, Rise, TypedCode} from '../components/motion';

export type ReelProps = {footage: boolean};

type SceneProps = ReelProps & {duration: number};
const Frame: React.FC<{index: string; label: string; title: string; highlight?: string[]; children: React.ReactNode}> = ({index, label, title, highlight, children}) => (
  <AbsoluteFill style={{background: C.bg, padding: '90px 120px'}}>
    <Embers count={28} intensity={0.45} seed={label} />
    <Kicker index={index} label={label} />
    <Headline text={title} size={78} delay={5} highlight={highlight} style={{marginTop: 24, maxWidth: 1650}} />
    {children}
    <Atmosphere glow={0.3} />
  </AbsoluteFill>
);
const Note: React.FC<{children: React.ReactNode; delay?: number}> = ({children, delay}) => {
  const body = <div style={{fontFamily: mono, fontSize: 23, lineHeight: 1.55, color: C.dim, marginTop: 28}}>{children}</div>;
  return delay === undefined ? body : <Rise delay={delay} distance={18}>{body}</Rise>;
};
const Game: React.FC<ReelProps> = ({footage}) => {
  const {fps} = useVideoConfig();
  return footage
    ? <Loop durationInFrames={8 * fps}><OffthreadVideo src={staticFile('footage/log-roll.mp4')} muted style={{width: '100%', height: '100%', objectFit: 'cover'}} /></Loop>
    : <KenBurns src={staticFile('log-roll.jpg')} />;
};

export const Intro: React.FC<SceneProps> = ({footage}) => {
  const frame = useCurrentFrame();
  return <AbsoluteFill style={{background: C.bg}}>
    <AbsoluteFill style={{opacity: 0.5, transform: `scale(${1.08 + frame / 2500}) translateX(${-frame / 30}px)`}}><Game footage={footage} /></AbsoluteFill>
    <AbsoluteFill style={{background: 'linear-gradient(90deg, #0a0706f5 10%, #0a070670)'}} />
    <Embers count={60} intensity={0.9} seed="intro" />
    <AbsoluteFill style={{justifyContent: 'center', padding: 130}}>
      <Rise delay={2}><Pill color={C.ember}>COMMUNITY PROTOTYPE · EXPERIMENTAL</Pill></Rise>
      <Headline text="Apple Metal development, connected to Logfire." size={112} delay={8} highlight={['Metal', 'Logfire']} style={{maxWidth: 1500, marginTop: 40}} />
      <FireLine delay={30} width={520} style={{marginTop: 36}} />
      <Note delay={40}>Swift SDK + native companion + correlated evidence</Note>
    </AbsoluteFill>
    <Atmosphere />
  </AbsoluteFill>;
};

export const Setup: React.FC<SceneProps> = () => {
  const frame = useCurrentFrame();
  return <Frame index="01" label="SETUP" title="Start with one Swift package." highlight={['Swift']}>
    <div style={{display: 'flex', gap: 48, marginTop: 55}}>
      <Rise delay={8} style={{width: 970}}>
        <Panel style={{padding: 38, height: 470, position: 'relative'}} glow={`${C.ember}18`}>
          <div style={{display: 'flex', gap: 10, alignItems: 'center', marginBottom: 24}}>
            {[C.bad, C.amber, C.ok].map((c) => <span key={c} style={{width: 13, height: 13, borderRadius: 7, background: c, opacity: 0.8}} />)}
            <span style={{fontFamily: mono, color: C.amber, fontSize: 21, marginLeft: 14}}>LogfireSwift · app target</span>
          </div>
          <TypedCode delay={20} code={`import LogfireSwift\n\nlet telemetry = try Logfire.development(\n    serviceName: "my-game")\n\ntelemetry.withSpan("game.load") {\n    loadLevel()\n}`} />
        </Panel>
      </Rise>
      <div style={{flex: 1}}>
        <Rise delay={70}>
          <Panel style={{padding: 30}}>
            <div style={{fontFamily: sans, fontSize: 38, color: C.text}}>Configure once</div>
            <div style={{marginTop: 28}}><TypedCode delay={88} speed={1.6} fontSize={23} lineHeight={1.55} code="logfire-apple configure --region us" /></div>
            <Note delay={120}>Enable <span style={{color: C.amber}}>LOGFIRE_DEV_DIRECT=1</span><br />Retain one client for the app.</Note>
          </Panel>
        </Rise>
        <Note delay={150}>Direct OTLP export for trusted development builds.<br />Add frame and responsiveness recording explicitly.</Note>
      </div>
    </div>
    <div style={{position: 'absolute', left: 120, bottom: 70, opacity: progress(frame, 0, 10)}}><FireLine delay={170} width={1680} /></div>
  </Frame>;
};

export const Correlation: React.FC<SceneProps> = () => {
  const frame = useCurrentFrame();
  const groups = [
    {title: 'Build trace', color: C.amber, root: 'xcode.build', rows: ['xcode.host.sample · log', 'xcode.build.task_summary · log'], link: 'build.id + source fingerprint'},
    {title: 'Run trace', color: C.ember, root: 'development.run', rows: ['game.performance.window · log', 'app.responsiveness.window · log', 'game.host.sample · log', 'development.run.summary · log'], link: 'session_id + build.id'},
    {title: 'Offline analysis trace', color: '#7cc4ff', root: 'development.timeline.import', rows: ['development.thread.timeline · log', 'development.thread.window · log', 'development.metal.drawable_wait · log'], link: 'source.run_trace_id + capture.id'},
  ];
  const pulse = ((frame - 60) * 14) % 2200;
  const active = Math.floor(Math.max(0, frame - 110) / 50) % 3;
  return <Frame index="02" label="TRACE STRUCTURE" title="From Xcode build to game investigation." highlight={['Xcode', 'investigation']}>
    <div style={{position: 'relative', marginTop: 60}}>
      <div style={{position: 'absolute', left: 0, right: 0, top: 140, height: 3, background: C.line, transform: `scaleX(${progress(frame, 20, 60)})`, transformOrigin: 'left'}} />
      {frame > 60 && <div style={{position: 'absolute', top: 136, left: pulse - 180, width: 180, height: 11, borderRadius: 6,
        background: `linear-gradient(90deg, transparent, ${C.ember})`, boxShadow: `0 0 22px ${C.ember}`}} />}
      <div style={{display: 'flex', gap: 30, position: 'relative'}}>
        {groups.map((g, i) => {
          const lit = frame > 110 && i === active;
          return <Rise key={g.root} delay={15 + i * 18} distance={60} style={{flex: 1}}>
            <Panel style={{height: 485, padding: 30, position: 'relative', borderColor: lit ? g.color : C.line, transition: 'none'}} glow={lit ? `${g.color}40` : undefined}>
              <Pill color={g.color}>{g.title}</Pill>
              <div style={{fontFamily: mono, fontSize: 25, color: C.text, marginTop: 32, display: 'flex', alignItems: 'center', gap: 12}}>
                <span style={{width: 12, height: 12, borderRadius: 6, background: g.color, boxShadow: `0 0 ${lit ? 18 : 8}px ${g.color}`}} />{g.root}</div>
              <div style={{borderLeft: `3px solid ${g.color}`, paddingLeft: 18, marginTop: 28, clipPath: `inset(0 0 ${(1 - progress(frame, 28 + i * 18, 40)) * 100}% 0)`}}>
                {g.rows.map((row, index) => <div key={row} style={{fontFamily: mono, fontSize: 19, color: C.dim, lineHeight: 2, opacity: progress(frame, 28 + i * 20 + index * 7, 15),
                  transform: `translateX(${(1 - progress(frame, 28 + i * 20 + index * 7, 15)) * 16}px)`}}>{row}
                  <div style={{height: 4, width: `${progress(frame, 30 + i * 20 + index * 7, 35) * 70}%`, background: g.color, marginBottom: 6, opacity: 0.6, borderRadius: 2}} /></div>)}
              </div>
              <Note delay={70 + i * 14}><span style={{color: g.color}}>⟷ </span>{g.link}</Note>
            </Panel>
          </Rise>;
        })}
      </div>
    </div>
    <Note delay={150}>Diagram of the verified structure. Frame summaries are logs; raw histograms go to Metrics.</Note>
  </Frame>;
};

export const Performance: React.FC<SceneProps> = ({footage}) => {
  const frame = useCurrentFrame();
  const {fps: rate} = useVideoConfig();
  const rise = progress(frame, 65, 140);
  const fps = Math.round(data.fpsCase.beforeFps + (data.fpsCase.afterFps - data.fpsCase.beforeFps) * rise);
  const color = interpolateColors(fps, [45, 80, 117], [C.bad, C.amber, C.ok]);
  const landed = spring({frame: frame - 205, fps: rate, config: {damping: 9, stiffness: 160}});
  const cpu = count(frame, 120, 70, data.cpuCase.beforeMedian, data.cpuCase.afterMedian);
  return <AbsoluteFill style={{background: C.bg}}>
    <AbsoluteFill style={{opacity: 0.65, transform: `scale(${1.1 + frame / 3000})`}}><Game footage={footage} /></AbsoluteFill>
    <AbsoluteFill style={{background: 'linear-gradient(90deg, #0a0706f5 5%, #0a070680 80%)'}} />
    <Embers count={40} intensity={0.7} seed="perf" />
    <div style={{position: 'absolute', left: 120, top: 100}}>
      <Kicker index="04" label="PERFORMANCE WORKFLOW" />
      <Headline text="Find the bottleneck. Chase smoother frames." size={96} delay={5} highlight={['bottleneck', 'smoother']} style={{maxWidth: 1050, marginTop: 35}} />
      <Note delay={30}>Frame timing → native CPU callers → shader replay → verify</Note>
    </div>
    <Rise delay={40} distance={60} style={{position: 'absolute', right: 120, bottom: 130, width: 680}}>
      <Panel style={{padding: '35px 48px', position: 'relative'}} glow={`${color}33`}>
        <Pill color={C.ok}>REPORTED LOG ROLL FIX</Pill>
        <div style={{fontFamily: sans, fontWeight: 800, fontSize: 200, lineHeight: 1.1, color, marginTop: 25, fontVariantNumeric: 'tabular-nums',
          transform: `scale(${1 + 0.06 * Math.sin(Math.min(1, landed) * Math.PI) * (frame > 205 ? 1 : 0)})`, transformOrigin: 'left center',
          textShadow: `0 0 ${30 + 30 * rise}px ${color}55`}}>{fps}<span style={{fontSize: 50, color: C.dim}}> FPS</span></div>
        <div style={{height: 16, borderRadius: 8, background: C.line, marginTop: 20}}>
          <div style={{height: '100%', width: `${fps / 120 * 100}%`, background: `linear-gradient(90deg, ${C.bad}, ${C.amber} 45%, ${C.ok})`, borderRadius: 8, boxShadow: `0 0 16px ${color}`}} /></div>
        <Note>Log Roll after ~15 games<br />CPU ~{data.fpsCase.beforeCpuPct}% → ~{data.fpsCase.afterCpuPct}%</Note>
      </Panel>
    </Rise>
    <Rise delay={100} style={{position: 'absolute', left: 120, bottom: 130, width: 700}}>
      <Pill color={C.ember}>MEASURED CPU CASE</Pill>
      <div style={{height: 10, width: 520, borderRadius: 5, background: C.line, marginTop: 26}}>
        <div style={{height: '100%', width: `${cpu / 35 * 100}%`, borderRadius: 5, background: interpolateColors(cpu, [8, 29], [C.ok, C.amber]), boxShadow: `0 0 12px ${C.ember}`}} />
      </div>
      <Note>{data.cpuCase.beforeMedian.toFixed(1)}% → {data.cpuCase.afterMedian.toFixed(1)}% main-thread CPU<br />Five runs per policy. Callback ≈ 60 Hz.</Note>
    </Rise>
    <Atmosphere glow={0.6} />
  </AbsoluteFill>;
};

export const CPUCase: React.FC<SceneProps> = () => {
  const frame = useCurrentFrame();
  const groups = [
    {name: 'Publish every frame', values: data.cpuCase.before, median: data.cpuCase.beforeMedian, color: C.amber},
    {name: 'Bound HUD publication', values: data.cpuCase.after, median: data.cpuCase.afterMedian, color: C.ok},
  ];
  return <Frame index="03" label="VERIFIED CPU CASE" title="Less SwiftUI work. Same callback rate." highlight={['SwiftUI']}>
    <div style={{display: 'flex', gap: 40, marginTop: 40}}>
      {groups.map((g, j) => <Rise key={g.name} delay={10 + j * 14} style={{flex: 1}}><Panel style={{padding: 34}}>
        <div style={{fontFamily: sans, fontSize: 35, color: C.text}}>{g.name}</div>
        <div style={{fontFamily: sans, fontWeight: 800, fontSize: 115, color: g.color, marginTop: 14, fontVariantNumeric: 'tabular-nums'}}>
          {count(frame, 20 + j * 10, 50, 0, g.median).toFixed(1)}<span style={{fontSize: 45}}>%</span></div>
        <div style={{fontFamily: mono, fontSize: 20, color: C.dim}}>median main-thread CPU · one core</div>
        <svg width="690" height="160" style={{marginTop: 30}}>
          {g.values.map((v, i) => {
            const p = progress(frame, 20 + j * 10 + i * 8, 25);
            const height = v / 35 * 135 * p;
            return <g key={i}><rect x={i * 133 + 4} y={150 - height} width={100} height={height} rx={5} fill={g.color} /><text x={i * 133 + 54} y={140 - height} textAnchor="middle" fill={C.text} fontSize={21} fontFamily={mono} opacity={p}>{v.toFixed(1)}%</text></g>;
          })}
        </svg>
        <Note>Five measured runs · callback ≈ 60 Hz</Note>
      </Panel></Rise>)}
    </div>
    <Note delay={90}>Same Release binary, seed and 65,536 particles. Warmups and profiling excluded.<br />A separate Time Profiler capture found SwiftUI callers. This establishes CPU savings; it does not establish an FPS or GPU gain.</Note>
  </Frame>;
};

export const NativeTools: React.FC<SceneProps> = () => {
  const frame = useCurrentFrame();
  const cards = [
    {title: 'CPU callers', source: 'Instruments · Time Profiler', color: '#7cc4ff', rows: ['SwiftUI call paths', 'Inclusive sampled weight', 'Main-thread running work'], command: 'run --profile cpu'},
    {title: 'Shader replay', source: 'Metal · GPU capture', color: '#e04dff', rows: ['Render + compute encoders', 'Selected shader costs', 'Register + spill evidence'], command: 'run --profile gpu'},
    {title: 'Native waits', source: 'Metal System Trace', color: C.amber, rows: ['Running / blocked / runnable', 'Next-drawable intervals', 'Coverage within SDK windows'], command: 'diagnose --trace CAPTURE'},
  ];
  return <Frame index="05" label="APPLE NATIVE TOOLS" title="Go from a slow frame to deeper evidence." highlight={['deeper', 'evidence']}>
    <div style={{display: 'flex', gap: 30, marginTop: 60}}>
      {cards.map((card, i) => {
        const p = progress(frame, 12 + i * 12, 24);
        return <div key={card.title} style={{flex: 1, perspective: 1200}}>
          <div style={{transform: `rotateY(${(1 - p) * -24}deg) translateX(${(1 - p) * 60}px)`, opacity: p, transformOrigin: 'left center'}}>
            <Panel style={{padding: 34, height: 470, position: 'relative', overflow: 'hidden'}} glow={`${card.color}22`}>
              <div style={{position: 'absolute', left: 0, top: 0, height: 4, width: `${progress(frame, 20 + i * 12, 30) * 100}%`, background: card.color, boxShadow: `0 0 16px ${card.color}`}} />
              <Pill color={card.color}>{card.source}</Pill>
              <div style={{fontFamily: sans, fontWeight: 700, fontSize: 49, color: C.text, marginTop: 32}}>{card.title}</div>
              <div style={{marginTop: 32}}>{card.rows.map((row, j) => {
                const r = progress(frame, 32 + i * 12 + j * 9, 15);
                return <div key={row} style={{fontFamily: mono, fontSize: 22, color: C.dim, lineHeight: 2, opacity: r, transform: `translateX(${(1 - r) * 18}px)`}}><span style={{color: card.color}}>▍ </span>{row}</div>;
              })}</div>
              <div style={{marginTop: 36, color: card.color}}><TypedCode delay={70 + i * 14} speed={1.4} fontSize={21} lineHeight={1.4} prompt="$ " code={card.command} /></div>
            </Panel>
          </div>
        </div>;
      })}
    </div>
    <Note delay={110}>Selected structured evidence in Logfire. Full recordings in Apple's native tools.</Note>
  </Frame>;
};

export const NativeWait: React.FC<SceneProps> = () => {
  const frame = useCurrentFrame();
  return <Frame index="04" label="NATIVE INVESTIGATION" title="Show the scope of every conclusion." highlight={['scope']}>
    <div style={{display: 'flex', gap: 40, marginTop: 60}}>
      <Rise delay={10} style={{flex: 1}}><Panel style={{padding: 38}}>
        <Pill color="#7cc4ff">INSTRUMENTS · NEXT DRAWABLE</Pill>
        <div style={{fontFamily: sans, fontWeight: 800, fontSize: 115, color: C.text, marginTop: 28, fontVariantNumeric: 'tabular-nums'}}>{Math.round(count(frame, 15, 45, 0, data.nativeWait.calls))}<span style={{fontSize: 35, color: C.dim}}> calls</span></div>
        <Note>{data.nativeWait.totalWallMs.toFixed(1)} ms total wall time<br />{data.nativeWait.longestWallMs.toFixed(1)} ms longest complete call</Note>
        <Note>One real Log Roll capture on a busy host.<br />This is diagnostic evidence, not a baseline.</Note>
      </Panel></Rise>
      <Rise delay={30} style={{flex: 1}}><Panel style={{padding: 38}}>
        <Pill color={C.amber}>CLIPPED TO ONE SDK WINDOW</Pill>
        <div style={{fontFamily: sans, fontWeight: 800, fontSize: 115, color: C.amber, marginTop: 28, fontVariantNumeric: 'tabular-nums'}}>{count(frame, 35, 45, 0, data.nativeWait.windowCoveragePct).toFixed(1)}<span style={{fontSize: 45}}>%</span></div>
        <Note>Native recording coverage of the SDK window<br />{data.nativeWait.windowWaitMs.toFixed(1)} ms overlapping drawable waits</Note>
        <Note>Wait intervals overlap CPU states.<br />They do not prove GPU saturation or missed display deadlines.</Note>
      </Panel></Rise>
    </div>
  </Frame>;
};

export const Dashboard: React.FC<SceneProps> = () => {
  const frame = useCurrentFrame();
  const {durationInFrames} = useVideoConfig();
  const zoom = interpolate(frame, [30, durationInFrames], [1, 1.5], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  const shift = interpolate(frame, [30, durationInFrames], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  const items = ['Session → runtime and build traces', 'Frames, CPU and queue delays', 'Build timing and host load', 'Gameplay events', 'Native coverage and GPU replay'];
  return <Frame index="06" label="REAL LOGFIRE DASHBOARD" title="Start with a readable session overview." highlight={['readable']}>
    <div style={{marginTop: 35, display: 'flex', gap: 35, alignItems: 'center'}}>
      <Rise delay={8} distance={50} style={{width: 1050}}>
        <Panel style={{width: 1050, height: 660, overflow: 'hidden', position: 'relative'}} glow={`${C.ember}22`}>
          <Img src={staticFile('apple-metal-overview.jpg')} style={{width: '100%', display: 'block', transformOrigin: '50% 40%',
            transform: `scale(${zoom}) translate(${shift * -2}%, ${shift * -4}%)`}} />
        </Panel>
      </Rise>
      <div style={{flex: 1}}>
        <Rise delay={20}><Pill color={C.ember}>ACTUAL INGESTED DATA</Pill></Rise>
        <div style={{marginTop: 28}}>
          {items.map((item, i) => {
            const p = progress(frame, 34 + i * 10, 16);
            return <div key={item} style={{fontFamily: mono, fontSize: 23, lineHeight: 1.55, color: C.dim, opacity: p, transform: `translateX(${(1 - p) * 24}px)`}}>
              <span style={{color: C.ember}}>▸ </span>{item}</div>;
          })}
        </div>
        <Note delay={100}>Query the evidence through <span style={{color: C.amber}}>MCP</span>.<br />Keep the full recording for Instruments.</Note>
      </div>
    </div>
  </Frame>;
};

export const Montage: React.FC<SceneProps> = ({footage}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const games = [
    {name: 'LOG ROLL', file: 'log-roll', note: 'Compute particles + glow'},
    {name: 'FLAPPY LOG', file: 'flappy-log', note: 'Particles + scrolling world'},
    {name: 'NEON STACK', file: 'log-stack', note: 'Falling blocks + Metal effects'},
  ];
  return <AbsoluteFill style={{background: C.bg}}>
    <div style={{position: 'absolute', inset: 0, display: 'flex', gap: 12}}>
      {games.map((game, i) => {
        const p = progress(frame, i * 7, 26);
        return <div key={game.file} style={{flex: 1, overflow: 'hidden', position: 'relative', clipPath: `inset(${(1 - p) * 100}% 0 0 0)`}}>
          <div style={{position: 'absolute', inset: 0, transformOrigin: game.file === 'log-stack' ? '50% 0%' : '50% 50%',
            transform: game.file === 'log-stack' ? `translateY(-24%) scale(${1.08 - 0.05 * p + frame / 3000})` : `scale(${1.25 - 0.12 * p + frame / 2000})`}}>
            {footage ? <Loop durationInFrames={8 * fps}><OffthreadVideo src={staticFile(`footage/${game.file}.mp4`)} muted style={{width: '100%', height: '100%', objectFit: 'cover', objectPosition: 'center bottom'}} /></Loop>
              : <Img src={staticFile(`${game.file}.jpg`)} style={{width: '100%', height: '100%', objectFit: 'cover', objectPosition: 'center bottom'}} />}
          </div>
          <div style={{position: 'absolute', inset: 0, background: 'linear-gradient(0deg, #0a0706f5, transparent 65%)'}} />
          <div style={{position: 'absolute', left: 50, bottom: 130}}>
            <Rise delay={14 + i * 7}><div style={{fontFamily: sans, fontWeight: 800, fontSize: 62, color: C.text}}>{game.name}</div></Rise>
            <Note delay={22 + i * 7}>{game.note}</Note>
          </div>
        </div>;
      })}
    </div>
    <Rise delay={40} style={{position: 'absolute', bottom: 48, left: 50}}><Pill color={C.ember}>THREE WORKLOADS · ONE DEVELOPMENT TOOLKIT</Pill></Rise>
    <Atmosphere glow={0.6} />
  </AbsoluteFill>;
};

export const End: React.FC<SceneProps> = () => {
  const frame = useCurrentFrame();
  const glow = 0.6 + 0.4 * Math.sin(frame / 12);
  return <AbsoluteFill style={{background: C.bg}}>
    <Embers count={110} intensity={1.1} seed="end" />
    <AbsoluteFill style={{background: `radial-gradient(60% 50% at 30% 55%, rgba(255,106,26,${0.10 * glow}), transparent 70%)`}} />
    <AbsoluteFill style={{padding: 130, justifyContent: 'center'}}>
      <Rise delay={2}><Pill color={C.ember}>APPLE METAL + LOGFIRE</Pill></Rise>
      <Headline text="Build. Play. Investigate. Verify." size={118} delay={5} stagger={6} highlight={['Investigate']} style={{marginTop: 38, maxWidth: 1550}} />
      <FireLine delay={40} width={760} style={{marginTop: 34, background: fire}} />
      <Note delay={50}>LogfireSwift · logfire-apple · dashboard templates</Note>
      <Note delay={64}>Experimental community integration for trusted developer and tester machines.<br /><span style={{color: C.text}}>github.com/bruno-espino/neon-stack-logfire</span></Note>
    </AbsoluteFill>
    <Atmosphere glow={0.8} />
  </AbsoluteFill>;
};
