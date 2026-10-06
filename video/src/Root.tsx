import React from 'react';
import {AbsoluteFill, Composition, Sequence} from 'remotion';
import {BAR, C, FPS} from './theme';
import {SceneFade, SpanWipe} from './components/kit';
import {Open} from './scenes/Open';
import {Title} from './scenes/Title';
import {Problem} from './scenes/Problem';
import {Code} from './scenes/Code';
import {Chain} from './scenes/Chain';
import {Fix} from './scenes/Fix';
import {Live} from './scenes/Live';
import {Montage} from './scenes/Montage';
import {End} from './scenes/End';

/** Scene lengths in bars (120 BPM, 2 s per bar). Cuts land on bar lines for the music. */
const SCENES: {id: string; bars: number; C: React.FC}[] = [
  {id: 'open', bars: 2.5, C: Open},
  {id: 'title', bars: 2, C: Title},
  {id: 'problem', bars: 3.5, C: Problem},
  {id: 'code', bars: 4, C: Code},
  {id: 'chain', bars: 6, C: Chain},
  {id: 'fix', bars: 4.5, C: Fix},
  {id: 'live', bars: 5, C: Live},
  {id: 'montage', bars: 3, C: Montage},
  {id: 'end', bars: 3, C: End},
];
const TOTAL = SCENES.reduce((n, s) => n + s.bars * BAR, 0);

export const Reel: React.FC = () => {
  let at = 0;
  return (
    <AbsoluteFill style={{background: C.bg}}>
      {SCENES.map(({id, bars, C: Scene}, i) => {
        const from = at, length = bars * BAR;
        at += length;
        return (
          <React.Fragment key={id}>
            <Sequence from={from} durationInFrames={length} name={id}>
              <SceneFade duration={length} inn={i === 0 ? 1 : 8} out={i === SCENES.length - 1 ? 1 : 10}><Scene /></SceneFade>
            </Sequence>
            {i > 1 && <Sequence from={from - 7} durationInFrames={15} name={`${id}-wipe`}><SpanWipe /></Sequence>}
          </React.Fragment>
        );
      })}
    </AbsoluteFill>
  );
};

export const Root: React.FC = () => (
  <>
    <Composition id="Reel" component={Reel} durationInFrames={TOTAL} fps={FPS} width={1920} height={1080} />
    {SCENES.map(({id, bars, C: Scene}) => (
      <Composition key={id} id={`scene-${id}`} component={Scene} durationInFrames={bars * BAR} fps={FPS} width={1920} height={1080} />
    ))}
  </>
);
