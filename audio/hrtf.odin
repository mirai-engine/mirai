#+private
package mirai_audio

import "base:runtime"
import "core:math"

// Head-related transfer functions for binaural output, translated from Steam
// Audio's HRTFMap and HRTFDatabase (hrtf_map.cpp, hrtf_database.cpp). The data
// is the HRTF Steam Audio ships (cipic_124.inl, from the CIPIC database), in its
// format: 'HRTF', version, directions (elevation and azimuth in degrees,
// canonical), sampling rates with their HRIR lengths, then per rate, per ear and
// per direction an HRIR of f32. Only the rate of the mixer's default is kept:
// the device resamples it.

HRTF_DATA :: #load("hrtf/cipic_124.hrtf")

Hrtf :: struct {
    count:int,   // measured directions
    samples:int, // HRIR length at the rate of the mixer
    azimuths:[]f32,   // interaural, degrees, ascending
    rings:int,        // elevations measured at each azimuth
    elevations:[]f32, // interaural, degrees: rings per azimuth, ascending
    // Per ear and direction, at the size of interp: the log magnitude and the
    // unwrapped phase of the spectrum of its HRIR.
    magnitude,phase:[]f32,
    interp:Fft,
    // A source that turned less than this cosine from the direction of its
    // filters keeps them: a quarter of the finest spacing of the measurements.
    reblend_cos:f32,
    // Scratch of the audio thread.
    blend_magnitude,blend_phase:[]f32,
    blend_spectrum:[]f32, // complex
    blend_hrir:[]f32, // at the size of the convolution
}

@(private="file")
hrtf_read :: proc(data:[]u8,at:^int) -> u32 {
    value:=transmute(u32)([4]u8{data[at^],data[at^+1],data[at^+2],data[at^+3]})
    at^+=4
    return value
}

// Interaural spherical coordinates (InterauralSphericalVector3) of a canonical
// direction: azimuth from the median plane toward +X, elevation around the
// interaural axis from below through ahead (90) and above (180) to behind.
interaural_angles :: proc "contextless" (direction:[3]f32) -> (azimuth,elevation:f32) {
    radius:=math.sqrt(direction.x*direction.x+direction.y*direction.y+direction.z*direction.z)
    azimuth=math.asin(clamp(direction.x/radius,-1,1))
    if abs(azimuth-math.PI/2)<1e-5 || abs(azimuth+math.PI/2)<1e-5 {return azimuth,0}
    elevation=math.mod(math.PI+math.atan2(direction.z/radius,direction.y/radius),2*math.PI)
    return
}

// Reads the HRIRs of one sampling rate of HRTF_DATA: Unsupported_Format when
// it has none.
hrtf_load :: proc(h:^Hrtf,sample_rate:int,allocator:runtime.Allocator) -> Error {
    data:=HRTF_DATA
    at:=8 // past 'HRTF' and the version
    count:=int(hrtf_read(data,&at))
    h.count=count
    azimuths:=make([]int,count,context.temp_allocator)
    elevations:=make([]int,count,context.temp_allocator)
    for i in 0..<count {
        e:=transmute(f32)hrtf_read(data,&at)*math.RAD_PER_DEG
        a:=transmute(f32)hrtf_read(data,&at)*math.RAD_PER_DEG
        canonical:=[3]f32{math.cos(e)*-math.sin(a),math.sin(e),math.cos(e)*-math.cos(a)}
        ia,ie:=interaural_angles(canonical)
        azimuths[i]=int(math.round(ia*math.DEG_PER_RAD))
        elevations[i]=int(math.round(ie*math.DEG_PER_RAD))
    }
    // The measurements lie on azimuth rings with the same number of elevations each, ring after ring.
    unique:=make([]int,count,context.temp_allocator)
    copy(unique,azimuths)
    for i in 1..<count {
        value,j:=unique[i],i
        for j>0 && unique[j-1]>value {unique[j]=unique[j-1];j-=1}
        unique[j]=value
    }
    rings:=0
    for i in 0..<count {
        if i==0 || unique[i]!=unique[i-1] {unique[rings]=unique[i];rings+=1}
    }
    h.rings=count/rings
    failed:runtime.Allocator_Error
    if h.azimuths,failed=make([]f32,rings,allocator);failed!=nil {return .Out_Of_Memory}
    if h.elevations,failed=make([]f32,count,allocator);failed!=nil {return .Out_Of_Memory}
    for i in 0..<rings {h.azimuths[i]=f32(unique[i])}
    for i in 0..<count {h.elevations[i]=f32(elevations[i])}
    finest:=f32(360)
    for i in 1..<rings {finest=min(finest,h.azimuths[i]-h.azimuths[i-1])}
    for i in 0..<count {
        if i%h.rings>0 && h.elevations[i]>h.elevations[i-1] {finest=min(finest,h.elevations[i]-h.elevations[i-1])}
    }
    h.reblend_cos=math.cos(finest*0.25*math.RAD_PER_DEG)
    skip,found:=0,false
    rates:=int(hrtf_read(data,&at))
    for _ in 0..<rates {
        rate:=int(hrtf_read(data,&at))
        samples:=int(hrtf_read(data,&at))
        if found {continue}
        if rate==sample_rate {h.samples,found=samples,true;continue}
        skip+=2*count*samples*4
    }
    if !found {return .Unsupported_Format}
    at+=skip
    fft_init(&h.interp,h.samples,allocator) or_return
    bins:=h.interp.n/2+1
    if h.magnitude,failed=make([]f32,2*count*bins,allocator);failed!=nil {return .Out_Of_Memory}
    if h.phase,failed=make([]f32,2*count*bins,allocator);failed!=nil {return .Out_Of_Memory}
    if h.blend_magnitude,failed=make([]f32,bins,allocator);failed!=nil {return .Out_Of_Memory}
    if h.blend_phase,failed=make([]f32,bins,allocator);failed!=nil {return .Out_Of_Memory}
    if h.blend_spectrum,failed=make([]f32,2*bins,allocator);failed!=nil {return .Out_Of_Memory}
    if h.blend_hrir,failed=make([]f32,max(next_pow2(BINAURAL_WINDOW+h.samples-1),h.interp.n),allocator);failed!=nil {return .Out_Of_Memory}
    signal:=make([]f32,h.interp.n,context.temp_allocator)
    spectrum:=make([]f32,2*bins,context.temp_allocator)
    for row in 0..<2*count {
        for k in 0..<h.samples {signal[k]=transmute(f32)hrtf_read(data,&at)}
        fft_forward(&h.interp,signal,spectrum)
        magnitude:=h.magnitude[row*bins:][:bins]
        phase:=h.phase[row*bins:][:bins]
        for k in 0..<bins {
            re,im:=spectrum[2*k],spectrum[2*k+1]
            magnitude[k]=math.ln(math.sqrt(re*re+im*im)+1e-9)
            phase[k]=math.atan2(im,re)
        }
        hrtf_unwrap(phase)
    }
    return .None
}

hrtf_destroy :: proc(h:^Hrtf,allocator:runtime.Allocator) {
    delete(h.azimuths,allocator);delete(h.elevations,allocator)
    delete(h.magnitude,allocator);delete(h.phase,allocator)
    delete(h.blend_magnitude,allocator);delete(h.blend_phase,allocator);delete(h.blend_spectrum,allocator);delete(h.blend_hrir,allocator)
    fft_destroy(&h.interp,allocator)
    h^={}
}

// HRTFDatabase::unwrapPhase, in place: a jump of more than pi between
// neighbouring bins is taken as a wrap.
@(private="file")
hrtf_unwrap :: proc "contextless" (phase:[]f32) {
    correction:=f32(0)
    previous:=phase[0]
    for k in 1..<len(phase) {
        delta:=phase[k]-previous
        previous=phase[k]
        equivalent:=(delta+math.PI)-math.floor((delta+math.PI)/(2*math.PI))*(2*math.PI)-math.PI
        if equivalent==-math.PI && delta>0 {equivalent=math.PI}
        if abs(delta)>=math.PI {correction+=equivalent-delta}
        phase[k]+=correction
    }
}

// HRTFMap::lowerAndUpperBound: the indices of the two values around needle.
@(private="file")
hrtf_bounds :: proc "contextless" (haystack:[]f32,needle:f32) -> (lower,upper:int) {
    u:=len(haystack)
    for value,i in haystack {
        if value>needle {u=i;break}
    }
    return max(u-1,0),min(u,len(haystack)-1)
}
@(private="file")
hrtf_linear_weights :: proc "contextless" (x,low,high:f32,low_index,high_index:int) -> (weight_low,weight_high:f32) {
    if low_index==high_index && low==high {return 0,1}
    weight_low=(high-x)/(high-low)
    return weight_low,1-weight_low
}

// HRTFMap::interpolatedHRIRWeights: the four measurements around a direction
// of the listener's space and their bilinear weights.
hrtf_weights :: proc "contextless" (h:^Hrtf,direction:[3]f32) -> (indices:[4]int,weights:[4]f32) {
    azimuth_rad,elevation_rad:=interaural_angles(direction)
    phi:=azimuth_rad*math.DEG_PER_RAD
    theta:=elevation_rad*math.DEG_PER_RAD
    theta_for_min,theta_for_max:=theta,theta
    last:=len(h.azimuths)-1
    min_index,max_index:=hrtf_bounds(h.azimuths,phi)
    phi_min,phi_max:=h.azimuths[min_index],h.azimuths[max_index]
    // Beyond the outermost rings the neighbour is the same ring seen from the other side of the axis.
    if min_index==0 && max_index==0 {
        phi_min+=2*(-90-phi_min)
        theta_for_min+=2*(180-theta_for_min)
    }
    if min_index==last && max_index==last {
        phi_max+=2*(90-phi_max)
        theta_for_max+=2*(180-theta_for_max)
    }
    if direction.z>0 {
        phi_min,phi_max=phi_max,phi_min
        min_index,max_index=max_index,min_index
        theta_for_min,theta_for_max=theta_for_max,theta_for_min
    }
    ring_min:=h.elevations[min_index*h.rings:][:h.rings]
    ring_max:=h.elevations[max_index*h.rings:][:h.rings]
    low_for_min,high_for_min:=hrtf_bounds(ring_min,theta_for_min)
    low_for_max,high_for_max:=hrtf_bounds(ring_max,theta_for_max)
    weight_phi_min,weight_phi_max:=hrtf_linear_weights(phi,phi_min,phi_max,min_index,max_index)
    w_low_min,w_high_min:=hrtf_linear_weights(theta_for_min,ring_min[low_for_min],ring_min[high_for_min],low_for_min,high_for_min)
    w_low_max,w_high_max:=hrtf_linear_weights(theta_for_max,ring_max[low_for_max],ring_max[high_for_max],low_for_max,high_for_max)
    weights={weight_phi_min*w_low_min,weight_phi_min*w_high_min,weight_phi_max*w_low_max,weight_phi_max*w_high_max}
    indices={min_index*h.rings+low_for_min,min_index*h.rings+high_for_min,max_index*h.rings+low_for_max,max_index*h.rings+high_for_max}
    return
}

// HRTFDatabase::interpolatedHRTF with full spatial blend: blends the log
// magnitudes and unwrapped phases of the four measurements around direction
// and writes, per ear, the spectrum of the blended HRIR at the size of conv.
hrtf_interpolate :: proc "contextless" (h:^Hrtf,conv:^Fft,direction:[3]f32,out:[2][]f32) #no_bounds_check {
    indices,weights:=hrtf_weights(h,direction)
    bins:=h.interp.n/2+1
    for ear in 0..<2 {
        for k in 0..<bins {h.blend_magnitude[k]=0;h.blend_phase[k]=0}
        for j in 0..<4 {
            row:=(ear*h.count+indices[j])*bins
            w:=weights[j]
            for k in 0..<bins {
                h.blend_magnitude[k]+=h.magnitude[row+k]*w
                h.blend_phase[k]+=h.phase[row+k]*w
            }
        }
        for k in 0..<bins {
            p:=h.blend_phase[k]
            p-=2*math.PI*math.round(p/(2*math.PI))
            magnitude:=math.exp(h.blend_magnitude[k])
            sin,cos:=math.sincos(p)
            h.blend_spectrum[2*k],h.blend_spectrum[2*k+1]=magnitude*cos,magnitude*sin
        }
        hrir:=h.blend_hrir[:conv.n]
        for &sample in hrir {sample=0}
        fft_inverse(&h.interp,h.blend_spectrum,hrir[:h.interp.n])
        fft_forward(conv,hrir,out[ear])
    }
}

finite :: proc "contextless" (x:f32) -> bool {return x-x==0}
finite3 :: proc "contextless" (v:[3]f32) -> bool {return finite(v.x) && finite(v.y) && finite(v.z)}
