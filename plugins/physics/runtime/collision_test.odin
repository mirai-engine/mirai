package physics

import "base:runtime"
import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:std/base"
import "mirai:std/serial"
import sim "plugins:physics/runtime/sim"

@(private="file") TEST_WORLD :: Collision_Category(1)
@(private="file") TEST_PLAYER :: Collision_Category(2)
@(private="file") TEST_PROJECTILE :: Collision_Category(3)
@(private="file") TEST_GHOST :: Collision_Category(4)
@(private="file") TEST_WALL :: Collision_Preset(2)
@(private="file") TEST_GHOST_PRESET :: Collision_Preset(3)

// A wall of the world that collides with everything, and a ghost that crosses
// the world and meets players and projectiles.
@(private="file")
collision_test_settings :: proc() -> Collision_Settings {
    settings:=COLLISION_SETTINGS_DEFAULT
    collision_preset_setting_set(&settings,{preset=TEST_WALL,belongs=collision_layers(TEST_WORLD),collides=COLLISION_LAYERS_ALL})
    collision_preset_setting_set(&settings,{preset=TEST_GHOST_PRESET,belongs=collision_layers(TEST_GHOST),collides=collision_layers(TEST_PLAYER,TEST_PROJECTILE)})
    return settings
}

// The names of the test, as the generator gives them to a World; the ghost preset is not declared.
@(private="file")
collision_test_names :: proc() -> (names:[8]core.Name_Info,types:[2]core.Named_Type_Info,bits:[1]core.Name_Bits_Info) {
    names={
        {type=Collision_Category,value=0,name="default"},{type=Collision_Category,value=1,name="world"},
        {type=Collision_Category,value=2,name="player"},{type=Collision_Category,value=3,name="projectile"},
        {type=Collision_Category,value=4,name="ghost"},
        {type=Collision_Preset,value=0,name="default"},{type=Collision_Preset,value=1,name="trigger"},
        {type=Collision_Preset,value=255,name="custom"},
    }
    types={{type=Collision_Category,name="Collision_Category",prefix="CATEGORY_",limit=32},{type=Collision_Preset,name="Collision_Preset",prefix="PRESET_",limit=256}}
    bits={{type=Collision_Layers,of=Collision_Category}}
    return
}

@(test)
presets_and_custom_colliders_meet_when_each_collides_with_the_other_without_allocations :: proc(t:^testing.T) {
    settings:=collision_test_settings()
    saved:=context
    context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    door:=collision_filter(&settings,COLLIDER_DEFAULT)
    wall:=collision_filter(&settings,{preset=TEST_WALL})
    trigger:=collision_filter(&settings,{preset=PRESET_TRIGGER})
    ghost:=collision_filter(&settings,{preset=TEST_GHOST_PRESET})
    projectile:=COLLIDER_DEFAULT
    collision_custom(&projectile,collision_layers(TEST_PROJECTILE),COLLISION_LAYERS_ALL&~collision_layers(TEST_PROJECTILE))
    shot:=collision_filter(&settings,projectile)
    seen:=query_hits(collision_layers(TEST_WORLD))
    everything,sensed:=query_hits(COLLISION_LAYERS_ALL),query_hits(COLLISION_LAYERS_ALL,overlaps=true)
    off:=collision_filter(&settings,collision_off(&settings,{preset=TEST_WALL}))
    context=saved
    // A new collider belongs to the Default category and blocks everything.
    testing.expect_value(t,door,Collision_Filter{layers=1,block=COLLISION_LAYERS_ALL})
    testing.expect_value(t,wall,Collision_Filter{layers=0b10,block=COLLISION_LAYERS_ALL})
    testing.expect_value(t,trigger,Collision_Filter{layers=1,overlap=COLLISION_LAYERS_ALL})
    testing.expect_value(t,ghost,Collision_Filter{layers=0b10000,block=0b1100})
    testing.expect(t,projectile.preset==PRESET_CUSTOM)
    testing.expect_value(t,sim.filter_response(wall,door),sim.Response.Block)
    testing.expect_value(t,sim.filter_response(ghost,wall),sim.Response.Ignore)
    testing.expect_value(t,sim.filter_response(ghost,shot),sim.Response.Block)
    testing.expect_value(t,sim.filter_response(shot,shot),sim.Response.Ignore)
    testing.expect_value(t,sim.filter_response(trigger,door),sim.Response.Overlap)
    testing.expect_value(t,sim.filter_response(trigger,ghost),sim.Response.Ignore)
    testing.expect_value(t,query_meets(seen,wall),sim.Response.Block)
    testing.expect_value(t,query_meets(seen,door),sim.Response.Ignore)
    testing.expect_value(t,query_meets(everything,trigger),sim.Response.Ignore)
    testing.expect_value(t,query_meets(sensed,trigger),sim.Response.Overlap)
    testing.expect_value(t,query_meets(everything,off),sim.Response.Ignore)
    testing.expect_value(t,off.layers,Collision_Layers(0b10))
    grouped:=COLLIDER_DEFAULT
    grouped.group=core.Entity(7)
    held:=collision_filter(&settings,grouped)
    testing.expect_value(t,held.group,u64(7))
    testing.expect_value(t,sim.filter_response(held,held),sim.Response.Ignore)
}

@(test)
collision_settings_reject_repeated_presets_custom_entries_and_bad_pushes :: proc(t:^testing.T) {
    settings:=collision_test_settings()
    testing.expect(t,collision_settings_valid(&settings))
    // A preset without a setting is the Default category colliding with everything.
    testing.expect_value(t,collision_filter(&settings,{preset=Collision_Preset(9)}),Collision_Filter{layers=1,block=COLLISION_LAYERS_ALL})
    broken:=settings
    broken.presets[5]={preset=TEST_WALL,belongs=1}
    testing.expect(t,!collision_settings_valid(&broken))
    broken=settings
    broken.presets[5]={preset=PRESET_CUSTOM,belongs=1}
    testing.expect(t,!collision_settings_valid(&broken))
    testing.expect_value(t,collision_preset_setting_set(&broken,{preset=PRESET_CUSTOM}),Collision_Error.Unknown_Preset)
    broken=settings
    broken.pushes[0]={TEST_PLAYER,Collision_Category(40),10}
    testing.expect(t,!collision_settings_valid(&broken))
    testing.expect_value(t,collision_push_set(&settings,TEST_PLAYER,TEST_PLAYER,-1),Collision_Error.Invalid_Force)
    testing.expect_value(t,collision_push_set(&settings,TEST_PLAYER,TEST_PLAYER,300),Collision_Error.None)
    testing.expect_value(t,collision_push(&settings,TEST_PLAYER,TEST_PLAYER),f32(300))
    // Writing the defaults of a preset leaves no entry for it.
    cleared:=settings
    testing.expect_value(t,collision_preset_setting_set(&cleared,{preset=TEST_WALL,belongs=1,collides=COLLISION_LAYERS_ALL}),Collision_Error.None)
    testing.expect_value(t,cleared.presets[1],Collision_Preset_Setting{})
    testing.expect_value(t,collision_layers(TEST_WORLD,TEST_GHOST,Collision_Category(40)),Collision_Layers(0b10010))
    defaults:=collision_filter(nil,COLLIDER_DEFAULT)
    testing.expect_value(t,defaults,Collision_Filter{layers=1,block=COLLISION_LAYERS_ALL})
}

// The settings, a Collider and a Query_Filter speak in text by the names the
// code declares, and keep the numbers.
@(test)
categories_and_presets_take_the_names_the_code_declares_in_text :: proc(t:^testing.T) {
    names,types,bits:=collision_test_names()
    tables:=[1]core.Table_Info{{name="Collider",type=Collider,info=type_info_of(Collider)}}
    info:=core.World_Info{tables=tables[:],names=names[:],named_types=types[:],name_bits=bits[:]}
    ws:=core.world_schema_make(&info,context.temp_allocator)
    if !testing.expect(t,ws!=nil) {return}
    defer core.world_schema_destroy(ws)
    type,ok:=serial.schema_add_type_info(&ws.schema,type_info_of(Collision_Settings))
    filter_type,filter_ok:=serial.schema_add_type_info(&ws.schema,type_info_of(Query_Filter))
    if !testing.expect(t,ok && filter_ok) {return}
    settings:Collision_Settings
    r:serial.Text_Reader
    serial.text_reader_init(&r,`{"presets":[{"preset":"trigger","sensor":true,"belongs":["default"],"collides":["player"]},{"preset":2,"belongs":["world"],"collides":["player","ghost"]}],"pushes":[{"a":"player","b":"player","force":300}]}`,context.temp_allocator)
    if !testing.expectf(t,serial.text_read(&r,&ws.schema,type,([^]u8)(&settings)[:size_of(settings)]),"%v",r.error) {return}
    testing.expect_value(t,settings.presets[0],Collision_Preset_Setting{preset=PRESET_TRIGGER,sensor=true,belongs=1,collides=0b100})
    testing.expect_value(t,settings.presets[1],Collision_Preset_Setting{preset=TEST_WALL,belongs=0b10,collides=0b10100})
    testing.expect_value(t,collision_push(&settings,TEST_PLAYER,TEST_PLAYER),f32(300))
    w:serial.Writer;serial.writer_init(&w,allocator=context.temp_allocator)
    serial.text_write(&w,&ws.schema,type,([^]u8)(&settings)[:size_of(settings)],.Line)
    text:=string(serial.writer_bytes(&w))
    testing.expectf(t,strings.contains(text,`"preset": "trigger"`) && strings.contains(text,`"preset": 2, "sensor": false, "belongs": ["world"], "collides": ["player", "ghost"]`) && strings.contains(text,`"a": "player", "b": "player"`),"%s",text)
    // A mask names its bits: the categories a query hits.
    hits:=query_hits(collision_layers(TEST_PLAYER,TEST_WORLD))
    serial.writer_reset(&w)
    serial.text_write(&w,&ws.schema,filter_type,([^]u8)(&hits)[:size_of(hits)],.Line)
    text=string(serial.writer_bytes(&w))
    testing.expectf(t,strings.contains(text,`"block": ["world", "player"]`),"%s",text)
    collider:Collider
    serial.text_reader_init(&r,`{"preset":"custom","belongs":["projectile"],"collides":["world"]}`,context.temp_allocator)
    testing.expect(t,serial.text_read(&r,&ws.schema,ws.tables[0].type,([^]u8)(&collider)[:size_of(collider)]))
    testing.expect(t,collider.preset==PRESET_CUSTOM && collider.belongs==0b1000 && collider.collides==0b10)
    testing.expect(t,collision_name(&info,Collision_Preset,i64(TEST_WALL))=="2" && collision_name(&info,Collision_Category,1)=="world")
}

// A setting for a value no code declares, and a collider of one, are problems
// that say how to fix them; its number still works.
@(test)
a_setting_or_a_collider_of_an_undeclared_value_is_a_problem :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    names,types,bits:=collision_test_names()
    info:=core.World_Info{names=names[:],named_types=types[:],name_bits=bits[:]}
    f.app.info=&info
    f.collision=collision_test_settings()
    at:=0
    field,_,value,found:=collision_settings_undeclared(&f.collision,&info,&at)
    testing.expect(t,found && field=="presets" && value==i64(TEST_WALL))
    field,_,value,found=collision_settings_undeclared(&f.collision,&info,&at)
    testing.expect(t,found && field=="presets" && value==i64(TEST_GHOST_PRESET))
    _,_,_,found=collision_settings_undeclared(&f.collision,&info,&at)
    testing.expect(t,!found)
    e:=core.create(&f.entities)
    core.add(&f.transforms,e,core.Transform{{0,0,0},1,{1,1,1}})
    collider:=collider_box({1,1,1})
    collider.preset=Collision_Preset(12)
    core.add(&f.colliders,e,collider)
    physics_test_step(&f,0)
    settings_problem,collider_problem:=false,false
    for &p in f.problems.entries[:f.problems.count] {
        text:=base.text_get(p.text[:])
        if base.text_get(p.code[:])=="physics.collision_settings" {settings_problem=p.entity==core.NONE && strings.contains(text,"which no code declares") && strings.contains(text,"2 entries")}
        if base.text_get(p.code[:])=="physics.collision" {collider_problem=p.entity==e && strings.contains(text,"preset 12")}
    }
    testing.expect(t,settings_problem && collider_problem)
    testing.expect_value(t,link_find(&f.state,e).filter,Collision_Filter{layers=1,block=COLLISION_LAYERS_ALL})
}

@(test)
a_wall_blocks_the_player_reports_a_sensor_and_a_new_collision_keeps_the_shape :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    f.collision=collision_test_settings()
    wall:=core.create(&f.entities)
    core.add(&f.transforms,wall,core.Transform{{0,0,0},1,{1,1,1}})
    wall_collider:=collider_box({0.25,2,2})
    wall_collider.preset=TEST_WALL
    core.add(&f.colliders,wall,wall_collider)
    movers:[2]core.Entity
    for category,i in ([2]Collision_Category{TEST_PLAYER,TEST_PROJECTILE}) {
        movers[i]=core.create(&f.entities)
        core.add(&f.transforms,movers[i],core.Transform{{-2,f32(i)*2-1,0},1,{1,1,1}})
        collider:=collider_sphere(0.25)
        collision_custom(&collider,collision_layers(category),COLLISION_LAYERS_ALL,sensor=category==TEST_PROJECTILE)
        core.add(&f.colliders,movers[i],collider)
        core.add(&f.rigids,movers[i],RIGID_BODY_DYNAMIC)
    }
    physics_test_step(&f,0)
    for mover in movers {set_velocity(&f.requests,mover,{3,0,0})}
    entered:=0
    for _ in 0..<80 {
        physics_test_step(&f)
        for event in f.events.overlap_begin.items {
            testing.expect(t,event.entity==wall && event.other==movers[1] || event.entity==movers[1] && event.other==wall)
            testing.expect(t,event.collider==event.entity)
            entered+=1
        }
    }
    testing.expect_value(t,entered,2)
    testing.expect(t,physics_test_pose(&f,movers[0]).position.x<-0.4)
    testing.expect(t,physics_test_pose(&f,movers[1]).position.x>1)
    created:=f.state.stats.shapes_created
    teleport(&f.requests,movers[1],{-2,1,0})
    core.get(&f.colliders,movers[1]).sensor=false
    physics_test_step(&f)
    set_velocity(&f.requests,movers[1],{3,0,0})
    for _ in 0..<60 {physics_test_step(&f)}
    testing.expect_value(t,f.state.stats.shapes_created,created)
    testing.expect(t,physics_test_pose(&f,movers[1]).position.x<-0.4)
    // The wall stops colliding with players: both cross it.
    collision_preset_setting_set(&f.collision,{preset=TEST_WALL,belongs=collision_layers(TEST_WORLD),collides=COLLISION_LAYERS_ALL&~collision_layers(TEST_PLAYER,TEST_PROJECTILE)})
    for i in 0..<2 {teleport(&f.requests,movers[i],{-2,f32(i)*2-1,0})}
    physics_test_step(&f)
    for mover in movers {set_velocity(&f.requests,mover,{3,0,0})}
    for _ in 0..<80 {physics_test_step(&f)}
    testing.expect_value(t,f.state.stats.shapes_created,created)
    testing.expect(t,physics_test_pose(&f,movers[0]).position.x>1)
    testing.expect_value(t,f.problems.count,0)
}

@(test)
a_character_takes_its_capsule_and_its_collision_from_its_collider :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    f.collision=collision_test_settings()
    e:=core.create(&f.entities)
    core.add(&f.transforms,e,core.Transform{{0,1,0},1,{1,1,1}})
    capsule:=collider_character(0.4,1.6)
    collision_custom(&capsule,collision_layers(TEST_PLAYER),COLLISION_LAYERS_ALL&~collision_layers(TEST_PROJECTILE))
    core.add(&f.colliders,e,capsule)
    config:=character_default()
    config.mass=0
    core.add(&f.characters,e,config)
    physics_test_step(&f,0)
    l:=link_find(&f.state,e)
    testing.expect(t,l!=nil && l.kind==.Character)
    desc:=sim.character_desc(&f.state.world,l.character)
    testing.expect(t,abs(desc.radius-0.4)<1e-5 && abs(desc.height-1.6)<1e-5)
    testing.expect_value(t,desc.filter,collision_filter(&f.collision,capsule))
    testing.expect(t,desc.mass>100 && desc.mass<1000)
    created:=f.state.stats.characters_created
    core.get(&f.colliders,e).collides=COLLISION_LAYERS_ALL
    // The locomotion writes the rest of the row every tick; that does not make it again.
    core.get(&f.characters,e).coyote=0.05
    physics_test_step(&f,0)
    testing.expect_value(t,f.state.stats.characters_created,created)
    current,_:=core.get(core.read(&f.colliders),e)
    testing.expect_value(t,sim.character_desc(&f.state.world,link_find(&f.state,e).character).filter,collision_filter(&f.collision,current))
    core.get(&f.colliders,e).size.x=0.3
    physics_test_step(&f,0)
    testing.expect_value(t,f.state.stats.characters_created,created+1)
}

@(test)
contact_rules_of_a_collider_reach_its_shape_without_making_it_again :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    f.gravity={0,-9.81,0}
    belt:=core.create(&f.entities)
    core.add(&f.transforms,belt,core.Transform{{0,-0.5,0},1,{1,1,1}})
    floor:=collider_box({10,0.5,10})
    floor.surface_speed={2,0,0}
    core.add(&f.colliders,belt,floor)
    box:=physics_test_box(&f,{0,0.25,0},{0.25,0.25,0.25},RIGID_BODY_DYNAMIC)
    walker:=core.create(&f.entities)
    core.add(&f.transforms,walker,core.Transform{{4,0,4},1,{1,1,1}})
    capsule:=collider_character()
    capsule.dominance=3
    core.add(&f.colliders,walker,capsule)
    core.add(&f.characters,walker,character_default())
    physics_test_step(&f,0)
    w:=&f.state.world
    _,_,dominance:=sim.shape_surface(w,sim.character_shape(w,link_find(&f.state,walker).character))
    testing.expect_value(t,dominance,i8(3))
    for _ in 0..<90 {physics_test_step(&f)}
    v:=sim.body_linear_velocity(w,link_find(&f.state,box).body)
    testing.expectf(t,abs(v.x-2)<0.05,"carried at %v",v)
    created:=f.state.stats.shapes_created
    core.get(&f.colliders,belt).surface_speed={}
    core.get(&f.colliders,belt).one_way=true
    for _ in 0..<60 {physics_test_step(&f)}
    testing.expect_value(t,f.state.stats.shapes_created,created)
    speed,one_way,_:=sim.shape_surface(w,link_find(&f.state,belt).shape)
    testing.expect(t,speed=={} && one_way)
    v=sim.body_linear_velocity(w,link_find(&f.state,box).body)
    testing.expectf(t,abs(v.x)<0.05,"stopped at %v",v)
    // The floor blocks from its +Y side: the box still rests on it.
    testing.expect(t,abs(physics_test_pose(&f,box).position.y-0.25)<0.03)
}
