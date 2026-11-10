#+private
package mirai_audio

import "core:math"

// Binaural output of spatial voices, translated from Steam Audio's
// BinauralEffect and OverlapAddConvolutionEffect (binaural_effect.cpp,
// overlap_add_convolution_effect.cpp, window_function.cpp): each block of a
// voice is windowed, transformed and multiplied by the HRTF of its direction
// for each ear; consecutive blocks share BINAURAL_OVERLAP samples that fall in
// one and rise in the next, so a change of direction crossfades between the
// two HRTFs.
//
// Every voice cuts its blocks at the chunks of the mixer, so the products of
// all the voices of a bus add up in frequency and go back to time once per
// chunk and ear, overlapped in one ring per bus: the voices cost one forward
// transform each. Chunks may be of any length up to CHUNK_FRAMES: each block
// rises over the samples the one before fell over and falls over at most
// BINAURAL_OVERLAP of its own, and the output is always BINAURAL_OVERLAP
// samples late, so a render of any size sounds the same.

BINAURAL_OVERLAP :: CHUNK_FRAMES/4
BINAURAL_WINDOW :: CHUNK_FRAMES+BINAURAL_OVERLAP

// WindowFunction::tukey's rise over length samples; the fall is its mirror.
binaural_rise :: proc "contextless" (m:^Mixer,i,length:int) -> f32 {
    if length==BINAURAL_OVERLAP {return m.binaural_window[i]}
    if length<2 {return 0.5}
    return 0.5*(1+math.cos(math.PI*(f32(i)/f32(length-1)-1)))
}

// Adds the block of a voice for the chunk that starts at clock: x holds the
// chunk, silent before the voice started. direction is in the listener's space.
binaural_add :: proc "contextless" (m:^Mixer,v:^Mix_Voice,index:u32,x:[]f32,direction:[3]f32,clock:u64) #no_bounds_check {
    bins:=m.conv.n/2+1
    // The HRTF of each ear for its direction, and its last BINAURAL_OVERLAP samples of input.
    spectra:=[2][]f32{m.binaural_spectra[int(index)*4*bins:][:bins*2],m.binaural_spectra[(int(index)*4+2)*bins:][:bins*2]}
    dry:=m.binaural_dry[int(index)*BINAURAL_OVERLAP:][:BINAURAL_OVERLAP]
    count:=len(x)
    if !v.binaural_live {v.binaural_direction_valid=false}
    // A voice that did not sound in the chunk before has nothing to rise over.
    if !v.binaural_live || v.binaural_clock!=clock {for &s in dry {s=0}}
    v.binaural_live=true
    d:=v.binaural_direction
    if !v.binaural_direction_valid || direction.x*d.x+direction.y*d.y+direction.z*d.z<m.hrtf.reblend_cos {
        hrtf_interpolate(&m.hrtf,&m.conv,direction,spectra)
        v.binaural_direction,v.binaural_direction_valid=direction,true
    }
    kept:=m.binaural_kept
    fall:=min(BINAURAL_OVERLAP,count)
    window:=m.binaural_windowed
    for &s in window {s=0}
    for i in 0..<kept {window[i]=dry[BINAURAL_OVERLAP-kept+i]*binaural_rise(m,i,kept)}
    flat:=count-fall
    for i in 0..<flat {window[kept+i]=x[i]}
    for j in 0..<fall {window[kept+flat+j]=x[flat+j]*binaural_rise(m,fall-1-j,fall)}
    fft_forward(&m.conv,window,m.binaural_dry_spectrum)
    s:=raw_data(m.binaural_dry_spectrum)
    for ear in 0..<2 {
        h:=raw_data(spectra[ear])
        sum:=raw_data(m.binaural_sums[(int(v.bus)*2+ear)*bins*2:])
        for k in 0..<bins {
            sr,si,hr,hi:=s[2*k],s[2*k+1],h[2*k],h[2*k+1]
            sum[2*k]+=sr*hr-si*hi
            sum[2*k+1]+=sr*hi+si*hr
        }
    }
    m.binaural_used[v.bus]=true
    // The newest BINAURAL_OVERLAP samples of input stay for the rise of the next block.
    if count>=BINAURAL_OVERLAP {
        copy(dry,x[count-BINAURAL_OVERLAP:])
    } else {
        copy(dry,dry[count:])
        copy(dry[BINAURAL_OVERLAP-count:],x)
    }
    v.binaural_clock=clock+u64(count)
}

// Once per chunk of n frames, after the voices: the sums of each bus back to
// time and into its ring, and the next n frames of each ring into its bus.
binaural_flush :: proc "contextless" (m:^Mixer,n:int) #no_bounds_check {
    bins:=m.conv.n/2+1
    ring_frames:=m.binaural_ring
    mask:=ring_frames-1
    read:=m.binaural_read
    start:=read+BINAURAL_OVERLAP-m.binaural_kept
    for bus in 0..<len(m.buses) {
        if m.binaural_used[bus] {
            for ear in 0..<2 {
                sum:=m.binaural_sums[(bus*2+ear)*bins*2:][:bins*2]
                fft_inverse(&m.conv,sum,m.binaural_wet)
                for &x in sum {x=0}
                ring:=raw_data(m.binaural_rings[(bus*2+ear)*ring_frames:])
                wet:=raw_data(m.binaural_wet)
                at:=start&mask
                first:=min(m.conv.n,ring_frames-at)
                for k in 0..<first {ring[at+k]+=wet[k]}
                for k in first..<m.conv.n {ring[k-first]+=wet[k]}
            }
            m.binaural_used[bus]=false
            m.binaural_left[bus]=i32(ring_frames)
        }
        if m.binaural_left[bus]<=0 {continue}
        out:=raw_data(m.bus_buffers[bus*CHUNK_FRAMES*2:])
        for ear in 0..<2 {
            ring:=raw_data(m.binaural_rings[(bus*2+ear)*ring_frames:])
            for k in 0..<n {
                i:=(read+k)&mask
                out[k*2+ear]+=ring[i]
                ring[i]=0
            }
        }
        m.binaural_left[bus]-=i32(n)
    }
    m.binaural_read=(read+n)&mask
    m.binaural_kept=min(BINAURAL_OVERLAP,n)
}
