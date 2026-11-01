package com.ryanheise.just_audio;

import androidx.media3.common.C;
import androidx.media3.common.audio.BaseAudioProcessor;
import java.nio.ByteBuffer;

/** Runs after ExoPlayer's PCM conversion, before output. No microphone access. */
public final class RhythmAudioProcessor extends BaseAudioProcessor {
    public final RhythmDsp dsp = new RhythmDsp();
    private int channels = 2, sampleRate = 48000;
    @Override
    protected AudioFormat onConfigure(AudioFormat format) throws UnhandledAudioFormatException {
        if (format.encoding!=C.ENCODING_PCM_16BIT || format.channelCount>8 || format.channelCount<1)
            throw new UnhandledAudioFormatException(format);
        channels=format.channelCount;
        sampleRate=format.sampleRate;
        return format;
    }
    @Override
    protected void onFlush() { dsp.reset(sampleRate); }
    @Override
    public void queueInput(ByteBuffer input) {
        int bytes=input.remaining();
        ByteBuffer output=replaceOutputBuffer(bytes);
        dsp.begin(bytes/(channels*2));
        int channel=0;
        while (input.remaining()>=2) {
            float value=input.getShort()/32768f;
            float filtered=dsp.sample(value,channel);
            output.putShort((short)Math.max(-32768,Math.min(32767,Math.round(filtered*32768))));
            channel=(channel+1)%channels;
        }
        output.flip();
    }
}
