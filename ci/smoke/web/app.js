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
