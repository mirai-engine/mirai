package mirai_physics

import "core:testing"
import "core:math/rand"

@(test)
restore_rejects_a_snapshot_naming_a_hull_rebuilt_since :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    corners:=[8]Vec3{{-1,-1,-1},{1,-1,-1},{-1,1,-1},{1,1,-1},{-1,-1,1},{1,-1,1},{-1,1,1},{1,1,1}}
    counts,indices:=BOX_FACE_COUNTS,BOX_FACE_INDICES
    hull,made:=hull_create(&w,{corners[:],counts[:],indices[:]})
    testing.expect(t,made)
    body:=test_body(&w,hull,{0,3,0})
    test_steps(&w,5)
    old:=make([]byte,world_snapshot_capacity(&w))
    defer delete(old)
    size,ok:=world_snapshot(&w,old)
    testing.expect(t,ok)
    // Its body goes, and the hull is built again larger under the same handle.
    body_destroy(&w,body)
    testing.expect(t,!hull_in_use(&w,hull))
    for &corner in corners {corner*=2}
    testing.expect(t,hull_rebuild(&w,hull,{corners[:],counts[:],indices[:]}))
    test_body(&w,hull,{0,3,0})
    test_steps(&w,5)
    now:=world_hash(&w)
    testing.expect(t,!world_restore(&w,old[:size]),"the old body would take the new geometry")
    testing.expect_value(t,world_hash(&w),now)
    current:=make([]byte,world_snapshot_capacity(&w))
    defer delete(current)
    size,_=world_snapshot(&w,current)
    test_steps(&w,5)
    testing.expect(t,world_restore(&w,current[:size]))
    testing.expect_value(t,world_hash(&w),now)
}

@(test)
restore_rejects_a_snapshot_naming_geometry_this_world_lacks :: proc(t:^testing.T) {
    a,b:World
    testing.expect(t,test_world(&a) && test_world(&b))
    defer world_destroy(&a)
    defer world_destroy(&b)
    corners:=[8]Vec3{{-1,-1,-1},{1,-1,-1},{-1,1,-1},{1,1,-1},{-1,-1,1},{1,-1,1},{-1,1,1},{1,1,1}}
    counts,indices:=BOX_FACE_COUNTS,BOX_FACE_INDICES
    hull,made:=hull_create(&a,{corners[:],counts[:],indices[:]})
    testing.expect(t,made)
    test_body(&a,hull,{0,3,0})
    buffer:=make([]byte,world_snapshot_capacity(&a))
    defer delete(buffer)
    size,_:=world_snapshot(&a,buffer)
    testing.expect(t,!world_restore(&b,buffer[:size]),"b has no hull in that slot")
    testing.expect_value(t,world_stats(&b).bodies,0)
    // Registered alike, the snapshot fits.
    hull_create(&b,{corners[:],counts[:],indices[:]})
    testing.expect(t,world_restore(&b,buffer[:size]))
    testing.expect_value(t,world_hash(&b),world_hash(&a))
}

// Random worlds stepped, edited, saved and restored: the replay after a restore gives the hashes of the
// original steps, and a snapshot with any byte changed or cut short is refused without touching the world.
@(test)
random_worlds_replay_after_restore_and_refuse_damaged_snapshots :: proc(t:^testing.T) {
    rng:=rand.create(0x5a0f)
    gen:=rand.default_random_generator(&rng)
    for round in 0..<12 {
        w:World
        testing.expect(t,test_world(&w,bodies=128,contacts=1024))
        test_ground(&w)
        bodies:=8+rand.int_max(40,gen)
        previous:Body_Handle
        for i in 0..<bodies {
            p:=Vec3{rand.float32_range(-4,4,gen),rand.float32_range(0.5,8,gen),rand.float32_range(-4,4,gen)}
            geometry:Geometry
            switch rand.int_max(3,gen) {
            case 0: geometry=Box{{rand.float32_range(0.1,0.6,gen),rand.float32_range(0.1,0.6,gen),rand.float32_range(0.1,0.6,gen)}}
            case 1: geometry=Sphere{rand.float32_range(0.1,0.5,gen)}
            case: geometry=Capsule{rand.float32_range(0.1,0.3,gen),rand.float32_range(0.1,0.5,gen)}
            }
            body:=test_body(&w,geometry,p,rand.int_max(10,gen)==0?.Kinematic:.Dynamic)
            body_set_velocity(&w,body,{rand.float32_range(-3,3,gen),0,rand.float32_range(-3,3,gen)},{0,rand.float32_range(-2,2,gen),0})
            if i>0 && rand.int_max(4,gen)==0 && body_type(&w,body)==.Dynamic && body_type(&w,previous)==.Dynamic {
                anchor:=0.5*(body_position(&w,body)+body_position(&w,previous))
                fa,fb:=joint_frames(&w,previous,body,anchor,{0,0,1})
                desc:=rand.int_max(6,gen)==5?test_distance(previous,body,1,1):test_joint(&w,Test_Joint(rand.int_max(len(Test_Joint),gen)),previous,body,anchor,{0,0,1})
                desc.frame_a,desc.frame_b=fa,fb
                joint_create(&w,desc)
            }
            previous=body
        }
        settle:=rand.int_max(60,gen)
        for step in 0..<settle {
            test_scene_edit(&w,step)
            world_step(&w,1.0/60)
        }
        buffer:=make([]byte,world_snapshot_capacity(&w))
        size,ok:=world_snapshot(&w,buffer)
        testing.expect(t,ok)
        saved:=world_hash(&w)
        hashes:[30]u64
        for &hash,i in hashes {
            test_scene_edit(&w,settle+i)
            world_step(&w,1.0/60)
            hash=world_hash(&w)
        }
        // Damaged copies first: the world stays where it is.
        damaged:=make([]byte,size)
        for _ in 0..<20 {
            copy(damaged,buffer[:size])
            at:=rand.int_max(size,gen)
            damaged[at]~=u8(1+rand.int_max(255,gen))
            testing.expectf(t,!world_restore(&w,damaged),"round %d: a change at byte %d of %d was accepted",round,at,size)
        }
        testing.expect(t,!world_restore(&w,buffer[:rand.int_max(size,gen)]))
        testing.expect_value(t,world_hash(&w),hashes[len(hashes)-1])
        testing.expect(t,world_restore(&w,buffer[:size]))
        testing.expect_value(t,world_hash(&w),saved)
        for hash,i in hashes {
            test_scene_edit(&w,settle+i)
            world_step(&w,1.0/60)
            if world_hash(&w)!=hash {
                testing.expectf(t,false,"round %d: the replay diverged %d steps after the restore",round,i)
                break
            }
        }
        delete(damaged)
        delete(buffer)
        world_destroy(&w)
    }
}
