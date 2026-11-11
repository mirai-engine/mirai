package terrain

import "core:math"
import "mirai:std/geom"
import mm "mirai:std/math"

// A closed mesh joined to a Volume (Add) or taken out of it (Carve), as a
// brush with its shape would: the mesh, in the space of the source, turns
// into distances over the samples it reaches, within the band, and those
// join the field over brush.blend, a part brush.amount of the way. What it
// turns solid is of brush.layer. Invalid for another kind of source or of
// brush, or a mesh that is not closed.
source_volume_mesh :: proc(s:^Source,operand:geom.Mesh,brush:Brush) -> (change:Change) {
    s.dug={}
    if s.kind!=.Volume || brush.kind!=.Add && brush.kind!=.Carve || !source_valid(s.info) || !source_samples_held(s) {return {error=.Invalid}}
    if !(brush.amount>0 && brush.amount<=1) {return {error=.Amount}}
    if !(brush.blend>=0) || brush.blend>HEIGHT_LIMIT {return {error=.Blend}}
    if brush.kind==.Add && brush.layer>=s.layer_count {return {error=.Layer}}
    if len(operand.indices)<12 || len(operand.indices)%3!=0 || !geom.mesh_is_valid(operand) || !geom.mesh_is_closed(operand.positions,operand.indices) {return {error=.Invalid}}
    band:=s.cell*SDF_BAND_CELLS
    origin:=source_origin(s)
    bounds_low,bounds_high:=geom.mesh_bounds(operand.positions)
    margin:=brush.blend+band
    low,high:[3]int
    for axis in 0..<3 {
        lo,hi:=math.ceil((bounds_low[axis]-margin-origin[axis])/s.cell),math.floor((bounds_high[axis]+margin-origin[axis])/s.cell)
        first,last:=f32(1),f32(s.samples[axis]-2)
        if hi<first || lo>last {return}
        low[axis],high[axis]=int(clamp(lo,first,last)),int(clamp(hi,first,last))
    }
    size:=high-low+1
    count:=size.x*size.y*size.z
    // The distance of each sample to the mesh, and whether it is inside: one more value each.
    if resize(&s.scratch,2*count)!=nil {return {error=.Out_Of_Memory}}
    distances,inside:=s.scratch[:count],s.scratch[count:2*count]
    reach:=margin+s.cell
    for &d in distances {d=reach}
    for &v in inside {v=0}
    // A sample a hair off the lattice never lies on an edge two triangles share.
    nudge:=[2]f32{0.000137,0.000291}*s.cell
    for t:=0;t<len(operand.indices);t+=3 {
        a,b,c:=operand.positions[operand.indices[t]],operand.positions[operand.indices[t+1]],operand.positions[operand.indices[t+2]]
        triangle:=mm.Triangle{a,b,c}
        from,to:[3]int
        outside:=false
        for axis in 0..<3 {
            from[axis]=max(int(math.ceil((min(a[axis],b[axis],c[axis])-reach-origin[axis])/s.cell)),low[axis])
            to[axis]=min(int(math.floor((max(a[axis],b[axis],c[axis])+reach-origin[axis])/s.cell)),high[axis])
            outside||=from[axis]>to[axis]
        }
        if !outside {
            for z in from.z..=to.z {for y in from.y..=to.y {for x in from.x..=to.x {
                p:=origin+[3]f32{f32(x),f32(y),f32(z)}*s.cell
                offset:=p-mm.closest_point_triangle(p,triangle)
                at:=x-low.x+size.x*(y-low.y+size.y*(z-low.z))
                distances[at]=min(distances[at],math.sqrt(offset.x*offset.x+offset.y*offset.y+offset.z*offset.z))
            }}}
        }
        // Each column the triangle is over: the samples under where it crosses turn in or out.
        x0:=max(int(math.ceil((min(a.x,b.x,c.x)-origin.x)/s.cell))-1,low.x)
        x1:=min(int(math.floor((max(a.x,b.x,c.x)-origin.x)/s.cell)),high.x)
        z0:=max(int(math.ceil((min(a.z,b.z,c.z)-origin.z)/s.cell))-1,low.z)
        z1:=min(int(math.floor((max(a.z,b.z,c.z)-origin.z)/s.cell)),high.z)
        area:=(b.x-a.x)*(c.z-a.z)-(b.z-a.z)*(c.x-a.x)
        if area==0 {continue}
        for z in z0..=z1 {for x in x0..=x1 {
            px,pz:=origin.x+f32(x)*s.cell+nudge.x,origin.z+f32(z)*s.cell+nudge.y
            u:=((px-a.x)*(c.z-a.z)-(pz-a.z)*(c.x-a.x))/area
            v:=((b.x-a.x)*(pz-a.z)-(b.z-a.z)*(px-a.x))/area
            if u<0 || v<0 || u+v>1 {continue}
            crossing:=a.y+(b.y-a.y)*u+(c.y-a.y)*v
            top:=min(int(math.ceil((crossing-origin.y)/s.cell))-1,high.y)
            for y in low.y..=top {
                at:=x-low.x+size.x*(y-low.y+size.y*(z-low.z))
                inside[at]=1-inside[at]
            }
        }}
    }
    change.low=high;change.high=low
    if !grid_prepare(&s.field,low,high,s.allocator) {return {error=.Out_Of_Memory}}
    defer grid_settle(&s.field,low,high,s.allocator)
    layered:=brush.kind==.Add
    if layered && !grid_prepare(&s.weights,low,high,s.allocator) {return {error=.Out_Of_Memory}}
    defer if layered {grid_settle(&s.weights,low,high,s.allocator)}
    for z in low.z..=high.z {for y in low.y..=high.y {for x in low.x..=high.x {
        p:=[3]int{x,y,z}
        at:=x-low.x+size.x*(y-low.y+size.y*(z-low.z))
        d:=inside[at]!=0?-distances[at]:distances[at]
        old:=source_value(s,p)
        target:=brush.kind==.Add?smooth_min(old,d,brush.blend):-smooth_min(-old,d,brush.blend)
        value:=clamp(math.lerp(old,target,brush.amount),-band,band)
        if value==old {continue}
        dug_count(s,p,old,value)
        if layered {grid_write(&s.weights,p,weights_grow(grid_value(&s.weights,p),int(brush.layer),int(s.layer_count),volume_solid(old,s.cell),volume_solid(value,s.cell)))}
        block_set(&s.field,p,value)
        change.changed=true
        for axis in 0..<3 {change.low[axis]=min(change.low[axis],p[axis]);change.high[axis]=max(change.high[axis],p[axis])}
    }}}
    return
}

// The surface of a Volume as one mesh in the space of its terrain, welded:
// what a plain .mesh of what was dug is made from. Its uvs are its place over
// UV_METERS across x and z. False without a surface, where a page of the
// source is not in memory, or without memory.
source_surface :: proc(s:^Source,out:^geom.Mesh_Buffer) -> bool {
    if s.kind!=.Volume || !source_valid(s.info) || !source_samples_held(s) {return false}
    geom.mesh_buffer_clear(out)
    part:Chunk_Mesh
    chunk_mesh_init(&part,s.allocator)
    defer chunk_mesh_destroy(&part)
    merged:geom.Mesh_Buffer
    geom.mesh_buffer_init(&merged,s.allocator)
    defer geom.mesh_buffer_destroy(&merged)
    counts:=chunk_counts(s)
    for i in 0..<counts.x*counts.y*counts.z {
        coord:=chunk_coord(s,i)
        if !chunk_build_terrain(s,coord,&part,false) {return false}
        g:=&part.geometry
        if len(g.indices)==0 {continue}
        first:=u32(len(merged.positions))
        if append(&merged.positions,..g.positions[:])!=len(g.positions) || append(&merged.normals,..g.normals[:])!=len(g.normals) {return false}
        if reserve(&merged.indices,len(merged.indices)+len(g.indices))!=nil {return false}
        for index in g.indices {append(&merged.indices,first+index)}
    }
    if len(merged.indices)==0 || !geom.mesh_weld(geom.mesh_buffer_view(&merged),0,out) {return false}
    if resize(&out.uvs,len(out.positions))!=nil {return false}
    for p,i in out.positions {out.uvs[i]={p.x,p.z}/UV_METERS}
    return true
}
