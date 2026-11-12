package terrain

import "core:math"
import "core:testing"

// A displaced chunk splits its cells on the triangles of its collider, keeps
// the side it shares with a chunk that is not displaced at the steps of that
// chunk, takes the fine steps on a side it shares with another, and leaves
// its holes empty.
@(test)
displaced_chunks_split_their_cells_on_the_collider_and_join_their_neighbors :: proc(t:^testing.T) {
    s:Source;defer source_destroy(&s)
    lod_seam_source(t,&s)
    hole:=source_point(&s,{5,0,6})+{s.cell*0.5,0,s.cell*0.5}
    testing.expect(t,source_edit(&s,{kind=.Hole,center=hole,radius=0.2}).changed)
    testing.expect(t,source_hole(&s,5,6))
    counts:=chunk_counts(&s)
    levels:=make([]u8,counts.x*counts.z);defer delete(levels)
    lod:=chunk_lod_sides(&s,levels,{0,0,0})
    DETAIL :: 2
    mesh:Chunk_Mesh;chunk_mesh_init(&mesh);defer chunk_mesh_destroy(&mesh)
    testing.expect(t,chunk_detail_build(&s,{0,0,0},lod,DETAIL,{0,DETAIL,0,0},&mesh))
    chunk_in_terrain(&mesh)
    m:=&mesh.geometry
    low,high,_:=chunk_region(&s,{0,0,0})
    start,end:=source_point(&s,low),source_point(&s,high)
    on_line :: proc "contextless" (value,from,cell:f32,steps:f32) -> bool {
        at:=(value-from)/cell*steps
        return abs(at-math.round(at))<1e-3
    }
    west,east:=0,0
    for p in m.positions {
        testing.expectf(t,abs(p.y-source_height(&s,p.x,p.z))<1e-4,"a vertex at %v is off the collider",p)
        testing.expect(t,on_line(p.x,start.x,s.cell,1<<DETAIL) && on_line(p.z,start.z,s.cell,1<<DETAIL))
        if abs(p.x-start.x)<1e-4 {
            west+=1
            testing.expectf(t,on_line(p.z,start.z,s.cell,1),"the side shared with a chunk not displaced has a vertex between samples at %v",p)
        }
        if abs(p.x-end.x)<1e-4 {east+=1}
    }
    cells:=high.z-low.z
    testing.expect_value(t,west,cells+1)
    testing.expect_value(t,east,cells<<DETAIL+1)
    // The chunk beside it at level 0 builds the same vertices along their side.
    neighbor:Chunk_Mesh;chunk_mesh_init(&neighbor);defer chunk_mesh_destroy(&neighbor)
    testing.expect(t,chunk_build(&s,{0,0,1},&neighbor,false,chunk_lod_sides(&s,levels,{0,0,1})))
    chunk_in_terrain(&neighbor)
    shared:=0
    for p in neighbor.geometry.positions {
        if abs(p.z-end.z)>1e-4 {continue}
        found:=false
        for q in m.positions {if abs(q.z-end.z)<1e-4 && abs(q.x-p.x)<1e-4 && abs(q.y-p.y)<1e-4 {found=true;break}}
        testing.expectf(t,found,"the vertex %v of the side the chunks share is not in the displaced one",p)
        shared+=1
    }
    testing.expect_value(t,shared,high.x-low.x+1)
    for corner:=0;corner+2<len(m.indices);corner+=3 {
        c:=(m.positions[m.indices[corner]]+m.positions[m.indices[corner+1]]+m.positions[m.indices[corner+2]])/3
        x,z:=int(math.floor((c.x-start.x)/s.cell))+low.x,int(math.floor((c.z-start.z)/s.cell))+low.z
        testing.expect(t,!source_hole(&s,x,z))
        a,b,d:=m.positions[m.indices[corner]],m.positions[m.indices[corner+1]],m.positions[m.indices[corner+2]]
        up:=(b.z-a.z)*(d.x-a.x)-(b.x-a.x)*(d.z-a.z)
        testing.expect(t,up>=0)
    }
}
