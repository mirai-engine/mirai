package importer

import "core:fmt"

// The scale of a node is how big what it draws is, as the source says it.
// The unit a file declares is already meters once its space is applied
// (space.odin). The import also puts the scale of the file's root into the
// meshes: the scale of a root node, and of each node that is the only child
// of one of those that draws nothing (the groups an exporter adds to turn
// centimeters into meters), goes down the hierarchy into every mesh that one
// node alone draws. Its vertices, bounds and colliders grow by it, the nodes
// above it take a scale of 1, what hangs from them the scale they lost, and
// every node stays where it was. The same source bakes the same: what is
// baked depends on no count of instances.
//
// Only a positive scale that is the same on every axis is baked, never under
// a root that holds a skin or a node a clip moves, and never into a mesh
// other nodes also draw, which keeps it on its node: a negative scale turns
// triangles inside out, an uneven one changes the shape of a sphere or a
// capsule, a skin binds the space its joints were bound in, the keys of a
// clip are in the space of their node's parent, and the nodes of a shared
// mesh are instances of one size. A mesh still drawn at a change of units
// (UNIT_FACTORS) is warned of: the mesh is not in meters.

// The scales that turn a unit into another: what a mesh drawn at one of them is most likely in.
UNIT_FACTORS :: [?]f32{10,100,1000,0.1,0.01,0.001,0.0254,1/0.0254,0.3048,1/0.3048}
// Of a scale: how far its axes may be from each other, and from 1, and still be the same.
@(private="file") SCALE_TOLERANCE :: f32(1e-4)
// How far from a factor of UNIT_FACTORS a scale is still that factor.
@(private="file") UNIT_TOLERANCE :: f32(5e-3)

@(private="file")
Scale_Hold :: enum u8 {Skinned,Animated}

@(private="file")
scale_uniform :: proc "contextless" (s:[3]f32) -> bool {
    largest:=max(abs(s.x),abs(s.y),abs(s.z))
    return abs(s.x-s.y)<=SCALE_TOLERANCE*largest && abs(s.x-s.z)<=SCALE_TOLERANCE*largest
}

// The factor of UNIT_FACTORS a scale is, if any.
unit_factor :: proc "contextless" (s:[3]f32) -> (factor:f32,ok:bool) {
    if !scale_uniform(s) || !(s.x>0) {return}
    for f in UNIT_FACTORS {
        if abs(s.x-f)<=UNIT_TOLERANCE*f {return f,true}
    }
    return
}

// The model is in the engine's space and faces -Z.
model_scales :: proc(r:^Reader) {
    zone(r.options,"import.scales")
    count:=len(r.nodes)
    if count==0 {return}
    // A scale is not moved through a node a clip moves or a skin under it, nor through those above them.
    animated:=make(map[string]bool,context.temp_allocator)
    for clip in r.animations {
        for track in clip.tracks {animated[track.target]=true}
    }
    held:=make([]bit_set[Scale_Hold],count,context.temp_allocator)
    #reverse for node,i in r.nodes {
        if node.mesh>=0 && len(r.meshes[node.mesh].skin)>0 {held[i]+={.Skinned}}
        if animated[node.path] {held[i]+={.Animated}}
        if node.parent>=0 && node.parent<i {held[node.parent]+=held[i]}
    }
    drawers:=make([]int,len(r.meshes),context.temp_allocator)
    for node in r.nodes {if node.mesh>=0 {drawers[node.mesh]+=1}}
    // root: the node is of the root of the file. passed: the scale it hands its
    // children, taken off its own; what it was handed is already in its
    // position and scale.
    root:=make([]bool,count,context.temp_allocator)
    passed:=make([]f32,count,context.temp_allocator)
    only:=make([]bool,count,context.temp_allocator) // the only child of its parent
    children:=make([]int,count,context.temp_allocator)
    for node in r.nodes {if node.parent>=0 {children[node.parent]+=1}}
    for node,i in r.nodes {only[i]=node.parent>=0 && children[node.parent]==1}
    for i in 0..<count {
        node:=&r.nodes[i]
        parent:=node.parent if node.parent>=0 && node.parent<i else -1
        // A held node's parent is held too, and hands it nothing.
        handed:=passed[parent] if parent>=0 else 1
        node.transform.position*=handed
        passed[i]=1
        root[i]=parent<0 || root[parent] && r.nodes[parent].mesh<0 && only[i]
        own:=node.transform.scale
        hand,kept:=handed,own
        if held[i]=={} && root[i] && scale_uniform(own) && own.x>0 {hand,kept=own.x*handed,{1,1,1}}
        if held[i]!={} || hand==1 || node.mesh>=0 && drawers[node.mesh]>1 {
            node.transform.scale=own*handed
            continue
        }
        if node.mesh>=0 {mesh_scale(&r.meshes[node.mesh],hand)}
        node.transform.scale=kept
        passed[i]=hand
    }
    // What still draws a mesh at a change of units.
    Far :: struct {count:int,node:int,factor:f32}
    far:=Far{node=-1}
    world:=make([][3]f32,count,context.temp_allocator)
    for node,i in r.nodes {
        world[i]=node.transform.scale
        if node.parent>=0 && node.parent<i {world[i]*=world[node.parent]}
        if node.mesh<0 || len(r.meshes[node.mesh].skin)>0 {continue}
        factor:=unit_factor(world[i]) or_continue
        if far.count==0 {far.node,far.factor=i,factor}
        far.count+=1
    }
    if far.count==0 {return}
    node:=&r.nodes[far.node]
    others:=fmt.tprintf(" and %d other nodes",far.count-1) if far.count>1 else ""
    why:="the scale of its nodes"
    switch {
    case drawers[node.mesh]>1: why="the scale of its nodes, which the import does not put into a mesh other nodes also draw"
    case .Animated in held[far.node]: why="the scale of its nodes, which the import does not move through a node a clip moves"
    }
    warn(r,"node %s%s draw their meshes at %g times their size by %s: the meshes are in other units than meters; export the source in meters",node.name,others,far.factor,why)
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
