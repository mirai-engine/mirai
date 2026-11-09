package render

import "core:testing"
import "mirai:core"
import mm "mirai:std/math"

// A world the renderer left for another is the one it knew when it draws it
// again, unless another scene took its place meanwhile.
@(test)
a_world_drawn_again_says_whether_another_scene_took_its_place :: proc(t:^testing.T) {
    es:core.Entities
    core.entities_init(&es)
    defer core.entities_destroy(&es)
    edited,played:core.Table(core.World_Transform)
    defer core.table_destroy(&edited)
    defer core.table_destroy(&played)
    place :: proc(table:^core.Table(core.World_Transform),es:^core.Entities) {
        core.add(table,core.create(es),core.World_Transform{mm.TRANSFORM_IDENTITY,mm.TRANSFORM_IDENTITY})
        core.table_settle(table,es)
    }
    // What render_sync does of it with the world of a frame.
    draw :: proc(sync:^Render_Sync,id:core.World_Id,table:^core.Table(core.World_Transform)) -> bool {
        replaced:=(!sync.synced || sync.world!=id) && world_shown(sync,id,core.read(table))
        core.changes(core.read(table),&sync.seen_worlds)
        sync.world,sync.synced=id,true
        return replaced
    }
    place(&edited,&es)
    place(&played,&es)
    sync:Render_Sync
    edit,play:=core.World_Id{1,1},core.World_Id{2,1}
    testing.expect(t,!draw(&sync,edit,&edited),"a world drawn for the first time was not left")
    testing.expect(t,!draw(&sync,play,&played))
    testing.expect(t,!draw(&sync,edit,&edited),"left as it was, it is the one known")
    testing.expect(t,!draw(&sync,play,&played))
    core.table_clear(&edited)
    place(&edited,&es)
    testing.expect(t,draw(&sync,edit,&edited),"another scene took its place while the other was drawn")
    testing.expect(t,!draw(&sync,play,&played))
    testing.expect(t,!draw(&sync,edit,&edited),"and once drawn it is the one known")
}

@(test)
an_entity_is_drawn_between_its_last_two_ticks_at_the_alpha_of_the_frame :: proc(t:^testing.T) {
    previous,current:=mm.TRANSFORM_IDENTITY,mm.TRANSFORM_IDENTITY
    current.position={2,0,0}
    world:=core.World_Transform{current,previous}
    testing.expect_value(t,drawn_transform(world,core.FRAME_TIME_DEFAULT),current)
    testing.expect_value(t,drawn_transform(world,{alpha=1}),current)
    testing.expect_value(t,drawn_transform(world,{alpha=0.5}).position,[3]f32{1,0,0})
    testing.expect_value(t,drawn_transform(world,{alpha=0}).position,previous.position)
}
