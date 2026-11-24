package abilities_editor

import "core:math"
import "core:mem"
import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:editor"
import erender "mirai:engine/render"
import "mirai:std/base"
import mm "mirai:std/math"
import ab "plugins:abilities/runtime"

@(private)
@(test_world)
Abilities_Editor_World :: struct {
    using world:Test_World,
    users:core.Table(ab.Ability_User),
    states:core.Table(ab.Ability_State),
    tracking:core.Table(ab.Ability_Tracking),
    worlds:core.Table(core.World_Transform),
    names:core.Table(core.Name),
    time:core.Time,
}

@(private="file") ABILITY_TABLE :: base.Asset_Id{1,1}
@(private="file") HITBOX_TABLE :: base.Asset_Id{3,3}

// What blocks an ability names what fails: the status, the attribute with its value against what
// the condition or the cost needs, or the cooldown left.
@(test)
a_blocked_ability_says_which_status_attribute_or_cooldown_and_by_how_much :: proc(t:^testing.T) {
    info,described:=test_info(t,Abilities_Editor_World)
    if !described {return}
    defer test_info_destroy(&info)
    session:=editor.Session{info=&info}
    user:ab.Ability_User
    user.attributes[0]={attribute=2,base=0,max=3}
    user.attributes[1]={attribute=3,base=2,max=200}
    state:=ab.Ability_State{values={0=0,1=2}}
    track:ab.Ability_Tracking
    track.cooldowns[1]={until=130}
    a:ab.Ability
    a.conditions[0]={attribute=2,at_least=1}
    a.conditions[1]={attribute=3,at_least=1,at_most=10}
    a.costs[1]={attribute=3,amount=5}
    Case :: struct {block:ab.Ability_Block,index:int,says:string}
    cases:=[]Case{
        {.Status_Missing,2,"requires the status 2"},
        {.Status_Blocked,5,"in the status 5, which blocks it"},
        {.Condition,0,"condition 0: 2 is 0 and has to be at least 1"},
        {.Condition,1,"condition 1: 3 is 2 and has to be from 1 to 10"},
        {.Cost,1,"cost 1: 3 is 2, less than the 5 it costs"},
        {.Cooldown,1,"its cooldown runs for 0.5 s more"},
    }
    for c in cases {
        text:=block_text(&session,c.block,c.index,&a,&user,&state,&track,100,1.0/60)
        testing.expectf(t,strings.contains(text,c.says),"%v at %d says %q, not %q",c.block,c.index,text,c.says)
    }
}

// An open hitbox is where its user stands and faces, with what its window hit; the overlay
// hitboxes draws it there, in the color of a hit once it hit something.
@(test)
an_open_hitbox_is_placed_in_the_world_with_what_it_hit_and_drawn_by_the_overlay :: proc(t:^testing.T) {
    info,described:=test_info(t,Abilities_Editor_World)
    if !described {return}
    defer test_info_destroy(&info)
    world:Abilities_Editor_World
    if !testing.expect(t,core.world_init(&info,.World,&world,context.allocator)) {return}
    defer core.world_destroy(&info,.World,&world)
    w:=core.world_ref(&world,&info)
    hitboxes:=[1]ab.Ability_Hitbox{{shape=.Box,center={0,1,-1.5},size={1,0.5,1}}}
    sheets:=[1]ab.Ability{}
    sheets[0].windows[0]={from=0,to=1,hitbox={HITBOX_TABLE,1}}
    sheets[0].windows[1]={from=0.5,to=1,hitbox={HITBOX_TABLE,1}}
    index:=[1]u32{0}
    sheet_rows:=[1]core.Record_Row{{table=ABILITY_TABLE,row=1}}
    hitbox_rows:=[1]core.Record_Row{{table=HITBOX_TABLE,row=1}}
    sheet_set:=core.Record_Set{size=size_of(ab.Ability),rows=sheet_rows[:],index=index[:],values=mem.slice_to_bytes(sheets[:])}
    hitbox_set:=core.Record_Set{size=size_of(ab.Ability_Hitbox),rows=hitbox_rows[:],index=index[:],values=mem.slice_to_bytes(hitboxes[:])}
    data:=ab.Ability_Data{abilities={&sheet_set},hitboxes={&hitbox_set}}
    player,dummy,other:=core.create(&world.entities),core.create(&world.entities),core.create(&world.entities)
    core.add(&world.names,dummy,core.name_make("Dummy"))
    turned:=mm.quat_axis_angle({0,1,0},math.PI/2)
    core.add(&world.worlds,player,core.World_Transform{transform={position={2,0,0},rotation=turned,scale={1,1,1}}})
    core.add(&world.users,player,ab.Ability_User{})
    core.add(&world.states,player,ab.Ability_State{ability={ABILITY_TABLE,1},start=0})
    track:ab.Ability_Tracking
    track.targets[0],track.windows[0]=dummy,0
    track.targets[1],track.windows[1]=other,1
    track.hit_count=2
    core.add(&world.tracking,player,track)
    world.time={tick=10,dt=1.0/60}
    core.settle(&info,&world,nil)
    // Turned a quarter about Y, forward (-Z) is -X: 1.5 m ahead of the user and 1 m up.
    r:=window_hitbox(w,player,&track,&hitboxes[0],0)
    testing.expectf(t,linalg_near(r.center,{0.5,1,0}) && r.rotation==turned && r.size==[3]f32{1,0.5,1} && r.shape==.Box,"placed at %v",r)
    testing.expectf(t,len(r.targets)==1 && r.targets[0]=="Dummy","window 0 hit only Dummy: %v",r.targets)
    // Only window 0 is open at tick 10: one box, of a hit.
    testing.expect_value(t,HITBOXES_CAPTURE_DEFAULT.provider.name,"hitboxes")
    storage:[256]erender.Debug_Vertex
    lines:=erender.debug_lines_make(storage[:],depth_test=false)
    hitboxes_draw(&lines,w,data)
    hit,open:=0,0
    for vertex in storage[:lines.count] {
        switch vertex.color {
        case mm.rgba8_pack(HITBOXES_CAPTURE_HIT):  hit+=1
        case mm.rgba8_pack(HITBOXES_CAPTURE_OPEN): open+=1
        }
    }
    testing.expectf(t,hit==24 && open==0,"the edges of one box of a hit: %d of hits, %d open",hit,open)
    // Without hits the same box is open.
    track.hit_count=0
    core.edit(&world.tracking,player).hit_count=0
    erender.debug_lines_clear(&lines)
    hitboxes_draw(&lines,w,data)
    testing.expect_value(t,lines.count,24)
    testing.expect_value(t,storage[0].color,mm.rgba8_pack(HITBOXES_CAPTURE_OPEN))

    // Clip-span-bound window hitbox draws only while its bit in state.span_open is set.
    sheets[0].windows[0]={}
    sheets[0].windows[1]={hitbox={HITBOX_TABLE,1}}
    base.text_set(sheets[0].windows[1].span[:],"swing")
    erender.debug_lines_clear(&lines)
    hitboxes_draw(&lines,w,data)
    testing.expect_value(t,lines.count,0)
    core.edit(&world.states,player).span_open=u16(1)<<1
    core.settle(&info,&world,nil)
    erender.debug_lines_clear(&lines)
    hitboxes_draw(&lines,w,data)
    testing.expect_value(t,lines.count,24)
}

@(private="file")
linalg_near :: proc(a,b:[3]f32) -> bool {return abs(a.x-b.x)<1e-4 && abs(a.y-b.y)<1e-4 && abs(a.z-b.z)<1e-4}
