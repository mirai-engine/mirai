package navigation_editor

import "core:math/linalg"
import "core:mem/virtual"
import "mirai:core"
import "mirai:editor"
import "mirai:std/ai"
import mm "mirai:std/math"
import nav "plugins:navigation/runtime"
import phys "plugins:physics/runtime"

// The way a drive of play.step takes through the navigation meshes: the next
// point from where its body stands now to its goal.

ROUTE_NODES :: 8192   // of a search
ROUTE_POLYGONS :: 4096
ROUTE_CORNERS :: 512
ROUTE_END :: f32(0.3) // m left of the way: the drive goes on by itself
ROUTE_SLACK :: f32(0.3) // m across the ground a corner must be from the body

@(storage)
Navigation_Route :: struct {provider:editor.Route_Provider}

NAVIGATION_ROUTE_DEFAULT :: Navigation_Route{provider={next=route_next}}

// The way along corners from a body at from: the first corner past where it
// stands and what is left; None once there is little left of it.
route_of :: proc "contextless" (corners:[]ai.Nav_Corner,from:[3]f32) -> editor.Route {
    left:=f32(0)
    prior:=from
    next:=-1
    for corner,i in corners {
        left+=linalg.length(corner.position-prior)
        prior=corner.position
        across:=corner.position-from
        across.y=0
        if next<0 && linalg.length(across)>ROUTE_SLACK {next=i}
    }
    if next<0 || left<ROUTE_END {return {}}
    return {state=.Found,next=corners[next].position,left=left}
}

@(private)
route_next :: proc(s:^editor.Session,w:core.World_Ref,body:core.Entity,goal:[3]f32) -> editor.Route {
    n:=core.world_storage_of(w,nav.Navigation)
    if n==nil {return {}}
    if !n.ready {return {state=.Waiting}}
    if n.count==0 {return {}}
    characters,colliders,walks:=core.world_table_of(w,phys.Character),core.world_table_of(w,phys.Collider),core.world_table_of(w,phys.Walk)
    swims,worlds:=core.world_table_of(w,phys.Swim),core.world_table_of(w,core.World_Transform)
    physics:=core.world_storage_of(w,phys.Physics_State)
    if characters==nil || colliders==nil || walks==nil || swims==nil || worlds==nil || physics==nil {return {}}
    character,is_character:=core.get(characters,body)
    collider,collides:=core.get(colliders,body)
    pose,placed:=core.get(worlds,body)
    if !is_character || !collides || !placed {return {}}
    class,_,_:=nav.class_of(n,character,collider,pose.scale,.Surface)
    if class<0 || nav.class_in_volume(n,class) {return {}}
    agent:=nav.NAV_AGENT_DEFAULT
    if agents:=core.world_table_of(w,nav.Nav_Agent);agents!=nil {
        if own,seated:=core.get(agents,body);seated {agent=own}
    }
    walk,_:=core.get(walks,body)
    gravity:=linalg.length(phys.gravity_of_entity(core.Ref(phys.Physics_State){physics},body))
    filter:=nav.agent_filter(n,class,agent,{walk.jump_height,walk.max_speed},core.has(swims,body),gravity)
    settings:=n.classes[class].class
    mesh:=&n.classes[class].mesh
    extents:=mm.Vec3{settings.radius*2+0.5,settings.height,settings.radius*2+0.5}
    from,start,found:=ai.nav_find_nearest(mesh,pose.position,extents,&filter)
    to,end,found_goal:=ai.nav_find_nearest(mesh,goal,extents*4,&filter)
    if !found || !found_goal {return n.classes[class].pending>0?{state=.Waiting}:{}}
    arena:virtual.Arena
    if virtual.arena_init_growing(&arena)!=nil {return {}}
    defer virtual.arena_destroy(&arena)
    memory:=virtual.arena_allocator(&arena)
    q:ai.Nav_Query
    if !ai.nav_query_init(&q,ROUTE_NODES,memory) {return {}}
    refs:=make([]ai.Nav_Ref,ROUTE_POLYGONS,memory)
    corners:=make([]ai.Nav_Corner,ROUTE_CORNERS,memory)
    count,_,partial:=ai.nav_find_path(&q,mesh,from,to,start,end,&filter,refs)
    if count==0 {return {}}
    target:=end
    if partial {target,_=ai.nav_closest_point_on_poly(mesh,refs[count-1],end)}
    count=ai.nav_path_straighten(mesh,&filter,start,target,refs,count)
    listed,_:=ai.nav_straight_path(mesh,start,target,refs[:count],corners)
    return route_of(corners[:listed],pose.position)
}
