package foliage

import "core:math/linalg"
import "mirai:core"
import mm "mirai:std/math"

// What a game asks of the foliage of its world, collides it or not: the
// instances that stand in a sphere or a box, and where an instance stands
// and of which type. As the world has them: on their ground, without what
// was taken out in play, however far from the players. For harvesting, an AI
// that looks for wood or cover, or a felled tree that becomes a body where it
// stood. An instance is in an area when its place (the foot of its pivot) is.

// An instance of a Foliage as the world has it.
Foliage_Found :: struct {
    plant:Foliage_Plant,
    type:u32,               // its type in the source of its Foliage (Foliage_Type.id)
    transform:mm.Transform, // in the world, as its batches draw it
}

// The instances of every Foliage within radius of center, in the world,
// appended to out. False without memory, with what fit appended.
foliage_in_sphere :: proc(out:^[dynamic]Foliage_Found,center:[3]f32,radius:f32,data:core.Ref(Foliage_Data),grounds:core.Ref(Foliage_Ground),removals:core.Ref(Foliage_Removals),foliages:^core.Table(Foliage,$A),worlds:^core.Table(core.World_Transform,$B)) -> bool {
    if !(radius>=0) {return true}
    return plants_in(out,center-radius,center+radius,center,radius,data.ptr,grounds.ptr,removals.ptr,foliages,worlds)
}

// The instances of every Foliage in the box from low to high, in the world,
// appended to out. False without memory, with what fit appended.
foliage_in_box :: proc(out:^[dynamic]Foliage_Found,low,high:[3]f32,data:core.Ref(Foliage_Data),grounds:core.Ref(Foliage_Ground),removals:core.Ref(Foliage_Removals),foliages:^core.Table(Foliage,$A),worlds:^core.Table(core.World_Transform,$B)) -> bool {
    return plants_in(out,low,high,{},-1,data.ptr,grounds.ptr,removals.ptr,foliages,worlds)
}

// Where an instance stands and of which type; false when the world does not
// show it (taken out, gone from its source, its Foliage not there).
foliage_plant :: proc(plant:Foliage_Plant,data:core.Ref(Foliage_Data),grounds:core.Ref(Foliage_Ground),removals:core.Ref(Foliage_Removals),foliages:^core.Table(Foliage,$A),worlds:^core.Table(core.World_Transform,$B)) -> (found:Foliage_Found,ok:bool) {
    f:=core.get(foliages,plant.foliage) or_return
    world:=core.get(worlds,plant.foliage) or_return
    entry:=data_find(data.ptr,f.source) if data.ptr!=nil else nil
    cell:=entry!=nil?source_cell(&entry.source,plant.coord):nil
    if cell==nil {return}
    work:Build_Work
    defer build_work_destroy(&work)
    if !cell_shown(&work,&entry.source,cell,grounds.ptr,removals.ptr,plant.foliage) {return}
    for p in work.placed {
        if p.id==plant.instance {return found_of(plant.foliage,cell.coord,p,world.transform),true}
    }
    return
}

// What the world shows of a cell of a Foliage, in work.placed.
@(private="file")
cell_shown :: proc(work:^Build_Work,s:^Source,cell:^Cell,grounds:^Foliage_Ground,removals:^Foliage_Removals,e:core.Entity) -> bool {
    tile,_:=ground_cell(ground_owner(grounds,e),cell.coord)
    removed,_:=removed_cell(removed_owner(removals,e),cell.coord)
    return cell_build(s,cell,tile,work,removed)
}

@(private="file")
found_of :: proc "contextless" (e:core.Entity,coord:[2]i32,p:Placed,owner:mm.Transform) -> Foliage_Found {
    return {{e,coord,p.id},p.type,{mm.transform_point(owner,p.position),owner.rotation*p.rotation,[3]f32{p.scale[0],p.scale[1],p.scale[0]}*owner.scale}}
}

// The first cell of a source at a coordinate or after it.
@(private="file")
cell_lower :: proc "contextless" (s:^Source,coord:[2]i32) -> int {
    low,high:=0,len(s.cells)
    for low<high {
        mid:=(low+high)/2
        if coord_before(s.cells[mid].coord,coord) {low=mid+1} else {high=mid}
    }
    return low
}

// The instances in a box of the world and, with a radius of 0 or more, in
// the sphere it holds; by Foliage, in the order of their cells.
@(private="file")
plants_in :: proc(out:^[dynamic]Foliage_Found,low,high,center:[3]f32,radius:f32,data:^Foliage_Data,grounds:^Foliage_Ground,removals:^Foliage_Removals,foliages:^core.Table(Foliage,$A),worlds:^core.Table(core.World_Transform,$B)) -> bool {
    if data==nil || !(low.x<=high.x && low.y<=high.y && low.z<=high.z) {return true}
    work:Build_Work
    defer build_work_destroy(&work)
    placed:=core.join(foliages,worlds)
    for e,f,world in core.each_joined(&placed) {
        entry:=data_find(data,f.source)
        if entry==nil {continue}
        // The box in the space of the entity, and the cells it meets.
        inverse,invertible:=mm.transform_inverse(world.transform)
        if !invertible {continue}
        local_low,local_high:=[3]f32{max(f32),max(f32),max(f32)},[3]f32{min(f32),min(f32),min(f32)}
        for corner in 0..<8 {
            p:=mm.transform_point(inverse,{corner&1!=0?high.x:low.x,corner&2!=0?high.y:low.y,corner&4!=0?high.z:low.z})
            local_low,local_high=linalg.min(local_low,p),linalg.max(local_high,p)
        }
        if !(local_high.x>=-COORD_MAX*CELL_SIZE && local_low.x<=COORD_MAX*CELL_SIZE && local_high.z>=-COORD_MAX*CELL_SIZE && local_low.z<=COORD_MAX*CELL_SIZE) {continue}
        first,_:=cell_of({max(local_low.x,-COORD_MAX*CELL_SIZE),0,max(local_low.z,-COORD_MAX*CELL_SIZE)})
        last,_:=cell_of({min(local_high.x,COORD_MAX*CELL_SIZE),0,min(local_high.z,COORD_MAX*CELL_SIZE)})
        s:=&entry.source
        // From the first cell of the box on, a row of it at a time: the cells are in order, z then x.
        at:=cell_lower(s,first)
        for at<len(s.cells) && s.cells[at].coord.y<=last.y {
            cell:=&s.cells[at]
            if cell.coord.x>last.x {at=cell_lower(s,{first.x,cell.coord.y+1});continue}
            if cell.coord.x<first.x {at=cell_lower(s,{first.x,cell.coord.y});continue}
            at+=1
            if !cell_shown(&work,s,cell,grounds,removals,e) {return false}
            for p in work.placed {
                found:=found_of(e,cell.coord,p,world.transform)
                place:=found.transform.position
                if place.x<low.x || place.y<low.y || place.z<low.z || place.x>high.x || place.y>high.y || place.z>high.z {continue}
                if radius>=0 && linalg.length2(place-center)>radius*radius {continue}
                if _,err:=append(out,found);err!=nil {return false}
            }
        }
    }
    return true
}
