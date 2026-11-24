package navigation

import "core:math/linalg"
import "core:testing"
import "mirai:core"
import scene "mirai:engine/scene"
import "mirai:std/ai"
import mm "mirai:std/math"

// In a run, the tiles build only within the reach of the sources of the
// navigation: the simulation sources with Navigation_Settings.resident, and
// each Nav_Source with its own distance or, without one, resident. With no
// reach, a Nav_Source that reaches everywhere, or in the editor, every tile
// builds.
@(test)
tiles_build_in_a_run_only_within_the_reach_of_the_sources_of_the_navigation :: proc(t:^testing.T) {
    Mark :: struct {position:[3]f32,distance:f32}
    Case :: struct {
        name:string,
        resident:f32,
        simulation:[]Mark,
        marks:[]Mark,
        playing:bool,
        reaches:[]Mark, // where tiles build and how far; none: everywhere
    }
    corner:=[]Mark{{{-26,0,-26},0}}
    other:=[]Mark{{{26,0,26},10}}
    other_resident:=[]Mark{{{26,0,26},0}}
    cases:=[]Case{
        {"no reach: everywhere",0,corner,nil,true,nil},
        {"resident around the simulation source",10,corner,nil,true,{{{-26,0,-26},10}}},
        {"a Nav_Source with a distance of its own",0,corner,other,true,{{{26,0,26},10}}},
        {"a Nav_Source without one takes resident",10,corner,other_resident,true,{{{-26,0,-26},10},{{26,0,26},10}}},
        {"a Nav_Source that reaches everywhere",0,corner,other_resident,true,nil},
        {"the editor builds everything",10,corner,nil,false,nil},
    }
    for c in cases {
        f:=new(Nav_Test)
        defer free(f)
        if !nav_test_init(t,f) {return}
        defer nav_test_destroy(f)
        nav_test_box(f,{0,-0.5,0},{30,0.5,30})
        f.nav_settings.resident=c.resident
        f.time.playing=c.playing
        for source,i in c.simulation {f.sources.items[i]={position=source.position}}
        f.sources.count=len(c.simulation)
        for mark in c.marks {
            e:=core.create(&f.entities)
            core.add(&f.nav_sources,e,Nav_Source{mark.distance})
            core.add(&f.worlds,e,core.World_Transform{transform={position=mark.position,rotation=1,scale=1}})
        }
        for _ in 0..<200 {nav_test_step(f)}
        if !testing.expectf(t,f.nav.count>0,"%s: no meshes",c.name) {continue}
        cl:=&f.nav.classes[0]
        built:=0
        near:=make([]int,len(c.reaches),context.temp_allocator)
        for &tile in cl.mesh.tiles {
            if !tile.used {continue}
            built+=1
            if len(c.reaches)==0 {continue}
            rect:=ai.nav_tile_rect(cl.config,tile.data.coord)
            within:=false
            for reach,i in c.reaches {
                away:=scene.box_distance(rect.min,rect.max,reach.position)
                if away<=reach.distance+1e-3 {within=true;near[i]+=1}
            }
            testing.expectf(t,within,"%s: tile %v built beyond every reach",c.name,tile.data.coord)
        }
        if len(c.reaches)==0 {
            testing.expectf(t,cl.pending==0 && built>=64,"%s: %d tiles built, %d left",c.name,built,cl.pending)
        } else {
            testing.expectf(t,cl.pending>0,"%s: tiles beyond the reaches wait",c.name)
            for count,i in near {testing.expectf(t,count>0,"%s: no tile built near %v",c.name,c.reaches[i].position)}
            // Still, the marks out of reach are not looked at again; a source that moves builds where it goes.
            looked:=f.builds.looked
            nav_test_step(f,8)
            testing.expectf(t,f.builds.looked==looked,"%s: %d marks looked at while nothing moved",c.name,f.builds.looked-looked)
            if len(c.simulation)>0 && c.resident>0 {
                f.sources.items[0].position={0,0,0}
                for _ in 0..<100 {nav_test_step(f)}
                _,_,found:=ai.nav_find_nearest_any(&cl.mesh,{0,0,0},{1,2,1})
                testing.expectf(t,found,"%s: the mesh builds where the source went",c.name)
            }
        }
        testing.expectf(t,f.problems.count==0,"%s: %v",c.name,core.problems_list(&f.problems))
    }
}

// An agent whose goal is on tiles not built yet walks to the edge of what is
// built toward it, with a partial path, waits there without arriving, and
// goes on to its goal once they are built. Tiles on its way build beyond the
// reach of every source of the navigation; those off its way do not.
@(test)
an_agent_walks_to_the_edge_of_what_is_built_and_on_as_the_rest_arrives :: proc(t:^testing.T) {
    Case :: struct {
        name:string,
        floor:[3]f32,    // half its size, with its near side at z 0
        unloaded:bool,   // the collision around the goal is not loaded until the agent waits at the edge
        reach:f32,       // of a Nav_Source where the agent starts; 0: none
    }
    cases:=[]Case{
        {"its goal on tiles that wait for their collision",{30,0.5,1.5},true,0},
        {"its goal beyond the reach of every source",{30,0.5,12},false,8},
    }
    from,to:=mm.Vec3{-26,0,1.5},mm.Vec3{26,0,1.5}
    for c in cases {
        f:=new(Nav_Test)
        defer free(f)
        if !nav_test_init(t,f) {return}
        defer nav_test_destroy(f)
        nav_test_box(f,{0,-0.5,c.floor.z},c.floor)
        if c.unloaded {
            append(&f.unloaded,mm.Aabb{{4,-1,-1},{31,3,4}})
            core.push(&f.ground.unloaded,mm.Aabb{})
        }
        if c.reach>0 {
            mark:=core.create(&f.entities)
            core.add(&f.nav_sources,mark,Nav_Source{c.reach})
            core.add(&f.transforms,mark,core.Transform{from,1,{1,1,1}})
        }
        e:=agents_test_walker(f,from)
        nav_test_settle(f)
        nav_move_to(&f.nav_requests,e,to)
        arrived,stopped_short:=false,false
        edge:=false // it walked a partial path while its goal was not on the mesh
        for _ in 0..<900 {
            agents_test_step(f)
            clear(&f.ground.unloaded.items)
            for event in f.nav_events.queue.items {
                arrived|=event.entity==e && event.kind==.Arrived
                stopped_short|=event.entity==e && event.kind==.Arrived_Partial
            }
            p,_:=core.get(&f.paths,e)
            pose,_:=core.get(&f.worlds,e)
            if f.nav.count>0 && p.state==.Moving && p.partial && pose.position.x>from.x+2 {
                _,_,on:=ai.nav_find_nearest_any(&f.nav.classes[0].mesh,to,{1,2,1})
                edge||=!on
            }
            if arrived {break}
        }
        p,_:=core.get(&f.paths,e)
        pose,_:=core.get(&f.worlds,e)
        if c.unloaded {
            testing.expectf(t,edge && !arrived && p.state==.Moving && p.partial && p.goal==to && pose.position.x>-10,
                "%s: it is %v at %v, partial %v",c.name,p.state,pose.position,p.partial)
            clear(&f.unloaded)
            core.push(&f.ground.unloaded,mm.Aabb{})
            for _ in 0..<900 {
                agents_test_step(f)
                clear(&f.ground.unloaded.items)
                if p,_=core.get(&f.paths,e);p.state==.Arrived {arrived=true;break}
            }
            pose,_=core.get(&f.worlds,e)
        }
        testing.expectf(t,arrived && p.state==.Arrived && !p.partial && linalg.distance(pose.position.xz,to.xz)<0.5,
            "%s: it is %v at %v",c.name,p.state,pose.position)
        testing.expectf(t,!stopped_short,"%s: it arrived short of its goal while tiles built",c.name)
        if c.reach>0 {
            cl:=&f.nav.classes[0]
            for &tile in cl.mesh.tiles {
                if !tile.used {continue}
                rect:=ai.nav_tile_rect(cl.config,tile.data.coord)
                testing.expectf(t,rect.min.z<from.z+c.reach,"%s: tile %v off its way and beyond the reach built",c.name,tile.data.coord)
            }
        }
        testing.expectf(t,f.problems.count==0,"%s: %v",c.name,core.problems_list(&f.problems))
    }
}
