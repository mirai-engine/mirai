package render

import "base:runtime"
import "core:math/rand"
import "core:testing"
import "mirai:core"
import "mirai:host"
import gpu "mirai:render"

// What render_sync gives the renderer is what changed: nothing in a frame
// where nothing did, the instances that moved, and of the lights only the one
// that moved.
@(test)
the_sync_gives_the_renderer_only_what_changed :: proc(t:^testing.T) {
    f:=new(Sync_Fixture);defer free(f)
    if !sync_fixture_init(t,f) {return}
    defer sync_fixture_destroy(f)
    cubes:[200]core.Entity
    for &cube,i in cubes {cube=sync_cube(f,f32(i))}
    lights:[8]core.Entity
    for &light,i in lights {
        light=core.create(&f.world.entities)
        core.add(&f.world.worlds,light,core.World_Transform{transform={position={f32(i),3,0},rotation=1,scale=1},previous={position={f32(i),3,0},rotation=1,scale=1}})
        core.add(&f.world.points,light,POINT_LIGHT_DEFAULT)
    }
    sync_frame(f)
    s:=&f.renderer.scene
    testing.expect(t,f.sync.synced && len(s.instances)==len(cubes) && len(s.lights)==len(lights))
    testing.expect_value(t,sync_frame(f),0)
    testing.expect(t,!s.lights_changed && s.changes.count==0 && !s.changes.all,"a frame where nothing changed gives nothing")

    moved:=[10]int{3,17,18,40,41,42,99,150,151,199}
    for at in moved {
        world:=core.edit(&f.world.worlds,cubes[at])
        world.transform.position.y=2
        world.previous=world.transform
    }
    testing.expect_value(t,sync_frame(f),len(moved))
    testing.expect(t,!s.lights_changed,"no light moved")
    for cube,i in cubes {testing.expect_value(t,s.instances[i].world[1][3],f32(i==3 || i==17 || i==18 || i>=40 && i<=42 || i==99 || i==150 || i==151 || i==199?2:0))}
    testing.expect_value(t,sync_frame(f),0)

    // A light moved alone: the renderer changes the light around it and where it was, and no instance.
    core.edit(&f.world.worlds,lights[5]).transform.position.z=1
    testing.expect_value(t,sync_frame(f),0)
    testing.expect(t,s.lights_changed && s.changes.count==2,"the light that moved goes to the renderer alone")
    for light,i in s.lights {testing.expect_value(t,light.position_range.z,f32(f.sync.light_owners[i].entity==lights[5]?1:0))}
    // One that goes gives its place to the last, and one hidden with what it hangs from is no light.
    core.add(&f.world.hidden,lights[0],Hidden{})
    core.remove(&f.world.points,lights[2])
    sync_frame(f)
    testing.expect(t,len(f.sync.light_owners)==6 && len(s.lights)==6)
    for owner,i in f.sync.light_owners {
        testing.expect(t,owner.entity!=lights[0] && owner.entity!=lights[2] && core.entity_map_get(&f.sync.lit[.Point],owner.entity)^==u32(i))
    }
    core.remove(&f.world.hidden,lights[0])
    sync_frame(f)
    testing.expect_value(t,len(s.lights),7)
}

// The instances the renderer has, by the object each is drawn for.
@(private="file")
given :: proc(t:^testing.T,s:^gpu.Scene_State) -> (by_object:map[u64]gpu.Gpu_Instance) {
    for instance,i in s.instances {
        object:=s.instance_keys[i].object
        testing.expectf(t,object not_in by_object,"object %x is drawn twice",object)
        by_object[object]=instance
    }
    return
}

// What two scenes differ in, for whoever compares what the renderer was given.
@(private="file")
same :: proc(t:^testing.T,a,b:map[u64]gpu.Gpu_Instance,what:string) {
    testing.expectf(t,len(a)==len(b),"%s: %d instances and %d",what,len(a),len(b))
    for object,instance in a {
        one,other:=instance,b[object]
        if !testing.expectf(t,object in b,"%s: object %x is missing",what,object) {continue}
        // The cut its rays trace it with is chosen from the eye, in the frame.
        one.meta.x&=gpu.INSTANCE_MESH_MASK
        other.meta.x&=gpu.INSTANCE_MESH_MASK
        one.prev_world,other.prev_world={},{}
        testing.expectf(t,one==other,"%s: object %x is drawn as %v, not %v",what,object,one,other)
    }
}

// A world of the fixture with meshes, a hierarchy, values and lights.
@(private="file")
populate :: proc(w:^Render_World,entities:[]core.Entity) {
    for &e,i in entities {
        e=core.create(&w.entities)
        place:=core.World_Transform{transform={position={f32(i%8),f32(i/8),0},rotation=1,scale=1},previous={position={f32(i%8),f32(i/8),0},rotation=1,scale=1}}
        core.add(&w.worlds,e,place)
        if i%5!=4 {core.add(&w.meshes,e,Mesh_Renderer{shape=i%3==0?.Sphere:.Cube})}
        if i%4==1 {core.add(&w.values,e,Material_Values{color={1,0.5,0.25,i%8==1?0.5:1}})}
        if i%7==3 {core.add(&w.points,e,POINT_LIGHT_DEFAULT)}
        if i%9==4 {core.add(&w.spots,e,SPOT_LIGHT_DEFAULT)}
        if i>0 && i%6==0 {core.add(&w.parents,e,core.Parent{entity=entities[i-1]})}
    }
}

// Another world shown in place of the one the renderer has is given through
// the same changes, of every row: a copy of it is drawn the same.
@(test)
a_world_copy_shown_in_its_place_is_drawn_the_same :: proc(t:^testing.T) {
    f:=new(Sync_Fixture);defer free(f)
    if !sync_fixture_init(t,f) {return}
    defer sync_fixture_destroy(f)
    entities:[48]core.Entity
    populate(&f.world,entities[:])
    sync_frame(f,{index=1,generation=1})
    s:=&f.renderer.scene
    first:=given(t,s);defer delete(first)
    lights:=make([]gpu.Gpu_Light,len(s.lights));defer delete(lights)
    copy(lights,s.lights[:])
    testing.expect(t,len(first)>30 && len(lights)>5)
    copied:Render_World
    if !core.test_world_init(t,&copied,test_types) {return}
    defer core.test_world_destroy(&copied)
    populate(&copied,entities[:])
    core.test_world_settle(&copied)
    world_sync(&copied,&f.sync,&f.app,{index=2,generation=1},core.ref(&copied.hierarchy))
    testing.expect(t,f.sync.synced && f.sync.world==core.World_Id{index=2,generation=1})
    second:=given(t,s);defer delete(second)
    same(t,first,second,"the copy")
    testing.expect_value(t,len(s.lights),len(lights))
    for light,i in s.lights {testing.expect_value(t,light,lights[i])}
    // And the first one again, with what changed in it meanwhile.
    core.remove(&f.world.meshes,entities[0])
    sync_frame(f,{index=1,generation=1})
    testing.expect_value(t,len(s.instances),len(first)-1)
}

// However the rows change, what the renderer has is what a sync that kept
// nothing gives it for the same world: entities that come and go, are hidden,
// hang from others, fade, move to no place or to one that is not a number,
// and lose their mesh or their light.
@(test)
changes_leave_the_renderer_what_a_world_given_whole_does :: proc(t:^testing.T) {
    f:=new(Sync_Fixture);defer free(f)
    if !sync_fixture_init(t,f) {return}
    defer sync_fixture_destroy(f)
    w:=&f.world
    entities:[64]core.Entity
    populate(w,entities[:])
    sync_frame(f)
    random:=rand.create(7)
    context.random_generator=runtime.default_random_generator(&random)
    for frame in 0..<160 {
        for _ in 0..<1+rand.int_max(6) {
            at:=rand.int_max(len(entities))
            e:=entities[at]
            switch rand.int_max(12) {
            case 0: if core.has(&w.meshes,e) {core.remove(&w.meshes,e)} else {core.add(&w.meshes,e,Mesh_Renderer{shape=rand.int_max(2)==0?.Cube:.None})}
            case 1: if core.has(&w.hidden,e) {core.remove(&w.hidden,e)} else {core.add(&w.hidden,e,Hidden{})}
            case 2: if core.has(&w.values,e) {core.edit(&w.values,e).color.a=rand.int_max(2)==0?1:0.25} else {core.add(&w.values,e,Material_Values{color={0,1,0,1}})}
            case 3: if core.has(&w.values,e) {core.edit(&w.values,e).color.r=rand.float32()}
            case 4: if world:=core.edit(&w.worlds,e);world!=nil {world.transform.position.z=rand.float32();world.previous=world.transform}
            case 5: if world:=core.edit(&w.worlds,e);world!=nil {world.transform.scale=rand.int_max(3)==0?0:1;world.previous=world.transform}
            case 6: if core.has(&w.elsewhere,e) {core.remove(&w.elsewhere,e)} else {core.add(&w.elsewhere,e,Drawn_Elsewhere{})}
            case 7: if core.has(&w.points,e) {core.remove(&w.points,e)} else {core.add(&w.points,e,POINT_LIGHT_DEFAULT)}
            case 8: if core.has(&w.worlds,e) {core.remove(&w.worlds,e)} else {core.add(&w.worlds,e,core.World_Transform{transform={rotation=1,scale=1},previous={rotation=1,scale=1}})}
            case 9: if mesh:=core.edit(&w.meshes,e);mesh!=nil {mesh.shape=Shape(rand.int_max(len(Shape)))}
            case 10: if core.has(&w.layers,e) {core.remove(&w.layers,e)} else {core.add(&w.layers,e,Layers{mask=2})}
            case 11:
                // It goes with everything it has, and another takes its index.
                core.destroy(&w.entities,e)
                entities[at]=sync_cube(f,f32(frame))
            }
        }
        // A visual instance drawn in place of a mesh of the world, in some frames.
        replacing:=frame%3==0
        if replacing {
            extra,usable:=mesh_instance(&f.assets,{shape=.Cone},1)
            extra.object_id,extra.replace_source=u64(entities[frame%len(entities)]),true
            testing.expect(t,usable && host.extras_instance_add(&f.app.extras,extra))
        }
        sync_frame(f)
        if !testing.expectf(t,f.sync.synced && len(f.renderer.scene.instances)==len(f.sync.drawn.entities)+int(replacing),"frame %d: %d instances of %d",frame,len(f.renderer.scene.instances),len(f.sync.drawn.entities)) {return}
        // In a frame after one with the visual instance: the mesh it replaced shows again.
        if frame%15!=13 {continue}
        s:=&f.renderer.scene
        changed:=given(t,s)
        lights:=len(s.lights)
        whole:Render_Sync
        whole.world,whole.synced,whole.assets_appearance=f.sync.world,true,f.assets.appearance
        world_sync(w,&whole,&f.app,hierarchy=core.ref(&w.hierarchy))
        sync_free(&whole)
        once:=given(t,s)
        same(t,changed,once,"what the changes left")
        testing.expect_value(t,len(s.lights),lights)
        delete(changed);delete(once)
        // The renderer has its instances in the order of that sync: this one gives them again.
        f.sync.synced=false
    }
}

// What takes the place of the mesh of an entity: a pose a library gives it,
// drawn as its own instance, and a visual instance of a frame, which hides it
// while it comes.
@(test)
a_posed_mesh_is_the_instance_of_its_entity_and_a_visual_one_hides_it :: proc(t:^testing.T) {
    f:=new(Sync_Fixture);defer free(f)
    if !sync_fixture_init(t,f) {return}
    defer sync_fixture_destroy(f)
    a,b:=sync_cube(f,0),sync_cube(f,2)
    posed:Posed_Meshes
    defer core.value_free(&posed,type_info_of(Posed_Meshes))
    frame :: proc(f:^Sync_Fixture,posed:^Posed_Meshes) -> int {return sync_frame(f,posed=posed)}
    frame(f,&posed)
    s:=&f.renderer.scene
    cube,sphere:=host.assets_shape(&f.assets,.Cube).handle,host.assets_shape(&f.assets,.Sphere).handle
    mesh_of :: proc(s:^gpu.Scene_State,at:int) -> gpu.Mesh_Handle {return gpu.Mesh_Handle(s.instances[at].meta.x&gpu.INSTANCE_MESH_MASK)}
    testing.expect(t,mesh_of(s,0)==cube && mesh_of(s,1)==cube)
    testing.expect(t,posed_set(&posed,b,{mesh=sphere}))
    testing.expect_value(t,frame(f,&posed),1)
    testing.expect(t,mesh_of(s,0)==cube && mesh_of(s,1)==sphere && len(s.instances)==2,"the pose is drawn as the instance of its entity")
    // And where its entity is: with the offset of what it hangs from, as any mesh.
    root:=core.create(&f.world.entities)
    core.add(&f.world.worlds,root,core.World_Transform{transform={rotation=1,scale=1},previous={rotation=1,scale=1}})
    core.add(&f.world.offsets,root,Draw_Offset{offset={0,2,0}})
    core.add(&f.world.parents,b,core.Parent{entity=root})
    core.test_world_settle(&f.world)
    core.hierarchy_settle(&f.world.hierarchy,core.read(&f.world.parents),&f.world.entities)
    frame(f,&posed)
    testing.expect(t,mesh_of(s,1)==sphere && s.instances[1].world[1][3]==2 && s.instances[0].world[1][3]==0,"a posed mesh is drawn with the offset of what it hangs from")
    // Given again as it is, nothing is made; one the renderer does not have shows the mesh of the entity.
    testing.expect(t,posed_set(&posed,b,{mesh=sphere}) && len(posed.changed)==0)
    testing.expect(t,posed_set(&posed,a,{mesh=gpu.Mesh_Handle(9999)}))
    frame(f,&posed)
    testing.expect(t,mesh_of(s,0)==cube && mesh_of(s,1)==sphere)
    posed_drop(&posed,b)
    frame(f,&posed)
    testing.expect_value(t,mesh_of(s,1),cube)

    hidden :: proc(s:^gpu.Scene_State,at:int) -> bool {return s.instances[at].meta.w&gpu.INSTANCE_FLAG_HIDDEN!=0}
    for pass in 0..<4 {
        shown:=pass==1 || pass==2
        if shown {
            // Faded: it shows a row derived for it, which goes when it stops coming.
            extra,usable:=mesh_instance(&f.assets,{shape=.Cone},1,Material_Values{color={0,1,0,0.5}})
            extra.object_id,extra.replace_source=u64(a),true
            // One of a mesh the renderer does not have is not drawn, and takes nothing with it.
            lost:=extra
            lost.mesh=gpu.Mesh_Handle(9999)
            testing.expect(t,usable && host.extras_instance_add(&f.app.extras,extra) && host.extras_instance_add(&f.app.extras,lost))
        }
        touched:=frame(f,&posed)
        testing.expectf(t,len(s.instances)==(shown?3:2) && hidden(s,0)==shown && !hidden(s,1),"pass %d: %d instances, the mesh hidden %v",pass,len(s.instances),hidden(s,0))
        // While it keeps coming, or keeps away, nothing is given again.
        if pass==2 || pass==3 {testing.expect_value(t,touched,pass==2?0:1)}
        testing.expect_value(t,f.assets.stats.derived,shown?1:0)
    }
    // One that replaces nothing leaves the world as it is, and still gives back its row.
    for pass in 0..<3 {
        if pass==0 {
            ghost,usable:=mesh_instance(&f.assets,{shape=.Cone},1,Material_Values{color={1,0,0,0.25}})
            testing.expect(t,usable && host.extras_instance_add(&f.app.extras,ghost))
        }
        touched:=frame(f,&posed)
        testing.expect(t,f.assets.stats.derived==(pass==0?1:0) && touched==(pass==0?1:0) && len(s.instances)==(pass==0?3:2))
    }
}

// What render_sync asks memory for, with the memory ending at each request
// in turn: a scene it has no memory for is empty and is made again by a later
// frame, and with memory enough it holds every instance.
@(test)
a_sync_without_memory_leaves_an_empty_scene_until_a_frame_makes_it :: proc(t:^testing.T) {
    f:=new(Sync_Fixture);defer free(f)
    if !sync_fixture_init(t,f) {return}
    entities:[24]core.Entity
    populate(&f.world,entities[:])
    core.test_world_settle(&f.world)
    limit:=Memory_Limit{owner=context.allocator,remaining=max(int)}
    limited:=runtime.Allocator{memory_limit_proc,&limit}
    defer {context.allocator=limited;sync_fixture_destroy(f)}
    done,refused:=false,false
    for served in 0..<256 {
        {
            context.allocator=limited
            limit.remaining=served
            world_sync(&f.world,&f.sync,&f.app,hierarchy=core.ref(&f.world.hierarchy))
            limit.remaining=max(int)
        }
        if done=f.sync.synced;done {break}
        refused=true
        testing.expectf(t,len(f.renderer.scene.instances)==0,"a scene refused with %d requests served is empty",served)
    }
    testing.expect(t,done && refused,"refused without memory, and with it it is made")
    testing.expect_value(t,len(f.renderer.scene.instances),len(f.sync.drawn.entities))
    testing.expect(t,len(f.sync.drawn.entities)>15)
}
