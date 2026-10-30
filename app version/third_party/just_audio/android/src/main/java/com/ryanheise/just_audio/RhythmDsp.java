package com.ryanheise.just_audio;

/** Allocation-free five-band PCM equalizer; all filter state belongs to the audio thread. */
public final class RhythmDsp {
    public static final int BANDS = 5, WAVE = 64;
    private static final double[] FREQUENCIES = {60, 230, 910, 3600, 14000};
    private volatile double[] targets = new double[BANDS];
    private volatile boolean enabled = true, visualizing;
    private volatile float[] waveform = new float[WAVE];
    private final double[] gains = new double[BANDS];
    private final double[][] coefficients = new double[BANDS][5];
    private final double[][] z1 = new double[8][BANDS], z2 = new double[8][BANDS];
    private final float[] capture = new float[WAVE];
    private double rate = 48000, preamp = 1;
    private int waveFrame;
    private boolean flat = true;

    public void configure(double[] values, boolean active) {
        double[] next = new double[BANDS];
        for (int i=0; i<BANDS; i++) next[i] = i<values.length && Double.isFinite(values[i]) ? Math.max(-12, Math.min(12, values[i])) : 0;
        targets = next;
        enabled = active;
    }
    public void visualize(boolean active) { visualizing = active; }
    public float[] waveform() { return waveform; }
    public void reset(int sampleRate) {
        rate = sampleRate;
        waveFrame = 0;
        for (int c=0; c<8; c++) { java.util.Arrays.fill(z1[c], 0); java.util.Arrays.fill(z2[c], 0); }
        java.util.Arrays.fill(capture, 0);
        waveform = new float[WAVE];
    }
    public void begin(int frames) {
        double[] next = targets;
        boolean wasFlat = flat;
        flat = true;
        double mix = 1-Math.exp(-frames/(rate*.02)), maximum = 0;
        for (int b=0; b<BANDS; b++) {
            gains[b] += ((enabled ? next[b] : 0)-gains[b])*mix;
            if (Math.abs(gains[b])<.001) gains[b] = 0;
            if (gains[b]!=0) flat = false;
            maximum = Math.max(maximum, gains[b]);
            double w = 2*Math.PI*Math.min(FREQUENCIES[b],rate*.45)/rate;
            double a = Math.pow(10,gains[b]/40), alpha = Math.sin(w)/(2*.85), a0 = 1+alpha/a;
            double[] q = coefficients[b];
            q[0]=(1+alpha*a)/a0; q[1]=-2*Math.cos(w)/a0; q[2]=(1-alpha*a)/a0;
            q[3]=-2*Math.cos(w)/a0; q[4]=(1-alpha/a)/a0;
        }
        preamp = Math.pow(10,-maximum/20);
        if (flat && !wasFlat) {
            for (int c=0;c<8;c++) { java.util.Arrays.fill(z1[c],0); java.util.Arrays.fill(z2[c],0); }
        }
    }
    public float sample(float value, int channel) {
        double x = value*preamp;
        for (int b=0; !flat && b<BANDS; b++) {
            double[] q = coefficients[b];
            double y = q[0]*x+z1[channel][b];
            z1[channel][b] = q[1]*x-q[3]*y+z2[channel][b];
            z2[channel][b] = q[2]*x-q[4]*y;
            x=y;
        }
        float out = (float)Math.max(-1,Math.min(1,x));
        if (channel==0 && visualizing) {
            int bucket = waveFrame*WAVE/2048;
            if (Math.abs(out)>Math.abs(capture[bucket])) capture[bucket]=out;
            if (++waveFrame==2048) {
                waveform=capture.clone();
                java.util.Arrays.fill(capture,0);
                waveFrame=0;
            }
        }
        return out;
    }
}
