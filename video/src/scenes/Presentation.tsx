import React from 'react';
import {AbsoluteFill, Img, OffthreadVideo, staticFile, useCurrentFrame} from 'remotion';
import data from '../data.json';
import {C, mono, sans} from '../theme';
import {Atmosphere, Embers, Headline, Kicker, Panel, Pill, progress} from '../components/kit';

export type ReelProps = {footage: boolean};

type SceneProps = ReelProps & {duration: number};
const Frame: React.FC<{index: string; label: string; title: string; children: React.ReactNode}> = ({index, label, title, children}) => (
  <AbsoluteFill style={{background: C.bg, padding: '90px 120px'}}>
    <Kicker index={index} label={label} />
    <Headline text={title} size={78} delay={5} style={{marginTop: 24, maxWidth: 1650}} />
    {children}
    <Atmosphere glow={0.3} />
  </AbsoluteFill>
);
const Note: React.FC<{children: React.ReactNode}> = ({children}) => (
  <div style={{fontFamily: mono, fontSize: 23, lineHeight: 1.55, color: C.dim, marginTop: 28}}>{children}</div>
);
const Game: React.FC<{footage: boolean}> = ({footage}) => footage
  ? <OffthreadVideo src={staticFile('footage/log-roll.mp4')} muted style={{width: '100%', height: '100%', objectFit: 'cover'}} />
  : <Img src={staticFile('log-roll.jpg')} style={{width: '100%', height: '100%', objectFit: 'cover'}} />;

export const Intro: React.FC<SceneProps> = ({footage}) => {
  const frame = useCurrentFrame();
  return <AbsoluteFill style={{background: C.bg}}>
    <AbsoluteFill style={{opacity: 0.5, transform: `scale(${1.02 + frame / 4500})`}}><Game footage={footage} /></AbsoluteFill>
    <AbsoluteFill style={{background: 'linear-gradient(90deg, #0a0706f5 10%, #0a070670)'}} />
    <AbsoluteFill style={{justifyContent: 'center', padding: 130}}>
      <Pill color={C.ember}>COMMUNITY PROTOTYPE · EXPERIMENTAL</Pill>
      <Headline text="Apple Metal development, connected to Logfire." size={112} delay={8} highlight={['Metal', 'Logfire']} style={{maxWidth: 1500, marginTop: 40}} />
      <Note>Swift SDK + native companion + correlated evidence</Note>
    </AbsoluteFill>
    <Atmosphere />
  </AbsoluteFill>;
};

export const Setup: React.FC<SceneProps> = () => {
  const frame = useCurrentFrame();
  return <Frame index="01" label="SETUP" title="Start with one Swift package.">
    <div style={{display: 'flex', gap: 48, marginTop: 55}}>
      <Panel style={{width: 970, padding: 38}}>
        <div style={{fontFamily: mono, color: C.amber, fontSize: 21, marginBottom: 24}}>LogfireSwift · app target</div>
        <pre style={{fontFamily: mono, fontSize: 27, lineHeight: 1.65, color: C.text, margin: 0}}>{`import LogfireSwift\n\nlet telemetry = try Logfire.development(\n    serviceName: "my-game")\n\ntelemetry.withSpan("game.load") {\n    loadLevel()\n}`}</pre>
      </Panel>
      <div style={{flex: 1, opacity: progress(frame, 24, 20)}}>
        <Panel style={{padding: 30}}>
          <div style={{fontFamily: sans, fontSize: 38, color: C.text}}>Configure once</div>
          <Note>logfire-apple configure --region us</Note>
          <Note>Enable LOGFIRE_DEV_DIRECT=1<br />Retain one client for the app.</Note>
        </Panel>
        <Note>Direct OTLP export for trusted development builds.<br />Add frame and responsiveness recording explicitly.</Note>
      </div>
    </div>
  </Frame>;
};

export const Correlation: React.FC<SceneProps> = () => {
  const frame = useCurrentFrame();
  const groups = [
    {title: 'Build trace', color: C.amber, root: 'xcode.build', rows: ['xcode.host.sample · log', 'xcode.build.task_summary · log'], link: 'build.id + source fingerprint'},
    {title: 'Run trace', color: C.ember, root: 'development.run', rows: ['game.performance.window · log', 'app.responsiveness.window · log', 'game.host.sample · log', 'development.run.summary · log'], link: 'session_id + build.id'},
    {title: 'Offline analysis trace', color: '#7cc4ff', root: 'development.timeline.import', rows: ['development.thread.timeline · log', 'development.thread.window · log', 'development.metal.drawable_wait · log'], link: 'source.run_trace_id + capture.id'},
  ];
  return <Frame index="02" label="TRACE STRUCTURE" title="From Xcode build to game investigation.">
    <div style={{display: 'flex', gap: 30, marginTop: 60}}>
      {groups.map((g, i) => <Panel key={g.root} style={{flex: 1, height: 485, padding: 30, opacity: progress(frame, 15 + i * 22, 20)}}>
        <Pill color={g.color}>{g.title}</Pill>
        <div style={{fontFamily: mono, fontSize: 25, color: C.text, marginTop: 32}}>{g.root}</div>
        <div style={{borderLeft: `3px solid ${g.color}`, paddingLeft: 18, marginTop: 28}}>
          {g.rows.map((row, index) => <div key={row} style={{fontFamily: mono, fontSize: 19, color: C.dim, lineHeight: 2, opacity: progress(frame, 28 + i * 20 + index * 7, 15)}}>{row}<div style={{height: 4, width: `${progress(frame, 30 + i * 20 + index * 7, 35) * 70}%`, background: g.color, marginBottom: 6, opacity: 0.6}} /></div>)}
        </div>
        <Note>{g.link}</Note>
      </Panel>)}
    </div>
    <Note>Diagram of the verified structure. Frame summaries are logs; raw histograms go to Metrics.</Note>
  </Frame>;
};

export const Performance: React.FC<SceneProps> = ({footage}) => {
  const frame = useCurrentFrame();
  const rise = progress(frame, 65, 140);
  const fps = Math.round(45 + 75 * rise);
  return <AbsoluteFill style={{background: C.bg}}>
    <AbsoluteFill style={{opacity: 0.65}}><Game footage={footage} /></AbsoluteFill>
    <AbsoluteFill style={{background: 'linear-gradient(90deg, #0a0706f5 5%, #0a070680 80%)'}} />
    <div style={{position: 'absolute', left: 120, top: 100}}>
      <Kicker index="04" label="PERFORMANCE WORKFLOW" />
      <Headline text="Find the bottleneck. Chase smoother frames." size={96} delay={5} highlight={['smoother']} style={{maxWidth: 1050, marginTop: 35}} />
      <Note>Frame timing → native CPU callers → shader replay → verify</Note>
    </div>
    <Panel style={{position: 'absolute', right: 120, bottom: 130, padding: '35px 48px', width: 680}} glow={`${C.ok}22`}>
      <Pill color={C.amber}>ILLUSTRATIVE OPTIMIZATION SCENARIO</Pill>
      <div style={{fontFamily: sans, fontWeight: 800, fontSize: 200, lineHeight: 1.1, color: C.ok, marginTop: 25, fontVariantNumeric: 'tabular-nums'}}>{fps}<span style={{fontSize: 50, color: C.dim}}> FPS</span></div>
      <div style={{height: 16, borderRadius: 8, background: C.line, marginTop: 20}}><div style={{height: '100%', width: `${fps / 120 * 100}%`, background: C.ok, borderRadius: 8}} /></div>
      <Note>45 → 120 FPS target · simulated figures</Note>
    </Panel>
    <div style={{position: 'absolute', left: 120, bottom: 130, maxWidth: 700}}>
      <Pill color={C.ember}>MEASURED CPU CASE</Pill>
      <Note>29.0% → 8.1% main-thread CPU<br />Five runs per policy. Callback ≈ 60 Hz.</Note>
    </div>
    <Atmosphere glow={0.6} />
  </AbsoluteFill>;
};

export const CPUCase: React.FC<SceneProps> = () => {
  const frame = useCurrentFrame();
  const groups = [
    {name: 'Publish every frame', values: data.cpuCase.before, median: data.cpuCase.beforeMedian, color: C.amber},
    {name: 'Bound HUD publication', values: data.cpuCase.after, median: data.cpuCase.afterMedian, color: C.ok},
  ];
  return <Frame index="03" label="VERIFIED CPU CASE" title="Less SwiftUI work. Same callback rate.">
    <div style={{display: 'flex', gap: 40, marginTop: 40}}>
      {groups.map((g, j) => <Panel key={g.name} style={{flex: 1, padding: 34}}>
        <div style={{fontFamily: sans, fontSize: 35, color: C.text}}>{g.name}</div>
        <div style={{fontFamily: sans, fontWeight: 800, fontSize: 115, color: g.color, marginTop: 14}}>{g.median.toFixed(1)}<span style={{fontSize: 45}}>%</span></div>
        <div style={{fontFamily: mono, fontSize: 20, color: C.dim}}>median main-thread CPU · one core</div>
        <svg width="690" height="160" style={{marginTop: 30}}>
          {g.values.map((v, i) => {
            const p = progress(frame, 20 + j * 10 + i * 8, 25);
            const height = v / 35 * 135 * p;
            return <g key={i}><rect x={i * 133 + 4} y={150 - height} width={100} height={height} rx={5} fill={g.color} /><text x={i * 133 + 54} y={140 - height} textAnchor="middle" fill={C.text} fontSize={21} fontFamily={mono}>{v.toFixed(1)}%</text></g>;
          })}
        </svg>
        <Note>Five measured runs · callback ≈ 60 Hz</Note>
      </Panel>)}
    </div>
    <Note>Same Release binary, seed and 65,536 particles. Warmups and profiling excluded.<br />A separate Time Profiler capture found SwiftUI callers. This establishes CPU savings; it does not establish an FPS or GPU gain.</Note>
  </Frame>;
};

export const NativeTools: React.FC<SceneProps> = () => {
  const frame = useCurrentFrame();
  const cards = [
    {title: 'CPU callers', source: 'Instruments · Time Profiler', color: '#7cc4ff', rows: ['SwiftUI call paths', 'Inclusive sampled weight', 'Main-thread running work'], command: 'run --profile cpu'},
    {title: 'Shader replay', source: 'Metal · GPU capture', color: '#e04dff', rows: ['Render + compute encoders', 'Selected shader costs', 'Register + spill evidence'], command: 'run --profile gpu'},
    {title: 'Native waits', source: 'Metal System Trace', color: C.amber, rows: ['Running / blocked / runnable', 'Next-drawable intervals', 'Coverage within SDK windows'], command: 'diagnose --trace CAPTURE'},
  ];
  return <Frame index="05" label="APPLE NATIVE TOOLS" title="Go from a slow frame to deeper evidence.">
    <div style={{display: 'flex', gap: 30, marginTop: 60}}>
      {cards.map((card, i) => <Panel key={card.title} style={{flex: 1, padding: 34, height: 470, opacity: progress(frame, 12 + i * 18, 20)}} glow={`${card.color}22`}>
        <Pill color={card.color}>{card.source}</Pill>
        <div style={{fontFamily: sans, fontWeight: 700, fontSize: 49, color: C.text, marginTop: 32}}>{card.title}</div>
        <div style={{marginTop: 32}}>{card.rows.map((row, j) => <div key={row} style={{fontFamily: mono, fontSize: 22, color: C.dim, lineHeight: 2, opacity: progress(frame, 32 + i * 18 + j * 10, 15)}}><span style={{color: card.color}}>▍ </span>{row}</div>)}</div>
        <div style={{fontFamily: mono, fontSize: 21, color: card.color, marginTop: 36}}>{card.command}</div>
      </Panel>)}
    </div>
    <Note>Selected structured evidence in Logfire. Full recordings in Apple's native tools.</Note>
  </Frame>;
};

export const NativeWait: React.FC<SceneProps> = () => {
  const frame = useCurrentFrame();
  return <Frame index="04" label="NATIVE INVESTIGATION" title="Show the scope of every conclusion.">
    <div style={{display: 'flex', gap: 40, marginTop: 60}}>
      <Panel style={{flex: 1, padding: 38}}>
        <Pill color="#7cc4ff">INSTRUMENTS · NEXT DRAWABLE</Pill>
        <div style={{fontFamily: sans, fontWeight: 800, fontSize: 115, color: C.text, marginTop: 28}}>{data.nativeWait.calls}<span style={{fontSize: 35, color: C.dim}}> calls</span></div>
        <Note>{data.nativeWait.totalWallMs.toFixed(1)} ms total wall time<br />{data.nativeWait.longestWallMs.toFixed(1)} ms longest complete call</Note>
        <Note>One real Log Roll capture on a busy host.<br />This is diagnostic evidence, not a baseline.</Note>
      </Panel>
      <Panel style={{flex: 1, padding: 38, opacity: progress(frame, 25, 20)}}>
        <Pill color={C.amber}>CLIPPED TO ONE SDK WINDOW</Pill>
        <div style={{fontFamily: sans, fontWeight: 800, fontSize: 115, color: C.amber, marginTop: 28}}>{data.nativeWait.windowCoveragePct.toFixed(1)}<span style={{fontSize: 45}}>%</span></div>
        <Note>Native recording coverage of the SDK window<br />{data.nativeWait.windowWaitMs.toFixed(1)} ms overlapping drawable waits</Note>
        <Note>Wait intervals overlap CPU states.<br />They do not prove GPU saturation or missed display deadlines.</Note>
      </Panel>
    </div>
  </Frame>;
};

export const Dashboard: React.FC<SceneProps> = () => {
  const frame = useCurrentFrame();
  return <Frame index="06" label="REAL LOGFIRE DASHBOARD" title="Start with a readable session overview.">
    <div style={{marginTop: 35, display: 'flex', gap: 35, alignItems: 'center'}}>
      <Panel style={{width: 1050, overflow: 'hidden', opacity: progress(frame, 10, 20)}}>
        <Img src={staticFile('apple-metal-overview.jpg')} style={{width: '100%', display: 'block'}} />
      </Panel>
      <div style={{flex: 1}}>
        <Pill color={C.ember}>ACTUAL INGESTED DATA</Pill>
        <Note>Session → runtime and build traces<br />Frames, CPU and queue delays<br />Build timing and host load<br />Gameplay events<br />Native coverage and GPU replay</Note>
        <Note>Query the evidence through MCP.<br />Keep the full recording for Instruments.</Note>
      </div>
    </div>
  </Frame>;
};

export const Montage: React.FC<SceneProps> = ({footage}) => {
  const frame = useCurrentFrame();
  const games = [
    {name: 'LOG ROLL', file: 'log-roll', note: 'Compute particles + glow'},
    {name: 'FLAPPY LOG', file: 'flappy-log', note: 'Particles + scrolling world'},
    {name: 'NEON STACK', file: 'log-stack', note: 'Falling blocks + Metal effects'},
  ];
  return <AbsoluteFill style={{background: C.bg}}>
    <div style={{position: 'absolute', inset: 0, display: 'flex', gap: 12}}>
      {games.map((game, i) => <div key={game.file} style={{flex: 1, overflow: 'hidden', position: 'relative', opacity: progress(frame, i * 6, 18)}}>
        {footage ? <OffthreadVideo src={staticFile(`footage/${game.file}.mp4`)} muted style={{width: '100%', height: '100%', objectFit: 'cover', objectPosition: 'center bottom'}} />
          : <Img src={staticFile(`${game.file}.jpg`)} style={{width: '100%', height: '100%', objectFit: 'cover', objectPosition: 'center bottom'}} />}
        <div style={{position: 'absolute', inset: 0, background: 'linear-gradient(0deg, #0a0706f5, transparent 65%)'}} />
        <div style={{position: 'absolute', left: 50, bottom: 130}}>
          <div style={{fontFamily: sans, fontWeight: 800, fontSize: 62, color: C.text}}>{game.name}</div>
          <Note>{game.note}</Note>
        </div>
      </div>)}
    </div>
    <div style={{position: 'absolute', bottom: 48, left: 50}}><Pill color={C.ember}>THREE WORKLOADS · ONE DEVELOPMENT TOOLKIT</Pill></div>
    <Atmosphere glow={0.6} />
  </AbsoluteFill>;
};

export const End: React.FC<SceneProps> = () => (
  <AbsoluteFill style={{background: C.bg}}>
    <Embers count={75} />
    <AbsoluteFill style={{padding: 130, justifyContent: 'center'}}>
      <Pill color={C.ember}>APPLE METAL + LOGFIRE</Pill>
      <Headline text="Build. Play. Investigate. Verify." size={118} delay={5} highlight={['Investigate']} style={{marginTop: 38, maxWidth: 1550}} />
      <Note>LogfireSwift · logfire-apple · dashboard templates</Note>
      <Note>Experimental community integration for trusted developer and tester machines.<br />github.com/bruno-espino/neon-stack-logfire</Note>
    </AbsoluteFill>
    <Atmosphere glow={0.8} />
  </AbsoluteFill>
);
