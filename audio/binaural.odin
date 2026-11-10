#+private
package mirai_audio

import "core:math"

// Binaural output of a spatial voice, translated from Steam Audio's
// BinauralEffect and OverlapAddConvolutionEffect (binaural_effect.cpp,
// overlap_add_convolution_effect.cpp, window_function.cpp): each block of the
// voice is windowed, convolved in frequency with the HRTF of its direction for
// each ear and overlapped with the blocks before. Consecutive blocks share
// BINAURAL_OVERLAP samples that fall in one and rise in the next, so a change
// of direction crossfades between the two HRTFs.
//
// Blocks may be of any length up to CHUNK_FRAMES: each one rises over the
// samples the one before fell over and falls over at most BINAURAL_OVERLAP of
// its own, and the output is always BINAURAL_OVERLAP samples late, so a render
// of any size sounds the same.

BINAURAL_OVERLAP :: CHUNK_FRAMES/4
BINAURAL_WINDOW :: CHUNK_FRAMES+BINAURAL_OVERLAP

// What a voice slot keeps for its binaural output, in the slabs of the mixer.
Binaural_Slot :: struct {
    spectra:[2][]f32,       // the HRTF of each ear for the direction of the last block, complex
    ring:[2][]f32,          // what is still to be output, from read on
    dry:[]f32,              // the last BINAURAL_OVERLAP samples of input, newest last
}

binaural_slot :: proc "contextless" (m:^Mixer,index:u32) -> (slot:Binaural_Slot) {
    bins:=m.conv.n/2+1
    ring:=m.binaural_ring
    for ear in 0..<2 {
        slot.spectra[ear]=m.binaural_spectra[(int(index)*2+ear)*bins*2:][:bins*2]
        slot.ring[ear]=m.binaural_rings[(int(index)*2+ear)*ring:][:ring]
    }
    slot.dry=m.binaural_dry[int(index)*BINAURAL_OVERLAP:][:BINAURAL_OVERLAP]
    return
}

// WindowFunction::tukey's rise over length samples; the fall is its mirror.
binaural_rise :: proc "contextless" (m:^Mixer,i,length:int) -> f32 {
    if length==BINAURAL_OVERLAP {return m.binaural_window[i]}
    if length<2 {return 0.5}
    return 0.5*(1+math.cos(math.PI*(f32(i)/f32(length-1)-1)))
}

// Writes count frames of stereo out from count mono samples of x, for the
// listener-space direction of the source.
binaural_run :: proc "contextless" (m:^Mixer,v:^Mix_Voice,index:u32,x:[]f32,out:[^]f32,direction:[3]f32) #no_bounds_check {
    slot:=binaural_slot(m,index)
    count:=len(x)
    if !v.binaural_live {
        for ear in 0..<2 {for &s in slot.ring[ear] {s=0}}
        for &s in slot.dry {s=0}
        v.binaural_kept=0;v.binaural_read=0
        v.binaural_live=true
        v.binaural_direction_valid=false
    }
    if !v.binaural_direction_valid || v.binaural_direction!=direction {
        hrtf_interpolate(&m.hrtf,&m.conv,direction,slot.spectra)
        v.binaural_direction,v.binaural_direction_valid=direction,true
    }
    kept:=int(v.binaural_kept)
    fall:=min(BINAURAL_OVERLAP,count)
    window:=m.binaural_windowed
    for &s in window {s=0}
    for i in 0..<kept {window[i]=slot.dry[BINAURAL_OVERLAP-kept+i]*binaural_rise(m,i,kept)}
    flat:=count-fall
    for i in 0..<flat {window[kept+i]=x[i]}
    for j in 0..<fall {window[kept+flat+j]=x[flat+j]*binaural_rise(m,fall-1-j,fall)}
    fft_forward(&m.conv,window,m.binaural_dry_spectrum)
    mask:=len(slot.ring[0])-1
    start:=int(v.binaural_read)+BINAURAL_OVERLAP-kept
    for ear in 0..<2 {
        h:=raw_data(slot.spectra[ear])
        d:=raw_data(m.binaural_dry_spectrum)
        y:=raw_data(m.binaural_wet_spectrum)
        for k in 0..<len(slot.spectra[ear])/2 {
            dr,di,hr,hi:=d[2*k],d[2*k+1],h[2*k],h[2*k+1]
            y[2*k]=dr*hr-di*hi
            y[2*k+1]=dr*hi+di*hr
        }
        fft_inverse(&m.conv,m.binaural_wet_spectrum,m.binaural_wet)
        ring:=raw_data(slot.ring[ear])
        wet:=raw_data(m.binaural_wet)
        at:=start&mask
        first:=min(m.conv.n,mask+1-at)
        for k in 0..<first {ring[at+k]+=wet[k]}
        for k in first..<m.conv.n {ring[k-first]+=wet[k]}
        read:=int(v.binaural_read)
        for k in 0..<count {
            i:=(read+k)&mask
            out[k*2+ear]=ring[i]
            ring[i]=0
        }
    }
    v.binaural_read=u32((int(v.binaural_read)+count)&mask)
    // The newest BINAURAL_OVERLAP samples of input stay for the rise of the next block.
    if count>=BINAURAL_OVERLAP {
        copy(slot.dry,x[count-BINAURAL_OVERLAP:])
    } else {
        copy(slot.dry,slot.dry[count:])
        copy(slot.dry[BINAURAL_OVERLAP-count:],x)
    }
    v.binaural_kept=u8(fall)
}
