package pcg_physics

import "core:math"
import "core:slice"
import "mirai:core"
import volume "mirai:engine/volume"
import "mirai:std/base"
import mm "mirai:std/math"
import pcg "plugins:pcg/runtime"
import phys "plugins:physics/runtime"

// What joins procedural placement and physics, so that neither knows the
// other. The Collider of an entity with a Pcg_Physics_Keep_Out keeps the
// points of every Pcg_Graph out of its shape grown by margin: the bridge
// gives the entity derived children with an excluding Pcg_Zone whose Volume
// holds that shape (a box, a sphere, the column over a circle for a
// cylinder, and for a capsule that column between two spheres), which pcg
// reads as any other excluding zone. They are made again only when the
// Collider or the margin changes, and never saved. pcg_physics_filter_overlaps
// takes out of what a cell places what would stand inside the colliders of
// the physics, for props stacked on or put inside other things.

KEEP_OUT_PIECES :: 3  // volumes one collider takes at most: those of a capsule
OUTLINE_SIDES :: 16   // of the polygon around the circle of a cylinder or a capsule
SIZE_MAX :: f32(1e5)  // m: a size or a margin past it is not a shape

@(component,description="Keeps the points of the Pcg_Graph of the world out of the Collider of this entity (a box, a sphere, a capsule or a cylinder) grown by margin: derived children of it with an excluding Pcg_Zone hold that shape.")
Pcg_Physics_Keep_Out :: struct {
    margin:f32 `mirai:"min=0,unit=m"`, // around the collider, in the frame of the entity: it scales with it as the collider does
}

PCG_PHYSICS_KEEP_OUT_DEFAULT :: Pcg_Physics_Keep_Out{margin=0.5}

// On a child that holds a part of the shape its parent keeps points out of.
// It has no core.Id: a scene never saves it, and the bridge makes it again
// from the Collider and the Pcg_Physics_Keep_Out of its parent.
@(component,derived,description="The derived child that keeps the points of the Pcg_Graph out of a part of the Collider of its parent: made again from it, never saved.")
Pcg_Keep_Out_Part :: struct {
    piece:u8 `mirai:"readonly"`, // of the pieces of its parent's shape
    hash:u64 `mirai:"readonly"`, // of what it was made from
}

// A volume that holds a piece of a collider grown by a margin, in the frame
// of its entity: its centre, its Volume and, for an Outline, the loop of
// points around a circle that its Spline holds.
Keep_Out_Piece :: struct {
    center:[3]f32,
    volume:volume.Volume,
    radius:f32, // of the circle of an Outline, which its polygon goes around
}

// Why a collider keeps nothing out.
Keep_Out_Error :: enum u8 {None,Kind,Size,Margin}

// The volumes that hold a collider grown by margin, in the frame of its
// entity. Kind: a Hull, a Mesh, a Heightfield, an External or an Auto, whose
// shape is not of its own sizes; Size: a size not above 0 and finite, or a
// centre not finite; Margin: a margin below 0 or not finite.
pcg_physics_keep_out_pieces :: proc "contextless" (c:phys.Collider,margin:f32) -> (pieces:[KEEP_OUT_PIECES]Keep_Out_Piece,count:int,error:Keep_Out_Error) {
    if !(margin>=0 && margin<=SIZE_MAX) {return pieces,0,.Margin}
    for v in c.center {if !(abs(v)<=2*SIZE_MAX) {return pieces,0,.Size}}
    positive :: proc "contextless" (v:f32) -> bool {return v>0 && v<=SIZE_MAX}
    #partial switch c.kind {
    case .Box:
        if !positive(c.size.x) || !positive(c.size.y) || !positive(c.size.z) {return pieces,0,.Size}
        pieces[0]={center=c.center,volume={shape=.Box,extents=c.size+margin}}
        return pieces,1,.None
    case .Sphere:
        if !positive(c.size.x) {return pieces,0,.Size}
        pieces[0]={center=c.center,volume={shape=.Sphere,extents={c.size.x+margin,0,0}}}
        return pieces,1,.None
    case .Cylinder:
        if !positive(c.size.x) || !positive(c.size.y) {return pieces,0,.Size}
        pieces[0]={center=c.center,volume=volume.outline(2*(c.size.y+margin)),radius=c.size.x+margin}
        return pieces,1,.None
    case .Capsule:
        // A capsule of half height 0 is a sphere.
        if !positive(c.size.x) || !(c.size.y>=0 && c.size.y<=SIZE_MAX) {return pieces,0,.Size}
        r,h:=c.size.x+margin,c.size.y
        pieces[0]={center=c.center+{0,h,0},volume={shape=.Sphere,extents={r,0,0}}}
        pieces[1]={center=c.center-{0,h,0},volume={shape=.Sphere,extents={r,0,0}}}
        if h<=0 {return pieces,1,.None}
        pieces[2]={center=c.center,volume=volume.outline(2*h),radius=r}
        return pieces,3,.None
    }
    return pieces,0,.Kind
}

// The loop of an Outline piece: a polygon of OUTLINE_SIDES points whose
// sides touch the circle, so it holds all of it.
pcg_physics_outline :: proc "contextless" (radius:f32) -> (s:volume.Spline) {
    corner:=radius/math.cos(f32(math.PI/OUTLINE_SIDES))
    s.count=OUTLINE_SIDES
    for i in 0..<OUTLINE_SIDES {
        sn,cs:=mm.sincos_det(f32(i)*f32(2*math.PI/OUTLINE_SIDES))
        s.points[i]={position={cs*corner,0,sn*corner},width=1}
    }
    return
}

@(private)
piece_hash :: proc(c:phys.Collider,margin:f32,piece:int) -> u64 {
    Fixed :: struct {kind:phys.Collider_Kind,size,center:[3]f32,margin:f32,piece:int}
    fixed:=Fixed{c.kind,c.size,c.center,margin,piece}
    return base.hash64(([^]byte)(&fixed)[:size_of(fixed)])
}

// What the bridge looked at last: the tables whose change makes it compare
// again. A world copied or rolled back takes them with its tables.
@(storage)
Pcg_Physics_Seen :: struct {
    seen:[3]core.Seen `mirai:"transient,hidden"`, // Pcg_Physics_Keep_Out, Collider and Pcg_Keep_Out_Part
    passes:u64 `mirai:"transient,hidden"`,        // the ticks it compared on
}

// Keeps the children of every entity with a Pcg_Physics_Keep_Out holding
// the shape of its Collider grown by its margin: only when one of those, or
// one of the children, changed, and then only the children whose shape
// changed are made again. A child whose parent lost either goes.
@(step="fixed",loops="game editor",stage="simulate",before="pcg_ground")
pcg_physics_keep_out :: proc(
    state:^Pcg_Physics_Seen,keep_outs:^core.Table(Pcg_Physics_Keep_Out,.Read),parts:^core.Table(Pcg_Keep_Out_Part,.Read),
    colliders:^core.Table(phys.Collider,.Read),parents:^core.Table(core.Parent,.Read),commands:core.Commands,problems:^core.Problems,
) {
    if !(core.touched(keep_outs,&state.seen[0]) | core.touched(colliders,&state.seen[1]) | core.touched(parts,&state.seen[2])) {return}
    state.passes+=1
    Known :: struct {parent,child:core.Entity,piece:u8,hash:u64}
    known:=make([dynamic]Known,0,core.count(parts),context.temp_allocator)
    for row in 0..<core.count(parts) {
        child:=core.entity_at(parts,row)
        parent,has:=core.get(parents,child)
        if !has || !core.has(keep_outs,parent.entity) || !core.has(colliders,parent.entity) {
            core.commands_destroy(commands,child)
            continue
        }
        part:=core.at(parts,row)
        append(&known,Known{parent.entity,child,part.piece,part.hash})
    }
    slice.sort_by(known[:],proc(a,b:Known) -> bool {return a.parent<b.parent || a.parent==b.parent && a.piece<b.piece})
    for row in 0..<core.count(keep_outs) {
        e:=core.entity_at(keep_outs,row)
        keep:=core.at(keep_outs,row)
        c,has:=core.get(colliders,e)
        pieces:[KEEP_OUT_PIECES]Keep_Out_Piece
        count:=0
        if has {
            error:Keep_Out_Error
            pieces,count,error=pcg_physics_keep_out_pieces(c,keep.margin)
            switch error {
            case .None:
            case .Kind:   core.report(problems,e,"pcg_physics.kind","the Collider of this Pcg_Physics_Keep_Out is a %v, which keeps no points out: give it a Box, a Sphere, a Capsule or a Cylinder",c.kind)
            case .Size:   core.report(problems,e,"pcg_physics.size","the Collider of this Pcg_Physics_Keep_Out has a size not above 0 or past %v m, or a centre that is not a number: give it the sizes of its shape",SIZE_MAX)
            case .Margin: core.report(problems,e,"pcg_physics.margin","the margin of this Pcg_Physics_Keep_Out is below 0, past %v m or not a number: give the metres around the collider points keep out of, or 0",SIZE_MAX)
            }
        } else {
            core.report(problems,e,"pcg_physics.collider","this Pcg_Physics_Keep_Out keeps no points out: its entity has no Collider; give it one, or take the Pcg_Physics_Keep_Out away")
        }
        // The children it had: those of the right shape stay, the others go.
        made:[KEEP_OUT_PIECES]bool
        low,high:=0,len(known)
        for low<high {mid:=(low+high)/2;if known[mid].parent<e {low=mid+1} else {high=mid}}
        for k in known[low:] {
            if k.parent!=e {break}
            piece:=int(k.piece)
            if piece<count && !made[piece] && k.hash==piece_hash(c,keep.margin,piece) {made[piece]=true;continue}
            core.commands_destroy(commands,k.child)
        }
        for piece in 0..<count {
            if made[piece] {continue}
            p:=pieces[piece]
            child:=core.commands_create(commands)
            core.commands_add(commands,child,core.Parent{entity=e})
            core.commands_add(commands,child,core.Transform{position=p.center,rotation=1,scale={1,1,1}})
            zone:=pcg.PCG_ZONE_DEFAULT
            zone.exclude=true
            core.commands_add(commands,child,zone)
            core.commands_add(commands,child,p.volume)
            if p.volume.shape==.Outline {core.commands_add(commands,child,pcg_physics_outline(p.radius))}
            core.commands_add(commands,child,Pcg_Keep_Out_Part{piece=u8(piece),hash=piece_hash(c,keep.margin,piece)})
        }
    }
}

// Takes out of placed, keeping the order of the others, what would stand
// inside a collider of the physics: each thing as a box of half_extents at
// its scale, standing on its position (its centre half its height up its y),
// turned by its rotation, placed in the world by frame (the frame of its
// graph, pcg.graph_frame). What is kept comes first and its count returns.
// Nothing is taken out, and ok is false, for half extents not above 0 and
// finite, a frame that is not finite, or a physics that is not made.
pcg_physics_filter_overlaps :: proc(
    physics:core.Ref(phys.Physics_State),placed:[]pcg.Placed,frame:mm.Transform,half_extents:[3]f32,
    filter:=phys.QUERY_FILTER_DEFAULT,ignore:=core.NONE,
) -> (kept:int,ok:bool) {
    kept=len(placed)
    for v in half_extents {if !(v>0 && v<=SIZE_MAX) {return}}
    for v in frame.position {if !(abs(v)<=max(f32)) {return}}
    for v in frame.scale {if !(abs(v)<=SIZE_MAX) {return}}
    if physics.ptr==nil || !physics.ready {return}
    kept=0
    scale:=[3]f32{abs(frame.scale.x),abs(frame.scale.y),abs(frame.scale.z)}
    for p in placed {
        half:=half_extents*p.scale*scale
        center:=mm.transform_point(frame,p.position+mm.quat_rotate(p.rotation,{0,half_extents.y*p.scale.y,0}))
        found:[1]core.Entity
        if n,_:=phys.overlap_box(physics,center,half,frame.rotation*p.rotation,found[:],filter,ignore);n>0 {continue}
        placed[kept]=p
        kept+=1
    }
    return kept,true
}
