import React from 'react';
import {AbsoluteFill, Composition, Sequence} from 'remotion';
import {SceneFade, SpanWipe} from './components/kit';
import {SceneMotion} from './components/motion';
import {C, FPS} from './theme';
import {Intro, Setup, Correlation, CPUCase, Performance, NativeTools, NativeWait, Dashboard, Montage, End, ReelProps} from './scenes/Presentation';
import {InputTrace} from './scenes/InputTrace';

const SCENES = [
  {id: 'intro', seconds: 7, component: Intro},
  {id: 'setup', seconds: 9, component: Setup},
  {id: 'correlation', seconds: 10, component: Correlation},
  {id: 'inputs', seconds: 10, component: InputTrace},
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
      return <React.Fragment key={id}>
        <Sequence from={from} durationInFrames={duration} name={id}>
          <SceneFade duration={duration}><SceneMotion duration={duration}><Scene duration={duration} footage={footage} /></SceneMotion></SceneFade>
        </Sequence>
        {from > 0 && <Sequence from={from - 7} durationInFrames={15} name={`${id}-wipe`}><SpanWipe /></Sequence>}
      </React.Fragment>;
    })}
  </AbsoluteFill>;
};
export const Root: React.FC = () => <>
  <Composition id="Reel" component={Reel} durationInFrames={TOTAL} fps={FPS} width={1920} height={1080} defaultProps={{footage: false}} />
  <Composition id="NativeEvidence" component={NativeWait} durationInFrames={10 * FPS} fps={FPS} width={1920} height={1080} defaultProps={{footage: false, duration: 10 * FPS}} />
  <Composition id="CPUCase" component={CPUCase} durationInFrames={12 * FPS} fps={FPS} width={1920} height={1080} defaultProps={{footage: false, duration: 12 * FPS}} />
  <Composition id="InputTrace" component={InputTrace} durationInFrames={10 * FPS} fps={FPS} width={1920} height={1080} defaultProps={{footage: false, duration: 10 * FPS}} />
</>;
