package navigation

import "core:math/linalg"
import "mirai:core"
import "mirai:std/ai"
import "mirai:std/base"
import mm "mirai:std/math"
import phys "plugins:physics/runtime"

// Navigation meshes made by themselves from the static collision of the
// physics, one for each class of agent, in tiles that are built again
// wherever that collision, an area or a bound changes. A class says how big
// an agent is and what it can jump or fall; an agent takes the smallest class
// that holds the capsule of its Character. Links join two points of a mesh:
// those of Nav_Link components, and those the build finds where a class can
// jump or drop. A class that flies or swims has a volume instead: the free
// space of the Nav_Bounds marked for the air, or of the water of the
// Fluid rows less their dry boxes, in zones built the same way. The meshes and
// volumes are state of the world: they copy with it, so a run starts with
// those of the document. A section saves the tiles over its box with its own
// scene, and they come and go with it; where the mesh is not there, the
// coarse graph of each mesh tells how the sections join.

NAV_CLASS_CAPACITY :: 8
NAV_AREA_CAPACITY :: 16 // areas with a cost in the settings

// What the surface of a navigation mesh is. Blocked is not walked; Walkable
// costs 1 per metre unless the settings say otherwise. A game declares its
// own after these: AREA_MUD :: navigation.Nav_Area_Kind(3).
@(names="AREA_")
Nav_Area_Kind :: distinct u8
AREA_BLOCKED :: Nav_Area_Kind(ai.NAV_AREA_BLOCKED)
AREA_WALKABLE :: Nav_Area_Kind(ai.NAV_AREA_WALKABLE)
// The ground under water deeper than a walker wades (Swim.depth of SWIM_DEFAULT): only agents that swim
// take it, and they swim there.
AREA_WATER :: Nav_Area_Kind(2)

// Bit i is the area i.
@(name_bits="Nav_Area_Kind")
Nav_Areas :: distinct u64

// What crossing a link is, for whoever crosses it: the engine crosses Jump,
// Drop, Climb and Ladder by itself; Door and those of a game wait for the
// game (nav_crossing_done). Swim and Fly join the mesh with a volume, and the
// agent plans on in the other space once it is there: Swim, from the shore
// into the water or out of it, navigation makes for an agent that walks and
// swims; Fly, a take-off from the surface into the air or a landing, is a
// Nav_Link for an agent that walks and flies, from the ground to the air.
@(names="LINK_")
Nav_Link_Kind :: distinct u8
LINK_JUMP :: Nav_Link_Kind(0)
LINK_DROP :: Nav_Link_Kind(1)
LINK_CLIMB :: Nav_Link_Kind(2)
LINK_LADDER :: Nav_Link_Kind(3)
LINK_DOOR :: Nav_Link_Kind(4)
LINK_SWIM :: Nav_Link_Kind(5)
LINK_FLY :: Nav_Link_Kind(6)

@(name_bits="Nav_Link_Kind")
Nav_Link_Kinds :: distinct u32

// What an agent can do besides walking, jumping and falling, that a link may need.
@(names="ABILITY_")
Nav_Ability :: distinct u8
ABILITY_CLIMB :: Nav_Ability(0)
ABILITY_LADDER :: Nav_Ability(1)
ABILITY_DOOR :: Nav_Ability(2)

@(name_bits="Nav_Ability")
Nav_Abilities :: distinct u32

// Where the agents of a class move: on a mesh over the walkable surface, or
// through the volume of the air or of the water.
Nav_Space :: enum u8 {Surface,Air,Water}

// A class of agent: how big it is, what it steps up and how steep it walks,
// and what the links generated for it may ask: how high and how far it jumps
// and how far it drops. 0 asks none of that kind. A class of the air or of
// the water uses only its radius and height: agents with a Fly take one of
// the air, and those with a Swim one of the water while they swim. Its mesh
// is made of the static collision that blocks a collider of its collision
// preset, the one its agents take, under the Collision_Settings of the
// physics: what blocks only other categories (a clip for players) is not in
// it. Default: what blocks the Default category, all blocking collision.
Nav_Class :: struct {
    name:[32]u8 `mirai:"text"`,
    space:Nav_Space,
    radius:f32 `mirai:"min=0,unit=m"`,
    height:f32 `mirai:"min=0,unit=m"`,
    climb:f32 `mirai:"min=0,unit=m"`,
    max_slope:f32 `mirai:"angle,min=0"`,
    jump_up:f32 `mirai:"min=0,unit=m"`,
    jump_across:f32 `mirai:"min=0,unit=m"`,
    drop:f32 `mirai:"min=0,unit=m"`,
    collision:phys.Collision_Preset, // that of the colliders of its agents; not Custom nor a sensor
}

Nav_Area_Cost :: struct {
    area:Nav_Area_Kind,
    cost:f32 `mirai:"min=0"`, // per metre; 0: 1
}

// How the navigation meshes of the project are made and searched. Changing
// a class or a size makes every mesh again.
@(storage,setting)
Navigation_Settings :: struct {
    classes:[NAV_CLASS_CAPACITY]Nav_Class `mirai:"trim"`,
    cell_size:f32 `mirai:"min=0,unit=m,section=Build,advanced"`, // across a voxel
    cell_height:f32 `mirai:"min=0,unit=m,advanced"`,      // along y of a voxel
    tile_cells:i32 `mirai:"min=8,max=512,advanced"`,      // voxels across a tile
    max_tiles:i32 `mirai:"min=1,advanced"`,                // of each class
    max_links:i32 `mirai:"min=0,advanced"`,                // of each class, given and generated
    builds:i32 `mirai:"min=1,max=64,advanced"`,            // tiles built at once
    areas:[NAV_AREA_CAPACITY]Nav_Area_Cost `mirai:"trim"`,
    path_iterations:i32 `mirai:"min=1,section=Agents,advanced"`, // polygons the searches of all agents expand in a tick
}

NAVIGATION_SETTINGS_DEFAULT :: Navigation_Settings{
    classes={
        0={name={0='H',1='u',2='m',3='a',4='n'},radius=0.3,height=1.8,climb=0.3,max_slope=0.25*mm.PI,jump_up=1.2,jump_across=4,drop=4},
        1={name={0='F',1='l',2='i',3='e',4='r'},space=.Air,radius=0.3,height=1.8},
        2={name={0='S',1='w',2='i',3='m',4='m',5='e',6='r'},space=.Water,radius=0.3,height=1.8},
    },
    cell_size=0.15,cell_height=0.1,tile_cells=64,max_tiles=1024,max_links=4096,builds=4,
    path_iterations=2048,
}

// The three that follow say what the Volume of their entity is to the
// navigation: it is to be a Box, taken upright where the entity is (its yaw
// turns it). Its blend, priority and mode do nothing here.

// Where meshes are made: the box of the Volume of its entity. Without any,
// the box of all the static collision. A box of the air is where agents fly,
// instead: the sky has no edge of its own.
@(component,description="Navigation meshes are made inside the box of the Volume of its entity; without any bounds, inside the box of all the static collision. With air, it is the space where agents fly instead.")
Nav_Bounds :: struct {
    air:bool,
}
NAV_BOUNDS_DEFAULT :: Nav_Bounds{}

// The surface inside the box of the Volume of its entity is of an area:
// cheaper or dearer to walk, or Blocked.
@(component,description="The walkable surface inside the box of the Volume of its entity is of an area: dearer or cheaper to walk, or blocked.")
Nav_Area :: struct {
    area:Nav_Area_Kind,
}
NAV_AREA_DEFAULT :: Nav_Area{area=AREA_BLOCKED}

// Something that moves and stops (a car, a crate, a door): while it moves,
// agents step aside from it; once it has been still `settle` seconds, the
// surface inside the box of the Volume of its entity is blocked until it
// moves again.
@(component,description="A thing agents step aside from while it moves; once still for a while, the surface under the box of the Volume of its entity is blocked until it moves again.")
Nav_Obstacle :: struct {
    settle:f32 `mirai:"min=0,unit=s"`,
}
NAV_OBSTACLE_DEFAULT :: Nav_Obstacle{settle=1}

// A way from the entity to `end` (in its frame) or to the entity `target`:
// a jump, a ladder, a door. Agents that cannot do what it needs go around.
@(component,description="A way between two points that agents can take: from this entity to its end, or to a target entity. Agents that cannot cross it go around.")
Nav_Link :: struct {
    end:[3]f32 `mirai:"unit=m"`,  // in the frame of the entity, without a target
    target:core.Entity,           // the end is this entity
    kind:Nav_Link_Kind,
    two_way:bool,
    cost:f32 `mirai:"min=0"`,     // added to its length
    area:Nav_Area_Kind,           // whose cost per metre the crossing pays
    abilities:Nav_Abilities,      // an agent needs them all
}
NAV_LINK_DEFAULT :: Nav_Link{end={0,0,2},kind=LINK_JUMP,area=AREA_WALKABLE}

// The owner of a link the build generated: the bit, and the tile coordinate below it.
LINK_OWNER_GENERATED :: u64(1)<<63

// The navigation meshes of a world, one per class of the settings.
@(storage,copy="navigation_copy",copy_kept="navigation_copy_kept",free="navigation_free",reset="navigation_free")
Navigation :: struct {
    classes:[NAV_CLASS_CAPACITY]Class_Mesh,
    count:int,
    settings:Navigation_Settings, // those the meshes were made with
    uid:u64,                      // of this copy, for the builds that write to it; 0 until a build looks
    revision:u64,                 // any tile or link of any class changed
    kept:[3]u64,                  // of a copy: the uid and the revision of the Navigation its meshes were built in, and its own revision when it took them (meshes_of)
    stats:Build_Stats,
    ready:bool,
}

Class_Mesh :: struct {
    class:Nav_Class,                     // the one of the settings it was made for
    filter:phys.Query_Filter,            // the static collision its mesh is made of: what blocks its agents (class_filter)
    mesh:ai.Nav_Mesh,
    config:ai.Nav_Build_Config,
    volume:ai.Nav_Volume,                // of a class of the air or the water, instead of the mesh
    volume_config:ai.Nav_Volume_Config,
    marks:base.Hash_Map(Tile_Mark),      // by tile or zone coordinate; changed through mark_set
    pending:int,                         // tiles that wait for a build or build: searches that find no surface wait for them
    ready:int,                           // marked tiles that can start a build
    loading:int,                         // marked tiles that wait for their collision to load
    linking:int,                         // tiles whose generated links wait to be made again
    coarse:ai.Nav_Coarse,                // of a class of the surface: how the sections join, by their portals
}

// What a tile of a class was built from and whether it waits for a build.
Tile_Mark :: struct {
    hash:u64,   // of the input of the tile it has; 0: none built
    stamp:u32,  // counts the times it was marked; a build started before the last one is thrown away
    dirty:bool,
    building:bool,
    links:bool,    // its generated links wait to be made again
    unloaded:bool, // dirty, it waits for the collision it reads to load: it keeps what it has
}

// Where the static collision is not loaded: a library that pages geometry in
// and out (the terrain, through the bridge navigation_terrain) names its
// boxes. The tiles and zones that read one keep what they have, built before
// or baked, instead of building from what is missing, and are built once it
// loads; a search that finds no surface waits for them. In a run, those that
// read only what the boxes cover go, and come back from the bakes once they do
// not. Not the state of the world: its writer makes it again from the world it
// runs on.
@(storage,host,by_world,free="nav_unloaded_free")
Nav_Unloaded :: struct {
    boxes:[dynamic]mm.Aabb,
    revision:u64, // changes whenever the boxes do
}

nav_unloaded_free :: proc(u:^Nav_Unloaded) {
    delete(u.boxes)
    u^={}
}

// Where the collision is not loaded this tick: what the terrain names, and
// the boxes of the sections that are away (Nav_Sections).
Unloaded :: struct {
    terrain:^Nav_Unloaded,
    sections:^Nav_Sections,
    revision:u64, // changes whenever the boxes of either do
}

// Whether a box reaches where the collision is not loaded. A tile (flat)
// does not wait for a section away where, seen from above, sections here
// cover it: it is another floor of their column, and the tile builds from
// what is here.
unloaded_overlaps :: proc "contextless" (u:Unloaded,box:mm.Aabb,flat:=false) -> bool {
    if u.terrain!=nil {for unloaded in u.terrain.boxes {if mm.aabb_overlaps(unloaded,box) {return true}}}
    if u.sections==nil {return false}
    for away in u.sections.away[:u.sections.away_count] {
        if !mm.aabb_overlaps(away,box) {continue}
        if flat && sections_stacked(u.sections,{linalg.max(away.min,box.min),linalg.min(away.max,box.max)}) {continue}
        return true
    }
    return false
}

// What a mark counts for in the tallies of its class.
@(private)
mark_tally :: proc "contextless" (c:^Class_Mesh,mark:Tile_Mark,sign:int) {
    if mark.dirty || mark.building {c.pending+=sign}
    if mark.dirty && !mark.building {
        if mark.unloaded {c.loading+=sign} else {c.ready+=sign}
    }
    if mark.links {c.linking+=sign}
}
mark_set :: proc "contextless" (c:^Class_Mesh,mark:^Tile_Mark,next:Tile_Mark) {
    mark_tally(c,mark^,-1)
    mark^=next
    mark_tally(c,next,1)
}
mark_remove :: proc(c:^Class_Mesh,key:u64) {
    if old,found:=base.hash_map_remove(&c.marks,key);found {mark_tally(c,old,-1)}
}

navigation_copy :: proc(dst,src:^Navigation) -> bool {
    of:=meshes_of(src)
    navigation_free(dst)
    dst^=src^
    dst.uid,dst.kept=0,of[0]!=0?{of[0],of[1],src.revision}:{}
    for &c in dst.classes {c={}}
    for i in 0..<src.count {
        from,to:=&src.classes[i],&dst.classes[i]
        if !ai.nav_mesh_copy(&to.mesh,&from.mesh) || !ai.nav_volume_copy(&to.volume,&from.volume) || !ai.nav_coarse_copy(&to.coarse,&from.coarse) || !class_copy(to,from) {
            navigation_free(dst)
            return false
        }
    }
    return true
}

// Whose meshes a Navigation holds: the uid and the revision of the one they
// were built in. Every change of a mesh, a volume or a coarse graph moves the
// revision, and a Navigation gets from the builds that first look at it a uid
// no other one of its world had, so no two different sets of meshes share
// the pair. A copy holds those of what it was copied from until its own
// revision moves. {0,0}: of none yet, as before any build looked at it.
@(private)
meshes_of :: proc "contextless" (n:^Navigation) -> [2]u64 {
    if n.kept[0]!=0 && n.kept[2]==n.revision {return {n.kept[0],n.kept[1]}}
    return n.uid!=0?{n.uid,n.revision}:{}
}

// The copy a history keeps. The meshes, the volumes and the coarse graphs
// are copied again only when dst holds those of another Navigation or of
// another revision (meshes_of): also after the world went back to a copy and
// built nothing since. What the looks change without a build (the marks of
// the tiles, the settings, the counts) is copied every time.
navigation_copy_kept :: proc(dst,src:^Navigation) -> bool {
    if dst==src {return true}
    of:=meshes_of(src)
    if of[0]==0 || meshes_of(dst)!=of || dst.count!=src.count {return navigation_copy(dst,src)}
    dst.settings,dst.stats,dst.ready,dst.revision=src.settings,src.stats,src.ready,src.revision
    dst.kept[2]=src.revision
    for i in 0..<src.count {
        if !class_copy(&dst.classes[i],&src.classes[i]) {
            navigation_free(dst)
            return false
        }
    }
    return true
}

// What a class is made for and the marks of its tiles, as a copy has them:
// no build of the copy is on its way, so what was building waits to build.
@(private)
class_copy :: proc(to,from:^Class_Mesh) -> bool {
    to.class,to.filter,to.config,to.volume_config=from.class,from.filter,from.config,from.volume_config
    to.pending,to.ready,to.loading,to.linking=0,0,0,0
    if len(to.marks.keys)!=len(from.marks.keys) {
        base.hash_map_destroy(&to.marks)
        if len(from.marks.keys)==0 {return true}
        if !base.hash_map_init(&to.marks,from.marks.capacity) {return false}
    }
    if len(from.marks.keys)==0 {return true}
    copy(to.marks.keys,from.marks.keys)
    copy(to.marks.values,from.marks.values)
    to.marks.has_zero,to.marks.usage=from.marks.has_zero,from.marks.usage
    it:=base.hash_map_iterator(&to.marks)
    for _,mark in base.hash_map_iterate(&it) {
        mark.dirty|=mark.building
        mark.building=false
        mark_tally(to,mark^,1)
    }
    return true
}
navigation_free :: proc(n:^Navigation) {
    for &c in n.classes {
        ai.nav_mesh_destroy(&c.mesh)
        ai.nav_volume_destroy(&c.volume)
        ai.nav_coarse_destroy(&c.coarse)
        base.hash_map_destroy(&c.marks)
        c={}
    }
    n^={}
}

coord_key :: #force_inline proc "contextless" (coord:[2]i32) -> u64 {return u64(u32(coord.x))<<32|u64(u32(coord.y))}
coord_of_key :: #force_inline proc "contextless" (key:u64) -> [2]i32 {return {i32(u32(key>>32)),i32(u32(key))}}
// A zone: 21 bits an axis, which its coordinates never leave.
zone_key :: #force_inline proc "contextless" (coord:[3]i32) -> u64 {
    return u64(u32(coord.x)&0x1fffff)|u64(u32(coord.y)&0x1fffff)<<21|u64(u32(coord.z)&0x1fffff)<<42
}
zone_of_key :: #force_inline proc "contextless" (key:u64) -> [3]i32 {
    signed :: #force_inline proc "contextless" (v:u64) -> i32 {return i32(u32(v)<<11)>>11}
    return {signed(key&0x1fffff),signed((key>>21)&0x1fffff),signed((key>>42)&0x1fffff)}
}
class_in_volume :: #force_inline proc "contextless" (n:^Navigation,class:int) -> bool {return n.classes[class].class.space!=.Surface}

// The class whose name it is, or -1.
class_find :: proc(n:^Navigation,name:string) -> int {
    for i in 0..<n.count {
        if base.text_get(n.classes[i].class.name[:])==name {return i}
    }
    return -1
}

// The filter of an agent of a class: the costs of the settings, the areas it
// avoids and what it can cross.
filter_make :: proc "contextless" (settings:^Navigation_Settings,excluded:Nav_Areas,can:ai.Nav_Need) -> (f:ai.Nav_Filter) {
    for entry in settings.areas {
        if entry.cost>0 && u8(entry.area)<=ai.NAV_AREA_MAX {f.costs[entry.area]=entry.cost}
    }
    f.excluded=u64(excluded)
    f.can=can
    return
}

// What the mesh of a class is made of: the static collision that blocks a
// collider of its preset under the collision settings of the physics.
class_filter :: proc "contextless" (collision:^phys.Collision_Settings,class:Nav_Class) -> phys.Query_Filter {
    filter:=phys.QUERY_FILTER_DEFAULT
    filter.filter=phys.collision_filter(collision,phys.Collider{preset=class.collision})
    return filter
}
