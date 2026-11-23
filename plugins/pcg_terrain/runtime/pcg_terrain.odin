package pcg_terrain

import "core:slice"
import "mirai:core"
import volume "mirai:engine/volume"
import "mirai:std/base"
import mm "mirai:std/math"
import pcg "plugins:pcg/runtime"
import terrain "plugins:terrain/runtime"

// What joins procedural placement and terrain, so that neither knows the
// other. A Pcg_Terrain_Stamp on a Pcg_Zone or a Pcg_Graph asks the terrain
// under it for one brush: once at its entity, or in dabs along the Spline of
// its entity, each time its values, its place or its shape change, and never
// again for the same ones (the hash of what it asked is saved with it, so
// opening the scene again or playing does not stamp twice). Each dab is a
// terrain.dig, which the terrain applies as any other edit: the bridge never
// writes a terrain. With conform_spline, the Spline of its entity takes a bed
// in the terrains under it instead: a derived child holds the Spline and a
// terrain.Terrain_Conform from the stamp, which the terrain makes its layer of
// splines from, and which goes with the stamp.

DABS_MAX :: 128             // of one stamp along a spline; a longer spline takes them farther apart
DAB_SPACING :: f32(0.5)     // of the radius, between the dabs along a spline
SIZE_MAX :: terrain.HEIGHT_LIMIT

Pcg_Terrain_Brush :: enum u8 {Flatten,Smooth,Raise,Lower,Noise,Paint,Carve}

@(component,description="Asks the terrain under this Pcg_Zone or Pcg_Graph for a brush, once at its entity or along its Spline, each time these values, its place or its shape change; with conform_spline, the terrain under its Spline conforms to it instead, a bed made again whenever it changes.")
Pcg_Terrain_Stamp :: struct {
    brush:Pcg_Terrain_Brush,
    strength:f32,                       // Raise, Lower and Noise: metres; Flatten, Smooth, Paint and Carve: a part from 0 to 1 (Carve at most 1); conform: the depth of the bed under the ground, negative raises it
    radius:f32 `mirai:"min=0,unit=m"`, // of each dab; conform: past the width of the spline, over which the ground meets the bed
    layer:u32,                          // Paint: the layer of the terrain it paints
    material:base.Asset_Id `mirai:"kind=.mat"`, // conform: the layer it paints on the bed; none: it paints nothing
    smooth:f32 `mirai:"min=0,unit=m"`, // conform: along the spline, over which the bed follows the ground
    conform_spline:bool,
    applied:u64 `mirai:"readonly,hidden"`, // the hash of what it last asked the terrain for
}

PCG_TERRAIN_STAMP_DEFAULT :: Pcg_Terrain_Stamp{brush=.Flatten,strength=0.5,radius=4,smooth=terrain.TERRAIN_CONFORM_DEFAULT.smooth}

// On the child that conforms the terrain to the Spline of a stamp. It has no
// core.Id: a scene never saves it, and the bridge makes it again from its parent.
@(component,derived,description="The derived child that conforms the terrain to the Spline of its parent's Pcg_Terrain_Stamp: made again from it, never saved.")
Pcg_Terrain_Bed :: struct {
    hash:u64 `mirai:"readonly"`, // of what it was made from
}

// What the bridge looked at last; a world copied or rolled back takes it with its tables.
@(storage)
Pcg_Terrain_Seen :: struct {
    seen:[6]core.Seen `mirai:"transient,hidden"`, // the tables of stamps, beds, World_Transform, Spline, Volume and Pcg_Zone
    passes:u64 `mirai:"transient,hidden"`,        // the ticks it compared on
    asked:u64 `mirai:"transient,hidden"`,         // dabs it asked the terrain for
}

// Why a stamp asks nothing.
Stamp_Error :: enum u8 {None,Brush,Layer,Conform,Spline}

// The brush of a dab of a stamp at a point of the world, and what is wrong with it.
pcg_terrain_brush :: proc "contextless" (s:Pcg_Terrain_Stamp,center:[3]f32,seed:u32) -> (b:terrain.Brush,error:terrain.Edit_Error) {
    b={center=center,radius=s.radius,amount=s.strength,rotation=1,hardness=0.5,falloff=.Smooth}
    switch s.brush {
    case .Flatten: b.kind,b.target=.Flatten,center.y
    case .Smooth:  b.kind=.Smooth
    case .Raise:   b.kind=.Raise
    case .Lower:   b.kind=.Lower
    case .Noise:   b.kind,b.scale,b.seed=.Noise,s.radius*0.5,seed
    case .Paint:   b.kind,b.layer=.Paint,s.layer
    case .Carve:   b.kind,b.shape=.Carve,.Sphere
    case:          return b,.Kind
    }
    if s.brush==.Paint && s.layer>=terrain.LAYERS_MAX {return b,.Layer}
    return b,terrain.brush_check(b)
}

// The Terrain_Conform a stamp gives the spline of its entity; false for
// values the terrain cannot take.
pcg_terrain_conform :: proc "contextless" (s:Pcg_Terrain_Stamp) -> (c:terrain.Terrain_Conform,ok:bool) {
    c={depth=s.strength,sides=s.radius,smooth=s.smooth,paint=s.material}
    ok=abs(c.depth)<=SIZE_MAX && c.sides>=0 && c.sides<=SIZE_MAX && c.smooth>=0 && c.smooth<=SIZE_MAX
    return
}

@(private)
stamp_hash :: proc(s:Pcg_Terrain_Stamp,place:mm.Transform,spline:^volume.Spline,shape:volume.Volume) -> u64 {
    s:=s
    s.applied=0
    h:=base.hash64(([^]byte)(&s)[:size_of(s)])
    place:=place
    h=base.hash64(([^]byte)(&place)[:size_of(place)],h)
    shape:=shape
    h=base.hash64(([^]byte)(&shape)[:size_of(shape)],h)
    if spline!=nil {
        count:=min(int(spline.count),volume.SPLINE_POINTS)
        h=base.hash64(([^]byte)(&spline.count)[:size_of(spline.count)],h)
        h=base.hash64(([^]byte)(&spline.points[0])[:count*size_of(mm.Path_Point)],h)
    }
    return h
}

@(private)
bed_hash :: proc(c:terrain.Terrain_Conform,spline:^volume.Spline) -> u64 {
    c:=c
    h:=base.hash64(([^]byte)(&c)[:size_of(c)])
    count:=min(int(spline.count),volume.SPLINE_POINTS)
    h=base.hash64(([^]byte)(&spline.count)[:size_of(spline.count)],h)
    return base.hash64(([^]byte)(&spline.points[0])[:count*size_of(mm.Path_Point)],h)
}

// Asks the terrain for what each stamp whose values, place or shape changed
// says, and keeps the bed of each that conforms its spline: only on a tick
// when one of those tables, or a bed, changed. A bed whose stamp went, or no
// longer conforms, goes.
@(step="fixed",loops="game editor",stage="intent",server)
pcg_terrain_stamp :: proc(
    state:^Pcg_Terrain_Seen,stamps:^core.Table(Pcg_Terrain_Stamp),beds:^core.Table(Pcg_Terrain_Bed,.Read),
    zones:^core.Table(pcg.Pcg_Zone,.Read),graphs:^core.Table(pcg.Pcg_Graph,.Read),
    worlds:^core.Table(core.World_Transform,.Read),splines:^core.Table(volume.Spline,.Read),volumes:^core.Table(volume.Volume,.Read),
    parents:^core.Table(core.Parent,.Read),requests:^terrain.Terrain_Requests,commands:core.Commands,problems:^core.Problems,
) {
    if !(core.touched(stamps,&state.seen[0]) | core.touched(beds,&state.seen[1]) | core.touched(worlds,&state.seen[2]) | core.touched(splines,&state.seen[3]) | core.touched(volumes,&state.seen[4]) | core.touched(zones,&state.seen[5])) {return}
    state.passes+=1
    // The beds: one for each stamp that conforms, of what it is now.
    Known :: struct {parent,child:core.Entity,hash:u64}
    known:=make([dynamic]Known,0,core.count(beds),context.temp_allocator)
    for row in 0..<core.count(beds) {
        child:=core.entity_at(beds,row)
        parent,has:=core.get(parents,child)
        stamp,stamped:=core.get(stamps,parent.entity)
        if !has || !stamped || !stamp.conform_spline || !core.has(splines,parent.entity) {
            core.commands_destroy(commands,child)
            continue
        }
        append(&known,Known{parent.entity,child,core.at(beds,row).hash})
    }
    slice.sort_by(known[:],proc(a,b:Known) -> bool {return a.parent<b.parent})
    dabs:[DABS_MAX]mm.Path_Point
    for row in 0..<core.count(stamps) {
        e:=core.entity_at(stamps,row)
        s:=core.at(stamps,row)
        if !core.has(zones,e) && !core.has(graphs,e) {
            core.report(problems,e,"pcg_terrain.owner","this Pcg_Terrain_Stamp asks the terrain for nothing: its entity has neither a Pcg_Zone nor a Pcg_Graph; give it one, or take the stamp away")
            continue
        }
        world,placed:=core.get(worlds,e)
        if !placed {continue}
        spline_row:=core.row_of(splines,e)
        spline:^volume.Spline=spline_row>=0?&splines.values[spline_row]:nil
        if s.conform_spline {
            low,high:=0,len(known)
            for low<high {mid:=(low+high)/2;if known[mid].parent<e {low=mid+1} else {high=mid}}
            bed_known:=low<len(known) && known[low].parent==e
            if spline==nil {
                core.report(problems,e,"pcg_terrain.spline","this Pcg_Terrain_Stamp conforms the terrain to a spline, but its entity has no Spline: give it one, or clear conform_spline")
                continue
            }
            c,ok:=pcg_terrain_conform(s)
            if !ok {
                core.report(problems,e,"pcg_terrain.conform","the strength (the depth of the bed), radius (its sides) or smooth of this Pcg_Terrain_Stamp is not a number or past %v m, or radius or smooth is below 0: give the metres of the bed",SIZE_MAX)
                if bed_known {core.commands_destroy(commands,known[low].child)}
                continue
            }
            h:=bed_hash(c,spline)
            kept:=false
            for k in known[low:] {
                if k.parent!=e {break}
                if !kept && k.hash==h {kept=true;continue}
                core.commands_destroy(commands,k.child)
            }
            if kept {continue}
            child:=core.commands_create(commands)
            core.commands_add(commands,child,core.Parent{entity=e})
            core.commands_add(commands,child,core.TRANSFORM_IDENTITY)
            core.commands_add(commands,child,spline^)
            core.commands_add(commands,child,c)
            core.commands_add(commands,child,Pcg_Terrain_Bed{hash=h})
            continue
        }
        shape,_:=core.get(volumes,e)
        h:=stamp_hash(s,world.transform,spline,shape)
        if h==s.applied {continue}
        core.edit(stamps,e).applied=h
        // The dabs: along the spline, or at the entity.
        points:=dabs[:1]
        points[0].position=world.transform.position
        if spline!=nil {
            piece:=max(s.radius*DAB_SPACING,0.25)
            n:=volume.spline_sample(spline,piece if piece<=SIZE_MAX else SIZE_MAX,dabs[:])
            if n==0 {
                core.report(problems,e,"pcg_terrain.spline","the Spline of this Pcg_Terrain_Stamp has fewer than 2 points, or one that is not a number: give it a path")
                continue
            }
            points=dabs[:n]
            for &p in points {p.position=mm.transform_point(world.transform,p.position)}
        }
        seed:=u32(base.hash_u64(h))
        for p in points {
            b,error:=pcg_terrain_brush(s,p.position,seed)
            if error==.None {error=terrain.dig(requests,b)}
            if error!=.None {
                core.report(problems,e,"pcg_terrain.brush","this Pcg_Terrain_Stamp asks the terrain for nothing: %s",terrain.edit_error_fix(error,b.kind))
                break
            }
            state.asked+=1
        }
    }
}
