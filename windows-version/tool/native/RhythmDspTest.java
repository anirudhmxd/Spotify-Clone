import com.ryanheise.just_audio.RhythmDsp;
public class RhythmDspTest {
    static double tone(double hz,int band,int gain,boolean enabled) {
        RhythmDsp dsp=new RhythmDsp();
        double[] gains=new double[5]; if(band>=0) gains[band]=gain;
        dsp.configure(gains,enabled); dsp.visualize(true); dsp.reset(48000);
        double energy=0;
        for(int offset=0;offset<96000;offset+=240) {
            dsp.begin(240);
            for(int i=offset;i<offset+240;i++) {
                float in=(float)(.05*Math.sin(2*Math.PI*hz*i/48000));
                float out=dsp.sample(in,0);
                if(!Float.isFinite(out)||Math.abs(out)>1) throw new AssertionError("Invalid audio");
                if(i>48000) energy+=out*out;
            }
        }
        double peak=0;for(float value:dsp.waveform())peak+=Math.abs(value);
        if(peak==0)throw new AssertionError("No measured waveform");
        return Math.sqrt(energy/47999);
    }
    public static void main(String[] args) {
        double[] frequencies={60,230,910,3600,14000};
        for(int b=0;b<5;b++) {
            double flat=tone(frequencies[b],-1,0,true),cut=tone(frequencies[b],b,-12,true),bypass=tone(frequencies[b],b,-12,false);
            double db=20*Math.log10(cut/flat);
            if(Math.abs(db+12)>.15||Math.abs(bypass-flat)>1e-6) throw new AssertionError("EQ response "+db);
            System.out.println(frequencies[b]+" Hz: "+db+" dB; bypass unchanged");
        }
        if(tone(60,0,12,true)/tone(8000,0,12,true)<3)throw new AssertionError("Bass boost inaudible");
        System.out.println("Android DSP signal tests passed.");
    }
}
