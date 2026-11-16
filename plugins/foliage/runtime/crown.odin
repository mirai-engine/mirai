package foliage

import "core:math"
import "core:math/linalg"
import "mirai:std/geom"

// The crown of a type: what rays meet of its far instances in place of its
// mesh, which their impostors draw. It is the surface of the voxels of the
// box of the type where its triangles are dense, coarse and opaque: the far
// forest keeps casting its shadow without leaves of alpha. Each face sits
// inside its voxel by CROWN_INSET of it, so that the surface an impostor
// draws, at the depth of its leaves, is lit from the side that faces the
// light; faces reach past the edges of their voxel as far, so that the
// surface has no cracks where they meet.

CROWN_CELLS :: 8        // voxels along the longest side of the box
CROWN_SURFACE :: f32(1) // area a voxel holds, in faces of it, to be solid: as much leaf as one of its sides
CROWN_INSET :: f32(0.3) // of a voxel: how far inside it each face is

// The crown of some triangles, written to out (positions, a normal a vertex
// and indices; flat faces). False when they span nothing, or no voxel holds
// enough of them.
crown_build :: proc(positions:[][3]f32,indices:[]u32,out:^geom.Mesh_Buffer) -> bool {
    geom.mesh_buffer_clear(out)
    if len(indices)<3 {return false}
    low,high:=[3]f32{max(f32),max(f32),max(f32)},[3]f32{min(f32),min(f32),min(f32)}
    for index in indices {
        if int(index)>=len(positions) {return false}
        p:=positions[index]
        low,high=linalg.min(low,p),linalg.max(high,p)
    }
    size:=high-low
    longest:=max(size.x,size.y,size.z)
    if !(longest>1e-6) || math.is_inf(longest) {return false}
    cell:=longest/CROWN_CELLS
    dims:[3]int
    for axis in 0..<3 {dims[axis]=clamp(int(math.ceil(size[axis]/cell)),1,CROWN_CELLS)}
    area:[CROWN_CELLS*CROWN_CELLS*CROWN_CELLS]f32
    voxel :: proc(p,low:[3]f32,cell:f32,dims:[3]int) -> int {
        at:[3]int
        for axis in 0..<3 {at[axis]=clamp(int((p[axis]-low[axis])/cell),0,dims[axis]-1)}
        return (at.z*dims.y+at.y)*dims.x+at.x
    }
    // Each triangle spreads its area over points of it, a few to a voxel.
    for i:=0;i+2<len(indices);i+=3 {
        a,b,c:=positions[indices[i]],positions[indices[i+1]],positions[indices[i+2]]
        triangle:=0.5*linalg.length(linalg.cross(b-a,c-a))
        if !(triangle>0) {continue}
        count:=clamp(int(math.ceil(4*triangle/(cell*cell))),1,64)
        for k in 0..<count {
            // The R2 sequence folded into the triangle: points spread evenly over it.
            u,v:=math.mod(0.3+f32(k)*0.7548777,1),math.mod(0.6+f32(k)*0.5698403,1)
            if u+v>1 {u,v=1-u,1-v}
            area[voxel(a+(b-a)*u+(c-a)*v,low,cell,dims)]+=triangle/f32(count)
        }
    }
    solid :: proc(area:^[CROWN_CELLS*CROWN_CELLS*CROWN_CELLS]f32,dims:[3]int,cell:f32,at:[3]int) -> bool {
        for axis in 0..<3 {if at[axis]<0 || at[axis]>=dims[axis] {return false}}
        return area[(at.z*dims.y+at.y)*dims.x+at.x]>=CROWN_SURFACE*cell*cell
    }
    inset,reach:=CROWN_INSET*cell,CROWN_INSET*cell
    for z in 0..<dims.z do for y in 0..<dims.y do for x in 0..<dims.x {
        at:=[3]int{x,y,z}
        if !solid(&area,dims,cell,at) {continue}
        corner:=low+[3]f32{f32(x),f32(y),f32(z)}*cell
        for axis in 0..<3 do for side in 0..<2 {
            next:=at
            next[axis]+=side*2-1
            if solid(&area,dims,cell,next) {continue}
            // The face across axis, on the side of the empty voxel, inside by inset.
            normal:[3]f32
            normal[axis]=f32(side*2-1)
            plane:=corner[axis]+(f32(side)*cell)-normal[axis]*inset
            u,v:=(axis+1)%3,(axis+2)%3
            first:=u32(len(out.positions))
            for k in 0..<4 {
                p:[3]f32
                p[axis]=plane
                p[u]=corner[u]+(k==1 || k==2?cell+reach:-reach)
                p[v]=corner[v]+(k>=2?cell+reach:-reach)
                append(&out.positions,p)
                append(&out.normals,normal)
            }
            // Counter-clockwise seen from outside.
            quad:=side==1?[6]u32{0,1,2,0,2,3}:[6]u32{0,2,1,0,3,2}
            for q in quad {append(&out.indices,first+q)}
        }
    }
    return len(out.indices)>0
}
