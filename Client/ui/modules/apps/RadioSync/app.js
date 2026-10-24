angular.module('beamng.apps')
.directive('radioSync', ['$injector', function ($injector) {
  return {
    templateUrl: '/ui/modules/apps/RadioSync/app.html',
    replace: true,
    restrict: 'EA',
    scope: true,
    link: function (scope, element) {
      var DRIFT_LIMIT = 1.5;      // seconds before a track gets re-seeked
      var DESTROY_AFTER = 5000;   // ms of silence before a player is dropped
      var STORAGE_KEY = 'radioSync.settings';

      var states = {};   // vid -> car radio state from the server (+ recvAt)
      var stations = {}; // station id -> { id, title, count, file, songTitle, elapsed, seq, recvAt }
      var players = {};  // vid -> { audio, url, seq, gain, zeroSince, error, fx }
      var gains = {};
      var fxMap = {};    // vid -> { pan, inside } from Lua
      var myPid = null;

      // Only the newest app instance plays. When the layout is reloaded, BeamNG can leave the old
      // instance alive without $destroy; it would keep playing at a volume no slider controls.
      var instanceId = {};
      window.__radioSyncInstance = instanceId;
      function retired() { return window.__radioSyncInstance !== instanceId; }

      scope.config = { songs: [] };
      scope.stationList = [];
      scope.current = null;    // server vid of the vehicle we sit in
      scope.own = false;
      scope.state = null;      // state of the radio shown in the panel
      scope.shownVid = null;
      scope.status = '';
      scope.settings = { volume: 0.5, muted: false, collapsed: false, tab: 'stations', realistic: true, v: 2 };
      scope.progress = { cur: 0, dur: 0, pct: 0 };
      scope.playing = false;

      try {
        var saved = JSON.parse(localStorage.getItem(STORAGE_KEY));
        if (saved && typeof saved === 'object') {
          for (var key in saved) scope.settings[key] = saved[key];
          if (saved.v !== 2) {
            // Volume curve changed: start in the middle of the new range.
            scope.settings.volume = 0.5;
            scope.settings.v = 2;
          }
        }
      } catch (e) {}
      if (['stations', 'music', 'queue'].indexOf(scope.settings.tab) === -1) scope.settings.tab = 'stations';

      function saveSettings() {
        try { localStorage.setItem(STORAGE_KEY, JSON.stringify(scope.settings)); } catch (e) {}
      }

      // ---------------------------------------------------------------- translations
      // {0}/{1} are replaced by t()'s extra arguments. Language: settings.lang ('auto' | 'de' | 'en');
      // auto follows the game's UI language ($translate), else the browser language.

      var I18N = {
        de: {
          expand: 'Ausklappen', collapse: 'Einklappen', lang: 'Sprache: {0}', langAuto: 'automatisch',
          radioOff: 'Radio aus', playlistEmptyTitle: 'Playlist leer', internetRadio: 'Internetradio',
          trackOf: 'Titel {0} von {1}', paused: ' · pausiert', open: ' · offen',
          openTip: 'Tür/Fenster offen – klingt nach außen lauter', damaged: ' · beschädigt', damagedTip: 'Radio beschädigt',
          nearby: ' · Auto in der Nähe', noRadioNear: 'Kein Radio in Hörweite',
          audioBlocked: 'Ton blockiert – einmal in die App klicken.',
          prev: 'Zurück', play: 'Abspielen', pause: 'Pause', next: 'Weiter', stop: 'Radio aus',
          loopAll: 'Playlist wiederholen', loopOne: 'Song wiederholen', loopOff: 'Nicht wiederholen',
          mute: 'Stumm', volOff: 'aus', real: 'Echt',
          realTip: 'Realistischer Klang: im Auto wie aus den Boxen, von außen gedämpft + Stereo-Richtung',
          tabStations: 'Sender', tabMusic: 'Musik', tabPlaylist: 'Playlist',
          liveRadio: 'Live-Radio', ownStations: 'Eigene Sender', songsCount: '{0} Songs', mix: 'Mix (alle Songs)',
          noStations: 'Noch keine Sender.', uploadTo: 'Songs hochladen nach:',
          noStationsHint: 'Jeder Unterordner (z.B. music/Rock/) wird ein eigener Sender.',
          downloading: 'Lade „{0}“ – {1}%', moreLeft: ' · noch {0} weitere',
          searchSong: 'Song suchen…', addAll: 'Alle {0} zur Playlist', addToPlaylist: 'Zur Playlist hinzufügen',
          noSongs: 'Keine Songs auf dem Server.', noSongsHint: 'Neue Songs erscheinen nach spätestens 30 s.',
          remove: 'Entfernen', playlistEmpty: 'Playlist leer.', playlistEmptyHint: 'Songs im Tab „Musik“ hinzufügen.',
          diagnose: 'Fahrzeug-Diagnose', diagSaved: 'Lauf {0} gespeichert in', diagFolder: '(BeamNG-Userordner)',
          close: 'schließen', collecting: 'Sammle Daten…', noVehicle: 'Kein Fahrzeug – erst in ein Auto setzen.',
          getIn: 'Steig in dein eigenes Auto, um das Radio zu steuern.',
          liveDown: 'Sender gerade nicht erreichbar – neuer Versuch in 1 Minute', connecting: 'Verbinde mit Sender…',
          songLoading: 'Song wird geladen…', inQueue: ' (in Warteschlange)',
          songError: 'Song konnte nicht abgespielt werden (Code {0}){1}',
          liveUnsupported: 'Live-Radio wird von diesem Spiel-Browser nicht unterstützt',
          mp3Unsupported: 'MP3-Stream nicht abspielbar',
          ownerVol: 'für alle', ownerVolTip: 'Radio-Lautstärke für alle – lauter = auch weiter zu hören'
        },
        en: {
          expand: 'Expand', collapse: 'Collapse', lang: 'Language: {0}', langAuto: 'automatic',
          radioOff: 'Radio off', playlistEmptyTitle: 'Playlist empty', internetRadio: 'Internet radio',
          trackOf: 'Track {0} of {1}', paused: ' · paused', open: ' · open',
          openTip: 'Door/window open – sounds louder outside', damaged: ' · damaged', damagedTip: 'Radio damaged',
          nearby: ' · car nearby', noRadioNear: 'No radio in earshot',
          audioBlocked: 'Sound blocked – click into the app once.',
          prev: 'Previous', play: 'Play', pause: 'Pause', next: 'Next', stop: 'Radio off',
          loopAll: 'Repeat playlist', loopOne: 'Repeat song', loopOff: 'No repeat',
          mute: 'Mute', volOff: 'off', real: 'Real',
          realTip: 'Realistic sound: like car speakers inside, muffled outside + stereo direction',
          tabStations: 'Stations', tabMusic: 'Music', tabPlaylist: 'Playlist',
          liveRadio: 'Live radio', ownStations: 'Own stations', songsCount: '{0} songs', mix: 'Mix (all songs)',
          noStations: 'No stations yet.', uploadTo: 'Upload songs to:',
          noStationsHint: 'Every subfolder (e.g. music/Rock/) becomes its own station.',
          downloading: 'Loading “{0}” – {1}%', moreLeft: ' · {0} more',
          searchSong: 'Search song…', addAll: 'Add all {0} to playlist', addToPlaylist: 'Add to playlist',
          noSongs: 'No songs on the server.', noSongsHint: 'New songs show up within 30 s.',
          remove: 'Remove', playlistEmpty: 'Playlist empty.', playlistEmptyHint: 'Add songs in the “Music” tab.',
          diagnose: 'Vehicle diagnose', diagSaved: 'Run {0} saved to', diagFolder: '(BeamNG user folder)',
          close: 'close', collecting: 'Collecting data…', noVehicle: 'No vehicle – get into a car first.',
          getIn: 'Get into your own car to control the radio.',
          liveDown: 'Station unreachable right now – retrying in 1 minute', connecting: 'Connecting to station…',
          songLoading: 'Loading song…', inQueue: ' (queued)',
          songError: 'Song could not be played (code {0}){1}',
          liveUnsupported: 'Live radio is not supported by this game browser',
          mp3Unsupported: 'MP3 stream cannot be played',
          ownerVol: 'for all', ownerVolTip: 'Radio volume for everyone – louder also carries further'
        }
      };

      scope.lang = 'de';

      scope.t = function (key, a, b) {
        var s = (I18N[scope.lang] && I18N[scope.lang][key]) || I18N.en[key] || key;
        if (a !== undefined) s = s.split('{0}').join(a);
        if (b !== undefined) s = s.split('{1}').join(b);
        return s;
      };

      function gameLanguage() {
        try {
          if ($injector.has('$translate')) {
            var l = $injector.get('$translate').use();
            if (l) return l;
          }
        } catch (e) {}
        return navigator.language || 'en';
      }

      // Re-run periodically so a language change in the game menu applies right away.
      function updateLanguage() {
        var pref = scope.settings.lang || 'auto';
        var l = pref === 'auto' ? gameLanguage() : pref;
        scope.lang = /^de/i.test(String(l)) ? 'de' : 'en';
      }
      updateLanguage();

      var LANG_NEXT = { auto: 'de', de: 'en', en: 'auto' };
      scope.cycleLanguage = function () {
        scope.settings.lang = LANG_NEXT[scope.settings.lang || 'auto'];
        saveSettings();
        updateLanguage();
      };
      scope.langLabel = function () {
        var pref = scope.settings.lang || 'auto';
        return pref === 'auto' ? 'A·' + scope.lang.toUpperCase() : pref.toUpperCase();
      };
      scope.langTitle = function () {
        var pref = scope.settings.lang || 'auto';
        return scope.t('lang', pref === 'auto' ? scope.t('langAuto') : pref.toUpperCase());
      };

      function lua(cmd, args) {
        var msg = { cmd: cmd };
        if (args) {
          for (var k in args) msg[k] = args[k];
        }
        bngApi.engineLua('extensions.radioSync.uiCommand(' + bngApi.serializeToLua(JSON.stringify(msg)) + ')');
      }

      function ownerCmd(cmd, args) {
        lua(cmd, { args: args || {} });
      }

      function isMine(vid) {
        return myPid !== null && typeof vid === 'string' && vid.split('-')[0] === String(myPid);
      }

      // What a car radio should play right now: its playlist track, or its station's current song.
      function playback(vid) {
        var s = states[vid];
        if (!s) return null;
        if (s.mode === 'live') {
          return { url: 'live:' + s.station, seq: 'live:' + s.station + ':' + s.seq, liveId: s.station,
                   paused: s.paused, live: true, station: true };
        }
        if (s.mode === 'station') {
          var st = stations[s.station];
          if (!st || !st.file) return null;
          return { url: 'music:' + st.file, seq: 'st:' + st.id + ':' + st.seq, elapsed: st.elapsed,
                   recvAt: st.recvAt, paused: s.paused, station: true };
        }
        if (!s.url) return null;
        return { url: s.url, seq: s.seq, elapsed: s.elapsed, recvAt: s.recvAt, paused: s.paused, station: false };
      }

      // Position the song should be at right now.
      function expectedTime(b) {
        if (b.paused && !b.station) return b.elapsed || 0;
        return (b.elapsed || 0) + (performance.now() - b.recvAt) / 1000;
      }

      // ---------------------------------------------------------------- sound effects
      // Each player runs through one chain whose parameters switch between two profiles:
      //   inside  - camera in the cabin: small door speakers + tweeters in a tiny, reflective room
      //   outside - heard through the car body: muffled, bass carries, panned towards the car
      // source -> highpass -> cabin bass -> box resonance -> mid dip -> presence -> lowpass
      //        -> compressor (stereo) -> L/R width matrix (+ right delay) -> pan -> dry / cabin / outside reverb

      var ctx = null;
      var cabinVerb = null;
      var outsideVerb = null;

      // Impulse response: a few discrete early reflections (glass, roof, dash) plus a dense decaying tail.
      function makeImpulse(c, seconds, reflections, tailPower) {
        var len = Math.floor(c.sampleRate * seconds);
        var ir = c.createBuffer(2, len, c.sampleRate);
        for (var ch = 0; ch < 2; ch++) {
          var d = ir.getChannelData(ch);
          for (var i = 0; i < len; i++) {
            d[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / len, tailPower) * 0.35;
          }
          reflections.forEach(function (r) {
            var at = Math.floor(c.sampleRate * (r[0] + (ch ? 0.0007 : 0)) / 1000);
            if (at < len) d[at] += r[1] * (ch ? 0.9 : 1);
          });
        }
        return ir;
      }

      // One AudioContext for the whole UI session, kept on window: BeamNG rebuilds the app when the
      // vehicle is swapped or tuned, and a fresh context would start suspended (silent) until a click.
      function audioContext() {
        if (ctx) return ctx;
        var shared = window.__radioSyncAudio;
        if (!shared) {
          var Ctx = window.AudioContext || window.webkitAudioContext;
          if (!Ctx) return null;
          var c = new Ctx();
          var cabin = c.createConvolver();
          cabin.buffer = makeImpulse(c, 0.09, [[1.3, 0.7], [2.4, 0.5], [3.7, 0.45], [5.1, 0.3], [7.9, 0.2]], 4);
          cabin.connect(c.destination);
          var outside = c.createConvolver();
          outside.buffer = makeImpulse(c, 0.4, [[9, 0.3], [21, 0.2]], 3);
          outside.connect(c.destination);
          shared = window.__radioSyncAudio = { ctx: c, cabin: cabin, outside: outside };
        }
        ctx = shared.ctx;
        cabinVerb = shared.cabin;
        outsideVerb = shared.outside;
        return ctx;
      }

      // All songs are local files in the game's VFS, so effects always work when enabled.
      function canFx() {
        return !!scope.settings.realistic && !!(window.AudioContext || window.webkitAudioContext);
      }

      function filter(c, type, freq, q, gain) {
        var f = c.createBiquadFilter();
        f.type = type;
        f.frequency.value = freq;
        if (q !== undefined) f.Q.value = q;
        if (gain !== undefined) f.gain.value = gain;
        return f;
      }

      function buildFx(p) {
        var c = audioContext();
        if (!c) return;
        if (c.state === 'suspended') c.resume();
        var n = {
          source: c.createMediaElementSource(p.audio),
          highpass: filter(c, 'highpass', 20, 0.7),
          cabin: filter(c, 'lowshelf', 90, undefined, 0),
          box: filter(c, 'peaking', 250, 1.2, 0),
          dip: filter(c, 'peaking', 2500, 0.9, 0),
          presence: filter(c, 'peaking', 5000, 1.4, 0),
          lowpass: filter(c, 'lowpass', 20000, 0.7),
          shaper: c.createWaveShaper(),
          comp: c.createDynamicsCompressor(),
          split: c.createChannelSplitter(2),
          merge: c.createChannelMerger(2),
          ll: c.createGain(), rl: c.createGain(), rr: c.createGain(), lr: c.createGain(),
          delayR: c.createDelay(0.01),
          pan: c.createStereoPanner ? c.createStereoPanner() : null,
          glitch: c.createGain(),
          dry: c.createGain(),
          cabinWet: c.createGain(),
          outsideWet: c.createGain()
        };
        // Mono files must be upmixed before the splitter, else the right channel stays silent.
        n.comp.channelCount = 2;
        n.comp.channelCountMode = 'explicit';
        n.comp.channelInterpretation = 'speakers';
        n.comp.threshold.value = -20;
        n.comp.knee.value = 12;
        n.comp.ratio.value = 1;
        n.comp.attack.value = 0.01;
        n.comp.release.value = 0.25;

        n.source.connect(n.highpass);
        n.highpass.connect(n.cabin);
        n.cabin.connect(n.box);
        n.box.connect(n.dip);
        n.dip.connect(n.presence);
        n.presence.connect(n.lowpass);
        n.lowpass.connect(n.shaper);
        n.shaper.oversample = '2x';
        n.shaper.connect(n.comp);
        n.comp.connect(n.split);
        // Width matrix: L' = L*ll + R*rl, R' = (R*rr + L*lr) delayed.
        n.split.connect(n.ll, 0); n.ll.connect(n.merge, 0, 0);
        n.split.connect(n.rl, 1); n.rl.connect(n.merge, 0, 0);
        n.split.connect(n.rr, 1); n.rr.connect(n.delayR);
        n.split.connect(n.lr, 0); n.lr.connect(n.delayR);
        n.delayR.connect(n.merge, 0, 1);
        var last = n.merge;
        if (n.pan) { n.merge.connect(n.pan); last = n.pan; }
        // Glitch gain: crash dropouts cut everything after it (dry and reverbs).
        last.connect(n.glitch);
        n.glitch.connect(n.dry);
        n.glitch.connect(n.cabinWet);
        n.glitch.connect(n.outsideWet);
        n.dry.connect(c.destination);
        n.cabinWet.connect(cabinVerb);
        n.outsideWet.connect(outsideVerb);
        p.fx = n;
        applyFx(p, { inside: false, pan: 0 });
      }

      function ramp(param, value) {
        param.setTargetAtTime(value, ctx.currentTime, 0.12);
      }

      // 0 = closed .. 1 = wide open (doors, tailgate, sunroof, broken glass), synced by the owner.
      function openness(p) {
        var s = states[p.vid];
        return s && s.open ? Math.max(0, Math.min(1, s.open)) : 0;
      }

      // 0 = intact .. 1 = wrecked radio, synced by the owner.
      function damageOf(p) {
        var s = states[p.vid];
        return s && s.damage ? Math.max(0, Math.min(1, s.damage)) : 0;
      }

      // Clipping curve with unity gain for quiet signals: tanh(d*x)/d leaves soft parts as they are
      // and squashes the peaks, so a damaged radio sounds harsher and slightly quieter, never louder.
      function distortionCurve(amount) {
        var d = 1 + amount * 8, len = 2048, curve = new Float32Array(len);
        for (var i = 0; i < len; i++) {
          var x = i * 2 / (len - 1) - 1;
          var e = Math.exp(2 * d * x);
          curve[i] = ((e - 1) / (e + 1)) / d;
        }
        return curve;
      }

      // Short burst of radio static (sparse clicks + hiss). It bypasses the media element, so it
      // is scaled by the element's volume to sit at the same level as the music.
      function crackle(p, seconds, level) {
        if (!p.fx || !ctx) return;
        var len = Math.floor(ctx.sampleRate * seconds);
        var buf = ctx.createBuffer(1, len, ctx.sampleRate);
        var d = buf.getChannelData(0);
        for (var i = 0; i < len; i++) {
          var hiss = (Math.random() * 2 - 1) * 0.15;
          d[i] = Math.random() < 0.004 ? (Math.random() * 2 - 1) : hiss;
        }
        var src = ctx.createBufferSource();
        var hp = filter(ctx, 'highpass', 1200, 0.7);
        var g = ctx.createGain();
        g.gain.value = level * p.audio.volume;
        src.buffer = buf;
        src.connect(hp);
        hp.connect(g);
        g.connect(p.fx.dry);
        src.start();
        src.onended = function () { g.disconnect(); };
      }

      // Crash: stutter, dropout, static, then fade back. power 0..1.
      function glitch(p, power) {
        var dropout = 0.15 + 0.85 * power;
        if (!p.fx || !ctx) {
          // Without effects: plain short mute.
          p.audio.volume = 0;
          setTimeout(function () { if (players[p.vid] === p) applyVolume(p); }, dropout * 1000);
          return;
        }
        var g = p.fx.glitch.gain;
        var t = ctx.currentTime;
        g.cancelScheduledValues(t);
        g.setValueAtTime(1, t);
        var stutters = 1 + Math.round(power * 4);
        for (var i = 0; i < stutters; i++) {
          t += 0.03 + Math.random() * 0.08;
          g.setValueAtTime(0, t);
          t += 0.03 + Math.random() * 0.1;
          g.setValueAtTime(0.3 + Math.random() * 0.7, t);
        }
        g.setValueAtTime(0, t);
        t += dropout;
        g.setValueAtTime(0.05, t);
        g.linearRampToValueAtTime(1, t + 0.4);
        crackle(p, (t - ctx.currentTime) + 0.2, 0.15 + 0.35 * power);
      }

      function lerp(a, b, t) { return a + (b - a) * t; }

      function applyFx(p, fx) {
        var n = p.fx;
        if (!n) return;
        fx = fx || { inside: false, pan: 0 };
        var o = openness(p);
        var dmg = damageOf(p);
        if (p.curveDamage !== dmg) {
          p.curveDamage = dmg;
          n.shaper.curve = dmg > 0 ? distortionCurve(dmg) : null;
        }
        // Damaged speakers lose highs; the listener's own closed car muffles outside radios further.
        var dull = (1 - 0.45 * dmg) * (1 - 0.5 * (fx.shield || 0));
        if (fx.inside) {
          // Door woofers can't do sub bass, the closed cabin boosts what's left (cabin gain),
          // boxy 250 Hz resonance, crossover dip, tweeter presence, rolled-off air.
          // Open doors/glass: cabin gain and cabin reflections leak out, some outdoor ambience.
          ramp(n.highpass.frequency, 50);
          ramp(n.cabin.gain, lerp(7, 2, o));
          ramp(n.box.gain, lerp(3, 1, o));
          ramp(n.dip.gain, -3);
          ramp(n.presence.gain, 2.5);
          ramp(n.lowpass.frequency, 11000 * dull);
          ramp(n.comp.ratio, 3);
          // Narrow stereo, driver sits closer to the left speaker: right arrives later and quieter.
          ramp(n.ll.gain, 0.8); ramp(n.rl.gain, 0.2);
          ramp(n.rr.gain, 0.7); ramp(n.lr.gain, 0.15);
          ramp(n.delayR.delayTime, 0.0012);
          if (n.pan) ramp(n.pan.pan, 0);
          ramp(n.dry.gain, 0.6);
          ramp(n.cabinWet.gain, lerp(0.45, 0.15, o));
          ramp(n.outsideWet.gain, 0.08 * o);
        } else {
          // Heard from outside: body + glass cut the highs, bass carries further.
          // Open doors/glass: much clearer, the sound escapes directly.
          var g = Math.max(0, Math.min(1, p.gain));
          ramp(n.highpass.frequency, 30);
          ramp(n.cabin.gain, lerp(8, 4, o));
          ramp(n.box.gain, 2);
          ramp(n.dip.gain, lerp(-6, -2, o));
          ramp(n.presence.gain, lerp(-4, 0, o));
          ramp(n.lowpass.frequency, lerp(350 + 2000 * g, 1500 + 9000 * g, o) * dull);
          ramp(n.comp.ratio, 2);
          // Mono-ish point source, direction comes from the panner.
          ramp(n.ll.gain, 0.5); ramp(n.rl.gain, 0.5);
          ramp(n.rr.gain, 0.5); ramp(n.lr.gain, 0.5);
          ramp(n.delayR.delayTime, 0);
          if (n.pan) ramp(n.pan.pan, fx.pan || 0);
          ramp(n.dry.gain, lerp(0.7, 1.1, o));
          ramp(n.cabinWet.gain, 0);
          ramp(n.outsideWet.gain, 0.12);
        }
      }

      // ---------------------------------------------------------------- live radio
      // The server relays internet stations as base64 MP3 chunks (RadioSyncLiveData). Each player
      // tuned to a live station feeds them into its own MediaSource.

      var LIVE_MAX_BEHIND = 6;   // seconds behind the newest data before jumping forward
      var LIVE_START = 1.0;      // seconds buffered before playback starts
      var liveErrors = {};       // live id -> true after the server reported a dead station

      function stopLive(p) {
        var lv = p.live;
        if (!lv) return;
        try { URL.revokeObjectURL(lv.objUrl); } catch (e) {}
        p.live = null;
      }

      function pumpLive(p, lv) {
        if (p.live !== lv || !lv.sb || lv.sb.updating || lv.ms.readyState !== 'open') return;
        var b = lv.sb.buffered;
        // Drop audio played long ago so memory stays small.
        if (b.length && p.audio.currentTime - b.start(0) > 60) {
          lv.sb.remove(b.start(0), p.audio.currentTime - 20);
          return;
        }
        if (!lv.queue.length) return;
        var size = 0, i;
        for (i = 0; i < lv.queue.length; i++) size += lv.queue[i].length;
        var data = new Uint8Array(size), off = 0;
        for (i = 0; i < lv.queue.length; i++) { data.set(lv.queue[i], off); off += lv.queue[i].length; }
        lv.queue = [];
        try { lv.sb.appendBuffer(data); } catch (e) { /* quota or parse error: skip piece */ }
      }

      function startLive(p, liveId) {
        stopLive(p);
        if (!window.MediaSource || !MediaSource.isTypeSupported('audio/mpeg')) {
          p.error = { key: 'liveUnsupported' };
          return;
        }
        var lv = { id: liveId, ms: new MediaSource(), sb: null, queue: [], gotData: false, since: performance.now() };
        lv.objUrl = URL.createObjectURL(lv.ms);
        p.live = lv;
        lv.ms.addEventListener('sourceopen', function () {
          if (p.live !== lv) return;
          try {
            lv.sb = lv.ms.addSourceBuffer('audio/mpeg');
          } catch (e) {
            p.error = { key: 'mp3Unsupported' };
            return;
          }
          lv.sb.addEventListener('updateend', function () { pumpLive(p, lv); });
          pumpLive(p, lv);
        });
        p.audio.src = lv.objUrl;
      }

      // Start once enough is buffered, stay close to the newest data (all players hear the same).
      function keepLive(p, wantPlay) {
        var lv = p.live;
        if (!lv || !lv.sb) return;
        var b = lv.sb.buffered;
        if (!b.length) return;
        var end = b.end(b.length - 1);
        if (end - p.audio.currentTime > LIVE_MAX_BEHIND || p.audio.currentTime < b.start(0)) {
          p.audio.currentTime = Math.max(b.start(0), end - 1.5);
        }
        if (wantPlay && p.audio.paused && end - b.start(0) >= LIVE_START) {
          var r = p.audio.play();
          if (r && r.catch) r.catch(function () {});
        }
      }

      scope.$on('RadioSyncLiveData', function (e, data) {
        if (!data || !data.id || !data.data) return;
        var bytes = null;
        for (var vid in players) {
          var p = players[vid];
          if (!p.live || p.live.id !== data.id) continue;
          if (!bytes) {
            var bin = atob(data.data);
            bytes = new Uint8Array(bin.length);
            for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
          }
          p.live.queue.push(bytes);
          p.live.gotData = true;
          pumpLive(p, p.live);
          var s = states[vid];
          keepLive(p, s && !s.paused);
        }
        if (liveErrors[data.id]) {
          delete liveErrors[data.id];
          scope.$evalAsync(updatePanel);
        }
      });

      scope.$on('RadioSyncLiveError', function (e, data) {
        if (!data || !data.id) return;
        scope.$evalAsync(function () {
          liveErrors[data.id] = true;
          updatePanel();
        });
      });

      scope.$on('RadioSyncLiveMeta', function (e, data) {
        if (!data || !data.id) return;
        scope.$evalAsync(function () {
          (scope.config.liveStations || []).forEach(function (st) {
            if (st.id === data.id) st.nowPlaying = data.title;
          });
        });
      });

      scope.liveNowPlaying = function (id) {
        var list = scope.config.liveStations || [];
        for (var i = 0; i < list.length; i++) {
          if (list[i].id === id) return list[i].nowPlaying || '';
        }
        return '';
      };

      // ---------------------------------------------------------------- cover art
      // Read from the ID3v2 tag (APIC / v2.2 PIC frame) of the locally cached song file.

      var covers = {};   // file -> object URL, or null while loading / when there is none

      function syncsafe(u, i) {
        return ((u[i] & 0x7f) << 21) | ((u[i + 1] & 0x7f) << 14) | ((u[i + 2] & 0x7f) << 7) | (u[i + 3] & 0x7f);
      }

      function parseCover(u) {
        if (u.length < 10 || u[0] !== 0x49 || u[1] !== 0x44 || u[2] !== 0x33) return null;   // "ID3"
        var ver = u[3], flags = u[5];
        var end = Math.min(u.length, 10 + syncsafe(u, 6));
        var pos = 10;
        if (flags & 0x40) {
          pos += ver === 4 ? syncsafe(u, 10) : 4 + ((u[10] << 24) | (u[11] << 16) | (u[12] << 8) | u[13]);
        }
        while (pos + 10 < end) {
          var id, size, hdr;
          if (ver === 2) {
            id = String.fromCharCode(u[pos], u[pos + 1], u[pos + 2]);
            size = (u[pos + 3] << 16) | (u[pos + 4] << 8) | u[pos + 5];
            hdr = 6;
          } else {
            id = String.fromCharCode(u[pos], u[pos + 1], u[pos + 2], u[pos + 3]);
            size = ver === 4 ? syncsafe(u, pos + 4)
              : ((u[pos + 4] << 24) | (u[pos + 5] << 16) | (u[pos + 6] << 8) | u[pos + 7]) >>> 0;
            hdr = 10;
          }
          if (!u[pos] || size <= 0) break;
          var b = pos + hdr, fend = Math.min(end, b + size);
          if (id === 'APIC' || id === 'PIC') {
            var enc = u[b], p = b + 1, mime;
            if (id === 'PIC') {
              var fmt = String.fromCharCode(u[p], u[p + 1], u[p + 2]).toLowerCase();
              mime = fmt === 'png' ? 'image/png' : 'image/jpeg';
              p += 3;
            } else {
              var m = p;
              while (p < fend && u[p] !== 0) p++;
              mime = String.fromCharCode.apply(null, u.subarray(m, p)) || 'image/jpeg';
              if (mime.indexOf('/') === -1) mime = 'image/' + mime.toLowerCase();
              p++;
            }
            p++;   // picture type
            // Description, terminated by 0x00 (Latin-1/UTF-8) or 0x00 0x00 (UTF-16).
            if (enc === 1 || enc === 2) {
              while (p + 1 < fend && !(u[p] === 0 && u[p + 1] === 0)) p += 2;
              p += 2;
            } else {
              while (p < fend && u[p] !== 0) p++;
              p++;
            }
            if (p < fend) return { mime: mime, data: u.subarray(p, fend) };
          }
          pos = b + size;
        }
        return null;
      }

      function loadCover(file) {
        if (file in covers || !window.fetch) return;
        covers[file] = null;
        var url = resolveUrl('music:' + file);
        if (!url) { delete covers[file]; return; }
        fetch(url).then(function (r) { return r.arrayBuffer(); }).then(function (buf) {
          var img = parseCover(new Uint8Array(buf));
          if (img) covers[file] = URL.createObjectURL(new Blob([img.data], { type: img.mime }));
          scope.$evalAsync(updatePanel);
        }).catch(function () {});
      }

      // ---------------------------------------------------------------- players

      var songReady = {};   // file -> true once cached locally

      function musicFile(url) {
        return url && url.indexOf('music:') === 0 ? url.substring(6) : null;
      }

      // "music:<path>" = song from the server music folder, cached in the game's VFS.
      // Returns null while the song is still downloading.
      function resolveUrl(url) {
        var file = musicFile(url);
        if (file === null || !songReady[file]) return null;
        var dir = scope.config.musicDir || '/ui/modules/apps/RadioSync/music/';
        return dir + file.split('/').map(encodeURIComponent).join('/');
      }

      function destroyPlayer(vid) {
        var p = players[vid];
        if (!p) return;
        stopLive(p);
        p.audio.pause();
        p.audio.removeAttribute('src');
        p.audio.load();
        if (p.fx) p.fx.source.disconnect();
        delete players[vid];
      }

      function createPlayer(vid) {
        var audio = new Audio();
        audio.preload = 'auto';
        var p = { vid: vid, audio: audio, url: null, seq: null, gain: 0, zeroSince: null, error: null, fx: null };
        p.fxCapable = canFx();
        if (p.fxCapable) buildFx(p);

        audio.addEventListener('loadedmetadata', function () {
          var b = playback(vid);
          if (!b || !isFinite(audio.duration)) return;
          var file = musicFile(b.url);
          if (file) lua('songDuration', { file: file, duration: audio.duration });
          var t = expectedTime(b);
          if (t < audio.duration) audio.currentTime = t;
          // Playlist song finished while we were still downloading it.
          if (!b.station && isMine(vid) && t >= audio.duration && !b.paused) lua('ended', { vid: vid, seq: b.seq });
        });
        audio.addEventListener('ended', function () {
          var b = playback(vid);
          if (b && !b.station && isMine(vid)) lua('ended', { vid: vid, seq: b.seq });
        });
        audio.addEventListener('error', function () {
          if (!audio.getAttribute('src')) return;
          var code = audio.error ? audio.error.code : 0;
          var detail = audio.error && audio.error.message ? ' – ' + audio.error.message.substring(0, 120) : '';
          p.error = { key: 'songError', a: code, b: detail };
          if (window.console) console.warn('[RadioSync] audio error', code, detail, audio.src);
          scope.$evalAsync(updatePanel);
        });
        audio.addEventListener('playing', function () {
          p.error = null;
          scope.$evalAsync(updatePanel);
        });

        players[vid] = p;
        return p;
      }

      // Slider 0..1 -> output level. Quadratic curve, 100% = MAX_OUTPUT (game audio is loud).
      var MAX_OUTPUT = 0.06;
      function applyVolume(p) {
        var x = parseFloat(scope.settings.volume) || 0;
        var v = scope.settings.muted ? 0 : p.gain * x * x * MAX_OUTPUT;
        p.audio.volume = Math.max(0, Math.min(1, v));
      }

      function syncPlayer(vid) {
        var b = playback(vid);
        var p = players[vid];
        if (!states[vid]) { destroyPlayer(vid); return; }
        if (!p) return;
        if (!b) {
          // Station without a song yet, or empty playlist.
          if (p.url !== null) { p.audio.pause(); p.audio.removeAttribute('src'); p.url = null; }
          return;
        }

        var audio = p.audio;
        if (p.url !== b.url || p.seq !== b.seq) {
          if (p.fxCapable !== canFx()) {
            // Effects on/off needs a fresh element (a routed element can't be un-routed).
            var gain = p.gain;
            destroyPlayer(vid);
            p = createPlayer(vid);
            p.gain = gain;
            applyVolume(p);
            applyFx(p, fxMap[vid]);
            audio = p.audio;
          }
          if (b.live) {
            p.url = b.url;
            p.seq = b.seq;
            p.error = null;
            startLive(p, b.liveId);
            return;
          }
          stopLive(p);
          var src = resolveUrl(b.url);
          if (src === null) {
            // Not downloaded yet: stay silent, retried when the cache reports it ready.
            if (p.url !== null) { audio.pause(); audio.removeAttribute('src'); }
            p.url = null;
            return;
          }
          p.url = b.url;
          p.seq = b.seq;
          p.error = null;
          audio.src = src;
        }

        if (b.live) {
          // Paused: stays silent; on resume keepLive jumps to the newest data.
          if (b.paused) {
            if (!audio.paused) audio.pause();
          } else {
            keepLive(p, true);
          }
          return;
        }

        if (b.paused) {
          if (!audio.paused) audio.pause();
          if (!b.station && audio.readyState >= 1 && Math.abs(audio.currentTime - (b.elapsed || 0)) > 0.25) {
            audio.currentTime = b.elapsed || 0;
          }
          return;
        }

        if (audio.readyState >= 1 && isFinite(audio.duration)) {
          var t = expectedTime(b);
          if (t < audio.duration && Math.abs(audio.currentTime - t) > DRIFT_LIMIT) audio.currentTime = t;
        }
        if (audio.paused && !audio.ended) {
          var r = audio.play();
          if (r && r.catch) r.catch(function () {});
        }
      }

      function updatePlayers() {
        if (retired()) {
          for (var old in players) destroyPlayer(old);
          return;
        }
        var now = performance.now();
        for (var vid in states) {
          var g = gains[vid] || 0;
          var p = players[vid];
          // Owner keeps its own radios loaded so "ended" is always reported.
          var keep = g > 0 || isMine(vid);
          if (!p && keep) {
            p = createPlayer(vid);
            p.gain = g;
            applyVolume(p);
            syncPlayer(vid);
          }
          if (!p) continue;
          p.gain = g;
          applyVolume(p);
          applyFx(p, fxMap[vid]);
          if (keep) {
            p.zeroSince = null;
          } else if (p.zeroSince === null) {
            p.zeroSince = now;
          } else if (now - p.zeroSince > DESTROY_AFTER) {
            destroyPlayer(vid);
          }
        }
        for (var v in players) {
          if (!states[v]) destroyPlayer(v);
        }
      }

      // ---------------------------------------------------------------- panel

      function updatePanel() {
        var vid = null;
        if (scope.current && states[scope.current]) {
          vid = scope.current;
        } else {
          var best = 0;
          for (var v in gains) {
            if (states[v] && gains[v] > best) { best = gains[v]; vid = v; }
          }
        }
        scope.shownVid = vid;
        scope.state = vid ? states[vid] : null;
        scope.station = scope.state && scope.state.mode === 'station' ? stations[scope.state.station] || null : null;
        var p = vid && players[vid];
        var b = vid && playback(vid);
        var waiting = b && musicFile(b.url);

        // Cover of the current song (only for songs already in the local cache).
        scope.cover = null;
        if (waiting && songReady[waiting]) {
          loadCover(waiting);
          scope.cover = covers[waiting] || null;
        }
        if (scope.state && !ownerVolDragging) scope.ownerVol.value = scope.state.volume !== undefined ? scope.state.volume : 0.7;
        var t = scope.t;
        if (b && b.live && liveErrors[b.liveId]) {
          scope.status = t('liveDown');
          scope.statusInfo = false;
        } else if (b && b.live && p && p.live && !p.live.gotData && !b.paused) {
          scope.status = t('connecting');
          scope.statusInfo = true;
        } else if (waiting && !songReady[waiting]) {
          var dl = scope.download;
          scope.status = t('songLoading') + (dl && dl.file === waiting ? ' ' + dl.pct + '%' : t('inQueue'));
          scope.statusInfo = true;
        } else {
          scope.status = p && p.error ? t(p.error.key, p.error.a, p.error.b) : '';
          scope.statusInfo = false;
        }
      }

      // Station title as shown: the server's "mix" station gets a translated name.
      scope.stationTitle = function (st) {
        if (!st) return '';
        return st.id === 'mix' ? scope.t('mix') : st.title;
      };

      scope.carStationTitle = function () {
        var s = scope.state;
        if (!s) return '';
        return s.station === 'mix' && s.mode === 'station' ? scope.t('mix') : s.title;
      };

      scope.nowTitle = function () {
        if (!scope.state) return scope.t('radioOff');
        if (scope.state.mode === 'live') return scope.liveNowPlaying(scope.state.station) || scope.state.title;
        if (scope.station) return scope.station.songTitle || scope.stationTitle(scope.station);
        return scope.state.title || scope.t('playlistEmptyTitle');
      };

      // ---------------------------------------------------------------- events

      function setState(vid, s) {
        if (s && typeof s === 'object') {
          var prev = states[vid];
          s.recvAt = performance.now();
          states[vid] = s;
          syncPlayer(vid);
          // New crash since the last state (not on first sight, e.g. after joining).
          if (prev && (s.crashSeq || 0) > (prev.crashSeq || 0) && players[vid]) {
            glitch(players[vid], s.crashPower || 0.5);
          }
        } else {
          delete states[vid];
          destroyPlayer(vid);
        }
      }

      scope.$on('RadioSyncConfig', function (e, data) {
        scope.$evalAsync(function () {
          scope.config = data || {};
          if (!Array.isArray(scope.config.songs)) scope.config.songs = [];
          songReady = {};
          scope.config.songs.forEach(function (s) { if (s.ready) songReady[s.file] = true; });
          // Songs that just finished downloading start playing now.
          for (var vid in players) syncPlayer(vid);
          updatePanel();
        });
      });

      scope.$on('RadioSyncStations', function (e, data) {
        scope.$evalAsync(function () {
          var now = performance.now();
          stations = {};
          scope.stationList = Array.isArray(data) ? data : [];
          scope.stationList.forEach(function (st) {
            st.recvAt = now;
            stations[st.id] = st;
          });
          for (var vid in players) syncPlayer(vid);
          updatePlayers();
          updatePanel();
        });
      });

      scope.download = null;   // { file, pct, left } of the running song download
      scope.$on('RadioSyncDownload', function (e, data) {
        scope.$evalAsync(function () {
          scope.download = data && data.file ? data : null;
          updatePanel();
        });
      });

      scope.songState = function (s) {
        if (s.ready) return 'ready';
        if (scope.download && scope.download.file === s.file) return 'loading';
        return 'queued';
      };

      scope.$on('RadioSyncSnapshot', function (e, data) {
        scope.$evalAsync(function () {
          for (var vid in states) {
            if (!data || !data[vid]) setState(vid, null);
          }
          if (data && typeof data === 'object') {
            for (var v in data) setState(v, data[v]);
          }
          updatePlayers();
          updatePanel();
        });
      });

      scope.$on('RadioSyncState', function (e, data) {
        if (!data || typeof data.vid !== 'string') return;
        scope.$evalAsync(function () {
          setState(data.vid, data.state);
          updatePlayers();
          updatePanel();
        });
      });

      scope.$on('RadioSyncGains', function (e, data) {
        if (!data) return;
        scope.$evalAsync(function () {
          gains = data.gains && !Array.isArray(data.gains) ? data.gains : {};
          fxMap = data.fx && !Array.isArray(data.fx) ? data.fx : {};
          scope.current = data.current || null;
          scope.own = !!data.own;
          if (data.myPid !== undefined && data.myPid !== null) myPid = data.myPid;
          updatePlayers();
          updatePanel();
        });
      });

      var driftTimer = setInterval(function () {
        for (var vid in players) syncPlayer(vid);
      }, 2000);

      // The browser may start the AudioContext suspended until a user gesture.
      function resumeAudio() {
        if (ctx && ctx.state === 'suspended') ctx.resume();
      }
      element[0].addEventListener('mousedown', resumeAudio, true);

      // Progress bar + equalizer state of the shown radio.
      var progressTimer = setInterval(function () {
        resumeAudio();
        scope.$evalAsync(updateLanguage);
        // Badly damaged radios cut out now and then.
        for (var id in players) {
          var dmg = damageOf(players[id]);
          if (dmg > 0.5 && !players[id].audio.paused && Math.random() < (dmg - 0.5) * 0.12) {
            glitch(players[id], 0.1);
          }
        }
        scope.$evalAsync(function () {
          var p = scope.shownVid && players[scope.shownVid];
          var s = scope.state;
          if (!p || !s) {
            scope.progress = { cur: 0, dur: 0, pct: 0 };
            scope.playing = false;
            return;
          }
          var dur = isFinite(p.audio.duration) ? p.audio.duration : 0;
          var cur = p.audio.currentTime || 0;
          scope.progress = { cur: cur, dur: dur, pct: dur ? Math.min(100, cur / dur * 100) : 0 };
          scope.playing = !p.audio.paused && !s.paused && p.gain > 0;
          scope.audioBlocked = !!(p.fx && ctx && ctx.state === 'suspended');
        });
      }, 500);

      scope.$on('$destroy', function () {
        clearInterval(driftTimer);
        clearInterval(progressTimer);
        // The shared AudioContext stays open for the next app instance.
        for (var vid in players) destroyPlayer(vid);
      });

      // ---------------------------------------------------------------- UI actions

      scope.canControl = function () {
        return scope.own && !!scope.current;
      };

      scope.isTrack = function () {
        return !!scope.state && scope.state.mode === 'track';
      };

      scope.selectStation = function (st) {
        ownerCmd('setStation', { stationId: st.id });
      };

      scope.selectLive = function (st) {
        ownerCmd('setLive', { liveId: st.id });
      };

      scope.liveList = function () {
        return Array.isArray(scope.config.liveStations) ? scope.config.liveStations : [];
      };

      scope.songFilter = { text: '' };

      scope.filteredSongs = function () {
        var q = (scope.songFilter.text || '').toLowerCase();
        if (!q) return scope.config.songs;
        return scope.config.songs.filter(function (s) { return s.title.toLowerCase().indexOf(q) !== -1; });
      };

      scope.addSong = function (song) {
        ownerCmd('addSongs', { files: [song.file] });
      };

      scope.addAllSongs = function () {
        var files = scope.filteredSongs().map(function (s) { return s.file; });
        if (files.length) ownerCmd('addSongs', { files: files });
      };

      scope.control = function (cmd) { ownerCmd('control', { cmd: cmd }); };

      // Owner volume ("for everyone"): sent at most every 250 ms while dragging.
      scope.ownerVol = { value: 0.7 };
      var ownerVolDragging = false, ownerVolTimer = null;
      scope.ownerVolumeChanged = function () {
        ownerVolDragging = true;
        if (ownerVolTimer) clearTimeout(ownerVolTimer);
        ownerVolTimer = setTimeout(function () {
          ownerCmd('control', { cmd: 'volume', value: parseFloat(scope.ownerVol.value) || 0 });
          // Let the server's echo arrive before the slider follows the state again.
          setTimeout(function () { ownerVolDragging = false; }, 600);
        }, 250);
      };

      var LOOP_NEXT = { all: 'one', one: 'off', off: 'all' };
      var LOOP_TITLE = { all: 'loopAll', one: 'loopOne', off: 'loopOff' };
      scope.loopMode = function () { return (scope.state && scope.state.loop) || 'all'; };
      scope.loopTitle = function () { return scope.t(LOOP_TITLE[scope.loopMode()]); };
      scope.cycleLoop = function () {
        ownerCmd('control', { cmd: 'loop', mode: LOOP_NEXT[scope.loopMode()] });
      };
      scope.playIndex = function (i) { ownerCmd('playIndex', { index: i + 1 }); };
      scope.removeTrack = function (i) { ownerCmd('removeTrack', { index: i + 1 }); };

      scope.setTab = function (tab) {
        scope.settings.tab = tab;
        saveSettings();
      };

      scope.toggleCollapsed = function () {
        scope.settings.collapsed = !scope.settings.collapsed;
        saveSettings();
      };

      scope.fmt = function (t) {
        if (!t || !isFinite(t)) return '0:00';
        var m = Math.floor(t / 60), sec = Math.floor(t % 60);
        return m + ':' + (sec < 10 ? '0' : '') + sec;
      };

      scope.seekTo = function (event) {
        if (!scope.canControl() || !scope.isTrack() || !scope.progress.dur) return;
        var rect = event.currentTarget.getBoundingClientRect();
        var frac = Math.max(0, Math.min(1, (event.clientX - rect.left) / rect.width));
        ownerCmd('control', { cmd: 'seek', pos: frac * scope.progress.dur });
      };

      scope.toggleRealistic = function () {
        scope.settings.realistic = !scope.settings.realistic;
        saveSettings();
        // Rebuild every player with or without the effect chain.
        for (var vid in players) destroyPlayer(vid);
        updatePlayers();
      };

      scope.toggleMute = function () {
        scope.settings.muted = !scope.settings.muted;
        saveSettings();
        for (var vid in players) applyVolume(players[vid]);
      };

      scope.volumeChanged = function () {
        scope.settings.volume = parseFloat(scope.settings.volume) || 0;
        saveSettings();
        for (var vid in players) applyVolume(players[vid]);
      };

      // Keep game controls from reacting while typing.
      scope.inputFocus = function (focused) {
        bngApi.engineLua('setCEFFocus(' + (focused ? 'true' : 'false') + ')');
      };

      // Vehicle diagnose (door/window data for later automatic detection).
      scope.diagnose = null;   // { text, path, run }
      scope.runDiagnose = function () {
        scope.diagnose = { text: scope.t('collecting') };
        lua('diagnose');
      };
      scope.closeDiagnose = function () { scope.diagnose = null; };
      scope.$on('RadioSyncDiagnose', function (e, data) {
        scope.$evalAsync(function () {
          if (data && data.code) data.text = scope.t(data.code);
          scope.diagnose = data || null;
        });
      });

      scope.queueIsArray = function () {
        return scope.state && Array.isArray(scope.state.queue) && scope.state.queue.length > 0;
      };

      lua('uiReady');
    }
  };
}]);
