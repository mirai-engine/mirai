package terrain

import "core:math"
import "core:math/linalg"
import "core:mem"
import "mirai:std/geom"
import mm "mirai:std/math"

// What a Volume does its own way: its field, a signed distance in blocks, read and written by sample.

// The field of a new Volume: a box of solid under air, an outer layer of air around it.
@(private)
volume_box :: proc(s:^Source) -> bool {
    cell:=s.cell
    half:=[3]f32{f32(s.samples.x-1),f32(s.samples.y-1),f32(s.samples.z-1)}*(cell*0.5)
    bottom:=-half.y+cell
    center_y:=bottom*0.5
    extents:=[3]f32{max(half.x-cell,cell*0.25),max(-bottom*0.5,cell*0.25),max(half.z-cell,cell*0.25)}
    // Each block takes values of its own only where it is not all air or all solid.
    Block :: struct {s:^Source,center_y:f32,extents:[3]f32}
    distance :: proc(b:^Block,p:[3]f32) -> f32 {
        p:=p-[3]f32{0,b.center_y,0}
        d:=[3]f32{abs(p.x),abs(p.y),abs(p.z)}-b.extents
        outside:=[3]f32{max(d.x,0),max(d.y,0),max(d.z,0)}
        return linalg.length(outside)+min(max(d.x,max(d.y,d.z)),0)
    }
    page :: proc(user:rawptr,first,extent:[3]int,values:[]f32) -> (fill:f32,uniform:bool) {
        b:=(^Block)(user)
        s:=b.s
        band:=s.cell*SDF_BAND_CELLS
        // A block further from the faces of the solid than its own reach is all air or all solid.
        low,high:=source_point(s,first),source_point(s,first+extent-1)
        middle:=distance(b,(low+high)*0.5)
        if reach:=linalg.length(high-low)*0.5;abs(middle)-reach>=band {return middle<0?-band:band,true}
        for z in 0..<extent.z {for y in 0..<extent.y {for x in 0..<extent.x {
            values[x+extent.x*(y+extent.y*z)]=clamp(distance(b,source_point(s,first+{x,y,z})),-band,band)
        }}}
        return
    }
    block:=Block{s,center_y,extents}
    if !grid_generate(&s.field,&block,page,s.allocator) {source_destroy(s);return false}
    s.field.filled=false
    return true
}

volume_density :: proc "contextless" (s:^Source,point:[3]f32) -> f32 {
    p:=(point-source_origin(s))/s.cell
    base_cell:[3]int
    weight:[3]f32
    for axis in 0..<3 {
        at:=clamp(p[axis],0,f32(s.samples[axis]-1))
        base_cell[axis]=min(int(at),int(s.samples[axis])-2)
        weight[axis]=at-f32(base_cell[axis])
    }
    result:=f32(0)
    for corner in 0..<8 {
        offset:=[3]int{corner&1,(corner>>1)&1,(corner>>2)&1}
        w:=(offset.x==0?1-weight.x:weight.x)*(offset.y==0?1-weight.y:weight.y)*(offset.z==0?1-weight.z:weight.z)
        result+=block_get(&s.field,base_cell+offset)*w
    }
    return result
}

// The first surface of a Volume a ray from origin along d meets between near and far.
@(private)
volume_ray :: proc(s:^Source,origin,d,low:[3]f32,near,far:f32) -> (point,normal:[3]f32,ok:bool) {
    near:=near
    // Each cell is extracted from a window of its samples and those its gradients read,
    // into memory of the call: rays of other threads read the same source.
    window:[4*4*4]f32
    backing:[4096]u8
    arena:mem.Arena
    mem.arena_init(&arena,backing[:])
    ray_mesh:geom.Mesh_Buffer
    geom.mesh_buffer_init(&ray_mesh,mem.arena_allocator(&arena))
    grid:=geom.Scalar_Grid{samples={int(s.samples.x),int(s.samples.y),int(s.samples.z)},cell={s.cell,s.cell,s.cell},origin=low}
    start:=(origin+d*(near+s.cell*1e-5)-low)/s.cell
    cell,advance:[3]int
    for axis in 0..<3 {cell[axis]=clamp(int(math.floor(start[axis])),0,int(s.samples[axis])-2);advance[axis]=d[axis]>=0?1:-1}
    for _ in 0..<int(s.samples.x+s.samples.y+s.samples.z)+4 {
        next:=[3]f32{1e9,1e9,1e9}
        for axis in 0..<3 {if abs(d[axis])>1e-9 {next[axis]=(low[axis]+f32(cell[axis]+(advance[axis]>0?1:0))*s.cell-origin[axis])/d[axis]}}
        end:=min(far,min(next.x,min(next.y,next.z)))
        last:[3]int
        for axis in 0..<3 {grid.first[axis],last[axis]=max(cell[axis]-1,0),min(cell[axis]+2,int(s.samples[axis])-1)}
        // A cell whose blocks are not in memory ends the ray: nothing is known past it.
        if !source_region_held(s,grid.first,last) {return}
        grid.extent=last-grid.first+1
        grid.values=window[:grid.extent.x*grid.extent.y*grid.extent.z]
        for z in 0..<grid.extent.z {for y in 0..<grid.extent.y {for x in 0..<grid.extent.x {
            window[x+grid.extent.x*(y+grid.extent.y*z)]=block_get(&s.field,grid.first+{x,y,z})
        }}}
        // A cell with every sample around it on one side holds no surface.
        crossed:=false
        for value in grid.values[1:] {if (value<0)!=(grid.values[0]<0) {crossed=true;break}}
        if !crossed {
            if end>=far {return}
            for axis in 0..<3 {
                if next[axis]>end {continue}
                cell[axis]+=advance[axis]
                if cell[axis]<0 || cell[axis]>=int(s.samples[axis])-1 {return}
            }
            near=end
            continue
        }
        if geom.isosurface(grid,cell,cell+[3]int{1,1,1},&ray_mesh)!=.None {return}
        best:=f32(1e9)
        for triangle:=0;triangle<len(ray_mesh.indices);triangle+=3 {
            a,b,c:=ray_mesh.positions[ray_mesh.indices[triangle]],ray_mesh.positions[ray_mesh.indices[triangle+1]],ray_mesh.positions[ray_mesh.indices[triangle+2]]
            face:=mm.Triangle{a,b,c}
            t,_,hit:=mm.ray_triangle({origin,d},face)
            if hit && t>=near-s.cell*1e-4 && t<=end+s.cell*1e-4 && t<best {best=t;normal=mm.triangle_normal(face);ok=true}
        }
        if ok {return origin+d*best,normal,true}
        if end>=far {return}
        for axis in 0..<3 {
            if next[axis]>end {continue}
            cell[axis]+=advance[axis]
            if cell[axis]<0 || cell[axis]>=int(s.samples[axis])-1 {return}
        }
        near=end
    }
    return
}
