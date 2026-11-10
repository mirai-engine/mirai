package mirai_audio

import "core:math"
import "core:testing"

@(test)
attenuation_models_follow_their_curves :: proc(t:^testing.T) {
    inverse:=Attenuation{model=.Inverse,min_distance=2,max_distance=50,rolloff=1}
    test_near(t,attenuation_gain(inverse,0),1)
    test_near(t,attenuation_gain(inverse,2),1)
    test_near(t,attenuation_gain(inverse,4),0.5)
    test_near(t,attenuation_gain(inverse,8),0.25)
    test_near(t,attenuation_gain(inverse,20),0.1)
    // Beyond the maximum distance the level stops falling.
    test_near(t,attenuation_gain(inverse,50),0.04)
    test_near(t,attenuation_gain(inverse,5000),0.04)
    inverse.rolloff=3
    test_near(t,attenuation_gain(inverse,4),2.0/(2+3*2))
    inverse.rolloff=0
    test_near(t,attenuation_gain(inverse,40),1)

    linear:=Attenuation{model=.Linear,min_distance=10,max_distance=110,rolloff=1}
    test_near(t,attenuation_gain(linear,5),1)
    test_near(t,attenuation_gain(linear,10),1)
    test_near(t,attenuation_gain(linear,35),0.75)
    test_near(t,attenuation_gain(linear,60),0.5)
    test_near(t,attenuation_gain(linear,110),0)
    test_near(t,attenuation_gain(linear,400),0)
    linear.rolloff=0.5
    test_near(t,attenuation_gain(linear,110),0.5)
    linear.rolloff=4
    test_near(t,attenuation_gain(linear,60),0)

    exponential:=Attenuation{model=.Exponential,min_distance=1,max_distance=100,rolloff=2}
    test_near(t,attenuation_gain(exponential,0.5),1)
    test_near(t,attenuation_gain(exponential,2),0.25)
    test_near(t,attenuation_gain(exponential,10),0.01)
    test_near(t,attenuation_gain(exponential,1000),0.0001,1e-7)
    exponential.rolloff=1
    test_near(t,attenuation_gain(exponential,4),0.25)

    test_near(t,attenuation_gain({model=.None,min_distance=1,max_distance=10,rolloff=1},500),1)
    // Distances that make no sense do not divide by zero.
    test_near(t,attenuation_gain({model=.Inverse},3),1e-4/(1e-4+0*3))
    test_near(t,attenuation_gain({model=.Linear,min_distance=5,max_distance=5,rolloff=1},9),1)
    testing.expect(t,!math.is_nan(attenuation_gain({model=.Exponential,rolloff=1},0)))
    // Every model falls or stays as the distance grows.
    for model in Attenuation_Model {
        a:=Attenuation{model=model,min_distance=1,max_distance=80,rolloff=1.5}
        previous:=f32(2)
        for step in 0..<400 {
            gain:=attenuation_gain(a,f32(step)*0.25)
            testing.expect(t,gain<=previous && gain>=0 && gain<=1)
            previous=gain
        }
    }
}

@(test)
listener_orientation_decides_where_a_source_comes_from :: proc(t:^testing.T) {
    near :: proc(t:^testing.T,got,want:[3]f32,loc:=#caller_location) {
        for i in 0..<3 {test_near(t,got[i],want[i],1e-5,loc)}
    }
    ahead:=quaternion128(1)
    d,distance:=listener_direction({},ahead,{5,0,0})
    near(t,d,{1,0,0});test_near(t,distance,5)
    d,_=listener_direction({},ahead,{0,0,-5});near(t,d,{0,0,-1})
    d,_=listener_direction({},ahead,{0,0,5});near(t,d,{0,0,1})
    d,_=listener_direction({},ahead,{0,7,0});near(t,d,{0,1,0})
    // At the listener it comes from above.
    d,distance=listener_direction({1,2,3},ahead,{1,2,3});near(t,d,{0,1,0});test_near(t,distance,0)
    // The listener moved: sides are relative to where it is.
    d,_=listener_direction({10,0,0},ahead,{5,0,0});near(t,d,{-1,0,0})
    // Turned a quarter turn to its left (about +Y): what was ahead is now at its right.
    left:=quaternion(real=math.cos_f32(math.PI/4),imag=0,jmag=math.sin_f32(math.PI/4),kmag=0)
    d,_=listener_direction({},left,{0,0,-5});near(t,d,{1,0,0})
    d,_=listener_direction({},left,{0,0,5});near(t,d,{-1,0,0})
    // A rotation that is not of unit length is taken as its direction, and zero as none.
    d,_=listener_direction({},left*3,{0,0,-5});near(t,d,{1,0,0})
    d,_=listener_direction({},quaternion128(0),{0,0,-5});near(t,d,{0,0,-1})
}

@(test)
doppler_raises_the_pitch_of_what_approaches :: proc(t:^testing.T) {
    c:=f32(343)
    // A source coming at a tenth of the speed of sound, and going away.
    test_near(t,doppler_pitch({},{},{0,0,-100},{0,0,34.3},1,c),1/0.9,1e-5)
    test_near(t,doppler_pitch({},{},{0,0,-100},{0,0,-34.3},1,c),1/1.1,1e-5)
    // A listener moving toward the source, and away from it.
    test_near(t,doppler_pitch({},{0,0,-34.3},{0,0,-100},{},1,c),1.1,1e-5)
    test_near(t,doppler_pitch({},{0,0,34.3},{0,0,-100},{},1,c),0.9,1e-5)
    // Moving together, or across the line between them, changes nothing.
    test_near(t,doppler_pitch({},{5,0,0},{0,0,-100},{5,0,0},1,c),1)
    test_near(t,doppler_pitch({},{},{0,0,-100},{50,0,0},1,c),1)
    // The factor scales the effect; zero turns it off.
    test_near(t,doppler_pitch({},{},{0,0,-100},{0,0,34.3},0,c),1)
    test_near(t,doppler_pitch({},{},{0,0,-100},{0,0,34.3},2,c),1/0.8,1e-5)
    // At the same place, and faster than sound: finite and bounded.
    test_near(t,doppler_pitch({1,1,1},{},{1,1,1},{0,0,900},1,c),1)
    test_near(t,doppler_pitch({},{},{0,0,-100},{0,0,5000},1,c),4)
    test_near(t,doppler_pitch({},{},{0,0,-100},{0,0,-5000},1,c),1/1.99,1e-4)
}

@(test)
fft_matches_the_discrete_fourier_transform_and_inverts :: proc(t:^testing.T) {
    for n in ([?]int{8,16,256,1024}) {
        f:Fft
        testing.expect_value(t,fft_init(&f,n,context.allocator),Error.None)
        defer fft_destroy(&f,context.allocator)
        signal:=make([]f32,n,context.temp_allocator)
        for &x,i in signal {x=math.sin(f32(i)*0.37)+f32(i%5)*0.1}
        spectrum:=make([]f32,n+2,context.temp_allocator)
        fft_forward(&f,signal,spectrum)
        for k in ([?]int{0,1,n/4,n/2}) {
            want:complex128
            for x,i in signal {
                angle:=-2*math.PI*f64(k*i)/f64(n)
                want+=complex(f64(x)*math.cos(angle),f64(x)*math.sin(angle))
            }
            test_near(t,spectrum[2*k],f32(real(want)),1e-3*f32(n))
            test_near(t,spectrum[2*k+1],f32(imag(want)),1e-3*f32(n))
        }
        back:=make([]f32,n,context.temp_allocator)
        fft_inverse(&f,spectrum,back)
        for x,i in signal {
            if !test_near(t,back[i],x,1e-4) {break}
        }
    }
}

@(test)
hrtf_covers_every_direction_with_weights_that_add_up_to_one :: proc(t:^testing.T) {
    for rate in ([?]int{24000,44100,48000}) {
        h:Hrtf
        testing.expect_value(t,hrtf_load(&h,rate,context.allocator),Error.None)
        defer hrtf_destroy(&h,context.allocator)
        testing.expect(t,h.count==1250 && h.samples>0 && h.rings*len(h.azimuths)==h.count)
        for i in 0..<400 {
            // Directions all around, the poles and the interaural axis included.
            z:=f32(i%20)/9.5-1
            angle:=f32(i/20)*math.PI/10
            r:=math.sqrt(max(1-z*z,0))
            direction:=[3]f32{r*math.cos(angle),z,r*math.sin(angle)}
            indices,weights:=hrtf_weights(&h,direction)
            sum:=f32(0)
            for w,j in weights {
                testing.expect(t,w>=-1e-5 && w<=1+1e-5 && indices[j]>=0 && indices[j]<h.count)
                sum+=w
            }
            if !test_near(t,sum,1,1e-4) {break}
        }
    }
    h:Hrtf
    testing.expect_value(t,hrtf_load(&h,22050,context.allocator),Error.Unsupported_Format)
    hrtf_destroy(&h,context.allocator)
    _,error:=mixer_create({sample_rate=22050})
    testing.expect_value(t,error,Error.Invalid_Desc)
}

// The part of each band the source keeps: what the direct effect does to it.
@(private="file")
band_gains :: proc(distance,occlusion:f32) -> [BANDS]f32 {
    gain,eq:=direct_gain_eq(1,1,air_absorption(distance),occlusion,TRANSMISSION_DEFAULT)
    return {gain*eq[0],gain*eq[1],gain*eq[2]}
}

@(test)
distance_and_occlusion_dull_a_source_and_never_raise_it :: proc(t:^testing.T) {
    // In the open and near, every band passes.
    near:=band_gains(0,0)
    for g in near {test_near(t,g,1,1e-4)}
    previous:=near
    for step in 1..<60 {
        g:=band_gains(f32(step*step),0)
        for i in 0..<BANDS {testing.expect(t,g[i]<=previous[i]+1e-6,"farther is never louder")}
        testing.expect(t,g[2]<=g[1] && g[1]<=g[0],"the air takes the highs first")
        previous=g
    }
    far:=band_gains(300,0)
    testing.expect(t,far[2]<=far[0]*EQ_GAIN_MIN+1e-6 && far[0]>0.9,"300 m of air leave the lows and take the highs down to the floor of the EQ")
    previous=band_gains(2,0)
    for step in 1..=20 {
        g:=band_gains(2,f32(step)/20)
        for i in 0..<BANDS {testing.expect(t,g[i]<=previous[i]+1e-6,"more hidden is never louder")}
        previous=g
    }
    hidden:=band_gains(2,1)
    testing.expect(t,hidden[0]>0.05 && hidden[2]<hidden[0]*0.5,"a hidden source is muffled, not silent")
    // The EQ never goes below its floor; all is finite at absurd distances.
    gain,eq:=direct_gain_eq(1,1,air_absorption(1e30),0,TRANSMISSION_DEFAULT)
    testing.expect(t,gain==0 && eq=={1,1,1})
    gain,eq=direct_gain_eq(1,1,air_absorption(-5),2,{-1,9,0})
    testing.expect(t,finite(gain) && gain<=1 && eq[0]>=EQ_GAIN_MIN)
    // A dipole is loudest ahead of the source and silent beside a figure-eight.
    eight:=Directivity{weight=1,power=1}
    test_near(t,directivity_gain(eight,{},1,{0,0,-3}),1)
    test_near(t,directivity_gain(eight,{},1,{3,0,0}),0)
    test_near(t,directivity_gain({weight=0.5,power=1},{},1,{0,0,3}),0)
    test_near(t,directivity_gain({},{},1,{0,0,3}),1)
}

// Energy above the band edge of 8 kHz relative to the whole, of one channel: the share of highs.
@(private="file")
high_share :: proc(samples:[]f32,channels,channel:int) -> f32 {
    total,high:f64
    for i in 1..<len(samples)/channels {
        x,previous:=f64(samples[i*channels+channel]),f64(samples[(i-1)*channels+channel])
        total+=x*x
        high+=(x-previous)*(x-previous)
    }
    return f32(high/max(total,1e-30))
}
@(private="file")
energy :: proc(samples:[]f32,channels,channel:int) -> f64 {
    sum:f64
    for i in 0..<len(samples)/channels {x:=f64(samples[i*channels+channel]);sum+=x*x}
    return sum
}
@(private="file")
test_noise :: proc(i:int) -> f32 {
    x:=u32(i)*2654435761
    x~=x>>15;x*=2246822519;x~=x>>13
    return f32(x%2001)/2000-0.5
}

// FRAMES of a looping noise placed at position for a listener at the origin
// looking down -Z, after the voice has settled.
@(private="file")
placed_noise :: proc(t:^testing.T,output:Output_Kind,position:[3]f32,occlusion:f32=0,frames:=8192,step:=0) -> []f32 {
    m:=test_mixer(t,{output=output})
    defer mixer_destroy(m)
    noise:=test_mono(t,m,RATE,test_noise)
    desc:=VOICE_DEFAULT
    desc.loop,desc.spatial,desc.position,desc.attenuation=true,true,position,{model=.None}
    desc.occlusion=occlusion
    testing.expect(t,voice_play(m,noise,desc)!=0)
    test_render(m,CHUNK_FRAMES*2)
    if step<=0 {
        out:=test_render(m,frames)
        result:=make([]f32,len(out),context.temp_allocator)
        copy(result,out)
        return result
    }
    out:=make([]f32,frames*2,context.temp_allocator)
    for done:=0;done<frames; {
        n:=min(step,frames-done)
        mixer_render(m,out[done*2:][:n*2])
        done+=n
    }
    return out
}

@(test)
headphones_tell_ahead_from_behind_and_above_from_level :: proc(t:^testing.T) {
    difference :: proc(a,b:[]f32) -> f32 {
        d,e:f64
        for i in 0..<len(a) {d+=f64(a[i]-b[i])*f64(a[i]-b[i]);e+=f64(a[i])*f64(a[i])}
        return f32(math.sqrt(d/max(e,1e-30)))
    }
    ahead:=placed_noise(t,.Headphones,{0.5,0,-3})
    behind:=placed_noise(t,.Headphones,{0.5,0,3})
    level:=placed_noise(t,.Headphones,{0,0,-3})
    above:=placed_noise(t,.Headphones,{0,3,-1})
    testing.expectf(t,difference(ahead,behind)>0.3,"ahead and behind sound alike: %v",difference(ahead,behind))
    testing.expectf(t,difference(level,above)>0.3,"above and level sound alike: %v",difference(level,above))
    // On speakers ahead and behind are the same: only headphones tell them apart.
    speakers_ahead:=placed_noise(t,.Speakers,{0.5,0,-3})
    speakers_behind:=placed_noise(t,.Speakers,{0.5,0,3})
    testing.expect(t,difference(speakers_ahead,speakers_behind)<1e-3)
}

@(test)
headphones_mirror_left_and_right_with_level_and_time_differences :: proc(t:^testing.T) {
    right:=placed_noise(t,.Headphones,{3,0,0})
    left:=placed_noise(t,.Headphones,{-3,0,0})
    db :: proc(a,b:f64) -> f32 {return f32(10*math.log10(a/max(b,1e-30)))}
    right_ild:=db(energy(right,2,1),energy(right,2,0))
    left_ild:=db(energy(left,2,0),energy(left,2,1))
    testing.expectf(t,right_ild>6 && left_ild>6,"the near ear is not louder: %v dB and %v dB",right_ild,left_ild)
    testing.expectf(t,abs(right_ild-left_ild)<3,"left and right are not mirrors: %v dB and %v dB",right_ild,left_ild)
    // The far ear hears it later: the lag of the best match of the two ears.
    lag :: proc(out:[]f32,near,far:int) -> int {
        best,best_lag:=f64(-1e30),0
        for l in -60..=60 {
            sum:f64
            for i in 100..<len(out)/2-100 {sum+=f64(out[i*2+near])*f64(out[(i+l)*2+far])}
            if sum>best {best,best_lag=sum,l}
        }
        return best_lag
    }
    right_lag,left_lag:=lag(right,1,0),lag(left,0,1)
    // A head is about 0.6 ms across for sound at the side: 20 to 40 samples at 48 kHz.
    testing.expectf(t,right_lag>=15 && right_lag<=45 && abs(right_lag-left_lag)<=3,"interaural delays %d and %d samples",right_lag,left_lag)
}

@(test)
binaural_output_does_not_depend_on_how_the_render_is_cut :: proc(t:^testing.T) {
    whole:=placed_noise(t,.Headphones,{2,1,-1},frames=4096)
    for step in ([?]int{1,7,100,300,1000}) {
        cut:=placed_noise(t,.Headphones,{2,1,-1},frames=4096,step=step)
        worst:=f32(0)
        for i in 0..<len(whole) {worst=max(worst,abs(whole[i]-cut[i]))}
        testing.expectf(t,worst<1e-4,"rendering in steps of %d frames differs by %v",step,worst)
    }
}

// A binaural voice that stops completes its last block, then ends; its bus
// plays what the convolution still holds.
@(test)
binaural_voice_plays_its_tail_when_it_stops :: proc(t:^testing.T) {
    m:=test_mixer(t,{output=.Headphones})
    defer mixer_destroy(m)
    noise:=test_mono(t,m,RATE,test_noise)
    desc:=VOICE_DEFAULT
    desc.loop,desc.spatial,desc.position,desc.attenuation=true,true,{2,0,-1},{model=.None}
    voice:=voice_play(m,noise,desc)
    test_render(m,CHUNK_FRAMES*4)
    voice_stop(m,voice)
    test_render(m,CHUNK_FRAMES)
    tail:=test_render(m,CHUNK_FRAMES)
    testing.expect(t,energy(tail,2,0)>0 && energy(tail,2,1)>0,"its tail plays after it went silent")
    mixer_update(m)
    testing.expect(t,!voice_valid(m,voice),"it ends once its last block is complete; its bus plays the rest")
    last:=test_render(m,CHUNK_FRAMES)
    testing.expect(t,energy(last[:BINAURAL_OVERLAP],2,0)>0)
    for x in last[CHUNK_FRAMES:] {testing.expect(t,abs(x)<1e-6,"then it is silent")}
}

@(test)
occlusion_and_distance_take_the_highs_of_what_is_heard :: proc(t:^testing.T) {
    for output in Output_Kind {
        open:=placed_noise(t,output,{0,0,-2})
        hidden:=placed_noise(t,output,{0,0,-2},occlusion=1)
        far:=placed_noise(t,output,{0,0,-200})
        for channel in 0..<2 {
            testing.expectf(t,high_share(hidden,2,channel)<high_share(open,2,channel)*0.8,"%v: hidden is not duller",output)
            testing.expectf(t,high_share(far,2,channel)<high_share(open,2,channel)*0.9,"%v: far is not duller",output)
            testing.expect(t,energy(hidden,2,channel)<energy(open,2,channel) && energy(hidden,2,channel)>0)
            testing.expect(t,energy(far,2,channel)<=energy(open,2,channel))
        }
    }
}

@(test)
spatial_voice_on_speakers_is_panned_and_attenuated_for_the_listener :: proc(t:^testing.T) {
    m:=test_mixer(t,{output=.Speakers})
    defer mixer_destroy(m)
    desc:=VOICE_DEFAULT
    desc.loop=true;desc.spatial=true
    desc.attenuation={model=.Inverse,min_distance=1,max_distance=100,rolloff=1}
    desc.pan=-1 // has no say for a spatial voice
    one:=test_mono(t,m,64,test_one)
    half:=f32(math.SQRT_TWO/2)
    // A constant sound passes the EQ of the air whole: only distance lowers it.
    air:=proc(d:f32) -> f32 {return air_absorption(d)[0]}
    // Four meters to the right: all in the right speaker, a quarter of the level.
    desc.position={4,0,0}
    voice:=voice_play(m,one,desc)
    test_render(m,CHUNK_FRAMES*4)
    out:=test_render(m,4)
    test_near(t,out[0],0,1e-6)
    test_near(t,out[1],0.25*air(4),1e-4)
    // Two meters ahead: centered, half the level.
    testing.expect(t,voice_set_position(m,voice,{0,0,-2}))
    test_render(m,CHUNK_FRAMES*4)
    out=test_render(m,4)
    test_near(t,out[0],0.5*half*air(2),1e-4)
    test_near(t,out[1],0.5*half*air(2),1e-4)
    // The listener steps to the right of it and looks the same way: now it is at its left.
    testing.expect(t,listener_set(m,{2,0,-2},1))
    test_render(m,CHUNK_FRAMES*4)
    out=test_render(m,4)
    test_near(t,out[0],0.5*air(2),1e-4)
    test_near(t,out[1],0,1e-6)
    // Turning around puts it at the right.
    around:quaternion128=quaternion(real=0,imag=0,jmag=1,kmag=0)
    listener_set(m,{2,0,-2},around)
    test_render(m,CHUNK_FRAMES*4)
    out=test_render(m,4)
    test_near(t,out[0],0,1e-6)
    test_near(t,out[1],0.5*air(2),1e-4)
    // Its volume still applies.
    voice_set_volume(m,voice,1.5)
    test_render(m,CHUNK_FRAMES*4)
    out=test_render(m,4)
    test_near(t,out[1],0.75*air(2),1e-3)
    // The same mixer on headphones: the voice goes on, now through the HRTF.
    testing.expect(t,mixer_set_output(m,.Headphones) && mixer_output(m)==.Headphones)
    test_render(m,CHUNK_FRAMES*4)
    out=test_render(m,CHUNK_FRAMES)
    testing.expect(t,energy(out,2,0)>0 && energy(out,2,1)>0,"it goes on playing")
    testing.expect(t,!mixer_set_output(m,Output_Kind(7)))
    voice_stop(m,voice)
    // What the HRTF raised past full scale is let go of by the limiter.
    test_render(m,int((LIMITER_HOLD+LIMITER_RELEASE)*RATE)+CHUNK_FRAMES)
    mixer_update(m)

    // A stereo sound with a place in the world is heard as one source.
    mixer_set_output(m,.Speakers)
    listener_set(m,{},1)
    desc.position={-1,0,0}
    stereo:=make([]f32,128,context.temp_allocator)
    for i in 0..<64 {stereo[i*2]=1;stereo[i*2+1]=0.5}
    sound,_:=sound_create(m,stereo,2,RATE)
    voice_play(m,sound,desc)
    test_render(m,CHUNK_FRAMES*4)
    out=test_render(m,4)
    test_near(t,out[0],0.75*air(1),1e-4)
    test_near(t,out[1],0,1e-6)
}

@(test)
spatial_voices_take_hostile_input_without_harm :: proc(t:^testing.T) {
    m:=test_mixer(t)
    defer mixer_destroy(m)
    noise:=test_mono(t,m,RATE,test_noise)
    nan:=math.nan_f32()
    inf:=math.inf_f32(1)
    desc:=VOICE_DEFAULT
    desc.loop,desc.spatial=true,true
    for bad in ([?][3]f32{{nan,0,0},{0,inf,0},{0,0,-inf}}) {
        d:=desc
        d.position=bad
        testing.expect_value(t,voice_play(m,noise,d),Voice(0))
        d=desc;d.velocity=bad;d.doppler=1
        testing.expect_value(t,voice_play(m,noise,d),Voice(0))
        d=desc;d.transmission=bad
        testing.expect_value(t,voice_play(m,noise,d),Voice(0))
        testing.expect(t,!listener_set(m,bad,1))
    }
    d:=desc;d.attenuation.min_distance=nan
    testing.expect_value(t,voice_play(m,noise,d),Voice(0))
    d=desc;d.rotation=quaternion(real=nan,imag=0,jmag=0,kmag=0)
    testing.expect_value(t,voice_play(m,noise,d),Voice(0))
    // The listener at the source, absurd numbers that are numbers, and a zero rotation.
    d=desc
    d.occlusion,d.transmission,d.directivity,d.rotation=50,{-3,7,1e30},{weight=9,power=1e9},0
    d.attenuation={model=.Exponential,min_distance=0,max_distance=-5,rolloff=1e30}
    at:=voice_play(m,noise,d)
    far:=voice_play(m,noise,desc)
    testing.expect(t,at!=0 && far!=0)
    testing.expect(t,voice_set_position(m,far,{1e30,-1e30,1e30},{1e30,0,0},quaternion128(0)))
    testing.expect(t,!voice_set_position(m,far,{nan,0,0}))
    testing.expect(t,!voice_set_occlusion(m,far,nan,{1,1,1}))
    testing.expect(t,voice_set_occlusion(m,at,-4,{2,-2,0}))
    for output in Output_Kind {
        mixer_set_output(m,output)
        for frames in ([?]int{1,255,257,CHUNK_FRAMES*3}) {
            out:=test_render(m,frames)
            for x in out {
                if !testing.expect(t,finite(x) && abs(x)<100,"the output is a sane number") {return}
            }
        }
    }
}

@(test)
doppler_changes_the_speed_of_a_spatial_voice :: proc(t:^testing.T) {
    m:=test_mixer(t,{speed_of_sound=300,output=.Speakers})
    defer mixer_destroy(m)
    desc:=VOICE_DEFAULT
    desc.spatial=true;desc.attenuation={model=.None}
    desc.position={0,0,-50}
    desc.velocity={0,0,60} // toward the listener at a fifth of the speed of sound: 300/(300-60)=1.25
    sound:=test_mono(t,m,100000,test_ramp)
    // The slope of the ramp, as it comes out at 50 m.
    step:=test_ramp(1)-test_ramp(0)
    half:=f32(math.SQRT_TWO/2)*air_absorption(50)[0]*step
    desc.doppler=1
    voice:=voice_play(m,sound,desc)
    test_render(m,CHUNK_FRAMES)
    out:=test_render(m,200)
    // A ramp keeps its slope through the EQ of the air once it settled: the pitch is its slope.
    test_near(t,(out[199*2]-out[0])/199,1.25*half,2e-3*step)
    // Without the effect the same voice plays as recorded.
    desc.doppler=0
    voice_stop(m,voice)
    plain:=voice_play(m,sound,desc)
    test_render(m,CHUNK_FRAMES)
    out=test_render(m,4)
    test_near(t,out[2]-out[0],half,1e-3*step)
    // The pitch of the voice and the effect multiply: it stops and the listener runs from it.
    voice_set_pitch(m,plain,2)
    voice_stop(m,plain)
    desc.doppler=1;desc.pitch=2;desc.velocity={}
    listener_set(m,{},1,{0,0,150})
    away:=voice_play(m,sound,desc)
    test_render(m,CHUNK_FRAMES)
    out=test_render(m,4)
    test_near(t,out[2]-out[0],2*0.5*half,1e-3*step)
    testing.expect(t,voice_valid(m,away))
}

// One noise voice ten meters away (its EQ on), turned to a new direction between renders
// of uneven sizes: the binaural output the per-voice path of Steam Audio's
// overlap-add gave, which the mix in frequency must reproduce.
@(private)
binaural_one_voice :: proc(t:^testing.T) -> []f32 {
    m:=test_mixer(t,{output=.Headphones})
    defer mixer_destroy(m)
    noise:=test_mono(t,m,RATE,test_noise)
    desc:=VOICE_DEFAULT
    desc.loop,desc.spatial,desc.position,desc.attenuation=true,true,{0,0,-10},{model=.None}
    desc.volume=BINAURAL_ONE_VOICE_LEVEL
    voice:=voice_play(m,noise,desc)
    FRAMES :: 4096
    out:=make([]f32,FRAMES*2,context.temp_allocator)
    sizes:=[?]int{100,256,37,300,1}
    turn:=0
    for done:=0;done<FRAMES; {
        n:=min(sizes[turn%len(sizes)],FRAMES-done)
        mixer_render(m,out[done*2:][:n*2])
        done+=n
        turn+=1
        angle,elevation:=f32(turn)*0.9,f32(turn%3-1)*0.4
        voice_set_position(m,voice,{10*math.sin(angle)*math.cos(elevation),10*math.sin(elevation),-10*math.cos(angle)*math.cos(elevation)})
    }
    return out
}

@(private="file") BINAURAL_ONE_VOICE :: #load("testdata/binaural_one_voice.f32")
// The recording was made at full level, louder than full scale at times: the
// voice plays at a power of two below it, under the limiter, and every sample
// comes out scaled exactly by it.
@(private="file") BINAURAL_ONE_VOICE_LEVEL :: f32(0.25)

// Adding the voices of a bus in frequency gives one voice what its own
// overlap-add gave it, recorded before the voices were added up.
@(test)
binaural_mix_in_frequency_keeps_the_output_of_a_voice :: proc(t:^testing.T) {
    recorded:=BINAURAL_ONE_VOICE
    got:=binaural_one_voice(t)
    if !testing.expect_value(t,len(recorded),len(got)*4) {return}
    // The EQ of a voice comes in over its first chunk.
    worst:=f32(0)
    for i in CHUNK_FRAMES*4..<len(got) {
        want:=transmute(f32)([4]u8{recorded[i*4],recorded[i*4+1],recorded[i*4+2],recorded[i*4+3]})
        worst=max(worst,abs(got[i]/BINAURAL_ONE_VOICE_LEVEL-want))
    }
    testing.expectf(t,worst<1e-5,"the voice differs from its own overlap-add by %v",worst)
}

// A source that turns less than the measurements can tell apart keeps its
// filters; one that turns more gets new ones.
@(test)
a_slowly_turning_source_keeps_its_filters :: proc(t:^testing.T) {
    m:=test_mixer(t,{output=.Headphones})
    defer mixer_destroy(m)
    step:=math.acos(m.hrtf.reblend_cos)*math.DEG_PER_RAD
    testing.expectf(t,step>0.5 && step<3,"filters are kept within %v degrees",step)
    noise:=test_mono(t,m,RATE,test_noise)
    desc:=VOICE_DEFAULT
    desc.loop,desc.spatial,desc.position=true,true,{0,0,-2}
    voice:=voice_play(m,noise,desc)
    test_render(m,CHUNK_FRAMES)
    index:=0
    for v,i in m.voices {
        if v.phase!=.Free {index=i}
    }
    first:=m.voices[index].binaural_direction
    turn:=step*0.5*math.RAD_PER_DEG
    voice_set_position(m,voice,{2*math.sin(turn),0,-2*math.cos(turn)})
    test_render(m,CHUNK_FRAMES)
    testing.expect(t,m.voices[index].binaural_direction==first,"half a step keeps the filters")
    turn=step*2*math.RAD_PER_DEG
    voice_set_position(m,voice,{2*math.sin(turn),0,-2*math.cos(turn)})
    test_render(m,CHUNK_FRAMES)
    testing.expect(t,m.voices[index].binaural_direction!=first,"two steps blend new ones")
}

// A near voice in sight skips its EQ, a far or hidden one runs it, and a
// binaural voice too far to be heard skips its transform.
@(test)
a_spatial_voice_runs_only_what_its_place_needs :: proc(t:^testing.T) {
    for output in Output_Kind {
        m:=test_mixer(t,{output=output})
        defer mixer_destroy(m)
        noise:=test_mono(t,m,RATE,test_noise)
        desc:=VOICE_DEFAULT
        desc.loop,desc.spatial=true,true
        cases:=[?]struct{position:[3]f32,occlusion:f32,eq:bool}{{{0,0,-2},0,false},{{0,0,-40},0,true},{{0,0,-2},1,true}}
        for c in cases {
            d:=desc
            d.position,d.occlusion=c.position,c.occlusion
            voice_play(m,noise,d)
        }
        d:=desc
        d.position,d.attenuation={0,0,-30},{model=.Linear,min_distance=1,max_distance=10,rolloff=1}
        voice_play(m,noise,d)
        test_render(m,CHUNK_FRAMES*2)
        for c,i in cases {testing.expectf(t,m.voices[i].eq_on==c.eq,"%v: voice %d runs its EQ: %v",output,i,m.voices[i].eq_on)}
        testing.expect(t,!m.voices[len(cases)].binaural_live,"a voice beyond its curve adds no transform")
    }
}
