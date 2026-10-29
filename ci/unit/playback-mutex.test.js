#!/usr/bin/env node
'use strict';
/*
 * Regression test for the "two stations play at once / pause stops working"
 * bug: @capgo/capacitor-native-audio's stop/unload/preload/play calls don't
 * cancel each other the way the old <audio> element's .src reassignment did,
 * so rapidly switching stations could leave two native players running.
 *
 * The fix in app.js serializes every native-playback call through a queue
 * (queueNative) and re-checks a generation counter (playGen) before each
 * step, so an abandoned attempt bails out - and undoes its own preload -
 * before ever calling play(). This test re-implements that exact pattern
 * (keep it in sync with app.js if that logic changes) against a fake native
 * layer with artificial latency, which is what actually exposes the race:
 * with zero latency the bug can't manifest, same as it wouldn't show up in
 * a desktop browser's instant local playback.
 *
 * Pure Node, no emulator/device needed - run with: node ci/unit/playback-mutex.test.js
 */

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function makeFakeNativeAudio(log) {
  let loaded = null;
  let playing = null;
  return {
    async stop() { log.push(['stop', playing]); playing = null; await delay(5); },
    async unload() { log.push(['unload', loaded]); loaded = null; await delay(5); },
    async preload(assetPath) { await delay(30); loaded = assetPath; log.push(['preload', assetPath]); },
    async play() {
      await delay(10);
      if (playing) throw new Error(`play() called while "${playing}" was already playing - OVERLAP BUG`);
      playing = loaded;
      log.push(['play', playing]);
    },
    getPlaying() { return playing; },
  };
}

// --- exact copy of the mutex pattern from app.js (playStation's native branch) ---
function makePlayer(NativeAudio) {
  let nativeQueue = Promise.resolve();
  function queueNative(task) {
    const run = () => Promise.resolve().then(task);
    const p = nativeQueue.then(run, run);
    nativeQueue = p.catch(() => {});
    return p;
  }
  let playGen = 0;
  async function playStation(stationId) {
    const gen = ++playGen;
    await queueNative(async () => {
      if (gen !== playGen) return;
      try { await NativeAudio.stop(); } catch (_) {}
      try { await NativeAudio.unload(); } catch (_) {}
      if (gen !== playGen) return;
      await NativeAudio.preload(stationId);
      if (gen !== playGen) {
        try { await NativeAudio.stop(); } catch (_) {}
        try { await NativeAudio.unload(); } catch (_) {}
        return;
      }
      await NativeAudio.play();
    });
  }
  return { playStation };
}

async function scenarioDoubleTap() {
  const log = [];
  const fake = makeFakeNativeAudio(log);
  const player = makePlayer(fake);

  // Exactly what a fast "next station" double-tap does: a second
  // playStation() call fires before the first one has settled.
  const pA = player.playStation('A.mp3');
  const pB = player.playStation('B.mp3');
  await Promise.all([pA, pB]);
  await delay(100); // let any stray async work surface

  const plays = log.filter((e) => e[0] === 'play');
  const failures = [];
  if (plays.length !== 1) failures.push(`expected exactly 1 play() call, got ${plays.length}: ${JSON.stringify(log)}`);
  if (fake.getPlaying() !== 'B.mp3') failures.push(`expected B.mp3 to end up playing, got ${fake.getPlaying()}`);
  if (plays.length === 1 && plays[0][1] !== 'B.mp3') failures.push(`the one play() call was for "${plays[0][1]}", not B.mp3`);
  return failures;
}

async function scenarioTripleTap() {
  const log = [];
  const fake = makeFakeNativeAudio(log);
  const player = makePlayer(fake);

  await Promise.all([player.playStation('X'), player.playStation('Y'), player.playStation('Z')]);
  await delay(100);

  const plays = log.filter((e) => e[0] === 'play');
  const failures = [];
  if (plays.length !== 1 || plays[0][1] !== 'Z') {
    failures.push(`three-way race: expected exactly 1 play() call for "Z", got ${JSON.stringify(plays)}`);
  }
  return failures;
}

async function scenarioSequentialIsUnaffected() {
  // Sanity check: the fix must not break the normal, non-racing case.
  const log = [];
  const fake = makeFakeNativeAudio(log);
  const player = makePlayer(fake);

  await player.playStation('A');
  await player.playStation('B');
  await delay(50);

  const plays = log.filter((e) => e[0] === 'play');
  const failures = [];
  if (plays.length !== 2) failures.push(`sequential switches should both play, got ${JSON.stringify(plays)}`);
  if (fake.getPlaying() !== 'B') failures.push(`expected B to end up playing, got ${fake.getPlaying()}`);
  return failures;
}

async function main() {
  const scenarios = {
    'rapid double-tap never double-plays': scenarioDoubleTap,
    'rapid triple-tap only plays the last station': scenarioTripleTap,
    'normal sequential switches still both play': scenarioSequentialIsUnaffected,
  };

  let allFailures = [];
  for (const [name, fn] of Object.entries(scenarios)) {
    try {
      const failures = await fn();
      if (failures.length) {
        console.error(`FAIL: ${name}`);
        failures.forEach((f) => console.error('  - ' + f));
        allFailures = allFailures.concat(failures);
      } else {
        console.log(`OK: ${name}`);
      }
    } catch (e) {
      console.error(`FAIL: ${name} (threw) - ${e.message}`);
      allFailures.push(e.message);
    }
  }

  if (allFailures.length) {
    console.error(`\n${allFailures.length} failure(s)`);
    process.exit(1);
  }
  console.log('\nAll playback-mutex scenarios passed.');
}

main();
