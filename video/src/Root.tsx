import React from 'react';
import {AbsoluteFill, Composition, Sequence} from 'remotion';
import {SceneFade} from './components/kit';
import {C, FPS} from './theme';
import {Intro, Setup, Correlation, CPUCase, Performance, NativeTools, NativeWait, Dashboard, Montage, End, ReelProps} from './scenes/Presentation';

const SCENES = [
  {id: 'intro', seconds: 7, component: Intro},
  {id: 'setup', seconds: 9, component: Setup},
  {id: 'correlation', seconds: 10, component: Correlation},
  {id: 'performance', seconds: 12, component: Performance},
  {id: 'native', seconds: 8, component: NativeTools},
  {id: 'dashboard', seconds: 9, component: Dashboard},
  {id: 'montage', seconds: 5, component: Montage},
  {id: 'end', seconds: 7, component: End},
];
const TOTAL = SCENES.reduce((sum, scene) => sum + scene.seconds * FPS, 0);
export const Reel: React.FC<ReelProps> = ({footage}) => {
  let at = 0;
  return <AbsoluteFill style={{background: C.bg}}>
    {SCENES.map(({id, seconds, component: Scene}) => {
      const from = at;
      const duration = seconds * FPS;
      at += duration;
      return <Sequence key={id} from={from} durationInFrames={duration} name={id}>
        <SceneFade duration={duration}><Scene duration={duration} footage={footage} /></SceneFade>
      </Sequence>;
    })}
  </AbsoluteFill>;
};
export const Root: React.FC = () => <>
  <Composition id="Reel" component={Reel} durationInFrames={TOTAL} fps={FPS} width={1920} height={1080} defaultProps={{footage: false}} />
  <Composition id="NativeEvidence" component={NativeWait} durationInFrames={10 * FPS} fps={FPS} width={1920} height={1080} defaultProps={{footage: false, duration: 10 * FPS}} />
  <Composition id="CPUCase" component={CPUCase} durationInFrames={12 * FPS} fps={FPS} width={1920} height={1080} defaultProps={{footage: false, duration: 12 * FPS}} />
</>;
