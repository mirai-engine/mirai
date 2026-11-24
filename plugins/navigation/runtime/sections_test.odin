package navigation

import "core:testing"
import "mirai:core"
import scene "mirai:engine/scene"

@(private)
@(test_world)
Sections_World :: struct {
    using world:Test_World,
    references:core.Table(scene.Scene_Reference),
    ids:core.Table(core.Id),
    worlds:core.Table(core.World_Transform),
}

// A section is here only while it is loaded and on as section_state says:
// a Spatial one by what its streaming wants, another by what it is asked.
@(test)
a_section_is_here_by_its_section_state :: proc(t:^testing.T) {
    Case :: struct {rule:enum {Manual,Spatial},state,streamed:scene.Section_State,loaded,here:bool}
    cases := []Case{
        {.Manual,.Active,.Unloaded,true,true},
        {.Manual,.Loaded,.Active,true,false},
        {.Manual,.Active,.Active,false,false},
        {.Spatial,.Active,.Active,true,true},
        {.Spatial,.Active,.Loaded,true,false}, // loaded and off: between the active and the load distance
        {.Spatial,.Loaded,.Active,true,true},
        {.Spatial,.Active,.Unloaded,false,false},
    }
    for c,i in cases {
        w:Sections_World
        if !test_world_init(t,&w) {return}
        defer test_world_destroy(&w)
        e:=core.create(&w.entities)
        reference:=scene.Scene_Reference{scene={1,1},extents={2,2,2},state=c.state,streamed=c.streamed}
        if c.rule==.Spatial {reference.rule=.Spatial} else {reference.rule=.Manual}
        if c.loaded {reference.loaded={1,1}}
        core.add(&w.references,e,reference)
        core.add(&w.worlds,e,core.World_Transform{transform={rotation=1,scale=1}})
        test_world_settle(&w)
        problems:core.Problems
        s:=sections_gather(&w.references,&w.worlds,&w.ids,&problems)
        testing.expectf(t,s.count==1 && s.items[0].here==c.here && s.items[0].away==!c.here,"case %d: %v",i,s.items[0])
    }
}

// Past NAV_SECTIONS_MAX sections with a box, a problem names the first left
// out and how many are; up to it, none.
@(test)
sections_past_the_cap_are_reported :: proc(t:^testing.T) {
    Case :: struct {sections,seen,dropped:int}
    cases := []Case{{NAV_SECTIONS_MAX,NAV_SECTIONS_MAX,0},{NAV_SECTIONS_MAX+1,NAV_SECTIONS_MAX,1},{NAV_SECTIONS_MAX+5,NAV_SECTIONS_MAX,5}}
    for c in cases {
        w:Sections_World
        if !test_world_init(t,&w) {return}
        defer test_world_destroy(&w)
        made:[NAV_SECTIONS_MAX+8]core.Entity
        for i in 0..<c.sections {
            made[i]=core.create(&w.entities)
            core.add(&w.references,made[i],scene.Scene_Reference{scene={1,1},extents={1,1,1},state=.Active,loaded={1,1}})
            core.add(&w.worlds,made[i],core.World_Transform{transform={position={f32(i)*4,0,0},rotation=1,scale=1}})
        }
        test_world_settle(&w)
        problems:core.Problems
        s:=sections_gather(&w.references,&w.worlds,&w.ids,&problems)
        testing.expect_value(t,s.count,c.seen)
        if c.dropped==0 {
            testing.expect_value(t,problems.count,0)
            continue
        }
        p:=core.problem_find(&problems,made[NAV_SECTIONS_MAX],"navigation.sections")
        testing.expectf(t,p!=nil && problems.count==1,"%d sections: %v",c.sections,core.problems_list(&problems))
        if p!=nil {testing.expectf(t,core.problem_text(p)[:2]==(c.dropped==1?"1 ":"5 "),"%s",core.problem_text(p))}
    }
}
