/* Minimal harness: exercises the exact same NativeAudio + MediaSession calls
   app.js uses for real stations, against a bundled local test tone instead of
   a live stream, so the CI assertion doesn't depend on any external service. */
(function () {
  'use strict';
  var statusEl = document.getElementById('status');
  function log(msg) {
    if (statusEl) statusEl.textContent = msg;
    console.log('[smoke] ' + msg);
  }

  function boot() {
    var Cap = window.Capacitor;
    if (!Cap || !Cap.isNativePlatform || !Cap.isNativePlatform()) { log('not-native'); return; }
    var NativeAudio = Cap.Plugins && Cap.Plugins.NativeAudio;
    var MediaSession = Cap.Plugins && Cap.Plugins.MediaSession;
    if (!NativeAudio || !MediaSession) { log('plugins-missing'); return; }

    // Registered so the smoke test can prove a real transport-control event
    // (hardware/notification media button) actually reaches our JS code, not
    // just that the notification/session exists and reports the right state.
    try {
      MediaSession.setActionHandler({ action: 'pause' }, function () { console.log('SMOKE_ACTION_FIRED:pause'); });
      MediaSession.setActionHandler({ action: 'play' }, function () { console.log('SMOKE_ACTION_FIRED:play'); });
    } catch (e) { console.log('SMOKE: setActionHandler threw: ' + (e && e.message)); }

    NativeAudio.configure({ focus: true, background: true, backgroundPlayback: true, showNotification: false })
      .then(function () {
        return NativeAudio.preload({ assetId: 'smoke', assetPath: 'assets/sounds/test.mp3', isUrl: false, volume: 1 });
      })
      .then(function () { return NativeAudio.loop({ assetId: 'smoke' }); })
      .then(function () { return MediaSession.setMetadata({ title: 'Smoke Test', artist: 'CI', album: 'Orbitune' }); })
      .then(function () { return MediaSession.setPlaybackState({ playbackState: 'playing' }); })
      .then(function () { log('playing'); })
      .catch(function (e) { log('error: ' + (e && e.message ? e.message : e)); });
  }

  document.addEventListener('deviceready', boot);
  setTimeout(boot, 1000); // fallback in case deviceready already fired or never fires
})();
