#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include "../../third_party/just_audio/darwin/just_audio/Sources/just_audio/RhythmDSP.h"
static double tone(double frequency, int band, int gain, bool enabled) {
    RhythmControl c; rh_control_init(&c);
    atomic_store(&c.enabled, enabled);
    if (band>=0) atomic_store(&c.gains[band], gain*100);
    atomic_store(&c.visualizing,true);
    RhythmDSP d; rh_reset(&d,48000);
    double energy=0;
    for (int offset=0;offset<96000;offset+=240) {
        rh_begin(&d,&c,240);
        for (int i=offset;i<offset+240;i++) {
            float in=.05*sin(2*3.141592653589793*frequency*i/48000);
            float out=rh_sample(&d,in,0);
            assert(isfinite(out) && fabsf(out)<=1);
            rh_capture(&d,&c,out);
            if (i>48000) energy+=out*out;
        }
    }
    int peak=0; for (int i=0;i<RH_WAVE;i++) peak+=abs(atomic_load(&c.wave[i]));
    assert(peak>0);
    return sqrt(energy/47999);
}
int main(void) {
    for (int band=0;band<5;band++) {
        double hz=rh_frequencies[band], flat=tone(hz,-1,0,true);
        double cut=tone(hz,band,-12,true), bypass=tone(hz,band,-12,false);
        double db=20*log10(cut/flat);
        assert(fabs(db+12)<.15);
        assert(fabs(bypass-flat)<1e-6);
        printf("%g Hz: cut %.2f dB; bypass unchanged\n",hz,db);
    }
    double low=tone(60,0,12,true), high=tone(8000,0,12,true);
    assert(low/high>3);
    puts("Native DSP frequency response, bypass, headroom and measured waveform passed.");
}
