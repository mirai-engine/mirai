package pcg

import "core:math"
import "mirai:std/base"

// What the CPU knows of the Micro layers of a source: they are not placed
// here, a renderer scatters them on the ground (plugins/foliage). For it a
// cell keeps where its Macro and Meso points stand before anything is
// suppressed (Occupancy, so taking a tree out never lets groundcover sprout
// at its stump), and micro_samples gives, on a grid over a cell, how much of
// the density of a Micro layer stands there: its field, its paint, its
// ground rule, the excluding zones and the Volume of the graph, and none
// where a point stands.

MICRO_SAMPLES :: 65 // per side of the grid of micro_samples over a cell, its corners and borders included

// Of the KEPT_SIDE by KEPT_SIDE squares of a cell (as Pcg_Ground_Cell.kept),
// those whose centre is within the radius of a Macro or Meso point that
// stands, at its scale, a bit each; all clear when nothing with a radius stands.
Occupancy :: [KEPT_WORDS]u64

// Whether a source has a Micro layer.
source_micro :: proc "contextless" (s:^Pcg_Source) -> bool {
    for l in s.layers {if l.tier==.Micro {return true}}
    return false
}

// The squares of a cell the points that stand cover, into o, and its hash
// (0 when none is covered): those of the cells around count where they reach
// in, including authored points of Macro/Meso layers in the 3 by 3 cells.
@(private)
occupancy_raster :: proc(o:^Occupancy,cell_size:f32,stood:[]Stood,s:^Pcg_Source=nil,coord:[2]i32={}) -> (hash:u64) {
    o^={}
    if !(cell_size>0) {return 0}
    step:=cell_size/KEPT_SIDE
    any:=false
    mark :: proc "contextless" (o:^Occupancy,step:f32,at:[2]f32,r:f32,any:^bool) {
        if !(r>0) {return}
        first:=[2]int{int(math.floor((at.x-r)/step)),int(math.floor((at.y-r)/step))}
        last:=[2]int{int(math.floor((at.x+r)/step)),int(math.floor((at.y+r)/step))}
        for v in max(first.y,0)..=min(last.y,KEPT_SIDE-1) {
            for u in max(first.x,0)..=min(last.x,KEPT_SIDE-1) {
                d:=[2]f32{(f32(u)+0.5)*step-at.x,(f32(v)+0.5)*step-at.y}
                if d.x*d.x+d.y*d.y>r*r {continue}
                k:=v*KEPT_SIDE+u
                o[k>>6]|=1<<(uint(k)&63)
                any^=true
            }
        }
    }
    for st in stood {mark(o,step,st.at,st.reach,&any)}
    if s!=nil {
        corner:=cell_corner(cell_size,coord)
        for dz in i32(-1)..=i32(1) {
            for dx in i32(-1)..=i32(1) {
                cell:=source_cell(s,coord+{dx,dz})
                if cell==nil || len(cell.points)==0 {continue}
                for pt in cell.points {
                    l,_:=source_layer(s,pt.layer)
                    if l==nil || l.tier==.Micro || !(l.radius>0) {continue}
                    r:=l.radius*max(pt.scale.x,pt.scale.z)
                    mark(o,step,{pt.position.x-corner.x,pt.position.z-corner.z},r,&any)
                }
            }
        }
    }
    if !any {return 0}
    return base.hash64(([^]u8)(o)[:size_of(Occupancy)])|1
}

// Whether a square of an occupancy at x and z from the corner of its cell is
// covered; past its border, as the nearest square inside it is.
occupied_at :: proc "contextless" (o:^Occupancy,cell_size:f32,x,z:f32) -> bool {
    if !(cell_size>0) {return false}
    step:=cell_size/KEPT_SIDE
    u,v:=x/step,z/step
    if u!=u {u=0}
    if v!=v {v=0}
    k:=int(clamp(v,0,KEPT_SIDE-1))*KEPT_SIDE+int(clamp(u,0,KEPT_SIDE-1))
    return o[k>>6]>>(uint(k)&63)&1!=0
}

// How much of the density of the Micro layer of index `layer` of the source
// of cin stands at each of MICRO_SAMPLES by MICRO_SAMPLES points over its
// cell, x first, from 0 to 255, into out: none off the ground, where the
// ground keeps points out (an excluding zone), outside the Volume of the
// graph, where its ground rule does not take it or occupied says a point
// stands; elsewhere its paint times its field, which reads occupancy 0 there.
// False when its program does not run, or out is short.
micro_samples :: proc(cin:^Pcg_Cell_Input,scratch:^Pcg_Scratch,layer:int,occupied:^Occupancy,out:[]u8) -> bool {
    n:=MICRO_SAMPLES
    s:=cin.source
    if s==nil || layer<0 || layer>=len(s.layers) || len(s.compiled)!=len(s.layers) || len(out)<n*n {return false}
    for &v in out[:n*n] {v=0}
    if cin.ground.absent || cin.ground.samples<2 {return true}
    l:=&s.layers[layer]
    cell:=s.info.cell_size
    step:=cell/f32(n-1)
    mask:=rule_mask(cin,l)
    context.allocator=scratch.allocator
    clear(&scratch.points);clear(&scratch.candidates)
    if !room(&scratch.points,n*n) || !room(&scratch.candidates,n*n) {return false}
    for z in 0..<n {
        for x in 0..<n {
            p:=Point{at={f32(x)*step,f32(z)*step},point=u32(z*n+x)}
            height,normal,ok:=ground_at(cin.ground,p.at.x,p.at.y)
            if !ok || ground_kept_out(cin.ground,p.at.x,p.at.y) {continue}
            if occupied!=nil && occupied_at(occupied,cell,p.at.x,p.at.y) {continue}
            p.height,p.normal=height,normal
            if !region_holds(cin.domain,frame_point(cin,p.at,height)) || !rule_takes(cin,l,&mask,p) {continue}
            append(&scratch.points,p)
            append(&scratch.candidates,u32(len(scratch.points)-1))
        }
    }
    count:=len(scratch.candidates)
    if count==0 {return true}
    if resize(&scratch.viability,count)!=nil {return false}
    if !field_values(cin,scratch,layer,scratch.points[:],scratch.candidates[:],scratch.viability[:count]) {return false}
    for c,i in scratch.candidates {
        p:=scratch.points[c]
        v:=scratch.viability[i]*paint_at(cin.paint,0,cell,p.at.x,p.at.y,false)
        out[p.point]=u8(clamp(v,0,1)*255+0.5)
    }
    return true
}
