package foliage

import "core:math/linalg"
import "mirai:core"
import "mirai:std/base"
import mm "mirai:std/math"
import pcg "plugins:pcg/runtime"

// What a game asks of the foliage of its world, collides it or not: the
// instances that stand in a sphere or a box, and where an instance stands
// and what its layer places. As the world has them: what the graph of each
// Foliage placed in the cells it keeps, without what was taken out, at any
// detail. For harvesting, an AI that looks for wood or cover, or a felled
// tree promoted where it stood (foliage_promote). An instance is in an area
// when its place (the foot of its pivot) is.

// An instance of a Foliage as the world has it.
Foliage_Found :: struct {
    plant:pcg.Pcg_Instance,
    layer:u32,              // the id of its layer in the source of its graph
    asset:base.Asset_Id,    // what its layer places
    transform:mm.Transform, // in the world, as its batches draw it
}

// The instances of every Foliage within radius of center, in the world,
// appended to out. False without memory, with what fit appended.
foliage_in_sphere :: proc(out:^[dynamic]Foliage_Found,center:[3]f32,radius:f32,data:core.Ref(pcg.Pcg_Data),generated:core.Ref(pcg.Pcg_Generated),foliages:^core.Table(Foliage,$A),graphs:^core.Table(pcg.Pcg_Graph,$B),worlds:^core.Table(core.World_Transform,$C)) -> bool {
    if !(radius>=0) {return true}
    return plants_in(out,center-radius,center+radius,center,radius,data.ptr,generated.ptr,foliages,graphs,worlds)
}

// The instances of every Foliage in the box from low to high, in the world,
// appended to out. False without memory, with what fit appended.
foliage_in_box :: proc(out:^[dynamic]Foliage_Found,low,high:[3]f32,data:core.Ref(pcg.Pcg_Data),generated:core.Ref(pcg.Pcg_Generated),foliages:^core.Table(Foliage,$A),graphs:^core.Table(pcg.Pcg_Graph,$B),worlds:^core.Table(core.World_Transform,$C)) -> bool {
    return plants_in(out,low,high,{},-1,data.ptr,generated.ptr,foliages,graphs,worlds)
}

// Where an instance stands and what its layer places; false when the world
// does not show it (taken out, its cell not kept, its Foliage not there).
foliage_plant :: proc(plant:pcg.Pcg_Instance,generated:core.Ref(pcg.Pcg_Generated),foliages:^core.Table(Foliage,$A),graphs:^core.Table(pcg.Pcg_Graph,$B),worlds:^core.Table(core.World_Transform,$C)) -> (found:Foliage_Found,ok:bool) {
    if !core.has(foliages,plant.graph) {return}
    graph:=core.get(graphs,plant.graph) or_return
    world:=core.get(worlds,plant.graph) or_return
    cell:=pcg.generated_cell(pcg.generated_graph(generated.ptr,plant.graph),plant.coord)
    if cell==nil {return}
    p:=pcg.placed_find(cell.placed[:],plant.id) or_return
    return found_of(plant.graph,plant.coord,p,pcg.graph_frame(graph,world.transform)),true
}

@(private="file")
found_of :: proc "contextless" (e:core.Entity,coord:[2]i32,p:pcg.Placed,frame:mm.Transform) -> Foliage_Found {
    return {{e,coord,p.id},p.layer,p.asset,{mm.transform_point(frame,p.position),frame.rotation*p.rotation,p.scale*frame.scale}}
}

// The instances in a box of the world and, with a radius of 0 or more, in
// the sphere it holds; by Foliage, in the order of their cells.
@(private="file")
plants_in :: proc(out:^[dynamic]Foliage_Found,low,high,center:[3]f32,radius:f32,data:^pcg.Pcg_Data,generated:^pcg.Pcg_Generated,foliages:^core.Table(Foliage,$A),graphs:^core.Table(pcg.Pcg_Graph,$B),worlds:^core.Table(core.World_Transform,$C)) -> bool {
    if data==nil || generated==nil || !(low.x<=high.x && low.y<=high.y && low.z<=high.z) {return true}
    for row in 0..<core.count(foliages) {
        e:=core.entity_at(foliages,row)
        graph,graphed:=core.get(graphs,e)
        world,placed:=core.get(worlds,e)
        entry:=pcg.data_find(data,graph.source) if graphed else nil
        gen:=pcg.generated_graph(generated,e)
        if !placed || entry==nil || gen==nil {continue}
        frame:=pcg.graph_frame(graph,world.transform)
        // The box in the frame of the cells, and the cells it meets.
        inverse,invertible:=mm.transform_inverse(frame)
        if !invertible {continue}
        local_low,local_high:=[3]f32{max(f32),max(f32),max(f32)},[3]f32{min(f32),min(f32),min(f32)}
        for corner in 0..<8 {
            p:=mm.transform_point(inverse,{corner&1!=0?high.x:low.x,corner&2!=0?high.y:low.y,corner&4!=0?high.z:low.z})
            local_low,local_high=linalg.min(local_low,p),linalg.max(local_high,p)
        }
        size:=entry.source.info.cell_size
        reach:=pcg.POSITION_MAX
        if !(local_high.x>=-reach && local_low.x<=reach && local_high.z>=-reach && local_low.z<=reach) {continue}
        first,_:=pcg.cell_of(size,{max(local_low.x,-reach),max(local_low.z,-reach)})
        last,_:=pcg.cell_of(size,{min(local_high.x,reach),min(local_high.z,reach)})
        for &cell in gen.cells {
            if !cell.built || cell.coord.x<first.x || cell.coord.y<first.y || cell.coord.x>last.x || cell.coord.y>last.y {continue}
            for p in cell.placed {
                found:=found_of(e,cell.coord,p,frame)
                place:=found.transform.position
                if place.x<low.x || place.y<low.y || place.z<low.z || place.x>high.x || place.y>high.y || place.z>high.z {continue}
                if radius>=0 && linalg.length2(place-center)>radius*radius {continue}
                if _,err:=append(out,found);err!=nil {return false}
            }
        }
    }
    return true
}
