# Native equalizer checks

From the app directory, the portable Apple DSP signal test runs without audio hardware:

```sh
clang -std=c11 tool/native/equalizer_test.c -o /tmp/rhythm-eq-test
/tmp/rhythm-eq-test
```

With JDK 17 or newer, check the Android filter independently of Android hardware:

```sh
javac -d /tmp/rhythm-eq-classes third_party/just_audio/android/src/main/java/com/ryanheise/just_audio/RhythmDsp.java tool/native/RhythmDspTest.java
java -cp /tmp/rhythm-eq-classes RhythmDspTest
```

Both tests measure each band using sine tones, check bypass, compare bass emphasis, and verify measured waveform samples. The Android PCM adapter also compiles against Media3 1.4.1's `media3-common` classes.

On macOS, `apple_audio_mix_test.m` exercises the real AVFoundation audio mixer and MediaToolbox tap. Supply a mono, 48 kHz, two-second WAV containing a 910 Hz sine tone; the expected measured cut is 12 dB. It renders offline without playing sound:

```sh
clang -fobjc-arc -fmodules -Wno-deprecated-declarations tool/native/apple_audio_mix_test.m third_party/just_audio/darwin/just_audio/Sources/just_audio/RhythmEqualizer.m -framework AVFoundation -framework MediaToolbox -framework Foundation -framework CoreMedia -o /tmp/rhythm-apple-eq-test
/tmp/rhythm-apple-eq-test /path/to/910hz.wav
```

These checks do not replace Android/iOS device builds and listening checks, including streaming AAC, saved audio, pause/resume, seeking, route changes, background playback and EQ bypass.
