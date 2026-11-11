package scene

import "core:math/linalg"
import "core:slice"
import "core:strings"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/spatial"

// A section of the world: the scene a reference names hangs from its entity
// without being copied into the document that holds the reference. Loading
// the document loads it under the entity; removing or turning off the entity
// takes the whole section; saving the document saves the reference, not what
// hangs from it, which is saved in its own scene. What repeats as a copy with
// overrides is a prefab instance, not a reference.
//
// What the world uses one of (Sky, Sun) arrives off in a section: the active
// one of the root rules, and the game or a trigger turns another on.
//
// The Id of an entity of a referenced scene is that of the reference combined
// with its own (id_in): a scene referenced twice repeats no Id, and every end
// of a session and every saved game computes the same one.

// How a section loads. With_Document: with the document that holds it.
// Manual: when the game asks (a level of a game of levels, the same zone
// whole or destroyed, the setup of a mission). Spatial: as the plugin
// streaming decides, by where the players are.
Section_Rule :: enum u8 {With_Document,Manual,Spatial}

// What a section is asked to be: not loaded; loaded and off (under Disabled:
// no function sees it, ready to turn on without a pause); on.
Section_State :: enum u8 {Active,Loaded,Unloaded}

@(component,replicated,description="A section of the world: the scene it names hangs from this entity, edited and saved in its own document. Removing or turning off the entity takes the whole section; its rule and its state say when it loads.")
Scene_Reference :: struct {
    scene:base.Asset_Id,
    extents:[3]f32 `mirai:"min=0,unit=m"`, // half the size of the box of the section around its entity, times its scale: where its unbounded volumes rule and, streamed, where it is
    distance:f32 `mirai:"min=0,unit=m"`,   // Spatial: how near its box a player comes for it to load; 0: the load distance of the streaming settings
    rule:Section_Rule,
    state:Section_State, // asked: with a network, the server asks and each end loads its own
    streamed:Section_State `mirai:"transient,local,readonly"`, // Spatial: what the streaming of this end wants, by where its players are
    loaded:base.Asset_Id `mirai:"transient,local,hidden"`, // the scene what hangs from it was loaded from
    failed:base.Asset_Id `mirai:"transient,local,hidden"`, // a scene that did not load: tried again when the section is asked again
    held:bool `mirai:"transient,local,hidden"`,   // loaded and off: what hangs from it is under Disabled (Section_Held)
    far:base.Asset_Id `mirai:"transient,local,hidden"`, // not loaded: the scene its far forms (Far_Kept) are of
}

// What a section is to be: a Spatial one, what the streaming of this end
// wants of it; another, what it is asked.
section_state :: proc "contextless" (reference:Scene_Reference) -> Section_State {
    return reference.rule==.Spatial?reference.streamed:reference.state
}

// What is off because of its section, which turns it on again with it: what
// hangs from a section loaded and off, and what is dormant. The reference
// stays on, so the state of the section can still be asked; what its author
// turned off stays off.
@(component,description="Off because its section is loaded and off, or not loaded: on again with it.")
Section_Held :: struct {}

// What stands for the section of reference while it is not loaded and on,
// beside it: its far form, which the plugin that makes it shows and takes
// away. The editor picks the reference through it.
@(component,description="The far form of a section that is not loaded and on, shown beside its reference.")
Section_Proxy :: struct {
    reference:core.Entity `mirai:"readonly"`,
}

// The Id an entity of a section has in its own scene: what saving the
// section (Capture_Desc.section) writes. An entity added to a section while
// it is edited in its world has none, and its own scene takes its Id.
@(component,description="The Id an entity of a section has in the scene of the section, from which its Id in the world is made.")
Section_Member :: struct {
    local:base.Entity_Id `mirai:"readonly,hidden"`, // a saved game keeps it; the scene of the section does not
}

REFERENCE_DEPTH :: 16 // references inside referenced scenes, past which a load fails

// The scenes the section of reference e is inside, outermost first: the scene
// of the world and that of each reference above e. A section whose scene is
// among them would hold itself.
section_path :: proc(w:core.World_Ref,e:core.Entity,allocator:=context.temp_allocator) -> []base.Asset_Id {
    path:=make([dynamic]base.Asset_Id,allocator)
    references:=core.world_table_of(w,Scene_Reference)
    parents:=core.world_table_of(w,core.Parent)
    if references!=nil && parents!=nil {
        at:=e
        for _ in 0..<core.HIERARCHY_DEPTH {
            parent,placed:=core.get(parents,at)
            if !placed || parent.entity==core.NONE {break}
            at=parent.entity
            if reference:=(^Scene_Reference)(core.raw_find(core.raw(references),type_info_of(Scene_Reference),at));reference!=nil {append(&path,reference.scene)}
        }
    }
    if root:=core.world_storage_of(w,Scene_Root);root!=nil && root.scene!={} {append(&path,root.scene)}
    slice.reverse(path[:])
    return path[:]
}

// The names of a path of scenes, as a problem says them.
path_text :: proc(assets:^host.Assets,path:[]base.Asset_Id,allocator:=context.temp_allocator) -> string {
    b:=strings.builder_make(allocator)
    for id,i in path {
        if i>0 {strings.write_string(&b," > ")}
        name:[base.ASSET_ID_TEXT]u8
        strings.write_string(&b,assets!=nil?host.assets_name(assets,id,&name):"?")
    }
    return strings.to_string(b)
}

// The Id in the world of the entity id of a scene referenced by the entity
// whose Id is reference; reference 0 leaves it as it is.
id_in :: proc "contextless" (reference,id:base.Entity_Id) -> base.Entity_Id {
    if reference==0 || id==0 {return id}
    combined:=base.Entity_Id(base.hash_combine(u64(reference),u64(id)))
    return combined!=0?combined:1
}

// Whether the box of a section whose entity is at pose holds a point of the
// world; one without a box holds none.
section_holds :: proc "contextless" (reference:Scene_Reference,pose:mm.Transform,point:[3]f32) -> bool {
    if reference.extents=={} {return false}
    local:=mm.quat_rotate(mm.quat_inverse(pose.rotation),point-pose.position)
    half:=reference.extents*linalg.abs(pose.scale)
    return abs(local.x)<=half.x && abs(local.y)<=half.y && abs(local.z)<=half.z
}

// The box of the world that holds the box of a section at pose; empty when it
// has none.
section_bounds :: proc "contextless" (reference:Scene_Reference,pose:mm.Transform) -> mm.Aabb {
    if reference.extents=={} {return mm.AABB_EMPTY}
    half:=reference.extents*linalg.abs(pose.scale)
    return mm.aabb_transform({-half,half},mm.transform_matrix({pose.position,pose.rotation,{1,1,1}}))
}

// The box of a section where it is.
Section_Box :: struct {
    entity:core.Entity, // of its Scene_Reference
    reference:Scene_Reference,
    pose:mm.Transform,
}

// The boxes of the sections of a world, in a tree of the boxes of the world
// around them: the sections that hold a point are found among the boxes near
// it, not by looking at every reference. Made again whole when a reference,
// or where one is, changes.
Section_Boxes :: struct {
    boxes:[dynamic]Section_Box,
    nodes:[dynamic]spatial.Bvh_Node,
    order:[dynamic]u32,
}

// Makes the boxes of the references that have one, where worlds puts them.
// False without memory: it holds none then.
section_boxes_build :: proc(b:^Section_Boxes,references:^core.Table(Scene_Reference,$A),worlds:^core.Table(core.World_Transform,$B)) -> bool {
    clear(&b.boxes);clear(&b.nodes);clear(&b.order)
    bounds:=make([dynamic]mm.Aabb,context.temp_allocator)
    for row in 0..<core.count(references) {
        reference:=core.at(references,row)
        e:=core.entity_at(references,row)
        pose,placed:=core.get(worlds,e)
        if !placed || reference.extents=={} {continue}
        box:=section_bounds(reference,pose.transform)
        if !spatial.aabb_valid(box) {continue}
        if _,no_room:=append(&b.boxes,Section_Box{e,reference,pose.transform});no_room!=nil {return section_boxes_fail(b)}
        if _,no_room:=append(&bounds,box);no_room!=nil {return section_boxes_fail(b)}
    }
    tree:spatial.Bvh
    if !spatial.bvh_build(&tree,bounds[:],{allocator=context.temp_allocator}) {return section_boxes_fail(b)}
    if resize(&b.nodes,len(tree.nodes))!=nil || resize(&b.order,len(tree.order))!=nil {return section_boxes_fail(b)}
    copy(b.nodes[:],tree.nodes)
    copy(b.order[:],tree.order)
    return true
}

@(private)
section_boxes_fail :: proc(b:^Section_Boxes) -> bool {
    clear(&b.boxes);clear(&b.nodes);clear(&b.order)
    return false
}

section_boxes_destroy :: proc(b:^Section_Boxes) {
    delete(b.boxes);delete(b.nodes);delete(b.order)
    b^={}
}

// The boxes that hold a point, appended to out.
section_boxes_at :: proc(b:^Section_Boxes,point:[3]f32,out:^[dynamic]Section_Box) {
    tree:=spatial.Bvh{nodes=b.nodes[:],order=b.order[:]}
    q:=spatial.bvh_query(&tree,{point,point})
    for leaf in spatial.bvh_query_next(&q) {
        for at in leaf {
            box:=b.boxes[at]
            if section_holds(box.reference,box.pose,point) {append(out,box)}
        }
    }
}
