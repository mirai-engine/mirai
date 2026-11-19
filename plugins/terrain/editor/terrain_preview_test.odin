package terrain_editor

import "core:testing"
import "mirai:core"
import terrain "plugins:terrain/runtime"
import "mirai:std/base"

@(private)
@(test_world)
Preview_Test_World :: struct {
    using world:Test_World,
    terrains:core.Table(terrain.Terrain),
    chunks:core.Table(terrain.Terrain_Chunk),
}

// A chunk previews every sample with the border it shows, which a stroke
// does not change, a hole either: only the chunks the stroke touches are
// previewed.
@(test)
a_preview_shows_the_border_of_its_chunk_and_a_hole_changes_no_border :: proc(t:^testing.T) {
    world:Preview_Test_World
    if !test_world_init(t,&world) {return}
    defer test_world_destroy(&world)
    tool:Terrain_Tool;defer terrain_tool_free(&tool)
    stroke:=&tool.stroke
    s:=&stroke.source
    if !testing.expect(t,terrain.source_make(s,.Heightfield,{69,1,69},0.5,16)) {return}
    stroke.id=base.Asset_Id{7,8}
    counts:=terrain.chunk_counts(s)
    total:=counts.x*counts.y*counts.z
    resize(&stroke.preview_at,total)
    for &slot in stroke.preview_at {slot=-1}
    owner:=core.create(&world.entities)
    core.add(&world.terrains,owner,terrain.Terrain{source=stroke.id,revision=1})
    // What the runtime shows: the column x=3 beside a node east of it, whose side is coarse.
    shown:=make([]terrain.Chunk_Lod,total,context.temp_allocator)
    for index in 0..<total {
        coord:=terrain.chunk_coord(s,index)
        if coord.x==3 {shown[index].sides[1]=terrain.COARSE_LEVEL}
        e:=core.create(&world.entities)
        core.add(&world.chunks,e,terrain.Terrain_Chunk{owner=owner,coord=coord,revision=1,lod=shown[index]})
    }
    test_world_settle(&world)
    preview_of :: proc(stroke:^Stroke,coord:[3]i32) -> (Preview,bool) {
        at:=preview_find(stroke,coord)
        if at<0 {return {},false}
        return stroke.previews[at],true
    }
    raise:=terrain.source_edit(s,{kind=.Raise,center={11,0,3},radius=1,amount=0.5})
    if !testing.expect(t,raise.changed) {return}
    stroke_changed(stroke,raise)
    preview_levels(stroke,core.read(&world.terrains),core.read(&world.chunks))
    east,found:=preview_of(stroke,{3,0,2})
    testing.expect(t,found && east.dirty)
    testing.expect_value(t,east.lod,shown[terrain.chunk_index(s,{3,0,2})])
    testing.expect_value(t,len(stroke.previews),1)
    hole:=terrain.source_edit(s,{kind=.Hole,center={3,0,3},radius=1})
    if !testing.expect(t,hole.changed) {return}
    stroke_changed(stroke,hole)
    preview_levels(stroke,core.read(&world.terrains),core.read(&world.chunks))
    middle,has_middle:=preview_of(stroke,{2,0,2})
    testing.expect(t,has_middle)
    testing.expect_value(t,middle.lod,terrain.Chunk_Lod{})
    _,has_north:=preview_of(stroke,{2,0,1})
    _,has_west:=preview_of(stroke,{1,0,2})
    testing.expect(t,!has_north && !has_west)
    testing.expect_value(t,len(stroke.previews),2)
}
