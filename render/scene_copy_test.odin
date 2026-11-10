package mirai_render

import "core:testing"

@(test)
rendered_copies_keep_motion_history_by_source_owner_and_variant :: proc(t:^testing.T) {
    r:=new(Renderer);defer free(r)
    r.allocator=context.allocator
    scene_init(r)
    defer scene_destroy(r)
    vertices:=[3]Mesh_Vertex{
        {position={-1,0,-1},normal={0,1,0},color={1,0,0}},
        {position={1,0,-1},normal={0,1,0},color={1,0,0}},
        {position={0,0,1},normal={0,1,0},color={1,0,0}},
    }
    mesh,ok:=mesh_add(r,vertices[:],[]u32{0,2,1})
    testing.expect(t,ok);if !ok {return}
    descriptors:=[4]Instance_Desc{
        {object_id=42,mesh=mesh,transform=Mat4(1),tint={1,1,1}},
        {object_id=42,copy_owner=7,copy_variant=1,mesh=mesh,transform=Mat4(1),tint={1,1,1},uniform_color=true},
        {object_id=42,copy_owner=8,copy_variant=1,mesh=mesh,transform=Mat4(1),tint={1,1,1},uniform_color=true},
        {object_id=42,copy_owner=7,copy_variant=2,mesh=mesh,transform=Mat4(1),tint={1,1,1},uniform_color=true},
    }
    for &desc,i in descriptors {desc.transform[0,3]=f32(i*3)}
    scene_given(r,descriptors[:],nil,{}, {})
    testing.expect_value(t,len(r.scene.instance_keys),4)
    // Each moved at its index: the source GPU id stays shared, and each copy draws its motion.
    moved:=descriptors
    for &desc,i in moved {desc.transform[2,3]=f32(i+1)}
    testing.expect(t,scene_update(r,0,moved[:]))
    for inst,i in r.scene.instances {
        testing.expect_value(t,inst.meta.z,42)
        testing.expect_value(t,inst.prev_world,rows_3x4(descriptors[i].transform))
        testing.expect_value(t,inst.world,rows_3x4(moved[i].transform))
    }
    // Another variant at an index starts with its own new pose.
    moved[3].copy_variant=3
    testing.expect(t,scene_update(r,3,moved[3:]))
    testing.expect_value(t,r.scene.instances[3].prev_world,r.scene.instances[3].world)
}
