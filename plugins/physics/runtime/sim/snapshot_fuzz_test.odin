package mirai_physics

import "core:fmt"
import "core:mem"
import "core:testing"
import "core:math/rand"
import "mirai:std/base"

@(test)
restore_rejects_a_kept_state_naming_a_hull_rebuilt_since :: proc(t:^testing.T) {
    w,old,current:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    defer world_destroy(&old)
    defer world_destroy(&current)
    test_ground(&w)
    corners:=[8]Vec3{{-1,-1,-1},{1,-1,-1},{-1,1,-1},{1,1,-1},{-1,-1,1},{1,-1,1},{-1,1,1},{1,1,1}}
    counts,indices:=BOX_FACE_COUNTS,BOX_FACE_INDICES
    hull,made:=hull_create(&w,{corners[:],counts[:],indices[:]})
    testing.expect(t,made)
    body:=test_body(&w,hull,{0,3,0})
    test_steps(&w,5)
    testing.expect(t,test_keep(&old,&w))
    // Its body goes, and the hull is built again larger under the same handle.
    body_destroy(&w,body)
    testing.expect(t,!hull_in_use(&w,hull))
    for &corner in corners {corner*=2}
    testing.expect(t,hull_rebuild(&w,hull,{corners[:],counts[:],indices[:]}))
    test_body(&w,hull,{0,3,0})
    test_steps(&w,5)
    now:=world_hash(&w)
    testing.expect(t,!test_restore(&w,&old),"the old body would take the new geometry")
    testing.expect_value(t,world_hash(&w),now)
    testing.expect(t,test_keep(&current,&w))
    test_steps(&w,5)
    testing.expect(t,test_restore(&w,&current))
    testing.expect_value(t,world_hash(&w),now)
}

@(test)
restore_rejects_a_kept_state_naming_geometry_this_world_lacks :: proc(t:^testing.T) {
    a,b,kept:World
    testing.expect(t,test_world(&a) && test_world(&b))
    defer world_destroy(&a)
    defer world_destroy(&b)
    defer world_destroy(&kept)
    corners:=[8]Vec3{{-1,-1,-1},{1,-1,-1},{-1,1,-1},{1,1,-1},{-1,-1,1},{1,-1,1},{-1,1,1},{1,1,1}}
    counts,indices:=BOX_FACE_COUNTS,BOX_FACE_INDICES
    hull,made:=hull_create(&a,{corners[:],counts[:],indices[:]})
    testing.expect(t,made)
    test_body(&a,hull,{0,3,0})
    testing.expect(t,test_keep(&kept,&a))
    testing.expect(t,!test_restore(&b,&kept),"b has no hull in that slot")
    testing.expect_value(t,world_stats(&b).bodies,0)
    // Registered alike, the state fits.
    hull_create(&b,{corners[:],counts[:],indices[:]})
    testing.expect(t,test_restore(&b,&kept))
    testing.expect_value(t,world_hash(&b),world_hash(&a))
}

// Random worlds with what breaks, characters, joints, twins and a fluid, stepped and edited: copies kept by
// what changed hold what a whole copy holds, and one put back by what changed repeats the original steps.
@(test)
random_worlds_kept_by_what_changed_hold_and_put_back_what_whole_copies_do :: proc(t:^testing.T) {
    rng:=rand.create(0x5a0f)
    for round in 0..<6 {
        seed:=rand.uint64(rand.default_random_generator(&rng))
        w,whole:World
        kept:[3]World
        taken:[3]int
        desc:=world_desc_default()
        desc.body_capacity,desc.shape_capacity,desc.contact_capacity,desc.joint_capacity=1024,1024,8192,64
        desc.hull_capacity,desc.event_capacity,desc.character_capacity=256,256,4
        desc.breakable_capacity,desc.piece_capacity,desc.bond_capacity=8,512,4096
        testing.expect(t,world_init(&w,desc))
        test_fuzz_scene(&w,seed)
        TICKS :: 90
        hashes:[TICKS]u64
        for tick in 0..<TICKS {
            test_fuzz_edit(&w,seed,tick)
            world_step(&w,1.0/60)
            hashes[tick]=world_hash(&w)
            k:=tick%len(kept)
            whole.lineage=0
            if !test_keep(&kept[k],&w) || !test_keep(&whole,&w) {
                testing.expectf(t,false,"round %v tick %v: a copy failed",round,tick)
                break
            }
            taken[k]=tick
            if world_hash(&kept[k])!=hashes[tick] || world_hash(&whole)!=hashes[tick] {
                testing.expectf(t,false,"round %v tick %v: the copy by what changed differs in %v",round,tick,test_differs(&kept[k],&whole))
                break
            }
        }
        k:=int(seed%len(kept))
        if testing.expect(t,test_restore(&w,&kept[k])) {
            testing.expectf(t,world_hash(&w)==hashes[taken[k]],"round %v: put back, the world differs in %v",round,test_differs(&w,&kept[k]))
            for tick in taken[k]+1..<TICKS {
                test_fuzz_edit(&w,seed,tick)
                world_step(&w,1.0/60)
                if world_hash(&w)!=hashes[tick] {
                    testing.expectf(t,false,"round %v: the replay diverged %v steps after tick %v",round,tick-taken[k],taken[k])
                    break
                }
            }
        }
        for &copy in kept {world_destroy(&copy)}
        world_destroy(&whole)
        world_destroy(&w)
    }
}

// The first array of the state, or tree, whose bytes differ between two worlds.
@(private)
test_differs :: proc(a,b:^World) -> string {
    names:=[12]string{"bodies","shapes","contacts","joints","blocks","characters","joint axes","islands","fluids","breakables","pieces","bonds"}
    other:=state_arrays(b)
    for array,i in state_arrays(a) {
        size:=int(array.high)*array.size
        if array.high!=other[i].high || mem.compare(array.bytes[:size],other[i].bytes[:size])!=0 {
            for slot in 0..<int(min(array.high,other[i].high)) {
                at:=slot*array.size
                if mem.compare(array.bytes[at:][:array.size],other[i].bytes[at:][:array.size])!=0 {return fmt.tprintf("%v, slot %v",names[i],slot)}
            }
            return names[i]
        }
    }
    for &tree,i in a.trees {
        nodes:=mem.slice_to_bytes(tree.nodes[:tree.node_high])
        if tree.node_high!=b.trees[i].node_high || mem.compare(nodes,mem.slice_to_bytes(b.trees[i].nodes[:tree.node_high]))!=0 {return fmt.tprintf("tree %v",i)}
    }
    return a.state==b.state?"nothing":"World_State"
}

@(private)
test_fuzz_scene :: proc(w:^World,seed:u64) {
    rng:=rand.create(seed)
    gen:=rand.default_random_generator(&rng)
    test_ground(w)
    // Many chunks of what rests, so that a write left unstamped shows.
    rest:=BODY_DESC_DEFAULT
    rest.asleep=true
    box:=SHAPE_DESC_DEFAULT
    box.geometry=Box{{0.2,0.2,0.2}}
    for i in 0..<320 {
        rest.position={f32(i%20)-10,0.2,f32(i/20)+12}
        shape_create(w,body_create(w,rest),box)
    }
    test_wall(w,12)
    fluid_create(w,{shape=.Box,position={6,1,6},half_extents={2,1,2},density=1000})
    previous:Body_Handle
    for i in 0..<16+rand.int_max(16,gen) {
        p:=Vec3{rand.float32_range(-5,5,gen),rand.float32_range(0.5,6,gen),rand.float32_range(-5,8,gen)}
        geometry:Geometry
        switch rand.int_max(3,gen) {
        case 0: geometry=Box{{rand.float32_range(0.1,0.5,gen),rand.float32_range(0.1,0.5,gen),rand.float32_range(0.1,0.5,gen)}}
        case 1: geometry=Sphere{rand.float32_range(0.1,0.4,gen)}
        case: geometry=Capsule{rand.float32_range(0.1,0.3,gen),rand.float32_range(0.1,0.4,gen)}
        }
        body:=test_body(w,geometry,p,rand.int_max(10,gen)==0?.Kinematic:.Dynamic)
        if i>0 && rand.int_max(4,gen)==0 && body_type(w,body)==.Dynamic && body_type(w,previous)==.Dynamic {
            anchor:=0.5*(body_position(w,body)+body_position(w,previous))
            fa,fb:=joint_frames(w,previous,body,anchor,{0,0,1})
            desc:=rand.int_max(6,gen)==5?test_distance(previous,body,1,1):test_joint(w,Test_Joint(rand.int_max(len(Test_Joint),gen)),previous,body,anchor,{0,0,1})
            desc.frame_a,desc.frame_b=fa,fb
            joint_create(w,desc)
        }
        previous=body
    }
    character_create(w,CHARACTER_DESC_DEFAULT,{-6,0,-4})
    character_create(w,CHARACTER_DESC_DEFAULT,{6,0,6})
}

// What a game does between ticks, the same for the same seed, tick and state.
@(private)
test_fuzz_edit :: proc(w:^World,seed:u64,tick:int) {
    rng:=rand.create(seed~u64(tick)*0x9e3779b97f4a7c15)
    gen:=rand.default_random_generator(&rng)
    random_body :: proc(w:^World,gen:rand.Generator) -> (Body_Handle,bool) {
        for _ in 0..<4 {
            h,_:=body_at(w,i32(rand.int_max(int(max(w.body_high,1)),gen)))
            if body,_:=body_read(w,h);body!=nil && body.type!=.Static && .Character not_in body.flags {return h,true}
        }
        return {},false
    }
    v:=Vec3{rand.float32_range(-4,4,gen),rand.float32_range(-1,4,gen),rand.float32_range(-4,4,gen)}
    for _ in 0..<rand.int_max(3,gen) {
        body,found:=random_body(w,gen)
        switch rand.int_max(16,gen) {
        case 0: if found {body_set_velocity(w,body,v,v.zxy)}
        case 1: if found {body_set_transform(w,body,body_position(w,body)+0.2*v,QUAT_IDENTITY)}
        case 2: if found {body_apply_impulse_at(w,body,20*v,body_center(w,body)+{0.1,0,0})}
        case 3: if found {body_destroy(w,body)}
        case 4: test_body(w,Box{{0.2,0.2,0.2}},{v.x,5,v.z})
        case 5: if found {body_set_type(w,body,body_type(w,body)==.Dynamic?.Kinematic:.Dynamic)}
        case 6:
            if !found {break}
            shapes:[1]Shape_Handle
            if body_shapes(w,body,shapes[:])==0 {break}
            shape_set_material(w,shapes[0],rand.float32_range(0,1,gen),rand.float32_range(0,1,gen))
            if rand.int_max(2,gen)==0 {shape_set_surface(w,shapes[0],{},rand.int_max(2,gen)==0,0)}
        case 7:
            for &joint,slot in w.joints[:w.joint_high] {
                if joint.generation&1==0 {continue}
                linear,angular:=w.joint_axes[slot].linear_axes,w.joint_axes[slot].angular_axes
                angular[0]={motion=.Limited,lower=-0.5,upper=0.5,drive={.Velocity},velocity=v.x,max_force=50}
                joint_set_axes(w,joint_handle(w,i32(slot)),linear,angular)
                break
            }
        case 8:
            for &ch,slot in w.characters[:w.character_high] {
                if ch.generation&1==0 {continue}
                h:=Character_Handle(base.handle_make(u32(slot),ch.generation))
                if rand.int_max(3,gen)==0 {character_launch(w,h,{0,4,0})} else {character_set_move(w,h,{ground={velocity=v*{1,0,1},force=3200},air={velocity=v*{1,0,1},force=400},yaw=v.x})}
            }
        case 9:
            breakables_strain(w,{point={v.x*0.4,1,0},radius=0.8},rand.float32_range(200,2000,gen),v)
        case 10: test_cannonball(w,{v.x*0.5,1,4},{0,0,-25})
        case 11: if found {body_set_awake(w,body,false)}
        case 12: fluid_set(w,fluid_handle(w,0),{shape=.Box,position={6+v.x*0.2,1,6},half_extents={2,1,2},density=1000})
        case 13: if found {body_rest(w,body,body_position(w,body),QUAT_IDENTITY)}
        case 14:
            if !found {break}
            if rand.int_max(2,gen)==0 {body_set_twin(w,body,{{0,0,8},QUAT_IDENTITY},{0,0,0},{0,0,1})} else {body_clear_twin(w,body)}
        case 15:
            if !found {break}
            body_set_damping(w,body,rand.float32_range(0,1,gen),rand.float32_range(0,1,gen))
            body_set_gravity_scale(w,body,rand.float32_range(0.5,1.5,gen))
            body_set_user_data(w,body,u64(tick))
        }
    }
}
