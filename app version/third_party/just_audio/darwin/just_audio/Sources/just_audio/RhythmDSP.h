// Rhythm's five-band peaking EQ. No allocation or locks in the audio callback.
#ifndef RHYTHM_DSP_H
#define RHYTHM_DSP_H
#include <math.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <string.h>
#define RH_BANDS 5
#define RH_CHANNELS 8
#define RH_WAVE 64
static const double rh_frequencies[RH_BANDS] = {60, 230, 910, 3600, 14000};
typedef struct {
    atomic_int gains[RH_BANDS]; // hundredths of a dB
    atomic_bool enabled, visualizing;
    atomic_int wave[RH_WAVE];
    atomic_bool supported;
} RhythmControl;
typedef struct {
    double b0, b1, b2, a1, a2;
} RhythmBiquad;
typedef struct {
    double rate, gains[RH_BANDS], preamp;
    RhythmBiquad coefficients[RH_BANDS];
    double z1[RH_CHANNELS][RH_BANDS], z2[RH_CHANNELS][RH_BANDS];
    float wave[RH_WAVE];
    unsigned waveFrame;
    bool enabled, visualizing, flat;
} RhythmDSP;
static inline void rh_control_init(RhythmControl *c) {
    for (int i=0; i<RH_BANDS; i++) atomic_init(&c->gains[i], 0);
    for (int i=0; i<RH_WAVE; i++) atomic_init(&c->wave[i], 0);
    atomic_init(&c->enabled, true);
    atomic_init(&c->visualizing, false);
    atomic_init(&c->supported, false);
}
static inline void rh_reset(RhythmDSP *d, double rate) {
    memset(d, 0, sizeof(*d));
    d->rate = rate;
    d->preamp = 1;
    d->flat = true;
}
static inline RhythmBiquad rh_peak(double hz, double db, double rate) {
    const double w = 2 * 3.141592653589793 * fmin(hz, rate * .45) / rate;
    const double a = pow(10, db / 40), alpha = sin(w) / (2 * .85);
    const double a0 = 1 + alpha / a;
    return (RhythmBiquad){(1+alpha*a)/a0, -2*cos(w)/a0, (1-alpha*a)/a0,
                           -2*cos(w)/a0, (1-alpha/a)/a0};
}
static inline void rh_begin(RhythmDSP *d, RhythmControl *c, unsigned frames) {
    d->enabled = atomic_load_explicit(&c->enabled, memory_order_relaxed);
    d->visualizing = atomic_load_explicit(&c->visualizing, memory_order_relaxed);
    // Smooth each control change over roughly 20 ms, independent of buffer size.
    double mix = 1 - exp(-(double)frames / (d->rate * .02));
    double maximum = 0;
    bool wasFlat = d->flat;
    d->flat = true;
    for (int i=0; i<RH_BANDS; i++) {
        double target = d->enabled ? atomic_load_explicit(&c->gains[i], memory_order_relaxed)/100.0 : 0;
        d->gains[i] += (target - d->gains[i]) * mix;
        if (fabs(d->gains[i]) < .001) d->gains[i] = 0;
        maximum = fmax(maximum, d->gains[i]);
        if (d->gains[i] != 0) d->flat = false;
        d->coefficients[i] = d->gains[i] == 0 ? (RhythmBiquad){1,0,0,0,0} : rh_peak(rh_frequencies[i], d->gains[i], d->rate);
    }
    d->preamp = pow(10, -maximum/20); // headroom when boosting bands
    if (d->flat && !wasFlat) { memset(d->z1, 0, sizeof(d->z1)); memset(d->z2, 0, sizeof(d->z2)); }
}
static inline float rh_sample(RhythmDSP *d, float value, unsigned channel) {
    if (d->flat) return value;
    double x = value * d->preamp;
    for (int b=0; b<RH_BANDS; b++) {
        RhythmBiquad q = d->coefficients[b];
        double y = q.b0*x + d->z1[channel][b];
        d->z1[channel][b] = q.b1*x - q.a1*y + d->z2[channel][b];
        d->z2[channel][b] = q.b2*x - q.a2*y;
        x = y;
    }
    // Protect the output if combined boosts exceed the reserved headroom.
    return (float)fmax(-1, fmin(1, x));
}
static inline void rh_capture(RhythmDSP *d, RhythmControl *c, float value) {
    if (!d->visualizing) return;
    unsigned bucket = (d->waveFrame * RH_WAVE) / 2048;
    if (fabsf(value) > fabsf(d->wave[bucket])) d->wave[bucket] = value;
    if (++d->waveFrame == 2048) {
        for (unsigned i=0; i<RH_WAVE; i++) {
            atomic_store_explicit(&c->wave[i], (int)(d->wave[i]*32767), memory_order_relaxed);
            d->wave[i] = 0;
        }
        d->waveFrame = 0;
    }
}
#endif
