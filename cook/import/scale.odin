package importer

import "core:fmt"
import mm "mirai:std/math"

// The scale of a node is how big what it draws is, as the source says it.
// A drawn mesh whose node and the nodes above it make it more than
// SCALE_LARGE times larger or smaller than its size is warned of: a source
// in other units (centimeters for meters gives a prop of 100 times its size).
// With Import_Settings.bake_scale the import puts that scale into the mesh
// instead: its vertices, bounds and colliders grow by it, its node takes a
// scale of 1, and what hangs from the node takes the scale it lost, so every
// node stays where it was. The same source and settings bake the same: what
// is baked depends on no count of instances.
//
// Only a positive scale that is the same on every axis is baked, never into
// a mesh with a skin, under a clip that moves a node it would change, or that
// nodes of different scales draw: a negative scale turns its triangles inside
// out, an uneven one changes the shape of a sphere or a capsule, and a skin
// binds the space its joints were bound in. A scale left is a warning that
// says why.

SCALE_LARGE :: f32(2)
// Of a scale: how far its axes may be from each other, and from 1, and still be the same.
@(private="file") SCALE_TOLERANCE :: f32(1e-4)

@(private="file")
Scale_Refusal :: enum u8 {Uneven,Negative,Skinned,Animated,Shared}

@(private="file")
scale_uniform :: proc "contextless" (s:[3]f32) -> bool {
    largest:=max(abs(s.x),abs(s.y),abs(s.z))
    return abs(s.x-s.y)<=SCALE_TOLERANCE*largest && abs(s.x-s.z)<=SCALE_TOLERANCE*largest
}

@(private="file")
scale_one :: proc "contextless" (s:[3]f32) -> bool {
    return abs(s.x-1)<=SCALE_TOLERANCE && abs(s.y-1)<=SCALE_TOLERANCE && abs(s.z-1)<=SCALE_TOLERANCE
}

// The model is in the engine's space and faces -Z.
model_scales :: proc(r:^Reader) {
    zone(r.options,"import.scales")
    if len(r.nodes)==0 {return}
    if r.options.settings.bake_scale {scales_bake(r)}
    // What is still drawn far from its size, by the scale of its node and of the nodes above it.
    Extreme :: struct {count:int,node:int,scale:f32}
    extreme:=Extreme{node=-1}
    world:=make([][3]f32,len(r.nodes),context.temp_allocator)
    for node,i in r.nodes {
        world[i]=node.transform.scale
        if node.parent>=0 && node.parent<i {world[i]*=world[node.parent]}
        if node.mesh<0 || len(r.meshes[node.mesh].skin)>0 {continue}
        far,beyond:=mm.scale_beyond(world[i],SCALE_LARGE)
        if !beyond {continue}
        if extreme.count==0 {extreme.node,extreme.scale=i,far}
        extreme.count+=1
    }
    if extreme.count==0 {return}
    others:=fmt.tprintf(" and %d other nodes",extreme.count-1) if extreme.count>1 else ""
    fix:="the source is likely in other units: fix its export, or import it with bake_scale (--bake-scale) to put a uniform scale into its meshes"
    if r.options.settings.bake_scale {fix="bake_scale could not bake it (see the warning that says why): fix the scale in the source"}
    warn(r,"node %s%s draw their meshes at %g times their size by the scale of their nodes; %s",r.nodes[extreme.node].name,others,extreme.scale,fix)
}

// Pushes each uniform positive scale down the nodes into the meshes they
// draw, parents before children.
@(private="file")
scales_bake :: proc(r:^Reader) {
    count:=len(r.nodes)
    // What a scale of a node changes is not baked: a node a clip moves, or a skin under it.
    animated:=make(map[string]bool,context.temp_allocator)
    for clip in r.animations {
        for track in clip.tracks {animated[track.target]=true}
    }
    held:=make([]bit_set[Scale_Refusal],count,context.temp_allocator)
    #reverse for node,i in r.nodes {
        if node.mesh>=0 && len(r.meshes[node.mesh].skin)>0 {held[i]+={.Skinned}}
        if animated[node.path] {held[i]+={.Animated}}
        if node.parent>=0 && node.parent<i {held[node.parent]+=held[i]&{.Skinned,.Animated}}
    }
    children:=make([dynamic]int,context.temp_allocator)
    push :: proc(r:^Reader,children:^[dynamic]int,at:int,s:f32) {
        clear(children)
        for node,i in r.nodes {if node.parent==at {append(children,i)}}
        for child in children^ {
            r.nodes[child].transform.position*=s
            r.nodes[child].transform.scale*=s
        }
        r.nodes[at].transform.scale={1,1,1}
    }
    refusals:[Scale_Refusal]struct {count:int,node:int}
    refuse :: proc(refusals:^[Scale_Refusal]struct {count:int,node:int},why:Scale_Refusal,node:int) {
        if refusals[why].count==0 {refusals[why].node=node}
        refusals[why].count+=1
    }
    baked:=make([]bool,len(r.meshes),context.temp_allocator)
    for i in 0..<count {
        s:=r.nodes[i].transform.scale
        if scale_one(s) {continue}
        why:=held[i]
        if !scale_uniform(s) {why+={.Uneven}} else if s.x<0 {why+={.Negative}}
        mesh:=r.nodes[i].mesh
        // Nodes that draw the same mesh bake it once, all at the same scale.
        if mesh>=0 && why=={} {
            for other,k in r.nodes {
                if k==i || other.mesh!=mesh {continue}
                if baked[mesh] || !scale_uniform(other.transform.scale) || abs(other.transform.scale.x-s.x)>SCALE_TOLERANCE*abs(s.x) || held[k]!={} {why+={.Shared};break}
            }
        }
        if why!={} {
            // One reason each, the first that holds: what the warning names.
            for reason in Scale_Refusal {if reason in why {refuse(&refusals,reason,i);break}}
            continue
        }
        if mesh<0 {
            push(r,&children,i,s.x)
            continue
        }
        mesh_scale(&r.meshes[mesh],s.x)
        baked[mesh]=true
        for other,k in r.nodes {if other.mesh==mesh {push(r,&children,k,s.x)}}
    }
    reasons:=[Scale_Refusal]string{
        .Uneven="its scale is not the same on every axis, which would change the shape of its spheres and capsules",
        .Negative="its scale is negative, which would turn its triangles inside out",
        .Skinned="it is or holds a skinned mesh, whose skin binds the space of its joints",
        .Animated="a clip moves it or a node under it",
        .Shared="nodes of other scales draw its mesh",
    }
    for refusal,why in refusals {
        if refusal.count==0 {continue}
        node:=&r.nodes[refusal.node]
        others:=fmt.tprintf(" and %d other nodes",refusal.count-1) if refusal.count>1 else ""
        warn(r,"bake_scale: node %s%s keep their scale %v: %s",node.name,others,node.transform.scale,reasons[why])
    }
}

// Makes a mesh s times larger, with its bounds and colliders.
@(private)
mesh_scale :: proc(mesh:^Imported_Mesh,s:f32) {
    for &vertex in mesh.vertices {vertex.position*=s}
    for &delta in mesh.morph_deltas {delta.position*=s}
    mesh.bounds_min*=s
    mesh.bounds_max*=s
    for &collider in mesh.collision.colliders {
        collider.center*=s
        collider.size*=s
    }
    for &point in mesh.collision.points {point*=s}
}
