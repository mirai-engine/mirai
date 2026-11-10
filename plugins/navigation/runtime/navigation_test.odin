package navigation

import "core:fmt"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import input "mirai:engine/input"
import scene "mirai:engine/scene"
import render "mirai:engine/render"
import "mirai:host"
import "mirai:std/ai"
import "mirai:std/base"
import "mirai:std/jobs"
import mm "mirai:std/math"
import phys "plugins:physics/runtime"

// A world with physics and navigation, stepped by hand: the static
// collision the tests make, the meshes built from it.
@(private)
Nav_Test :: struct {
    entities:core.Entities,
    rigids:core.Table(phys.Rigid_Body),
    colliders:core.Table(phys.Collider),
    characters:core.Table(phys.Character),
    moves:core.Table(phys.Character_Move),
    joints:core.Table(phys.Joint),
    statics:core.Table(render.Mesh_Renderer),
    parents:core.Table(core.Parent),
    names:core.Table(core.Name),
    transforms:core.Table(core.Transform),
    motions:core.Table(core.Motion),
    replicas:core.Table(core.Pose_Target),
    character_states:core.Table(phys.Character_State),
    joint_states:core.Table(phys.Joint_State),
    volumes:core.Table(phys.Fluid_Volume),
    bounds:core.Table(Nav_Bounds),
    areas:core.Table(Nav_Area),
    links:core.Table(Nav_Link),
    obstacles:core.Table(Nav_Obstacle),
    references:core.Table(scene.Scene_Reference),
    worlds:core.Table(core.World_Transform),
    ids:core.Table(core.Id),
    disabled:core.Table(core.Disabled),
    hierarchy:core.Hierarchy,
    places:core.Places,
    jumps:core.Jumps,
    state:phys.Physics_State,
    physics_settings:phys.Physics_Settings,
    collision:phys.Collision_Settings,
    sync_check:core.Sync_Check,
    simulation_hash:core.Simulation_Hash,
    requests:phys.Body_Requests,
    joint_requests:phys.Joint_Requests,
    events:phys.Physics_Events,
    meshes:phys.Collider_Meshes,
    nav:Navigation,
    builds:Navigation_Builds,
    build_requests:Nav_Build_Requests,
    settings:Navigation_Settings,
    bakes:core.Table(Navigation_Bake),
    unloaded:Nav_Unloaded,
    time:core.Time, // of the build
    app:host.App,
    problems:core.Problems,
}

@(private)
nav_test_init :: proc(f:^Nav_Test) {
    core.entities_init(&f.entities)
    core.table_init(&f.rigids,"Rigid_Body")
    core.table_init(&f.colliders,"Collider")
    core.table_init(&f.characters,"Character")
    core.table_init(&f.moves,"Character_Move")
    core.table_init(&f.joints,"Joint")
    core.table_init(&f.statics,"Mesh_Renderer")
    core.table_init(&f.parents,"Parent")
    core.table_init(&f.names,"Name")
    core.table_init(&f.transforms,"Transform")
    core.table_init(&f.motions,"Motion")
    core.table_init(&f.replicas,"Replica")
    core.table_init(&f.character_states,"Character_State")
    core.table_init(&f.joint_states,"Joint_State")
    core.table_init(&f.volumes,"Fluid_Volume")
    core.table_init(&f.bounds,"Nav_Bounds")
    core.table_init(&f.areas,"Nav_Area")
    core.table_init(&f.links,"Nav_Link")
    core.table_init(&f.obstacles,"Nav_Obstacle")
    core.table_init(&f.references,"Scene_Reference")
    core.table_init(&f.worlds,"World_Transform")
    core.table_init(&f.ids,"Id")
    core.table_init(&f.disabled,"Disabled")
    core.table_init(&f.bakes,"Navigation_Bake")
    f.transforms.base,f.worlds.base,f.parents.base,f.names.base,f.ids.base,f.disabled.base=true,true,true,true,true,true
    f.physics_settings={bodies=64,shapes=64,contacts=256,joints=4,characters=8}
    f.collision=phys.COLLISION_SETTINGS_DEFAULT
    f.settings=NAVIGATION_SETTINGS_DEFAULT
    f.settings.tile_cells=48
    jobs.system_init(&f.app.jobs,{threads=0})
}

@(private)
nav_test_destroy :: proc(f:^Nav_Test) {
    builds_free(&f.builds)
    navigation_free(&f.nav)
    nav_unloaded_free(&f.unloaded)
    delete(f.build_requests.queue.items)
    phys.state_destroy(&f.state)
    phys.collider_meshes_destroy(&f.meshes)
    core.table_destroy(&f.rigids)
    core.table_destroy(&f.colliders)
    core.table_destroy(&f.characters)
    core.table_destroy(&f.moves)
    core.table_destroy(&f.joints)
    core.table_destroy(&f.statics)
    core.table_destroy(&f.parents)
    core.table_destroy(&f.names)
    core.table_destroy(&f.transforms)
    core.table_destroy(&f.motions)
    core.table_destroy(&f.replicas)
    core.table_destroy(&f.character_states)
    core.table_destroy(&f.joint_states)
    core.table_destroy(&f.volumes)
    core.table_destroy(&f.bounds)
    core.table_destroy(&f.areas)
    core.table_destroy(&f.links)
    core.table_destroy(&f.obstacles)
    core.table_destroy(&f.references)
    core.table_destroy(&f.worlds)
    core.table_destroy(&f.ids)
    core.table_destroy(&f.disabled)
    core.table_destroy(&f.bakes)
    core.value_free(&f.hierarchy,type_info_of(core.Hierarchy))
    delete(f.places.queue.items);delete(f.jumps.queue.items)
    core.entities_destroy(&f.entities)
    delete(f.requests.queue.items)
    delete(f.joint_requests.queue.items)
    delete(f.events.contact_begin.items);delete(f.events.contact_end.items)
    delete(f.events.overlap_begin.items);delete(f.events.overlap_end.items)
    delete(f.events.sleep.items);delete(f.events.wake.items);delete(f.events.joint_break.items)
    jobs.system_destroy(&f.app.jobs)
}

// What the generated settle does: Disabled and the hierarchy first, then every table.
@(private)
nav_test_settle :: proc(f:^Nav_Test,g:^Agents_Test=nil) {
    core.table_settle(&f.disabled,&f.entities)
    core.table_settle(&f.parents,&f.entities)
    core.hierarchy_settle(&f.hierarchy,core.read(&f.parents),&f.entities)
    core.entities_activity(&f.entities,core.read(&f.disabled),core.ref(&f.hierarchy))
    core.table_settle(&f.ids,&f.entities)
    core.table_settle(&f.rigids,&f.entities)
    core.table_settle(&f.colliders,&f.entities)
    core.table_settle(&f.characters,&f.entities)
    core.table_settle(&f.moves,&f.entities)
    core.table_settle(&f.joints,&f.entities)
    core.table_settle(&f.statics,&f.entities)
    core.table_settle(&f.parents,&f.entities)
    core.table_settle(&f.names,&f.entities)
    core.table_settle(&f.transforms,&f.entities)
    core.table_settle(&f.motions,&f.entities)
    core.table_settle(&f.replicas,&f.entities)
    core.table_settle(&f.character_states,&f.entities)
    core.table_settle(&f.joint_states,&f.entities)
    core.table_settle(&f.volumes,&f.entities)
    core.table_settle(&f.bounds,&f.entities)
    core.table_settle(&f.areas,&f.entities)
    core.table_settle(&f.links,&f.entities)
    core.table_settle(&f.obstacles,&f.entities)
    core.table_settle(&f.references,&f.entities)
    core.table_settle(&f.worlds,&f.entities)
    core.table_settle(&f.bakes,&f.entities)
    if g!=nil {
        core.table_settle(&g.agents,&f.entities);core.table_settle(&g.paths,&f.entities);core.table_settle(&g.inputs,&f.entities)
        core.table_settle(&g.drivables,&f.entities);core.table_settle(&g.walks,&f.entities);core.table_settle(&g.flights,&f.entities);core.table_settle(&g.swims,&f.entities)
        core.table_settle(&g.worlds,&f.entities);core.table_settle(&g.remotes,&f.entities);core.table_settle(&g.fars,&f.entities);core.table_settle(&g.roamings,&f.entities)
    }
    core.entities_settle(&f.entities)
}

// One tick of physics and of the build, then as many more as the builds take.
@(private)
nav_test_step :: proc(f:^Nav_Test,ticks:=1) {
    for _ in 0..<ticks {
        nav_test_settle(f)
        phys.physics_step(
            &f.state,core.ref(&f.physics_settings),&f.requests,&f.events,&f.meshes,&f.app,{dt=0,playing=false},
            core.read(&f.rigids),core.read(&f.colliders),core.read(&f.characters),core.read(&f.moves),
            &f.joints,core.read(&f.statics),core.read(&f.parents),core.read(&f.names),
            &f.transforms,&f.motions,core.read(&f.replicas),&f.character_states,&f.joint_states,core.read(&f.volumes),&f.joint_requests,core.ref(&f.collision),core.ref(&f.sync_check),&f.simulation_hash,nil,&f.problems,{},{},{},{},{},core.ref(&f.hierarchy),
        )
        nav_test_settle(f)
        navigation_build(&f.nav,&f.builds,core.ref(&f.settings),core.read(&f.bakes),core.ref(&f.state),&f.build_requests,core.read(&f.bounds),core.read(&f.areas),core.read(&f.links),core.read(&f.obstacles),f.time,core.read(&f.transforms),core.read(&f.parents),core.ref(&f.unloaded),core.read(&f.references),core.read(&f.worlds),core.read(&f.ids),&f.app,&f.problems)
    }
}

// Steps until no tile waits or builds, and the coarse graph is made; the tallies of the marks
// stay those of a count.
@(private)
nav_test_settled :: proc(t:^testing.T,f:^Nav_Test) {
    for _ in 0..<400 {
        nav_test_step(f)
        waiting:=f.builds.coarse_revision!=f.nav.revision || f.builds.coarse_sections!=f.builds.sections.hash
        for i in 0..<f.nav.count {
            c:=&f.nav.classes[i]
            counted:Class_Mesh
            it:=base.hash_map_iterator(&c.marks)
            for _,mark in base.hash_map_iterate(&it) {
                waiting|=mark.dirty && !mark.unloaded || mark.building || mark.links
                mark_tally(&counted,mark^,1)
            }
            testing.expectf(t,counted.pending==c.pending && counted.ready==c.ready && counted.loading==c.loading && counted.linking==c.linking,"class %d tallies %v %v %v %v, counted %v %v %v %v",i,c.pending,c.ready,c.loading,c.linking,counted.pending,counted.ready,counted.loading,counted.linking)
        }
        if !waiting {return}
        when ODIN_DEBUG {}
    }
    testing.fail_now(t,"the builds did not settle")
}

@(private)
nav_test_box :: proc(f:^Nav_Test,position,half:[3]f32) -> core.Entity {
    e:=core.create(&f.entities)
    core.add(&f.transforms,e,core.Transform{position,1,{1,1,1}})
    core.add(&f.colliders,e,phys.collider_box(half))
    return e
}

@(private)
Test_Corners :: struct {items:[64]ai.Nav_Corner,count:int}

nav_test_path :: proc(t:^testing.T,f:^Nav_Test,from,to:mm.Vec3,can:=ai.NAV_CAN_ALL,avoid:=Nav_Areas{}) -> (corners:Test_Corners,status:ai.Search_Status) {
    mesh:=&f.nav.classes[0].mesh
    filter:=filter_make(&f.settings,avoid,can)
    a,start,ok:=ai.nav_find_nearest(mesh,from,{1,2,1},&filter)
    b,end,ok2:=ai.nav_find_nearest(mesh,to,{1,2,1},&filter)
    if !ok || !ok2 {return {},.Invalid}
    q:ai.Nav_Query
    ai.nav_query_init(&q,4096)
    defer ai.nav_query_destroy(&q)
    refs:[1024]ai.Nav_Ref
    count:int
    partial:bool
    count,status,partial=ai.nav_find_path(&q,mesh,a,b,start,end,&filter,refs[:])
    if partial {status=.No_Path}
    corners.count,_=ai.nav_straight_path(mesh,start,end,refs[:count],corners.items[:])
    return
}

@(private)
corners_length :: proc(corners:[]ai.Nav_Corner) -> (length:f32) {
    for i in 1..<len(corners) {length+=linalg.length(corners[i].position-corners[i-1].position)}
    return
}

@(test)
a_class_is_made_of_the_collision_that_blocks_its_agents :: proc(t:^testing.T) {
    PLAYER,ZOMBIE,CLIP :: phys.Collision_Category(1),phys.Collision_Category(2),phys.Collision_Category(3)
    PRESET_ZOMBIE :: phys.Collision_Preset(2)
    f:Nav_Test
    nav_test_init(&f)
    defer nav_test_destroy(&f)
    nav_test_box(&f,{0,-0.5,0},{10,0.5,10})
    // A clip that blocks zombies alone, across the way.
    wall:=core.create(&f.entities)
    core.add(&f.transforms,wall,core.Transform{{0,1,0},1,{1,1,1}})
    collider:=phys.collider_box({1,1,4})
    phys.collision_custom(&collider,phys.collision_layers(CLIP),phys.collision_layers(ZOMBIE))
    core.add(&f.colliders,wall,collider)
    zombie:=phys.Collision_Preset_Setting{preset=PRESET_ZOMBIE,belongs=phys.collision_layers(ZOMBIE),collides=phys.COLLISION_LAYERS_ALL}
    testing.expect_value(t,phys.collision_preset_setting_set(&f.collision,zombie),phys.Collision_Error.None)
    length :: proc(t:^testing.T,f:^Nav_Test) -> f32 {
        nav_test_settled(t,f)
        path,status:=nav_test_path(t,f,{-5,0,0},{5,0,0})
        testing.expect_value(t,status,ai.Search_Status.Found)
        return corners_length(path.items[:path.count])
    }
    // The Default preset: the clip does not block it.
    testing.expect(t,length(t,&f)<10.5)
    // The zombies' preset: the mesh goes around the clip.
    f.settings.classes[0].collision=PRESET_ZOMBIE
    testing.expect(t,length(t,&f)>11)
    // What the preset is changes in Collision_Settings: the class is made again, through the clip.
    zombie.belongs=phys.collision_layers(PLAYER)
    testing.expect_value(t,phys.collision_preset_setting_set(&f.collision,zombie),phys.Collision_Error.None)
    testing.expect(t,length(t,&f)<10.5)
    // A preset that blocks nothing makes no mesh and says why.
    name:=base.text_get(f.settings.classes[0].name[:])
    f.settings.classes[0].collision=phys.PRESET_TRIGGER
    nav_test_settled(t,&f)
    testing.expect(t,class_find(&f.nav,name)<0,"the class has no mesh")
    testing.expect(t,core.problem_find(&f.problems,core.NONE,"navigation.class")!=nil,"the class says why it has no mesh")
}

@(test)
a_floor_with_a_box_gets_a_mesh_that_goes_around_the_box :: proc(t:^testing.T) {
    f:Nav_Test
    nav_test_init(&f)
    defer nav_test_destroy(&f)
    nav_test_box(&f,{0,-0.5,0},{10,0.5,10})
    nav_test_box(&f,{0,1,0},{1,1,4})
    nav_test_settled(t,&f)
    testing.expect(t,f.nav.ready && f.nav.count==3 && f.nav.stats.built>0)
    testing.expect_value(t,f.problems.count,0)
    corners,status:=nav_test_path(t,&f,{-5,0,0},{5,0,0})
    testing.expect_value(t,status,ai.Search_Status.Found)
    // Around the box: past one of its ends, farther than straight through it.
    length:=corners_length(corners.items[:corners.count])
    testing.expect(t,corners.count>=3 && length>11)
    for c in corners.items[:corners.count] {testing.expect(t,!(abs(c.position.x)<1.2 && abs(c.position.z)<4.2))}
}

@(test)
moving_collision_builds_again_only_the_tiles_it_touches :: proc(t:^testing.T) {
    f:Nav_Test
    nav_test_init(&f)
    defer nav_test_destroy(&f)
    nav_test_box(&f,{0,-0.5,0},{10,0.5,10})
    region:=core.create(&f.entities)
    core.add(&f.transforms,region,core.Transform{{0,0,0},1,{1,1,1}})
    core.add(&f.bounds,region,Nav_Bounds{half={10,4,10}})
    wall:=nav_test_box(&f,{0,1,0},{0.5,1,10})
    nav_test_settled(t,&f)
    _,status:=nav_test_path(t,&f,{-5,0,0},{5,0,0})
    testing.expect_value(t,status,ai.Search_Status.No_Path)
    built:=f.nav.stats.built
    tiles:=0
    for &tile in f.nav.classes[0].mesh.tiles {if tile.used {tiles+=1}}
    // The wall slides away to the side: the way opens.
    core.add(&f.transforms,wall,core.Transform{{0,1,14},1,{1,1,1}})
    nav_test_settled(t,&f)
    _,status=nav_test_path(t,&f,{-5,0,0},{5,0,0})
    testing.expect_value(t,status,ai.Search_Status.Found)
    rebuilt:=f.nav.stats.built+f.nav.stats.emptied-built
    testing.expect(t,rebuilt>0 && rebuilt<u64(tiles))
}

@(test)
tiles_where_the_collision_is_not_loaded_keep_what_they_have_until_it_loads :: proc(t:^testing.T) {
    f:Nav_Test
    nav_test_init(&f)
    defer nav_test_destroy(&f)
    nav_test_box(&f,{0,-0.5,0},{10,0.5,10})
    region:=core.create(&f.entities)
    core.add(&f.transforms,region,core.Transform{{0,0,0},1,{1,1,1}})
    core.add(&f.bounds,region,Nav_Bounds{half={10,4,10}})
    wall:=nav_test_box(&f,{0,1,0},{0.5,1,10})
    nav_test_settled(t,&f)
    _,status:=nav_test_path(t,&f,{-5,0,0},{5,0,0})
    testing.expect_value(t,status,ai.Search_Status.No_Path)
    built:=f.nav.stats.built+f.nav.stats.emptied
    // The wall leaves where a paging library says the collision is not loaded: nothing is built there.
    append(&f.unloaded.boxes,mm.Aabb{{-2,-1,-12},{2,3,12}})
    f.unloaded.revision+=1
    core.destroy(&f.entities,wall)
    nav_test_settled(t,&f)
    _,status=nav_test_path(t,&f,{-5,0,0},{5,0,0})
    testing.expect_value(t,status,ai.Search_Status.No_Path)
    testing.expect_value(t,f.nav.stats.built+f.nav.stats.emptied,built)
    unloaded:=0
    it:=base.hash_map_iterator(&f.nav.classes[0].marks)
    for _,mark in base.hash_map_iterate(&it) {if mark.unloaded {unloaded+=1}}
    testing.expect(t,unloaded>0)
    // It loads: the tiles build from what is there now.
    clear(&f.unloaded.boxes)
    f.unloaded.revision+=1
    nav_test_settled(t,&f)
    _,status=nav_test_path(t,&f,{-5,0,0},{5,0,0})
    testing.expect_value(t,status,ai.Search_Status.Found)
    testing.expect(t,f.nav.stats.built+f.nav.stats.emptied>built)
}

// The order the static collision gives its triangles in depends on how its
// shapes were added: the same triangles are the same input.
@(test)
the_hash_of_triangles_does_not_depend_on_their_order :: proc(t:^testing.T) {
    vertices:=[][3]f32{{0,0,0},{1,0,0},{0,0,1},{5,1,5},{6,1,5},{5,1,6}}
    first:=triangles_hash(vertices,{0,1,2,3,4,5})
    testing.expect_value(t,triangles_hash(vertices,{3,4,5,0,1,2}),first)
    moved:=[][3]f32{{5,1,5},{6,1,5},{5,1,6},{0,0,0},{1,0,0},{0,0,1}}
    testing.expect_value(t,triangles_hash(moved,{0,1,2,3,4,5}),first)
    testing.expect(t,triangles_hash(vertices,{0,1,2})!=first,"other triangles are another input")
}

// In a run, the tiles that read only where the terrain is not loaded go, and
// one that reads across its edge waits and keeps what it has; the edited
// world keeps them all. Loaded again, they come back from the bake of the
// scene with their hashes and the build finds them unchanged.
@(test)
the_tiles_where_the_terrain_is_not_loaded_go_in_a_run_and_come_back_from_the_bake :: proc(t:^testing.T) {
    f:Nav_Test
    nav_test_init(&f)
    defer nav_test_destroy(&f)
    nav_test_box(&f,{0,-0.5,0},{10,0.5,10})
    region:=core.create(&f.entities)
    core.add(&f.transforms,region,core.Transform{{0,0,0},1,{1,1,1}})
    core.add(&f.bounds,region,Nav_Bounds{half={10,4,10}})
    nav_test_settled(t,&f)
    root:=fmt.tprintf("%s/mirai-nav-paging-%d",os.get_env("TEMP",context.temp_allocator),os.get_pid())
    testing.expect_value(t,os.make_directory_all(root),nil)
    defer os.remove_all(root)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    id:=base.Asset_Id{0x6e6176,1}
    bytes,error:=bake_bytes(&f.nav,id,&assets.types,allocator=context.temp_allocator)
    testing.expect_value(t,error,asset.Error.None)
    testing.expect_value(t,asset.registry_memory_set(&assets.registry,"scene.navmesh",bytes),asset.Error.None)
    f.app.assets=&assets
    core.add(&f.bakes,core.create(&f.entities),Navigation_Bake{asset=id})
    nav_test_settled(t,&f)
    testing.expect_value(t,f.problems.count,0)
    mesh:=&f.nav.classes[0].mesh
    marks:=&f.nav.classes[0].marks
    far,near:=ai.nav_mesh_coord(mesh,{-9,0,0}),ai.nav_mesh_coord(mesh,{-4,0,0})
    tile:=ai.nav_mesh_tile_at(mesh,far)
    if !testing.expect(t,far!=near && tile!=nil && ai.nav_mesh_tile_at(mesh,near)!=nil) {return}
    hash:=tile.data.hash
    before,built:=nav_test_tiles(&f.nav),f.nav.stats.built+f.nav.stats.emptied
    // The terrain west of x=0 is not loaded: the edited world keeps its tiles.
    append(&f.unloaded.boxes,mm.Aabb{{-40,-1e4,-40},{0,1e4,40}})
    f.unloaded.revision+=1
    nav_test_settled(t,&f)
    testing.expect_value(t,nav_test_tiles(&f.nav),before)
    testing.expect_value(t,f.nav.stats.dropped,0)
    // In a run, the tiles that read only there go.
    f.time.playing=true
    nav_test_settled(t,&f)
    testing.expect(t,f.nav.stats.dropped>0 && nav_test_tiles(&f.nav)==before-int(f.nav.stats.dropped))
    testing.expect(t,ai.nav_mesh_tile_at(mesh,far)==nil && base.hash_map_ptr(marks,coord_key(far))==nil)
    // Marked, the one that reads across x=0 waits for the terrain and keeps what it has.
    mark_box(&f.nav,{{-4,-1,-1},{-3,1,1}},{f.builds.bounds[:],f.builds.air[:],f.builds.water[:],f.builds.dry[:]})
    nav_test_settled(t,&f)
    waiting:=base.hash_map_ptr(marks,coord_key(near))
    testing.expect(t,ai.nav_mesh_tile_at(mesh,near)!=nil && waiting!=nil && waiting.dirty && waiting.unloaded)
    // Loaded: they come back from the bake as they were, and none is built.
    unchanged:=f.nav.stats.unchanged
    clear(&f.unloaded.boxes)
    f.unloaded.revision+=1
    nav_test_settled(t,&f)
    testing.expect_value(t,nav_test_tiles(&f.nav),before)
    testing.expect_value(t,f.nav.stats.built+f.nav.stats.emptied,built)
    testing.expect(t,f.nav.stats.unchanged>unchanged)
    back:=ai.nav_mesh_tile_at(mesh,far)
    mark:=base.hash_map_ptr(marks,coord_key(far))
    testing.expect(t,back!=nil && back.data.hash==hash && mark!=nil && mark.hash==hash)
    _,status:=nav_test_path(t,&f,{-9,0,0},{9,0,0})
    testing.expect_value(t,status,ai.Search_Status.Found)
    testing.expect_value(t,f.problems.count,0)
}

// A section that streams keeps its tiles while it is not on, as the terrain
// that is not loaded; on again, they build from what it has.
@(test)
the_tiles_of_a_section_that_streams_wait_for_it_to_be_on :: proc(t:^testing.T) {
    f:Nav_Test
    nav_test_init(&f)
    defer nav_test_destroy(&f)
    nav_test_box(&f,{0,-0.5,0},{10,0.5,10})
    region:=core.create(&f.entities)
    core.add(&f.transforms,region,core.Transform{{0,0,0},1,{1,1,1}})
    core.add(&f.bounds,region,Nav_Bounds{half={10,4,10}})
    wall:=nav_test_box(&f,{0,1,0},{0.5,1,10})
    section:=core.create(&f.entities)
    core.add(&f.references,section,scene.Scene_Reference{scene={1,1},extents={2,3,12},rule=.Spatial,state=.Active,loaded={1,1}})
    core.add(&f.worlds,section,core.World_Transform{transform={rotation=1,scale=1}})
    nav_test_settled(t,&f)
    built:=f.nav.stats.built+f.nav.stats.emptied
    // It goes off and its wall with it: nothing is built there.
    core.get(&f.references,section).state=.Loaded
    core.destroy(&f.entities,wall)
    nav_test_settled(t,&f)
    _,status:=nav_test_path(t,&f,{-5,0,0},{5,0,0})
    testing.expect_value(t,status,ai.Search_Status.No_Path)
    testing.expect_value(t,f.nav.stats.built+f.nav.stats.emptied,built)
    core.get(&f.references,section).state=.Active
    nav_test_settled(t,&f)
    _,status=nav_test_path(t,&f,{-5,0,0},{5,0,0})
    testing.expect_value(t,status,ai.Search_Status.Found)
}

// Without Nav_Bounds the box of the static collision bounds the meshes: a
// terrain that lets its colliders go does not take the tiles with it.
@(test)
the_bounds_of_the_collision_keep_the_tiles_where_it_is_not_loaded :: proc(t:^testing.T) {
    f:Nav_Test
    nav_test_init(&f)
    defer nav_test_destroy(&f)
    nav_test_box(&f,{-6,-0.5,0},{6,0.5,6})
    far:=nav_test_box(&f,{6,-0.5,0},{6,0.5,6})
    nav_test_settled(t,&f)
    tiles :: proc(f:^Nav_Test) -> (count:int) {for &tile in f.nav.classes[0].mesh.tiles {if tile.used {count+=1}};return}
    before:=tiles(&f)
    append(&f.unloaded.boxes,mm.Aabb{{0.5,-1e4,-7},{13,1e4,7}})
    f.unloaded.revision+=1
    core.destroy(&f.entities,far)
    nav_test_settled(t,&f)
    testing.expect_value(t,tiles(&f),before)
    _,status:=nav_test_path(t,&f,{-8,0,0},{8,0,0})
    testing.expect_value(t,status,ai.Search_Status.Found)
}

@(test)
a_blocked_area_takes_the_surface_under_it :: proc(t:^testing.T) {
    f:Nav_Test
    nav_test_init(&f)
    defer nav_test_destroy(&f)
    nav_test_box(&f,{0,-0.5,0},{10,0.5,10})
    zone:=core.create(&f.entities)
    core.add(&f.transforms,zone,core.Transform{{0,0,0},1,{1,1,1}})
    core.add(&f.areas,zone,Nav_Area{half={1,2,10},area=AREA_BLOCKED})
    nav_test_settled(t,&f)
    // An agent that cannot jump: one that can jumps over the strip, by the links generated across it.
    _,status:=nav_test_path(t,&f,{-5,0,0},{5,0,0},{})
    testing.expect_value(t,status,ai.Search_Status.No_Path)
    _,status=nav_test_path(t,&f,{-5,0,0},{5,0,0})
    testing.expect_value(t,status,ai.Search_Status.Found)
    core.remove(&f.areas,zone)
    nav_test_settled(t,&f)
    _,status=nav_test_path(t,&f,{-5,0,0},{5,0,0},{})
    testing.expect_value(t,status,ai.Search_Status.Found)
}

// Two roofs 2.5 m apart over a street 6 m down: the class jumps 1.2 m up and
// 4 m across and drops 4 m, so it jumps from roof to roof but cannot drop to
// the street, nor jump back up to the higher roof.
@(test)
links_are_generated_between_roofs_for_what_the_class_can_do :: proc(t:^testing.T) {
    f:Nav_Test
    nav_test_init(&f)
    defer nav_test_destroy(&f)
    nav_test_box(&f,{0,-6.5,0},{12,0.5,12})
    nav_test_box(&f,{-4,-3,0},{2.75,3,3})
    nav_test_box(&f,{4,-2.5,0},{2.75,3.5,3})
    nav_test_settled(t,&f)
    mesh:=&f.nav.classes[0].mesh
    across,down:=0,0
    for &link in mesh.links {
        if !link.used || link.desc.owner&LINK_OWNER_GENERATED==0 {continue}
        if link.desc.need.down>4.5 {down+=1}
        if (link.desc.start.x<0)!=(link.desc.end.x<0) && link.desc.start.y>-1 && link.desc.end.y>-1 {across+=1}
    }
    testing.expect(t,across>=2 && down==0)
    can:=ai.Nav_Need{up=1.2,across=4,down=4}
    corners,status:=nav_test_path(t,&f,{-5,0,0},{5,1,0},can)
    testing.expect_value(t,status,ai.Search_Status.Found)
    jumped:=false
    for c in corners.items[:corners.count] {jumped|=.Link in c.flags}
    testing.expect(t,jumped)
    // One that cannot jump stays on its roof.
    _,status=nav_test_path(t,&f,{-5,0,0},{5,1,0},{})
    testing.expect_value(t,status,ai.Search_Status.No_Path)
    // A wall between the roofs closes the arc: the links go.
    nav_test_box(&f,{0,0,0},{0.25,6,6})
    nav_test_settled(t,&f)
    for &link in mesh.links {
        if !link.used || link.desc.owner&LINK_OWNER_GENERATED==0 {continue}
        testing.expect(t,(link.desc.start.x<0)==(link.desc.end.x<0) || link.desc.start.y< -1 || link.desc.end.y< -1)
    }
}

// A body that drops steps off the edge first: a platform lower than the drop of
// the class gets drop links down from its edges, and a path from it to the
// floor takes one.
@(test)
a_platform_gets_drop_links_off_its_edges :: proc(t:^testing.T) {
    f:Nav_Test
    nav_test_init(&f)
    defer nav_test_destroy(&f)
    nav_test_box(&f,{0,-0.5,0},{10,0.5,10})
    nav_test_box(&f,{0,1.75,0},{3,1.75,3})
    nav_test_settled(t,&f)
    drops:=0
    for &link in f.nav.classes[0].mesh.links {
        if link.used && link.desc.kind==u8(LINK_DROP) {
            drops+=1
            testing.expect(t,link.desc.start.y>3 && link.desc.end.y<1)
        }
    }
    testing.expect(t,drops>=4)
    corners,status:=nav_test_path(t,&f,{0,3.5,0},{0,0,8},{down=4})
    testing.expect_value(t,status,ai.Search_Status.Found)
    dropped:=false
    for c in corners.items[:corners.count] {dropped|=.Link in c.flags}
    testing.expect(t,dropped)
}

@(test)
a_link_component_joins_what_the_mesh_does_not :: proc(t:^testing.T) {
    f:Nav_Test
    nav_test_init(&f)
    defer nav_test_destroy(&f)
    f.settings.classes[0].jump_up,f.settings.classes[0].jump_across,f.settings.classes[0].drop=0,0,0
    nav_test_box(&f,{-4,-0.5,0},{2.5,0.5,3})
    nav_test_box(&f,{4,1.5,0},{2.5,0.5,3})
    ladder:=core.create(&f.entities)
    core.add(&f.transforms,ladder,core.Transform{{-2,0,0},1,{1,1,1}})
    core.add(&f.links,ladder,Nav_Link{end={4,2,0},kind=LINK_LADDER,two_way=true,area=AREA_WALKABLE})
    nav_test_settled(t,&f)
    _,status:=nav_test_path(t,&f,{-5,0,0},{5,2,0},{})
    testing.expect_value(t,status,ai.Search_Status.No_Path)
    climber:=ai.Nav_Need{abilities=1<<u32(ABILITY_LADDER)}
    corners,found:=nav_test_path(t,&f,{-5,0,0},{5,2,0},climber)
    testing.expect_value(t,found,ai.Search_Status.Found)
    _,status=nav_test_path(t,&f,{5,2,0},{-5,0,0},climber)
    testing.expect_value(t,status,ai.Search_Status.Found)
    core.remove(&f.links,ladder)
    nav_test_settled(t,&f)
    _,status=nav_test_path(t,&f,{-5,0,0},{5,2,0},climber)
    testing.expect_value(t,status,ai.Search_Status.No_Path)
}

// A jump of a Nav_Link is checked against the physics as a generated one: a
// low ceiling over the gap leaves it out of the class until it goes, and a
// wall that comes where it lands takes it out again.
@(test)
the_arc_of_a_link_component_is_checked_against_the_collision :: proc(t:^testing.T) {
    f:Nav_Test
    nav_test_init(&f)
    defer nav_test_destroy(&f)
    f.settings.classes[0].jump_up,f.settings.classes[0].jump_across,f.settings.classes[0].drop=0,0,0
    nav_test_box(&f,{-4,-0.5,0},{2.5,0.5,3})
    nav_test_box(&f,{4,-0.5,0},{2.5,0.5,3})
    ceiling:=nav_test_box(&f,{0,0.9,0},{1.6,0.2,3})
    jump:=core.create(&f.entities)
    core.add(&f.transforms,jump,core.Transform{{-2,0,0},1,{1,1,1}})
    core.add(&f.links,jump,Nav_Link{end={4,0,0},kind=LINK_JUMP,two_way=true,area=AREA_WALKABLE})
    nav_test_settled(t,&f)
    jumper:=ai.Nav_Need{up=1,down=1,across=5}
    _,status:=nav_test_path(t,&f,{-5,0,0},{5,0,0},jumper)
    testing.expect_value(t,status,ai.Search_Status.No_Path)
    testing.expect(t,core.problem_find(&f.problems,jump,"navigation.link_arc")!=nil,"the blocked arc is a problem of the link")
    core.destroy(&f.entities,ceiling)
    nav_test_settled(t,&f)
    corners,found:=nav_test_path(t,&f,{-5,0,0},{5,0,0},jumper)
    testing.expect_value(t,found,ai.Search_Status.Found)
    crossed:=false
    for c in corners.items[:corners.count] {crossed|=.Link in c.flags}
    testing.expect(t,crossed)
    _,status=nav_test_path(t,&f,{5,0,0},{-5,0,0},jumper)
    testing.expect_value(t,status,ai.Search_Status.Found)
    // A wall where it lands takes it out again.
    nav_test_box(&f,{2.3,1.8,0},{0.3,1,3})
    nav_test_settled(t,&f)
    _,status=nav_test_path(t,&f,{-5,0,0},{5,0,0},jumper)
    testing.expect_value(t,status,ai.Search_Status.No_Path)
}

@(test)
a_copied_navigation_keeps_its_meshes_and_builds_again_only_what_changed :: proc(t:^testing.T) {
    f:Nav_Test
    nav_test_init(&f)
    defer nav_test_destroy(&f)
    nav_test_box(&f,{0,-0.5,0},{10,0.5,10})
    nav_test_settled(t,&f)
    copied:Navigation
    testing.expect(t,navigation_copy(&copied,&f.nav))
    defer navigation_free(&copied)
    testing.expect(t,copied.uid==0 && copied.count==3)
    built:=f.nav.stats.built
    // The copy goes to the builds as a world they did not see: they check every tile and build none.
    navigation_free(&f.nav)
    f.nav=copied
    copied={}
    nav_test_settled(t,&f)
    testing.expect(t,f.nav.stats.built==built && f.nav.stats.unchanged>0)
}

@(test)
the_class_of_an_agent_is_the_smallest_that_holds_it :: proc(t:^testing.T) {
    n:Navigation
    n.classes[0].class=NAVIGATION_SETTINGS_DEFAULT.classes[0]
    n.classes[1].class={name={0='B'},radius=1,height=3,climb=0.3,max_slope=0.7}
    n.count=2
    human:=phys.character_default()
    class,_,_:=class_of(&n,human,phys.collider_character(),{1,1,1},.Surface)
    testing.expect_value(t,class,0)
    class,_,_=class_of(&n,human,phys.collider_character(0.8,2.5),{1,1,1},.Surface)
    testing.expect_value(t,class,1)
    class,_,_=class_of(&n,human,phys.collider_character(0.3,1.8),{2,1.5,2},.Surface)
    testing.expect_value(t,class,1)
    radius,height:f32
    class,radius,height=class_of(&n,human,phys.collider_character(2,4),{1,1,1},.Surface)
    testing.expect(t,class==-1 && abs(radius-2)<1e-4 && abs(height-4)<1e-4)
    steep:=human
    steep.max_slope=0.3
    class,_,_=class_of(&n,steep,phys.collider_character(),{1,1,1},.Surface)
    testing.expect_value(t,class,-1)
    // Who flies takes a class of the air, and only them, whatever its step and slope.
    class,_,_=class_of(&n,human,phys.collider_character(),{1,1,1},.Air)
    testing.expect_value(t,class,-1)
    n.classes[2].class={name={0='F'},space=.Air,radius=0.5,height=2}
    n.count=3
    class,_,_=class_of(&n,steep,phys.collider_character(),{1,1,1},.Air)
    testing.expect_value(t,class,2)
    class,_,_=class_of(&n,human,phys.collider_character(0.3,0.9),{1,1,1},.Surface)
    testing.expect_value(t,class,0)
}

@(test)
a_jump_launch_lands_on_the_end_of_its_link :: proc(t:^testing.T) {
    from,to:=mm.Vec3{0,0,0},mm.Vec3{3,1,0}
    g:=f32(9.81)
    velocity,_,total:=jump_launch(from,to,LINK_JUMP,g)
    // Integrate the flight in small steps.
    p,v:=from,velocity
    top:=f32(0)
    dt:=total/1000
    for _ in 0..<1000 {
        v.y-=g*dt
        p+=v*dt
        top=max(top,p.y)
    }
    testing.expect(t,linalg.length(p-to)<0.05)
    testing.expect(t,abs(top-(1+ai.NAV_JUMP_CLEARANCE))<0.05)
}

@(test)
a_baked_navmesh_reads_back_the_same_tiles_and_links :: proc(t:^testing.T) {
    f:Nav_Test
    nav_test_init(&f)
    defer nav_test_destroy(&f)
    nav_test_box(&f,{0,-6.5,0},{12,0.5,12})
    nav_test_box(&f,{-4,-3,0},{2.75,3,3})
    nav_test_box(&f,{4,-2.5,0},{2.75,3.5,3})
    nav_test_settled(t,&f)
    types:asset.Types
    asset.types_init(&types)
    defer asset.types_destroy(&types)
    bytes,error:=bake_bytes(&f.nav,{1,2},&types)
    defer delete(bytes)
    testing.expect_value(t,error,asset.Error.None)
    file:asset.Asset
    testing.expect_value(t,asset.asset_open(&file,bytes),asset.Error.None)
    defer asset.asset_close(&file)
    back:Navigation
    defer navigation_free(&back)
    testing.expect(t,navigation_reset(&back,&f.settings,&f.collision,&f.problems))
    count,ok:=bake_read(&back,&file,&types)
    tiles,links,generated:=0,0,0
    for &tile in f.nav.classes[0].mesh.tiles {if tile.used {tiles+=1}}
    for &link in f.nav.classes[0].mesh.links {if link.used && link.desc.owner&LINK_OWNER_GENERATED!=0 {generated+=1}}
    for &link in back.classes[0].mesh.links {if link.used {links+=1}}
    testing.expect(t,ok && count==tiles && tiles>0 && links==generated && generated>0)
    // Every tile reads back as it was, with its hash in its mark.
    for &tile in f.nav.classes[0].mesh.tiles {
        if !tile.used {continue}
        other:=ai.nav_mesh_tile_at(&back.classes[0].mesh,tile.data.coord)
        testing.expect(t,other!=nil)
        if other==nil {continue}
        testing.expect(t,len(other.data.polys)==len(tile.data.polys) && other.data.hash==tile.data.hash && other.data.bounds==tile.data.bounds)
        for p,i in tile.data.polys {testing.expect(t,other.data.polys[i]==p)}
        mark:=base.hash_map_ptr(&back.classes[0].marks,coord_key(tile.data.coord))
        testing.expect(t,mark!=nil && mark.hash==tile.data.hash)
    }
    // A class made of other collision is not seeded with the tiles of the bake.
    other:=f.settings
    other.classes[0].collision=phys.Collision_Preset(2)
    collision:=f.collision
    testing.expect_value(t,phys.collision_preset_setting_set(&collision,{preset=phys.Collision_Preset(2),belongs=phys.collision_layers(phys.Collision_Category(2)),collides=phys.COLLISION_LAYERS_ALL}),phys.Collision_Error.None)
    mismatch:Navigation
    defer navigation_free(&mismatch)
    testing.expect(t,navigation_reset(&mismatch,&other,&collision,&f.problems))
    _,mismatch_ok:=bake_read(&mismatch,&file,&types)
    testing.expect(t,mismatch_ok)
    for tile in mismatch.classes[0].mesh.tiles {testing.expect(t,!tile.used)}
    // Another version is not read and leaves the meshes alone.
    file.blob.header.kind_version+=1
    _,ok=bake_read(&back,&file,&types)
    testing.expect(t,!ok)
}

// Agents on top of the world of Nav_Test: the tables and queues of
// navigation_agents and of the locomotion, stepped in the order of the loop.
@(private)
Agents_Test :: struct {
    agents:core.Table(Nav_Agent),
    paths:core.Table(Nav_Path),
    inputs:core.Table(input.Move_Input),
    drivables:core.Table(input.Drivable),
    walks:core.Table(phys.Walk),
    flights:core.Table(phys.Fly),
    swims:core.Table(phys.Swim),
    worlds:core.Table(core.World_Transform),
    remotes:core.Table(core.Remote),
    fars:core.Table(Nav_Far),
    roamings:core.Table(scene.Roaming),
    requests:Nav_Requests,
    events:Nav_Events,
    loco:phys.Locomotion_Requests,
    run:Navigation_Agents,
    tick:u64,
}

@(private)
agents_test_init :: proc(g:^Agents_Test) {
    core.table_init(&g.agents,"Nav_Agent")
    core.table_init(&g.paths,"Nav_Path")
    core.table_init(&g.inputs,"Move_Input")
    core.table_init(&g.drivables,"Drivable")
    core.table_init(&g.walks,"Walk")
    core.table_init(&g.flights,"Fly")
    core.table_init(&g.swims,"Swim")
    core.table_init(&g.worlds,"World_Transform")
    core.table_init(&g.remotes,"Remote")
    core.table_init(&g.fars,"Nav_Far")
    core.table_init(&g.roamings,"Roaming")
    g.worlds.base=true
}

@(private)
agents_test_destroy :: proc(g:^Agents_Test) {
    agents_free(&g.run)
    core.table_destroy(&g.agents);core.table_destroy(&g.paths);core.table_destroy(&g.inputs);core.table_destroy(&g.drivables)
    core.table_destroy(&g.walks);core.table_destroy(&g.flights);core.table_destroy(&g.swims);core.table_destroy(&g.worlds);core.table_destroy(&g.remotes)
    core.table_destroy(&g.fars);core.table_destroy(&g.roamings)
    delete(g.requests.queue.items);delete(g.events.queue.items);delete(g.loco.queue.items)
}

@(private)
agents_test_settle :: proc(f:^Nav_Test,g:^Agents_Test) {nav_test_settle(f,g)}

// A flying character: a capsule with Walk and Fly that navigation moves.
@(private)
agents_test_flier :: proc(f:^Nav_Test,g:^Agents_Test,feet:[3]f32) -> core.Entity {
    e:=core.create(&f.entities)
    core.add(&f.transforms,e,core.Transform{feet,1,{1,1,1}})
    core.add(&f.colliders,e,phys.collider_character(0.25,0.8))
    character:=phys.character_default()
    character.mode=phys.MODE_FLYING
    core.add(&f.characters,e,character)
    core.add(&f.moves,e,phys.Character_Move{})
    core.add(&f.motions,e,core.Motion{})
    core.add(&g.walks,e,phys.WALK_DEFAULT)
    core.add(&g.flights,e,phys.Fly{speed=3,acceleration=20})
    core.add(&g.inputs,e,input.Move_Input{})
    core.add(&g.agents,e,NAV_AGENT_DEFAULT)
    return e
}

@(private)
agents_test_step :: proc(f:^Nav_Test,g:^Agents_Test) {
    time:=core.Time{tick=g.tick,seconds=f64(g.tick)/60,dt=1.0/60,playing=true}
    g.tick+=1
    agents_test_settle(f,g)
    for row in 0..<core.count(&f.transforms) {
        e:=core.entity_at(&f.transforms,row)
        t:=mm.Transform(core.at(&f.transforms,row)^)
        if w:=core.get(&g.worlds,e);w!=nil {w.transform=t} else {core.add(&g.worlds,e,core.World_Transform{transform=t})}
    }
    agents_test_settle(f,g)
    navigation_build(&f.nav,&f.builds,core.ref(&f.settings),core.read(&f.bakes),core.ref(&f.state),&f.build_requests,core.read(&f.bounds),core.read(&f.areas),core.read(&f.links),core.read(&f.obstacles),time,core.read(&f.transforms),core.read(&f.parents),core.ref(&f.unloaded),core.read(&f.references),core.read(&f.worlds),core.read(&f.ids),&f.app,&f.problems)
    navigation_agents(core.ref(&f.nav),&g.run,core.read(&g.agents),&g.paths,&g.requests,&g.events,&g.inputs,core.read(&g.drivables),core.read(&f.characters),core.read(&f.colliders),core.read(&g.walks),core.read(&g.flights),core.read(&g.swims),core.read(&f.character_states),core.read(&f.motions),core.read(&g.worlds),core.read(&f.obstacles),&g.loco,core.ref(&f.state),core.ref(&f.builds),&g.fars,
        &g.roamings,&f.disabled,{&f.transforms,core.read(&f.parents),&f.places,&f.jumps},&f.requests,time,&f.problems)
    agents_test_settle(f,g)
    navigation_crossing(core.read(&g.paths),&f.moves,core.read(&f.characters),core.read(&g.walks),core.read(&f.motions),core.read(&g.worlds),core.ref(&f.state),time)
    no_slides:core.Table(phys.Slide);no_mantles:core.Table(phys.Mantle);no_tacticals:core.Table(phys.Tactical_Sprint);no_ledges:core.Table(phys.Ledge_Jump)
    phys.locomotion_step(&f.characters,&f.moves,&g.inputs,core.read(&g.walks),core.read(&g.flights),core.read(&g.swims),core.read(&no_slides),core.read(&no_mantles),core.read(&no_tacticals),core.read(&no_ledges),core.read(&f.character_states),core.read(&f.motions),core.read(&f.transforms),core.read(&f.parents),core.read(&g.remotes),core.ref(&f.state),{},{},&g.loco,time,core.CLOCK_DEFAULT,&f.problems)
    agents_test_settle(f,g)
    phys.physics_step(
        &f.state,core.ref(&f.physics_settings),&f.requests,&f.events,&f.meshes,&f.app,time,
        core.read(&f.rigids),core.read(&f.colliders),core.read(&f.characters),core.read(&f.moves),
        &f.joints,core.read(&f.statics),core.read(&f.parents),core.read(&f.names),
        &f.transforms,&f.motions,core.read(&f.replicas),&f.character_states,&f.joint_states,core.read(&f.volumes),&f.joint_requests,core.ref(&f.collision),core.ref(&f.sync_check),&f.simulation_hash,nil,&f.problems,{},{},{},{},{},core.ref(&f.hierarchy),
    )
}

@(test)
fliers_leave_a_u_shaped_cave_under_its_wall_and_step_aside_from_each_other :: proc(t:^testing.T) {
    f:Nav_Test
    nav_test_init(&f)
    defer nav_test_destroy(&f)
    g:Agents_Test
    agents_test_init(&g)
    defer agents_test_destroy(&g)
    f.settings.classes[1]={name={0='B',1='i',2='r',3='d'},space=.Air,radius=0.3,height=0.9}
    // A floor, and a wall from above that leaves a gap under it; the air between them, closed on z by its bounds.
    nav_test_box(&f,{5,-0.5,2},{8,0.5,4})
    nav_test_box(&f,{5,6.25,2},{0.5,3.75,3})
    bounds:=core.create(&f.entities)
    core.add(&f.transforms,bounds,core.Transform{{5,5,2},1,{1,1,1}})
    core.add(&f.bounds,bounds,Nav_Bounds{half={5,5,2},air=true})
    nav_test_settled(t,&f)
    testing.expect(t,f.nav.count==3 && class_in_volume(&f.nav,1))
    volume:=&f.nav.classes[1].volume
    zones:=0
    for &zone in volume.zones {if zone.used {zones+=1}}
    testing.expect(t,zones>0)
    a:=agents_test_flier(&f,&g,{2,6,2})
    b:=agents_test_flier(&f,&g,{8,6,2})
    nav_move_to(&g.requests,a,{8,6,2})
    nav_move_to(&g.requests,b,{2,6,2})
    least:=f32(1e9)
    lowest:=f32(1e9)
    arrived:[2]bool
    for _ in 0..<60*30 {
        agents_test_step(&f,&g)
        pa,_:=core.get(core.read(&g.worlds),a)
        pb,_:=core.get(core.read(&g.worlds),b)
        least=min(least,linalg.distance(pa.position,pb.position))
        lowest=min(lowest,pa.position.y,pb.position.y)
        // Never through the wall.
        for p in ([2]mm.Vec3{pa.position,pb.position}) {
            testing.expect(t,!(p.x>4.5-0.2 && p.x<5.5+0.2 && p.y+0.8>2.55))
        }
        for e,i in ([2]core.Entity{a,b}) {
            if p,ok:=core.get(core.read(&g.paths),e);ok {
                testing.expect(t,p.state!=.Failed)
                if p.state==.Arrived {arrived[i]=true}
            }
        }
        if arrived[0] && arrived[1] {break}
    }
    testing.expectf(t,arrived[0] && arrived[1],"arrived %v",arrived)
    testing.expectf(t,lowest<1.6,"the lowest feet %v: under the wall",lowest)
    testing.expectf(t,least>0.5,"the nearest the two came %v",least)
    pa,_:=core.get(core.read(&g.worlds),a)
    // A flier takes its goal for the center of its capsule.
    testing.expectf(t,linalg.distance(pa.position+{0,0.4,0},mm.Vec3{8,6,2})<0.5,"a ends at %v",pa.position)
}

// A swimmer: a capsule with a Swim alone, which navigation moves through the water.
@(private)
agents_test_swimmer :: proc(f:^Nav_Test,g:^Agents_Test,feet:[3]f32) -> core.Entity {
    e:=core.create(&f.entities)
    core.add(&f.transforms,e,core.Transform{feet,1,{1,1,1}})
    core.add(&f.colliders,e,phys.collider_character(0.25,0.8))
    character:=phys.character_default()
    character.mode=phys.MODE_SWIMMING
    character.density=1000
    core.add(&f.characters,e,character)
    core.add(&f.moves,e,phys.Character_Move{})
    core.add(&f.motions,e,core.Motion{})
    core.add(&g.swims,e,phys.Swim{speed=2,acceleration=8,depth=1.2,surface_offset=0.25})
    core.add(&g.inputs,e,input.Move_Input{})
    core.add(&g.agents,e,NAV_AGENT_DEFAULT)
    return e
}

@(test)
swimmers_leave_a_u_shaped_cave_under_its_wall_and_keep_out_of_a_dry_box :: proc(t:^testing.T) {
    f:Nav_Test
    nav_test_init(&f)
    defer nav_test_destroy(&f)
    g:Agents_Test
    agents_test_init(&g)
    defer agents_test_destroy(&g)
    f.settings.classes[1]={name={0='F',1='i',2='s',3='h'},space=.Water,radius=0.3,height=0.9}
    // A floor, and a wall from above that leaves a gap under it, in a pool closed on z by its sides; a dry box over the far side.
    nav_test_box(&f,{5,-0.5,2},{8,0.5,4})
    nav_test_box(&f,{5,6.25,2},{0.5,3.75,3})
    pool:=core.create(&f.entities)
    core.add(&f.transforms,pool,core.Transform{{5,5,2},1,{1,1,1}})
    core.add(&f.volumes,pool,phys.fluid_volume_box({5,5,2}))
    dry:=core.create(&f.entities)
    core.add(&f.transforms,dry,core.Transform{{8.5,2,2},1,{1,1,1}})
    core.add(&f.volumes,dry,phys.fluid_volume_dry({1.5,1.5,2},1))
    nav_test_step(&f)
    nav_test_settled(t,&f)
    testing.expect(t,f.nav.count>=2 && class_in_volume(&f.nav,1))
    volume:=&f.nav.classes[1].volume
    _,_,in_dry:=ai.nav_volume_find_nearest(volume,{8.5,2,2},{0.1,0.1,0.1})
    testing.expect(t,!in_dry)
    _,_,in_water:=ai.nav_volume_find_nearest(volume,{2,6,2},{0.1,0.1,0.1})
    testing.expect(t,in_water)
    a:=agents_test_swimmer(&f,&g,{2,6,2})
    b:=agents_test_swimmer(&f,&g,{8,6,2})
    nav_move_to(&g.requests,a,{8,6,2})
    nav_move_to(&g.requests,b,{2,6,2})
    least,lowest:=f32(1e9),f32(1e9)
    arrived:[2]bool
    for _ in 0..<60*40 {
        agents_test_step(&f,&g)
        pa,_:=core.get(core.read(&g.worlds),a)
        pb,_:=core.get(core.read(&g.worlds),b)
        least=min(least,linalg.distance(pa.position,pb.position))
        lowest=min(lowest,pa.position.y,pb.position.y)
        for p in ([2]mm.Vec3{pa.position,pb.position}) {
            testing.expect(t,!(p.x>4.5-0.2 && p.x<5.5+0.2 && p.y+0.8>2.55))
            testing.expect(t,!(p.x>7.2 && p.y+0.4<3.3 && p.y+0.4>0.7))
        }
        for e,i in ([2]core.Entity{a,b}) {
            if p,ok:=core.get(core.read(&g.paths),e);ok {
                testing.expect(t,p.state!=.Failed)
                if p.state==.Arrived {arrived[i]=true}
            }
        }
        if arrived[0] && arrived[1] {break}
    }
    testing.expectf(t,arrived[0] && arrived[1],"arrived %v",arrived)
    testing.expectf(t,lowest<1.6,"the lowest feet %v: under the wall",lowest)
    testing.expectf(t,least>0.5,"the nearest the two came %v",least)
}

@(test)
the_ground_under_deep_water_is_of_the_water_and_only_swimmers_cross_it :: proc(t:^testing.T) {
    f:Nav_Test
    nav_test_init(&f)
    defer nav_test_destroy(&f)
    // A floor across a pool three metres deep over its far half, with a strip of shallows around it.
    nav_test_box(&f,{8,-0.5,4},{8,0.5,4})
    pool:=core.create(&f.entities)
    core.add(&f.transforms,pool,core.Transform{{8,1.5,4},1,{1,1,1}})
    core.add(&f.volumes,pool,phys.fluid_volume_box({3,1.5,4.5}))
    nav_test_step(&f)
    nav_test_settled(t,&f)
    walker:=agent_avoids(NAV_AGENT_DEFAULT,false)
    testing.expect(t,walker&Nav_Areas(1<<u64(AREA_WATER))!=0 && agent_avoids(NAV_AGENT_DEFAULT,true)==NAV_AGENT_DEFAULT.avoid)
    _,status:=nav_test_path(t,&f,{1,0,4},{8,0,4})
    testing.expect_value(t,status,ai.Search_Status.Found)
    // The middle of the pool is its deep ground: a walker that cannot swim does not get there.
    _,status=nav_test_path(t,&f,{1,0,4},{8,0,4},avoid=walker)
    testing.expect(t,status!=.Found)
    _,status=nav_test_path(t,&f,{1,0,4},{15,0,4},avoid=walker)
    testing.expect(t,status!=.Found)
}

// Sections in a row along x, each with its own floor: the first holds x in
// [-30, -10], the second [-10, 10] and the third [10, 30].
@(private)
Row_Sections :: struct {references,floors:[3]core.Entity,boxes:[3]mm.Aabb,keys:[3]u64}

@(private)
nav_test_sections :: proc(f:^Nav_Test,count:int) -> (s:Row_Sections) {
    for i in 0..<count {
        x:=f32(i-1)*20
        s.floors[i]=nav_test_box(f,{x,-0.5,0},{10,0.5,6})
        e:=core.create(&f.entities)
        reference:=scene.Scene_Reference{scene={1,u64(i+1)},extents={10,3,6},rule=.Spatial,state=.Active,loaded={1,u64(i+1)}}
        world:=core.World_Transform{transform={position={x,0,0},rotation=1,scale=1}}
        core.add(&f.references,e,reference)
        core.add(&f.worlds,e,world)
        core.add(&f.ids,e,core.Id{base.Entity_Id(100+i)})
        s.references[i],s.boxes[i],s.keys[i]=e,scene.section_bounds(reference,world.transform),u64(100+i)
    }
    return
}

// The section goes away, and its floor with it.
@(private)
nav_test_drop :: proc(f:^Nav_Test,s:^Row_Sections,i:int) {
    reference:=core.get(&f.references,s.references[i])
    reference.loaded,reference.state={},.Unloaded
    core.destroy(&f.entities,s.floors[i])
}

@(private)
nav_test_tiles :: proc(n:^Navigation) -> (count:int) {
    for &tile in n.classes[0].mesh.tiles {if tile.used {count+=1}}
    return
}

@(private)
nav_test_path_on :: proc(n:^Navigation,settings:^Navigation_Settings,from,to:mm.Vec3) -> (corners:Test_Corners,status:ai.Search_Status) {
    mesh:=&n.classes[0].mesh
    filter:=filter_make(settings,{},ai.NAV_CAN_ALL)
    a,start,ok:=ai.nav_find_nearest(mesh,from,{1,2,1},&filter)
    b,end,ok2:=ai.nav_find_nearest(mesh,to,{1,2,1},&filter)
    if !ok || !ok2 {return {},.Invalid}
    q:ai.Nav_Query
    ai.nav_query_init(&q,4096)
    defer ai.nav_query_destroy(&q)
    refs:[1024]ai.Nav_Ref
    count:int
    partial:bool
    count,status,partial=ai.nav_find_path(&q,mesh,a,b,start,end,&filter,refs[:])
    if partial {status=.No_Path}
    corners.count,_=ai.nav_straight_path(mesh,start,end,refs[:count],corners.items[:])
    return
}

// Each section bakes the tiles over its box; a world that reads the two
// bakes has one mesh across their border, and the scene that holds them
// keeps only the coarse graph of both.
@(test)
the_tiles_two_sections_bake_join_at_their_border :: proc(t:^testing.T) {
    f:Nav_Test
    nav_test_init(&f)
    defer nav_test_destroy(&f)
    s:=nav_test_sections(&f,2)
    nav_test_settled(t,&f)
    testing.expect_value(t,len(f.nav.classes[0].coarse.regions),2)
    types:asset.Types
    asset.types_init(&types)
    defer asset.types_destroy(&types)
    first,e1:=bake_bytes(&f.nav,{1,1},&types,{within=true,inside=s.boxes[0]})
    defer delete(first)
    second,e2:=bake_bytes(&f.nav,{1,2},&types,{within=true,inside=s.boxes[1]})
    defer delete(second)
    root,e3:=bake_bytes(&f.nav,{1,3},&types,{outside=s.boxes[:2],coarse=true})
    defer delete(root)
    testing.expect(t,e1==.None && e2==.None && e3==.None)
    back:Navigation
    defer navigation_free(&back)
    testing.expect(t,navigation_reset(&back,&f.settings,&f.collision,&f.problems))
    read :: proc(t:^testing.T,n:^Navigation,bytes:[]u8,types:^asset.Types) -> int {
        file:asset.Asset
        testing.expect_value(t,asset.asset_open(&file,bytes),asset.Error.None)
        defer asset.asset_close(&file)
        count,ok:=bake_read(n,&file,types)
        testing.expect(t,ok)
        return count
    }
    // The scene keeps no tile: the boxes of its sections cover them all.
    testing.expect_value(t,read(t,&back,root,&types),0)
    testing.expect_value(t,len(back.classes[0].coarse.regions),2)
    a:=read(t,&back,first,&types)
    _,status:=nav_test_path_on(&back,&f.settings,{-25,0,0},{5,0,0})
    testing.expect(t,a>0 && status!=.Found)
    // The tiles on the border are in both bakes and read once.
    b:=read(t,&back,second,&types)
    testing.expect_value(t,a+b,nav_test_tiles(&f.nav))
    testing.expect_value(t,nav_test_tiles(&back),nav_test_tiles(&f.nav))
    corners,found:=nav_test_path_on(&back,&f.settings,{-25,0,0},{5,0,0})
    testing.expect_value(t,found,ai.Search_Status.Found)
    testing.expect(t,corners.count>=2 && abs(corners_length(corners.items[:corners.count])-30)<1)
}

// A section that goes away takes the tiles only it covers, and keeps those
// it shares with a section here; back, its bake puts them in again before
// they are built, and the tiles are what they were.
@(test)
the_tiles_of_a_section_go_with_it_and_come_back_with_its_bake :: proc(t:^testing.T) {
    f:Nav_Test
    nav_test_init(&f)
    defer nav_test_destroy(&f)
    s:=nav_test_sections(&f,3)
    nav_test_settled(t,&f)
    before:=nav_test_tiles(&f.nav)
    types:asset.Types
    asset.types_init(&types)
    defer asset.types_destroy(&types)
    bytes,error:=bake_bytes(&f.nav,{1,2},&types,{within=true,inside=s.boxes[1]})
    defer delete(bytes)
    testing.expect_value(t,error,asset.Error.None)
    mesh:=&f.nav.classes[0].mesh
    middle,border:=ai.nav_mesh_coord(mesh,{1,0,1}),ai.nav_mesh_coord(mesh,{-9,0,1})
    nav_test_drop(&f,&s,1)
    nav_test_settled(t,&f)
    testing.expect(t,f.nav.stats.dropped>0 && nav_test_tiles(&f.nav)<before)
    testing.expect(t,ai.nav_mesh_tile_at(mesh,middle)==nil && ai.nav_mesh_tile_at(mesh,border)!=nil)
    // Its part of the coarse graph stays.
    testing.expect(t,ai.nav_coarse_region(&f.nav.classes[0].coarse,s.keys[1])!=nil)
    // Back, with its floor; its Navigation_Bake reads the bake.
    reference:=core.get(&f.references,s.references[1])
    reference.loaded,reference.state={1,2},.Active
    s.floors[1]=nav_test_box(&f,{0,-0.5,0},{10,0.5,6})
    file:asset.Asset
    testing.expect_value(t,asset.asset_open(&file,bytes),asset.Error.None)
    defer asset.asset_close(&file)
    count,ok:=bake_read(&f.nav,&file,&types)
    testing.expect(t,ok && count>0 && ai.nav_mesh_tile_at(mesh,middle)!=nil)
    nav_test_settled(t,&f)
    testing.expect_value(t,nav_test_tiles(&f.nav),before)
    _,status:=nav_test_path(t,&f,{-25,0,0},{25,0,0})
    testing.expect_value(t,status,ai.Search_Status.Found)
}

// Settled with sections here and away, ticks that change nothing build,
// drop and make nothing.
@(test)
nothing_changes_while_nothing_does :: proc(t:^testing.T) {
    f:Nav_Test
    nav_test_init(&f)
    defer nav_test_destroy(&f)
    s:=nav_test_sections(&f,3)
    nav_test_settled(t,&f)
    nav_test_drop(&f,&s,1)
    nav_test_settled(t,&f)
    revision,stats,coarse:=f.nav.revision,f.nav.stats,f.builds.coarse_revision
    nav_test_step(&f,120)
    testing.expect_value(t,f.nav.revision,revision)
    testing.expect_value(t,f.nav.stats,stats)
    testing.expect_value(t,f.builds.coarse_revision,coarse)
}

// Two sections in a column, as down a well: the upper holds y in [-1, 5] with
// its floor at 0 for x below 4, the lower y in [-7, -1] with its floor at -3,
// and the edge of the upper drops onto the lower.
@(private)
Well_Sections :: struct {upper,lower,floor,ground:core.Entity,keys:[2]u64}

@(private)
nav_test_well :: proc(f:^Nav_Test) -> (w:Well_Sections) {
    w.floor=nav_test_box(f,{-3,-0.5,0},{7,0.5,6})
    w.ground=nav_test_box(f,{0,-3.5,0},{10,0.5,6})
    for i in 0..<2 {
        e:=core.create(&f.entities)
        reference:=scene.Scene_Reference{scene={1,u64(i+1)},extents={10,3,6},rule=.Spatial,state=.Active,loaded={1,u64(i+1)}}
        core.add(&f.references,e,reference)
        core.add(&f.worlds,e,core.World_Transform{transform={position={0,2 if i==0 else -4,0},rotation=1,scale=1}})
        core.add(&f.ids,e,core.Id{base.Entity_Id(200+i)})
        w.keys[i]=u64(200+i)
        if i==0 {w.upper=e} else {w.lower=e}
    }
    return
}

// With the lower section of the well away, the tiles of the upper one, which
// read its column, build from what is here: a wall there cuts the floor. Made
// again, the upper section keeps the portal down the well.
@(test)
the_tiles_over_a_section_away_build_from_what_is_here :: proc(t:^testing.T) {
    f:Nav_Test
    nav_test_init(&f)
    defer nav_test_destroy(&f)
    w:=nav_test_well(&f)
    nav_test_settled(t,&f)
    down :: proc(c:^ai.Nav_Coarse,w:Well_Sections) -> bool {
        region:=ai.nav_coarse_region(c,w.keys[0])
        if region==nil {return false}
        for p in c.portals[region.portal_first:][:region.portal_count] {if p.outside==w.keys[1] {return true}}
        return false
    }
    testing.expect(t,down(&f.nav.classes[0].coarse,w))
    reference:=core.get(&f.references,w.lower)
    reference.loaded,reference.state={},.Unloaded
    core.destroy(&f.entities,w.ground)
    nav_test_settled(t,&f)
    _,status:=nav_test_path(t,&f,{-8,0,0},{2,0,0})
    testing.expect_value(t,status,ai.Search_Status.Found)
    nav_test_box(&f,{-3,1,0},{0.5,1,7})
    nav_test_settled(t,&f)
    _,status=nav_test_path(t,&f,{-8,0,0},{2,0,0})
    testing.expect_value(t,status,ai.Search_Status.No_Path)
    testing.expect(t,down(&f.nav.classes[0].coarse,w))
}

// A walking character that navigation moves.
@(private)
agents_test_walker :: proc(f:^Nav_Test,g:^Agents_Test,feet:[3]f32) -> core.Entity {
    e:=core.create(&f.entities)
    core.add(&f.transforms,e,core.Transform{feet,1,{1,1,1}})
    core.add(&f.colliders,e,phys.collider_character())
    core.add(&f.characters,e,phys.character_default())
    core.add(&f.moves,e,phys.Character_Move{})
    core.add(&f.motions,e,core.Motion{})
    core.add(&g.walks,e,phys.WALK_DEFAULT)
    core.add(&g.inputs,e,input.Move_Input{})
    core.add(&g.agents,e,NAV_AGENT_DEFAULT)
    return e
}

// The middle section is not loaded: an agent from the first to the third
// walks to the portal its way enters it by, goes on far and off through it,
// and comes out on the mesh of the third, where it walks to its goal.
@(test)
an_agent_crosses_a_section_that_is_not_loaded_and_comes_out_in_the_next :: proc(t:^testing.T) {
    f:Nav_Test
    nav_test_init(&f)
    defer nav_test_destroy(&f)
    g:Agents_Test
    agents_test_init(&g)
    defer agents_test_destroy(&g)
    s:=nav_test_sections(&f,3)
    nav_test_settled(t,&f)
    coarse:=&f.nav.classes[0].coarse
    middle:=ai.nav_coarse_region(coarse,s.keys[1])
    testing.expect(t,len(coarse.regions)==3 && middle!=nil && middle.portal_count>=2)
    // The middle one has portals toward both sides, each with its twin.
    sides:[2]bool
    for p in coarse.portals[middle.portal_first:][:middle.portal_count] {
        testing.expect(t,p.twin>=0 && (p.outside==s.keys[0] || p.outside==s.keys[2]))
        sides[0]|=p.outside==s.keys[0]
        sides[1]|=p.outside==s.keys[2]
    }
    testing.expect(t,sides=={true,true})
    nav_test_drop(&f,&s,1)
    nav_test_settled(t,&f)
    walker:=agents_test_walker(&f,&g,{-25,0,0})
    goal:=mm.Vec3{25,0,0}
    nav_move_to(&g.requests,walker,goal)
    far,roamed,arrived,through:=false,false,false,false
    entries:=0
    lowest:=f32(1e9)
    for _ in 0..<60*40 {
        agents_test_step(&f,&g)
        pose,_:=core.get(core.read(&g.worlds),walker)
        lowest=min(lowest,pose.position.y)
        now:=core.raw_row(core.raw(&g.fars),walker)>=0
        if now {
            if !far {entries+=1}
            roamed|=core.raw_row(core.raw(&g.roamings),walker)>=0
            through|=abs(pose.position.x)<8
            testing.expect(t,core.entity_off(&f.entities,walker))
        }
        far=now
        if p,ok:=core.get(core.read(&g.paths),walker);ok {
            testing.expect(t,p.state!=.Failed)
            if p.state==.Arrived {arrived=true;break}
        }
    }
    testing.expectf(t,entries==1 && roamed && through && arrived,"far %d times, roaming %v, through the middle %v, arrived %v",entries,roamed,through,arrived)
    testing.expectf(t,lowest>-1,"it fell to %v",lowest)
    pose,_:=core.get(core.read(&g.worlds),walker)
    testing.expectf(t,linalg.length(mm.Vec3{pose.position.x-goal.x,0,pose.position.z-goal.z})<1,"it ends at %v",pose.position)
    agents_test_step(&f,&g)
    testing.expect(t,!core.entity_off(&f.entities,walker) && core.raw_row(core.raw(&g.fars),walker)<0 && !core.has(&g.roamings,walker))
}

// Steps until the agent is far and has arrived there, off.
@(private)
agents_test_far_arrival :: proc(t:^testing.T,f:^Nav_Test,g:^Agents_Test,e:core.Entity) -> bool {
    for _ in 0..<60*30 {
        agents_test_step(f,g)
        far:=cast(^Nav_Far)core.raw_find(core.raw(&g.fars),type_info_of(Nav_Far),e)
        if far!=nil && far.arrived {
            p:=cast(^Nav_Path)core.raw_find(core.raw(&g.paths),type_info_of(Nav_Path),e)
            return p!=nil && p.state==.Arrived && core.entity_off(&f.entities,e)
        }
    }
    return false
}

// An agent whose goal is in a section that is not loaded gets there far and
// off; when the section loads where it is, it is put on its mesh, arrived.
@(test)
an_agent_that_arrives_far_appears_when_its_section_loads :: proc(t:^testing.T) {
    f:Nav_Test
    nav_test_init(&f)
    defer nav_test_destroy(&f)
    g:Agents_Test
    agents_test_init(&g)
    defer agents_test_destroy(&g)
    s:=nav_test_sections(&f,3)
    nav_test_settled(t,&f)
    nav_test_drop(&f,&s,1)
    nav_test_settled(t,&f)
    walker:=agents_test_walker(&f,&g,{-25,0,0})
    nav_move_to(&g.requests,walker,{2,0,1})
    testing.expect(t,agents_test_far_arrival(t,&f,&g,walker))
    pose,_:=core.get(core.read(&g.worlds),walker)
    testing.expectf(t,linalg.length(pose.position-mm.Vec3{2,0,1})<0.5,"it got to %v",pose.position)
    // It stays where it got while its section is away.
    for _ in 0..<60 {agents_test_step(&f,&g)}
    testing.expect(t,core.entity_off(&f.entities,walker))
    reference:=core.get(&f.references,s.references[1])
    reference.loaded,reference.state={1,2},.Active
    s.floors[1]=nav_test_box(&f,{0,-0.5,0},{10,0.5,6})
    told:=false
    for _ in 0..<60*10 {
        agents_test_step(&f,&g)
        for event in g.events.queue.items {told|=event.kind==.Arrived && event.entity==walker}
        if !core.entity_off(&f.entities,walker) {break}
    }
    testing.expect(t,!core.entity_off(&f.entities,walker) && told)
    p,ok:=core.get(core.read(&g.paths),walker)
    testing.expect(t,ok && p.state==.Arrived && core.raw_row(core.raw(&g.fars),walker)<0)
    // On the mesh, and it stands there.
    for _ in 0..<30 {agents_test_step(&f,&g)}
    pose,_=core.get(core.read(&g.worlds),walker)
    testing.expectf(t,linalg.length(mm.Vec3{pose.position.x-2,0,pose.position.z-1})<0.5 && abs(pose.position.y)<0.5,"it stands at %v",pose.position)
    mesh:=&f.nav.classes[0].mesh
    filter:=filter_make(&f.settings,{},{})
    _,_,on:=ai.nav_find_nearest(mesh,pose.position,{0.1,1,0.1},&filter)
    testing.expect(t,on)
}

// Asked to go back while it is far, an agent walks out of the section that
// is not loaded and on to its goal.
@(test)
an_agent_far_takes_the_requests_of_the_game :: proc(t:^testing.T) {
    f:Nav_Test
    nav_test_init(&f)
    defer nav_test_destroy(&f)
    g:Agents_Test
    agents_test_init(&g)
    defer agents_test_destroy(&g)
    s:=nav_test_sections(&f,3)
    nav_test_settled(t,&f)
    nav_test_drop(&f,&s,1)
    nav_test_settled(t,&f)
    walker:=agents_test_walker(&f,&g,{-25,0,0})
    nav_move_to(&g.requests,walker,{0,0,0})
    testing.expect(t,agents_test_far_arrival(t,&f,&g,walker))
    back:=mm.Vec3{-25,0,2}
    nav_move_to(&g.requests,walker,back)
    arrived:=false
    for _ in 0..<60*30 {
        agents_test_step(&f,&g)
        if p,ok:=core.get(core.read(&g.paths),walker);ok && p.state==.Arrived {arrived=true;break}
    }
    pose,_:=core.get(core.read(&g.worlds),walker)
    testing.expectf(t,arrived && linalg.length(mm.Vec3{pose.position.x-back.x,0,pose.position.z-back.z})<1,"arrived %v at %v",arrived,pose.position)
    testing.expect_value(t,f.problems.count,0)
}

// Three sections in a row along x, tall enough to fly in, with the air of
// one Nav_Bounds over them from 0 to 10 m; in the middle one a wall from 2.5 m
// up, with a gap under it. The middle one goes away, wall and all: a flier
// from the first to the third goes far at the portal into it and through it
// by the way its coarse graph has, under where the wall was, not straight.
@(test)
a_flier_far_takes_the_way_through_the_air_of_the_section_away :: proc(t:^testing.T) {
    f:Nav_Test
    nav_test_init(&f)
    defer nav_test_destroy(&f)
    g:Agents_Test
    agents_test_init(&g)
    defer agents_test_destroy(&g)
    f.settings.classes[1]={name={0='B',1='i',2='r',3='d'},space=.Air,radius=0.3,height=0.9}
    references,floors:[3]core.Entity
    for i in 0..<3 {
        x:=f32(i-1)*20
        floors[i]=nav_test_box(&f,{x,-0.5,0},{10,0.5,6})
        e:=core.create(&f.entities)
        core.add(&f.references,e,scene.Scene_Reference{scene={1,u64(i+1)},extents={10,8,6},rule=.Spatial,state=.Active,loaded={1,u64(i+1)}})
        core.add(&f.worlds,e,core.World_Transform{transform={position={x,5,0},rotation=1,scale=1}})
        core.add(&f.ids,e,core.Id{base.Entity_Id(300+i)})
        references[i]=e
    }
    wall:=nav_test_box(&f,{0,6.25,0},{0.5,3.75,6})
    air:=core.create(&f.entities)
    core.add(&f.transforms,air,core.Transform{{0,5,0},1,{1,1,1}})
    core.add(&f.bounds,air,Nav_Bounds{half={30,5,6},air=true})
    // The ways of a region of the air are searched over ticks.
    on_its_way:=0
    for _ in 0..<400 {
        nav_test_step(&f)
        if f.builds.region_busy && f.builds.region_class==1 {on_its_way+=1}
        if ai.nav_coarse_region(&f.nav.classes[1].coarse,301)!=nil {break}
    }
    testing.expectf(t,on_its_way>1,"the region was on its way %d ticks",on_its_way)
    nav_test_settled(t,&f)
    coarse:=&f.nav.classes[1].coarse
    middle:=ai.nav_coarse_region(coarse,301)
    testing.expect(t,middle!=nil && middle.portal_count>=2)
    reference:=core.get(&f.references,references[1])
    reference.loaded,reference.state={},.Unloaded
    core.destroy(&f.entities,floors[1])
    core.destroy(&f.entities,wall)
    nav_test_settled(t,&f)
    flier:=agents_test_flier(&f,&g,{-25,6,0})
    goal:=mm.Vec3{25,6,0}
    nav_move_to(&g.requests,flier,goal)
    far,arrived,under:=false,false,false
    entries:=0
    highest:=f32(-1e9)
    for _ in 0..<60*60 {
        agents_test_step(&f,&g)
        pose,_:=core.get(core.read(&g.worlds),flier)
        now:=core.raw_row(core.raw(&g.fars),flier)>=0
        if now {
            if !far {entries+=1}
            if abs(pose.position.x)<1 {
                highest=max(highest,pose.position.y)
                under=true
            }
        }
        far=now
        if p,ok:=core.get(core.read(&g.paths),flier);ok {
            testing.expect(t,p.state!=.Failed)
            if p.state==.Arrived {arrived=true;break}
        }
    }
    testing.expectf(t,entries==1 && under && arrived,"far %d times, under the wall %v, arrived %v",entries,under,arrived)
    // Its feet, under the bottom of the wall less the half of its capsule.
    testing.expectf(t,highest<2.5-0.4,"it went through where the wall was at %v",highest)
    pose,_:=core.get(core.read(&g.worlds),flier)
    testing.expectf(t,linalg.distance(pose.position+{0,0.4,0},goal)<1,"it ends at %v",pose.position)
    testing.expect_value(t,f.problems.count,0)
}

// A character that walks and swims, or walks and flies: navigation moves it in either space.
@(private)
agents_test_amphibian :: proc(f:^Nav_Test,g:^Agents_Test,feet:[3]f32,flies:bool) -> core.Entity {
    e:=core.create(&f.entities)
    core.add(&f.transforms,e,core.Transform{feet,1,{1,1,1}})
    core.add(&f.colliders,e,phys.collider_character(0.25,0.8))
    character:=phys.character_default()
    character.density=1000
    core.add(&f.characters,e,character)
    core.add(&f.moves,e,phys.Character_Move{})
    core.add(&f.motions,e,core.Motion{})
    core.add(&g.walks,e,phys.WALK_DEFAULT)
    if flies {core.add(&g.flights,e,phys.Fly{speed=3,acceleration=20})} else {core.add(&g.swims,e,phys.Swim{speed=2,acceleration=8,depth=1.2,surface_offset=0.25})}
    core.add(&g.inputs,e,input.Move_Input{})
    core.add(&g.agents,e,NAV_AGENT_DEFAULT)
    return e
}

// Steps until the agent arrives, and tells what modes the physics gave it and what it crossed.
@(private)
agents_test_travel :: proc(f:^Nav_Test,g:^Agents_Test,e:core.Entity,seconds:int) -> (arrived:bool,modes:bit_set[0..<16],crossed:[dynamic]Nav_Link_Kind,failed:bool) {
    crossed=make([dynamic]Nav_Link_Kind,context.temp_allocator)
    for _ in 0..<60*seconds {
        agents_test_step(f,g)
        c,_:=core.get(core.read(&f.characters),e)
        if int(c.mode)<16 {modes+={int(c.mode)}}
        for event in g.events.queue.items {if event.entity==e && event.kind==.Crossed {append(&crossed,event.link)}}
        p,_:=core.get(core.read(&g.paths),e)
        failed||=p.state==.Failed
        if p.state==.Arrived {return !p.partial,modes,crossed,failed}
    }
    return
}

// An agent that walks and swims meets a pool deeper than it wades across
// its way: one plan takes it to the shore, through the volume of the water
// and out on the far side, where it walks to its goal.
@(test)
an_amphibian_walks_into_the_water_at_the_shore_swims_across_and_walks_out :: proc(t:^testing.T) {
    f:Nav_Test
    nav_test_init(&f)
    defer nav_test_destroy(&f)
    g:Agents_Test
    agents_test_init(&g)
    defer agents_test_destroy(&g)
    nav_test_box(&f,{12,-0.5,4},{12,0.5,4})
    pool:=core.create(&f.entities)
    core.add(&f.transforms,pool,core.Transform{{12,1.5,4},1,{1,1,1}})
    core.add(&f.volumes,pool,phys.fluid_volume_box({4,1.5,4}))
    nav_test_step(&f)
    nav_test_settled(t,&f)
    e:=agents_test_amphibian(&f,&g,{2,0,4},false)
    nav_move_to(&g.requests,e,{22,0,4})
    for _ in 0..<30 {
        agents_test_step(&f,&g)
        if p,_:=core.get(core.read(&g.paths),e);p.state==.Moving {break}
    }
    p,_:=core.get(core.read(&g.paths),e)
    testing.expectf(t,p.state==.Moving && p.medium && p.kind==LINK_SWIM && p.to.x>p.from.x,"its plan crosses into the water: %v %v %v",p.state,p.medium,p.kind)
    arrived,modes,crossed,failed:=agents_test_travel(&f,&g,e,60)
    testing.expect(t,arrived && !failed,"it walks out on the far side to its goal")
    testing.expect(t,int(phys.MODE_SWIMMING) in modes,"it swims")
    testing.expectf(t,len(crossed)>=2 && crossed[0]==LINK_SWIM && crossed[len(crossed)-1]==LINK_SWIM,"in and out by the shores: %v",crossed)
    at,_:=core.get(core.read(&g.worlds),e)
    testing.expectf(t,linalg.distance(at.position,mm.Vec3{22,0,4})<1,"at %v",at.position)
}

// An agent that walks and flies takes off by a Nav_Link of LINK_FLY from the
// ground into the air, flies to the one over a platform it cannot climb, and
// lands there by that link the other way.
@(test)
an_agent_that_walks_and_flies_takes_off_and_lands_by_links_of_the_air :: proc(t:^testing.T) {
    f:Nav_Test
    nav_test_init(&f)
    defer nav_test_destroy(&f)
    g:Agents_Test
    agents_test_init(&g)
    defer agents_test_destroy(&g)
    f.settings.classes[0].jump_up,f.settings.classes[0].jump_across,f.settings.classes[0].drop=0,0,0
    nav_test_box(&f,{12,-0.5,4},{12,0.5,4})
    nav_test_box(&f,{20,2,4},{3,2,4})
    sky:=core.create(&f.entities)
    core.add(&f.transforms,sky,core.Transform{{12,5,4},1,{1,1,1}})
    core.add(&f.bounds,sky,Nav_Bounds{half={12,5,4},air=true})
    off:=core.create(&f.entities)
    core.add(&f.transforms,off,core.Transform{{4,0,4},1,{1,1,1}})
    core.add(&f.links,off,Nav_Link{end={0,3,0},kind=LINK_FLY,area=AREA_WALKABLE})
    land:=core.create(&f.entities)
    core.add(&f.transforms,land,core.Transform{{19,4,4},1,{1,1,1}})
    core.add(&f.links,land,Nav_Link{end={0,2.5,0},kind=LINK_FLY,two_way=true,area=AREA_WALKABLE})
    nav_test_step(&f)
    nav_test_settled(t,&f)
    for &link in f.nav.classes[0].mesh.links {testing.expect(t,!link.used || link.desc.kind!=u8(LINK_FLY),"a take-off is no link of the mesh")}
    e:=agents_test_amphibian(&f,&g,{1,0,4},true)
    nav_move_to(&g.requests,e,{21,4,4})
    arrived,modes,crossed,failed:=agents_test_travel(&f,&g,e,60)
    testing.expect(t,arrived && !failed,"it gets onto the platform")
    testing.expect(t,int(phys.MODE_FLYING) in modes,"it flies")
    testing.expectf(t,len(crossed)>=2 && crossed[0]==LINK_FLY && crossed[len(crossed)-1]==LINK_FLY,"off and down by the links of the air: %v",crossed)
    // It may arrive still falling onto the platform: there it stands.
    for _ in 0..<60 {agents_test_step(&f,&g)}
    at,_:=core.get(core.read(&g.worlds),e)
    testing.expectf(t,abs(at.position.y-4)<0.1 && at.position.x>17 && at.position.x<23,"on the platform, at %v",at.position)
}

// An agent that no class holds fails where it is sent, and says so once, as
// any other that cannot get there.
@(test)
an_agent_no_class_holds_fails_and_says_so_once :: proc(t:^testing.T) {
    f:Nav_Test
    nav_test_init(&f)
    defer nav_test_destroy(&f)
    g:Agents_Test
    agents_test_init(&g)
    defer agents_test_destroy(&g)
    e:=core.create(&f.entities)
    core.add(&f.transforms,e,core.Transform{{2,0,2},1,{1,1,1}})
    core.add(&f.colliders,e,phys.collider_character(2,4))
    core.add(&f.characters,e,phys.character_default())
    core.add(&f.moves,e,phys.Character_Move{})
    core.add(&f.motions,e,core.Motion{})
    core.add(&g.walks,e,phys.WALK_DEFAULT)
    core.add(&g.inputs,e,input.Move_Input{})
    core.add(&g.agents,e,NAV_AGENT_DEFAULT)
    nav_move_to(&g.requests,e,{4,0,2})
    failed:=0
    for _ in 0..<3 {
        agents_test_step(&f,&g)
        for event in g.events.queue.items {if event.entity==e && event.kind==.Failed {failed+=1}}
    }
    p,_:=core.get(core.read(&g.paths),e)
    testing.expect(t,p.state==.Failed && failed==1)
}

// Two bodies a seat drives are asked to walk: the seated agent writes its
// Move_Input toward its way each tick and arrives, keeping the buttons of its
// seat; the other is left to its seat and stays.
@(test)
a_seated_agent_walks_where_it_is_asked_while_its_seat_drives_it :: proc(t:^testing.T) {
    f:Nav_Test
    nav_test_init(&f)
    defer nav_test_destroy(&f)
    g:Agents_Test
    agents_test_init(&g)
    defer agents_test_destroy(&g)
    nav_test_box(&f,{0,-0.5,0},{10,0.5,10})
    nav_test_settled(t,&f)
    walkers:[2]core.Entity
    for &e,i in walkers {
        e=agents_test_walker(&f,&g,{-6,0,f32(i)*4-2})
        core.add(&g.drivables,e,input.Drivable{seat=core.create(&f.entities)})
    }
    agents_test_settle(&f,&g)
    core.get(&g.agents,walkers[0]).seated=true
    held:=input.action_bit(2) // a button the seat holds
    core.get(&g.inputs,walkers[0]).buttons=held
    for e,i in walkers {nav_move_to(&g.requests,e,{6,0,f32(i)*4-2})}
    for _ in 0..<30 {agents_test_step(&f,&g)}
    seated,_:=core.get(core.read(&g.inputs),walkers[0])
    left,_:=core.get(core.read(&g.inputs),walkers[1])
    testing.expect(t,seated.move!={} && seated.buttons==held,"it steers and the seat keeps its buttons")
    testing.expect_value(t,left.move,[3]f32{})
    arrived,_,_,failed:=agents_test_travel(&f,&g,walkers[0],10)
    testing.expect(t,arrived && !failed,"the seated agent arrives")
    pose,_:=core.get(core.read(&g.worlds),walkers[0])
    stayed,_:=core.get(core.read(&g.worlds),walkers[1])
    testing.expectf(t,pose.position.x>5,"it walked to %v",pose.position)
    testing.expectf(t,abs(stayed.position.x+6)<0.1,"the other stayed at %v",stayed.position)
    testing.expect_value(t,f.problems.count,0)
}

// Six walkers patrol the paths of the AI arena of the demo, each from another
// point: up a ladder onto a platform, off it by a drop, around a blocked area
// and over a fence by a link the game crosses. Where they crowd at the start
// of a link, stepping aside pushes none off the platform; and one put off the
// level of its way plans again from where it is, as one asked elsewhere in
// the middle of a drop does once it lands.
@(test)
walkers_that_crowd_at_the_start_of_a_link_keep_to_the_mesh :: proc(t:^testing.T) {
    f:Nav_Test
    nav_test_init(&f)
    defer nav_test_destroy(&f)
    g:Agents_Test
    agents_test_init(&g)
    defer agents_test_destroy(&g)
    VAULT :: Nav_Link_Kind(7)
    ladder_user :: proc(f:^Nav_Test,g:^Agents_Test,feet:[3]f32) -> core.Entity {
        e:=agents_test_walker(f,g,feet)
        agents_test_settle(f,g)
        core.get(&g.agents,e).abilities=Nav_Abilities(1<<u32(ABILITY_LADDER))
        return e
    }
    nav_test_box(&f,{0,-0.5,0},{20,0.5,15})
    nav_test_box(&f,{11,0.9,0},{0.15,0.9,16})
    nav_test_box(&f,{-8,1.75,0},{3,1.75,3})
    nav_test_box(&f,{-8,1.75,8.5},{3,1.75,3})
    ladder:=core.create(&f.entities)
    core.add(&f.transforms,ladder,core.Transform{{-11.8,0,0},1,{1,1,1}})
    core.add(&f.links,ladder,Nav_Link{end={1.4,3.5,0},kind=LINK_LADDER,two_way=true,area=AREA_WALKABLE,abilities=Nav_Abilities(1<<u32(ABILITY_LADDER))})
    vault:=core.create(&f.entities)
    core.add(&f.transforms,vault,core.Transform{{10.2,0,0},1,{1,1,1}})
    core.add(&f.links,vault,Nav_Link{end={1.6,0,0},kind=VAULT,two_way=true,area=AREA_WALKABLE})
    zone:=core.create(&f.entities)
    core.add(&f.transforms,zone,core.Transform{{4,0,0},1,{1,1,1}})
    core.add(&f.areas,zone,Nav_Area{half={3,1.02,6},area=AREA_BLOCKED})
    nav_test_settled(t,&f)
    points:=[4]mm.Vec3{{-15,0,-10},{-7,3.5,1},{17,0,10},{17,0,-10}}
    walkers:[6]core.Entity
    next,reached,crossing:[6]int
    heights,drops:[6]f32
    for &e,i in walkers {
        e=ladder_user(&f,&g,{-15+f32(i%4)*1.5,0,-12+f32(i/4)*1.5})
        next[i]=i%4
        nav_move_to(&g.requests,e,points[next[i]])
    }
    fell:=0
    for _ in 0..<60*120 {
        agents_test_step(&f,&g)
        for e,i in walkers {
            p,_:=core.get(core.read(&g.paths),e)
            pose,_:=core.get(core.read(&g.worlds),e)
            // A fall of a level while it walks, not the end of a drop that lands it.
            drops[i]=drops[i]+heights[i]-pose.position.y if p.state!=.Crossing && pose.position.y<heights[i] else 0
            if drops[i]>1 {fell+=1}
            heights[i]=pose.position.y
            // The game crosses the fence a while after it starts, as the guards of the demo.
            if p.state==.Crossing && p.manual {
                crossing[i]+=1
                if crossing[i]==36 {
                    core.push(&f.requests.queue,phys.Body_Request{entity=e,kind=.Teleport,position=p.to,rotation=1})
                    nav_crossing_done(&g.requests,e)
                }
                continue
            }
            crossing[i]=0
            if p.state!=.Arrived && p.state!=.Failed {continue}
            if p.state==.Arrived {reached[i]+=1}
            next[i]=(next[i]+1)%len(points)
            nav_move_to(&g.requests,e,points[next[i]])
        }
    }
    testing.expectf(t,fell==0,"walkers fell off a level for %d ticks without crossing a link",fell)
    for e,i in walkers {
        pose,_:=core.get(core.read(&g.worlds),e)
        p,_:=core.get(core.read(&g.paths),e)
        testing.expectf(t,reached[i]>=4,"walker %d reached %d points, at %v, %v",i,reached[i],pose.position,p.state)
    }
    // Put down off the platform as it walks on it, it climbs back by the ladder.
    e:=ladder_user(&f,&g,{-10,3.5,-2})
    nav_move_to(&g.requests,e,{-6,3.5,2})
    for _ in 0..<10 {agents_test_step(&f,&g)}
    core.push(&f.requests.queue,phys.Body_Request{entity=e,kind=.Teleport,position={-9,0,-5},rotation=1})
    arrived,_,crossed,_:=agents_test_travel(&f,&g,e,30)
    testing.expectf(t,arrived && len(crossed)>0 && crossed[0]==LINK_LADDER,"it arrives %v by the links %v",arrived,crossed)
    // Asked elsewhere as it jumps to the roof beside, out of reach of any mesh.
    nav_move_to(&g.requests,e,{-8,3.5,9})
    for _ in 0..<60*10 {
        agents_test_step(&f,&g)
        p,_:=core.get(core.read(&g.paths),e)
        pose,_:=core.get(core.read(&g.worlds),e)
        if p.state==.Crossing && p.kind==LINK_JUMP && abs(pose.position.z-4.25)<0.3 {break}
    }
    nav_move_to(&g.requests,e,{-2,0,-8})
    arrived,_,_,_=agents_test_travel(&f,&g,e,30)
    testing.expect(t,arrived,"it goes on from where it lands")
    testing.expect_value(t,f.problems.count,0)
}

// Whether a copy holds what another does: the meshes, and what the looks keep of them.
@(private="file")
nav_test_same :: proc(a,b:^Navigation) -> bool {
    if a.count!=b.count || a.ready!=b.ready || a.revision!=b.revision || a.settings!=b.settings || a.stats!=b.stats || a.uid!=b.uid {return false}
    for i in 0..<a.count {
        x,y:=&a.classes[i],&b.classes[i]
        if x.class!=y.class || x.filter!=y.filter || x.config!=y.config || x.volume_config!=y.volume_config {return false}
        if x.pending!=y.pending || x.ready!=y.ready || x.loading!=y.loading || x.linking!=y.linking || x.marks.count!=y.marks.count {return false}
        it:=base.hash_map_iterator(&x.marks)
        for key,mark in base.hash_map_iterate(&it) {
            other:=base.hash_map_ptr(&y.marks,key)
            if other==nil || other^!=mark^ {return false}
        }
        if !core.value_equal(&x.mesh,&y.mesh,type_info_of(ai.Nav_Mesh)) || !core.value_equal(&x.volume,&y.volume,type_info_of(ai.Nav_Volume)) || !core.value_equal(&x.coarse,&y.coarse,type_info_of(ai.Nav_Coarse)) {return false}
    }
    return true
}

// The copy a history keeps takes the meshes again only when a build changed
// them, and always holds what a whole copy does: also of a world that went
// back to an older copy and built other meshes from there.
@(test)
a_kept_navigation_copies_its_meshes_again_only_when_a_build_changed_them :: proc(t:^testing.T) {
    tracking:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracking,context.allocator)
    defer mem.tracking_allocator_destroy(&tracking)
    kept,whole,first:Navigation
    defer {navigation_free(&kept);navigation_free(&whole);navigation_free(&first)}
    f:Nav_Test
    nav_test_init(&f)
    defer nav_test_destroy(&f)
    nav_test_box(&f,{0,-0.5,0},{10,0.5,10})
    nav_test_settled(t,&f)
    // How many allocations the copy a history keeps makes of the world as it is, and whether it is what a whole copy holds.
    copies :: proc(t:^testing.T,f:^Nav_Test,tracking:^mem.Tracking_Allocator,kept,whole:^Navigation,what:string) -> (allocations:i64) {
        {
            context.allocator=mem.tracking_allocator(tracking)
            before:=tracking.total_allocation_count
            testing.expectf(t,navigation_copy_kept(kept,&f.nav),"%s: no copy",what)
            allocations=tracking.total_allocation_count-before
            testing.expect(t,navigation_copy(whole,&f.nav))
        }
        testing.expectf(t,nav_test_same(kept,whole),"%s: the copy a history keeps is not what a whole copy holds",what)
        return
    }
    testing.expect(t,navigation_copy(&first,&f.nav))
    testing.expect(t,copies(t,&f,&tracking,&kept,&whole,"the first copy")>0)
    testing.expect_value(t,kept.uid,u64(0))
    // Another copy a history keeps, of the same tick as first.
    early,early_whole:Navigation
    defer {navigation_free(&early);navigation_free(&early_whole)}
    testing.expect(t,copies(t,&f,&tracking,&early,&early_whole,"another copy")>0)
    nav_test_step(&f,3)
    testing.expect_value(t,copies(t,&f,&tracking,&kept,&whole,"ticks that build nothing"),0)
    // A wall marks its tiles before any is built: the marks come with the copy, the meshes stay.
    revision:=f.nav.revision
    nav_test_box(&f,{2,1,0},{0.3,1,3})
    nav_test_step(&f)
    copies(t,&f,&tracking,&kept,&whole,"tiles marked")
    nav_test_settled(t,&f)
    testing.expect(t,f.nav.revision>revision)
    testing.expect(t,copies(t,&f,&tracking,&kept,&whole,"tiles built")>0)
    testing.expect_value(t,copies(t,&f,&tracking,&kept,&whole,"the same tiles"),0)
    // Other settings make every mesh again, for the same uid: the revision goes on, and the copy takes them.
    f.settings.classes[0].radius+=0.1
    nav_test_settled(t,&f)
    testing.expect(t,f.nav.uid==kept.kept[0] && f.nav.revision>kept.kept[1])
    testing.expect(t,copies(t,&f,&tracking,&kept,&whole,"meshes of other settings")>0)
    // The world goes back to its first copy, before any build looks at it: the copy of that tick
    // holds its meshes already, and the one of the last tick takes them.
    built:=f.nav.revision
    f.settings.classes[0].radius-=0.1
    testing.expect(t,navigation_copy(&f.nav,&first))
    testing.expect_value(t,f.nav.uid,u64(0))
    testing.expect_value(t,copies(t,&f,&tracking,&early,&early_whole,"the copy of the tick it went back to"),0)
    testing.expect(t,copies(t,&f,&tracking,&kept,&whole,"a later copy of a world that went back")>0)
    testing.expect_value(t,copies(t,&f,&tracking,&kept,&whole,"the same meshes"),0)
    // From there it builds the wall again, under another uid: other meshes, whatever the revision.
    nav_test_settled(t,&f)
    testing.expect(t,f.nav.uid!=0 && f.nav.uid!=first.kept[0] && f.nav.revision!=first.revision)
    f.nav.revision=built
    testing.expect(t,copies(t,&f,&tracking,&kept,&whole,"other meshes at the same revision")>0)
    testing.expect(t,copies(t,&f,&tracking,&early,&early_whole,"other meshes than those of the first tick")>0)
}
