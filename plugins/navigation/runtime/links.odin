package navigation

import "core:math/linalg"
import "mirai:core"
import "mirai:std/ai"
import "mirai:std/base"
import mm "mirai:std/math"
import phys "plugins:physics/runtime"

// The links of the meshes: those of the Nav_Link components, in every class,
// and those the build generates where a class can jump or drop, from the
// walls of each tile, with an arc the physics finds free.

NAV_LINK_TILES_PER_TICK :: 8 // tiles whose generated links are made again in a tick
NAV_GENERATED_PER_TILE :: 256

// The owner of the links generated from the walls of a tile.
generated_owner :: #force_inline proc "contextless" (coord:[2]i32) -> u64 {
    return LINK_OWNER_GENERATED|u64(u32(coord.x)&0x7fffffff)<<32|u64(u32(coord.y))
}

// What a Nav_Link asks of an agent of a class, by its ends and kind.
link_need :: proc "contextless" (link:Nav_Link,start,end:mm.Vec3) -> (need:ai.Nav_Need) {
    dy:=end.y-start.y
    switch link.kind {
    case LINK_JUMP:
        need={up=max(dy,0),down=max(-dy,0),across=linalg.length(mm.Vec3{end.x-start.x,0,end.z-start.z})}
        if link.two_way {need.up,need.down=abs(dy),abs(dy)}
    case LINK_DROP:
        need={down=max(-dy,0)}
        if link.two_way {need.up=abs(dy)}
    case LINK_CLIMB:
        need.abilities|=1<<u32(ABILITY_CLIMB)
    case LINK_LADDER:
        need.abilities|=1<<u32(ABILITY_LADDER)
    case LINK_DOOR:
        need.abilities|=1<<u32(ABILITY_DOOR)
    }
    need.abilities|=u32(link.abilities)
    return
}

@(private)
Link_Seen :: struct {
    link:Nav_Link,
    start,end:mm.Vec3,
}

// Puts in every class the links of the Nav_Link components that are new,
// moved or changed, and takes out those of the components that went. The
// arc of a jump or a drop is checked against the physics for the capsule of
// each class, as a generated one, again when the static collision changes
// across it (changed): a class the arc does not fit does not get the link,
// or gets it one way only.
@(private)
links_update :: proc(n:^Navigation,b:^Navigation_Builds,links:core.Read(Nav_Link),transforms:core.Read(core.Transform),parents:core.Read(core.Parent),physics:core.Ref(phys.Physics_State),changed:mm.Aabb,fresh:bool,problems:^core.Problems) {
    if !boxes_touched(links,{},transforms,parents,&b.links_seen) && !fresh && mm.aabb_is_empty(changed) {return}
    if fresh {
        for i in 0..<n.count {
            if class_in_volume(n,i) {continue}
            mesh:=&n.classes[i].mesh
            for &link,slot in mesh.links {
                if link.used && link.desc.owner&LINK_OWNER_GENERATED==0 {ai.nav_mesh_remove_link(mesh,ai.nav_ref_link(link.salt,u32(slot),false))}
            }
        }
        core.entity_map_clear(&b.links)
    }
    seen,enough:=seen_reset(b,len(b.links.values),problems)
    if !enough {b.links_seen={};return}
    b.looked+=u64(core.count(links))+u64(len(seen))
    for row in 0..<core.count(links) {
        e:=core.entity_at(links,row)
        link:=links.table.values[row]
        pose,ok:=core.world_of(transforms,parents,e)
        if !ok {continue}
        start:=pose.position
        end:=mm.transform_point(pose,link.end)
        if link.target!=core.NONE {
            if to,found:=core.world_of(transforms,parents,link.target);found {end=to.position}
        }
        now:=Link_Seen{link,start,end}
        at:=core.entity_map_index(&b.links,e)
        if at>=0 {
            if at<len(seen) {seen[at]=true}
            if b.links.values[at]==now && !(link_arced(link) && mm.aabb_overlaps(link_arc_box(start,end,n),changed)) {continue}
            b.links.values[at]=now
        } else {
            core.entity_map_put(&b.links,e,now)
        }
        for i in 0..<n.count {
            if class_in_volume(n,i) {continue}
            mesh:=&n.classes[i].mesh
            ai.nav_mesh_remove_links_of(mesh,u64(e))
            // A take-off joins the surface with the air: the agents that fly take it from the builds (agent_space_links).
            if link.kind==LINK_FLY {continue}
            class:=n.classes[i].class
            from,to,two_way:=start,end,link.two_way
            if link_arced(link) {
                check:=Arc_Check{physics,class.radius,class.height,n.classes[i].filter}
                kind:=ai.Nav_Jump_Kind.Jump if link.kind==LINK_JUMP else .Drop
                forward:=arc_clear(&check,{start=start,end=end,kind=kind})
                back:=link.two_way && arc_clear(&check,{start=end,end=start,kind=.Jump})
                switch {
                case forward: two_way=back
                case back: from,to,two_way=end,start,false
                case:
                    core.report(problems,e,"navigation.link_arc","The arc of this link does not fit an agent of class %q: the collision blocks it; move its ends or clear the way",base.text_get(class.name[:]))
                    continue
                }
            }
            shown:=link
            shown.two_way=two_way
            desc:=ai.Nav_Link_Desc{start=from,end=to,radius=max(class.radius*2,0.5),kind=u8(link.kind),two_way=two_way,area=u8(link.area),cost=link.cost,need=link_need(shown,from,to),owner=u64(e)}
            if ai.nav_mesh_add_link(mesh,desc)==0 {
                core.report(problems,e,"navigation.links","The mesh of class %q has no room for this link: raise max_links in Navigation_Settings",base.text_get(class.name[:]))
            }
        }
        n.revision+=1
    }
    for at:=len(seen)-1;at>=0;at-=1 {
        if seen[at] {continue}
        e:=b.links.entities[at]
        for i in 0..<n.count {if !class_in_volume(n,i) {ai.nav_mesh_remove_links_of(&n.classes[i].mesh,u64(e))}}
        core.entity_map_remove_at(&b.links,at)
        n.revision+=1
    }
}

// Whether the crossing of a link is a ballistic arc the physics must leave free.
@(private)
link_arced :: #force_inline proc "contextless" (link:Nav_Link) -> bool {return link.kind==LINK_JUMP || link.kind==LINK_DROP}

// The box the arc of a link sweeps, for the capsule of the largest class.
@(private)
link_arc_box :: proc "contextless" (start,end:mm.Vec3,n:^Navigation) -> mm.Aabb {
    reach:=f32(0)
    for i in 0..<n.count {reach=max(reach,n.classes[i].class.radius+n.classes[i].class.height)}
    box:=mm.aabb_add_point(mm.aabb_add_point(mm.AABB_EMPTY,start),end)
    box.max.y+=ai.NAV_JUMP_CLEARANCE
    return {box.min-reach,box.max+reach}
}

// Marks for new generated links the tiles from which an agent of a class could jump into a tile that changed.
@(private)
links_mark :: proc(n:^Navigation,class:int,coord:[2]i32) {
    c:=&n.classes[class]
    settings:=n.classes[class].class
    if settings.jump_up<=0 && settings.jump_across<=0 && settings.drop<=settings.climb {return}
    reach:=max(settings.jump_across,settings.radius*4)+c.config.cell_size*4
    tiles:=i32(reach/c.mesh.tile_width)+1
    for z in coord.y-tiles..=coord.y+tiles {
        for x in coord.x-tiles..=coord.x+tiles {
            if mark:=base.hash_map_ptr(&c.marks,coord_key({x,z}));mark!=nil && !mark.links {
                next:=mark^
                next.links=true
                mark_set(c,mark,next)
            }
        }
    }
}

@(private)
Arc_Check :: struct {
    physics:core.Ref(phys.Physics_State),
    radius,height:f32,
    filter:phys.Query_Filter, // what blocks the agents of the class
}

// Whether a capsule of the class fits along the arc of a link, a little above
// its ends so the ground it stands on does not count. A body that drops first
// steps off the edge and then falls: the step over the edge is not checked
// against the ground it leaves.
@(private)
arc_clear :: proc(user:rawptr,link:ai.Nav_Jump_Link) -> bool {
    check:=cast(^Arc_Check)user
    SEGMENTS :: 8
    radius:=check.radius*0.9
    half:=max(check.height*0.5-radius,0)
    lift:=mm.Vec3{0,radius+half+0.05,0}
    off:=f32(0)
    if link.kind==.Drop {
        flat:=linalg.length(mm.Vec3{link.end.x-link.start.x,0,link.end.z-link.start.z})
        off=min(check.radius*1.5/max(flat,1e-4),0.9)
    }
    point :: proc(link:ai.Nav_Jump_Link,u,off:f32) -> mm.Vec3 {
        if link.kind!=.Drop {return ai.nav_jump_point(link,u)}
        p:=link.start+(link.end-link.start)*u
        k:=max(u-off,0)/(1-off)
        p.y=link.start.y+(link.end.y-link.start.y)*k*k
        return p
    }
    previous:=point(link,off,off)+lift
    for i in 1..=SEGMENTS {
        p:=point(link,off+(1-off)*f32(i)/SEGMENTS,off)+lift
        d:=p-previous
        length:=linalg.length(d)
        if length>1e-4 {
            if _,hit:=phys.sweep(check.physics,phys.Capsule{radius=radius,half_height=half},previous,mm.QUAT_IDENTITY,d/length,length,filter=check.filter);hit {return false}
        }
        previous=p
    }
    return true
}

// Makes again the generated links of the tiles marked for them, a few each tick.
@(private)
links_generate :: proc(n:^Navigation,physics:core.Ref(phys.Physics_State),problems:^core.Problems) {
    done:=0
    found:[NAV_GENERATED_PER_TILE]ai.Nav_Jump_Link
    for i in 0..<n.count {
        if class_in_volume(n,i) || n.classes[i].linking==0 {continue}
        c:=&n.classes[i]
        class:=c.class
        it:=base.hash_map_iterator(&c.marks)
        for key,mark in base.hash_map_iterate(&it) {
            // A tile that waits for its collision keeps what it has: its links are made from that.
            if !mark.links || mark.dirty && !mark.unloaded || mark.building {continue}
            if done>=NAV_LINK_TILES_PER_TICK {return}
            done+=1
            next:=mark^
            next.links=false
            mark_set(c,mark,next)
            coord:=coord_of_key(key)
            owner:=generated_owner(coord)
            if ai.nav_mesh_remove_links_of(&c.mesh,owner)>0 {n.revision+=1}
            if ai.nav_mesh_tile_at(&c.mesh,coord)==nil {continue}
            jump:=ai.Nav_Jump{up=class.jump_up,across=class.jump_across,down=class.drop,radius=class.radius,climb=class.climb,step=max(c.config.cell_size*4,class.radius)}
            check:=Arc_Check{physics,class.radius,class.height,n.classes[i].filter}
            count,complete:=ai.nav_jump_links(&c.mesh,coord,jump,found[:],arc_clear,&check)
            if !complete {
                core.report(problems,core.NONE,"navigation.generated_links","A tile of class %q at %v has more than %d places to jump or drop from: some get no link",base.text_get(class.name[:]),coord,NAV_GENERATED_PER_TILE)
            }
            for link in found[:count] {
                kind:=LINK_JUMP if link.kind==.Jump else LINK_DROP
                desc:=ai.Nav_Link_Desc{start=link.start,end=link.end,radius=jump.step,kind=u8(kind),area=u8(AREA_WALKABLE),cost=1+link.need.up+link.need.down*0.25,need=link.need,owner=owner}
                if ai.nav_mesh_add_link(&c.mesh,desc)==0 {
                    core.report(problems,core.NONE,"navigation.links","The mesh of class %q has no room for its generated links: raise max_links in Navigation_Settings",base.text_get(class.name[:]))
                    break
                }
            }
            if count>0 {n.revision+=1}
        }
    }
}
