package navigation

import "core:testing"
import "mirai:core"
import scene "mirai:engine/scene"
import mm "mirai:std/math"

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
        s:Nav_Sections
        defer sections_free(&s)
        testing.expect(t,sections_gather(&s,&w.references,&w.worlds,&w.ids,&problems))
        testing.expectf(t,len(s.items)==1 && s.items[0].here==c.here && s.items[0].away==!c.here,"case %d: %v",i,s.items[0])
    }
}

// Every section with a box is seen, however many: those away are away
// and those here keep their tiles, past the 64 of a fixed list too.
@(test)
any_number_of_sections_is_seen :: proc(t:^testing.T) {
    Case :: struct {sections,away:int}
    cases := []Case{{0,0},{1,1},{64,10},{65,65},{200,70}}
    for c in cases {
        w:Sections_World
        if !test_world_init(t,&w) {return}
        defer test_world_destroy(&w)
        // The last ones are away, past the first 64 when there are more.
        for i in 0..<c.sections {
            e:=core.create(&w.entities)
            here:=i<c.sections-c.away
            core.add(&w.references,e,scene.Scene_Reference{scene={1,1},extents={1,1,1},state=.Active if here else .Unloaded,loaded={1,1} if here else {}})
            core.add(&w.worlds,e,core.World_Transform{transform={position={f32(i)*4,0,0},rotation=1,scale=1}})
        }
        test_world_settle(&w)
        problems:core.Problems
        s:Nav_Sections
        defer sections_free(&s)
        testing.expect(t,sections_gather(&s,&w.references,&w.worlds,&w.ids,&problems))
        testing.expectf(t,len(s.items)==c.sections && len(s.away)==c.away && len(s.away_keys)==c.away && len(s.here)==c.sections-c.away,"%v: %d seen, %d away",c,len(s.items),len(s.away))
        testing.expect_value(t,problems.count,0)
        if c.away>0 {
            last:=mm.Vec3{f32(c.sections-1)*4,0,0}
            testing.expectf(t,sections_away(&s,last) && sections_covered(&s,{last-0.5,last+0.5}),"%v: the last section is away",c)
        }
        if c.away<c.sections {testing.expectf(t,!sections_away(&s,{0,0,0}),"%v: the first is here",c)}
        // Gathered again, the same.
        hash:=s.hash
        testing.expect(t,sections_gather(&s,&w.references,&w.worlds,&w.ids,&problems) && s.hash==hash && len(s.items)==c.sections)
    }
}
