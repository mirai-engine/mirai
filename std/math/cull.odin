package mirai_math

import "core:simd"

// Frustum culling of many boxes at once. Bit i of `visible` is set when
// boxes[i] passes frustum_overlaps_aabb and cleared when it does not;
// `visible` needs a bit for every box: without them it writes nothing and
// returns 0. Returns how many passed.
//
// Each box is tested against the six planes together, four lanes at a time,
// from its center and half size.
frustum_cull_aabbs :: proc "contextless" (frustum:Frustum,boxes:[]Aabb,visible:[]u64) -> int {
    if len(visible)<(len(boxes)+63)>>6 {return 0}
    // Planes 0-3 and 4-5; the two spare lanes hold a plane that everything passes.
    nx,ny,nz,d,ax,ay,az:[2]simd.f32x4
    {
        x,y,z,w:[8]f32
        for plane,side in frustum.planes {
            x[side],y[side],z[side],w[side]=plane.normal.x,plane.normal.y,plane.normal.z,plane.d
        }
        for group in 0..<2 {
            o:=group*4
            nx[group]=simd.f32x4{x[o],x[o+1],x[o+2],x[o+3]}
            ny[group]=simd.f32x4{y[o],y[o+1],y[o+2],y[o+3]}
            nz[group]=simd.f32x4{z[o],z[o+1],z[o+2],z[o+3]}
            d[group]=simd.f32x4{w[o],w[o+1],w[o+2],w[o+3]}
            ax[group],ay[group],az[group]=simd.abs(nx[group]),simd.abs(ny[group]),simd.abs(nz[group])
        }
    }
    zero:simd.f32x4
    count:=0
    for &word in visible[:(len(boxes)+63)>>6] {word=0}
    // No branch on the result: whether a box is visible is not predictable.
    #no_bounds_check for box,index in boxes {
        center,half:=(box.min+box.max)*0.5,(box.max-box.min)*0.5
        cx,cy,cz:=simd.f32x4(center.x),simd.f32x4(center.y),simd.f32x4(center.z)
        hx,hy,hz:=simd.f32x4(half.x),simd.f32x4(half.y),simd.f32x4(half.z)
        // Signed distance of the corner of the box farthest along each normal.
        first:=nx[0]*cx+ny[0]*cy+nz[0]*cz+d[0]+ax[0]*hx+ay[0]*hy+az[0]*hz
        second:=nx[1]*cx+ny[1]*cy+nz[1]*cz+d[1]+ax[1]*hx+ay[1]*hy+az[1]*hz
        outside:=simd.reduce_or(simd.bit_or(simd.lanes_lt(first,zero),simd.lanes_lt(second,zero)))
        inside:=u64(outside==0)
        visible[index>>6]|=inside<<uint(index&63)
        count+=int(inside)
    }
    return count
}

// The same result one plane at a time: the reference frustum_cull_aabbs is checked and measured against.
@(private)
frustum_cull_aabbs_scalar :: proc "contextless" (frustum:Frustum,boxes:[]Aabb,visible:[]u64) -> int {
    count:=0
    if len(visible)<(len(boxes)+63)>>6 {return 0}
    for &word in visible[:(len(boxes)+63)>>6] {word=0}
    #no_bounds_check for box,index in boxes {
        if frustum_overlaps_aabb(frustum,box) {
            visible[index>>6]|=u64(1)<<uint(index&63)
            count+=1
        }
    }
    return count
}
