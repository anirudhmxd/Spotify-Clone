import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as native;
import 'package:rhythm/brand.dart';
import 'package:rhythm/models/experience.dart';
import 'package:rhythm/music_controller.dart';
import 'package:rhythm/services/audio_engine.dart';
import 'package:rhythm/widgets/equalizer_panel.dart';
import 'fakes.dart';

class _EqAudio extends FakeAudio {
  final applied = <List<double>>[];
  final enabledStates = <bool>[];
  Completer<void>? gate;
  bool fail = false;
  int waveformReads = 0;
  @override
  bool get supportsEqualizer => true;
  @override
  Future<void> setEqualizer(List<double> gains, {bool enabled = true}) async {
    applied.add([...gains]);
    enabledStates.add(enabled);
    await gate?.future;
    if (fail) throw StateError('Native EQ unavailable');
  }

  @override
  Future<List<double>> waveform({bool enabled = true}) async {
    if (!enabled) return [];
    waveformReads++;
    return List.generate(64, (i) => .4 * sin(i * .4));
  }
}

class _Repository extends FakeRepository {
  final saved = <AppSettings>[];
  @override
  Future<void> saveSettings(AppSettings value) async {
    saved.add(value);
  }
}

class _NativePlayer extends Fake implements native.AudioPlayer {
  List<double>? gains;
  bool? enabled;
  @override
  Future<void> setRhythmEqualizer(
    List<double> values, {
    bool enabled = true,
  }) async {
    gains = values;
    this.enabled = enabled;
  }

  @override
  Future<Map<String, dynamic>> rhythmWaveform({bool enabled = true}) async => {
    'samples': [.1, -.2, .3],
    'supported': true,
  };
}

Widget eq(MusicController c) => MaterialApp(
  theme: RhythmBrand.theme,
  home: Scaffold(
    body: SingleChildScrollView(child: EqualizerPanel(controller: c)),
  ),
);

void main() {
  test('settings migrate old presets and persist bounded custom bands', () {
    expect(AppSettings.fromJson({'equalizer': 'bass'}).eqGains, [
      6,
      4,
      0,
      -1,
      -1,
    ]);
    final settings = AppSettings.fromJson({
      'equalizer': 'custom',
      'equalizerBands': [99, -99, double.nan, 3.5, 0],
      'equalizerEnabled': false,
    });
    expect(settings.eqGains, [12, -12, 0, 3.5, 0]);
    final saved = AppSettings.fromJson(settings.toJson());
    expect(saved.eqGains, settings.eqGains);
    expect(saved.equalizerEnabled, isFalse);
  });
  test(
    'engine forwards band gains and measured waveform to native playback',
    () async {
      final player = _NativePlayer();
      final engine = JustAudioEngine(player: player);
      await engine.setEqualizer([1, 2, 3, 4, 5], enabled: false);
      expect(player.gains, [1, 2, 3, 4, 5]);
      expect(player.enabled, isFalse);
      expect(await engine.waveform(), [.1, -.2, .3]);
    },
  );
  testWidgets(
    'live band changes do not reload, seek, or pause the song; saving is debounced',
    (tester) async {
      final audio = _EqAudio();
      final repo = _Repository();
      final c = MusicController(repo, audio);
      addTearDown(c.dispose);
      await c.playTracks([song('seed0000001')], 0);
      audio.tick(const Duration(seconds: 30));
      audio.applied.clear();
      c.setEqualizerBand(0, 2);
      c.setEqualizerBand(0, 4);
      c.setEqualizerBand(0, 6);
      await tester.pump(const Duration(milliseconds: 25));
      expect(audio.applied, [
        [6, 0, 0, 0, 0],
      ]);
      expect(audio.files, hasLength(1));
      expect(audio.playing, isTrue);
      expect(audio.position, const Duration(seconds: 30));
      expect(repo.saved, isEmpty);
      await tester.pump(const Duration(milliseconds: 500));
      expect(repo.saved.single.eqGains, [6, 0, 0, 0, 0]);
      c.enableEqualizer(false);
      await tester.pump(const Duration(milliseconds: 25));
      expect(audio.enabledStates.last, isFalse);
      await tester.pump(const Duration(milliseconds: 500));
    },
  );
  testWidgets(
    'slow native updates finish with the latest curve, not an older drag value',
    (tester) async {
      final audio = _EqAudio()..gate = Completer<void>();
      final c = MusicController(_Repository(), audio);
      addTearDown(c.dispose);
      c.setEqualizerBand(1, 2);
      await tester.pump(const Duration(milliseconds: 25));
      c.setEqualizerBand(1, 8);
      await tester.pump(const Duration(milliseconds: 25));
      audio.gate!.complete();
      await tester.pump();
      expect(audio.applied.first, [0, 2, 0, 0, 0]);
      expect(audio.applied.last, [0, 8, 0, 0, 0]);
      await tester.pump(const Duration(milliseconds: 500));
    },
  );
  testWidgets(
    'native failures are visible instead of claiming an audible adjustment',
    (tester) async {
      final audio = _EqAudio()..fail = true;
      final c = MusicController(_Repository(), audio);
      addTearDown(c.dispose);
      c.setEqualizerPreset('bass');
      await tester.pump(const Duration(milliseconds: 25));
      expect(c.equalizerError, isNotNull);
      await tester.pumpWidget(eq(c));
      expect(find.textContaining('could not be applied'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
    },
  );
  for (final width in [360.0, 1280.0]) {
    testWidgets(
      'graph and live waveform work at width $width; polling stops when closed',
      (tester) async {
        tester.view.physicalSize = Size(width, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final audio = _EqAudio();
        final c = MusicController(_Repository(), audio);
        addTearDown(c.dispose);
        await c.playTracks([song('seed0000001')], 0);
        await tester.pumpWidget(eq(c));
        await tester.pump(const Duration(milliseconds: 60));
        expect(audio.waveformReads, greaterThan(0));
        expect(find.byType(DropdownButton<String>), findsNothing);
        final graph = find.byKey(const ValueKey('equalizer-graph'));
        await tester.dragFrom(tester.getCenter(graph), const Offset(0, -45));
        await tester.pump(const Duration(milliseconds: 40));
        expect(c.settings.eqGains[2], greaterThan(0));
        expect(audio.applied.last[2], greaterThan(0));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        final reads = audio.waveformReads;
        await tester.pump(const Duration(seconds: 1));
        expect(audio.waveformReads, reads);
      },
    );
  }
}
