package terrain

import "core:math/linalg"

// The surface of a Heightfield at a point of its space from its coarse grid,
// which is in memory while the source is, whatever pages are: its height
// (the bilinear blend of coarse_height), its normal there and the weights of
// the layers it shows, painted with its automatic layers over them. A hole
// counts where its page is in memory, and elsewhere in a cell of the coarse
// grid at least half holes, as the far pieces cut them. False off the source.
source_coarse_at :: proc "contextless" (s:^Source,x,z:f32) -> (height:f32,normal:[3]f32,weights:Layer_Mix,ok:bool) {
    if s.kind!=.Heightfield || !source_valid(s.info) || s.samples.x<2 || s.samples.z<2 {return}
    nx,nz:=int(s.samples.x),int(s.samples.z)
    origin:=source_origin(s)
    column,row:=(x-origin.x)/s.cell,(z-origin.z)/s.cell
    if !(column>=0 && row>=0 && column<=f32(nx-1) && row<=f32(nz-1)) {return}
    c,r:=min(int(column),nx-2),min(int(row),nz-2)
    if cell_held(s,c,r) {
        if source_hole(s,c,r) {return}
    } else if !grid_none(&s.coarse.holes) && grid_get(&s.coarse.holes,min(c/COARSE,s.coarse.holes.size.x-1),min(r/COARSE,s.coarse.holes.size.z-1))>=128 {return}
    along :: proc "contextless" (p:f32,samples:int) -> (i:int,t,span:f32) {
        i=min(int(p)/COARSE,coarse_count(samples)-2)
        low,high:=coarse_position(i,samples),coarse_position(i+1,samples)
        return i,clamp((p-f32(low))/f32(high-low),0,1),f32(high-low)
    }
    i,u,span_x:=along(column,nx)
    j,v,span_z:=along(row,nz)
    a,b:=coarse_value(s,i,j),coarse_value(s,i+1,j)
    d,e:=coarse_value(s,i,j+1),coarse_value(s,i+1,j+1)
    height=(a*(1-u)+b*u)*(1-v)+(d*(1-u)+e*u)*v
    dx:=((b-a)*(1-v)+(e-d)*v)/(span_x*s.cell)
    dz:=((d-a)*(1-u)+(e-b)*u)/(span_z*s.cell)
    normal=linalg.normalize0([3]f32{-dx,1,-dz})
    wa,wb:=coarse_weight(s,i,j),coarse_weight(s,i+1,j)
    wd,we:=coarse_weight(s,i,j+1),coarse_weight(s,i+1,j+1)
    weights=layers_vertex(s,(wa*(1-u)+wb*u)*(1-v)+(wd*(1-u)+we*u)*v,normal,height)
    return height,normal,weights,true
}
