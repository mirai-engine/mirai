package terrain

import "core:math"
import mm "mirai:std/math"

// What a Heightfield does its own way: its field, one height per sample over X/Z.

source_height :: proc "contextless" (s:^Source,x,z:f32) -> f32 {
    origin:=source_origin(s)
    column,row:=clamp((x-origin.x)/s.cell,0,f32(s.samples.x-1)),clamp((z-origin.z)/s.cell,0,f32(s.samples.z-1))
    c,r:=min(int(column),int(s.samples.x)-2),min(int(row),int(s.samples.z)-2)
    u,v:=column-f32(c),row-f32(r)
    a,b:=grid_get(&s.field,c,r),grid_get(&s.field,c+1,r)
    d,e:=grid_get(&s.field,c,r+1),grid_get(&s.field,c+1,r+1)
    if u+v<=1 {return a+(b-a)*u+(d-a)*v}
    return e+(d-e)*(1-u)+(b-e)*(1-v)
}

// The first surface of a Heightfield a ray from origin along d meets between near and far.
@(private)
heightfield_ray :: proc(s:^Source,origin,d,low:[3]f32,near,far:f32) -> (point,normal:[3]f32,ok:bool) {
    near:=near
    start:=(origin+d*(near+s.cell*1e-5)-low)/s.cell
    c,r:=clamp(int(math.floor(start.x)),0,int(s.samples.x)-2),clamp(int(math.floor(start.z)),0,int(s.samples.z)-2)
    sx,sz:=d.x>=0?1:-1,d.z>=0?1:-1
    for _ in 0..<int(s.samples.x+s.samples.z)+2 {
        tx,tz:=f32(1e9),f32(1e9)
        if abs(d.x)>1e-9 {tx=(low.x+f32(c+(sx>0?1:0))*s.cell-origin.x)/d.x}
        if abs(d.z)>1e-9 {tz=(low.z+f32(r+(sz>0?1:0))*s.cell-origin.z)/d.z}
        end:=min(far,min(tx,tz))
        // A cell whose pages are not in memory ends the ray: nothing is known past it.
        if !cell_held(s,c,r) {return}
        a,b,e,f:=source_point(s,{c,0,r}),source_point(s,{c+1,0,r}),source_point(s,{c,0,r+1}),source_point(s,{c+1,0,r+1})
        best:=f32(1e9)
        faces:=[2]mm.Triangle{{a,e,b},{b,e,f}}
        for triangle in faces[:source_hole(s,c,r)?0:2] {
            t,_,hit:=mm.ray_triangle({origin,d},triangle)
            if hit && t>=near-s.cell*1e-4 && t<=end+s.cell*1e-4 && t<best {best=t;normal=mm.triangle_normal(triangle);ok=true}
        }
        if ok {return origin+d*best,normal,true}
        if end>=far || tx==1e9 && tz==1e9 {return}
        if tx<=tz {c+=sx}
        if tz<=tx {r+=sz}
        if c<0 || r<0 || c>=int(s.samples.x)-1 || r>=int(s.samples.z)-1 {return}
        near=end
    }
    return
}

// Whether the four samples around cell c,r of a Heightfield are in memory.
cell_held :: #force_inline proc "contextless" (s:^Source,c,r:int) -> bool {
    g:=&s.field
    if !g.paged {return true}
    return !grid_absent(g,c/PAGE+g.counts.x*(r/PAGE)) && !grid_absent(g,(c+1)/PAGE+g.counts.x*(r/PAGE)) && !grid_absent(g,c/PAGE+g.counts.x*((r+1)/PAGE)) && !grid_absent(g,(c+1)/PAGE+g.counts.x*((r+1)/PAGE))
}

// The height of a Heightfield at a local point x,z, as source_height; ok is
// false outside the source or where its pages are not in memory.
source_height_held :: proc "contextless" (s:^Source,x,z:f32) -> (height:f32,ok:bool) {
    if s.kind!=.Heightfield || !source_valid(s.info) || len(s.field.pages)==0 {return}
    origin:=source_origin(s)
    column,row:=(x-origin.x)/s.cell,(z-origin.z)/s.cell
    if !(column>=0 && row>=0 && column<=f32(s.samples.x-1) && row<=f32(s.samples.z-1)) {return}
    if !cell_held(s,min(int(column),int(s.samples.x)-2),min(int(row),int(s.samples.z)-2)) {return}
    return source_height(s,x,z),true
}

// The level of each chunk of a Heightfield: the coarsest its error lets the view see, or by its
// distance, made finer where it meets a finer neighbor (lod_levels_balance). A chunk with holes or
// joined to a Volume stays at level 0.
@(private)
heightfield_levels :: proc(entry:^Data_Source,source:^Resident_Source,settings:Terrain_Settings,by_error:bool,base:f32) {
    s:=&entry.source
    q:=&source.quad
    for &level,i in source.levels {
        chunk:=&source.chunks[i]
        next:=u8(0)
        joined:=source.join.ground!={} && join_side_chunk(s,i) || join_cut_key(s,source.join.cuts[:],i)!=0
        if settings.lod_distance>=0 && !chunk_holed(s,i) && !joined {
            maximum:=chunk_lod_max(s,chunk_coord(s,i))
            next=lod_level_error(entry.errors,q,i,0,maximum,chunk.pixels,chunk.spacing,s.cell,level)
            // The distance makes a chunk coarser only as far as its error lets it be.
            if !by_error {
                distant:=lod_level(chunk.distance,base,maximum,level)
                next=len(entry.errors)==quad_total(q)?min(distant,next):distant
            }
        }
        level=next
    }
    lod_levels_balance(s,source.levels)
}
