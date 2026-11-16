package host

import "core:testing"
import "mirai:std/base"
import "mirai:std/geom"

@(test)
generated_collision_and_heightfield_survive_source_changes_and_retire_together :: proc(t:^testing.T) {
    assets:Assets
    if !testing.expect(t,assets_init(&assets,{root="assets",capacity=4})) {return}
    defer assets_destroy(&assets)
    positions:=[4]geom.Vec3{{0,0,0},{1,1,0},{0,2,1},{1,3,1}}
    indices:=[6]u32{0,2,1,1,2,3}
    uvs:=[4]geom.Vec2{{0,0},{1,0},{0,1},{1,1}}
    heights:=[4]f32{0,1,2,3}
    borders:=[4]u8{1,0,1,0}
    materials:=[2]base.Asset_Id{{1,0},{2,0}}
    surfaces:=[1]u8{1}
    field:=Assets_Heightfield{heights[:],2,2,{1,1,1},{-1,2,-3},borders[:],nil,materials[:],surfaces[:]}
    edges:=[2]u8{1,4}
    mesh:=geom.Mesh{positions=positions[:],indices=indices[:],uvs=uvs[:]}
    id,created:=assets_mesh_generate(&assets,mesh,options={collision=true,heightfield=&field,no_lods=true,disabled_edges=edges[:]})
    if !testing.expect(t,created && assets_mesh_generated(&assets,id)) {return}
    positions[0],indices[0],uvs[0],heights[0]={9,9,9},3,{9,9},9
    edges[0]=0
    borders[0]=0
    materials[1],surfaces[0]={},0
    held,found:=assets_heightfield(&assets,id)
    testing.expect(t,found)
    testing.expect_value(t,held.heights[0],f32(0))
    testing.expect_value(t,held.origin,[3]f32{-1,2,-3})
    testing.expect_value(t,held.disabled_borders[0],u8(1))
    testing.expect(t,len(held.materials)==2 && held.materials[1]==base.Asset_Id{2,0} && len(held.surfaces)==1 && held.surfaces[0]==1,"the material of each cell is the generator's copy")
    testing.expect_value(t,assets_mesh_disabled_edges(&assets,id)[0],u8(1))
    buffer:geom.Mesh_Buffer
    geom.mesh_buffer_init(&buffer)
    defer geom.mesh_buffer_destroy(&buffer)
    append(&buffer.positions,geom.Vec3{10,10,10})
    append(&buffer.normals,geom.Vec3{0,1,0});append(&buffer.uvs,geom.Vec2{})
    testing.expect(t,assets_geometry(&assets,id,.None,&buffer,true))
    testing.expect_value(t,buffer.positions[1],geom.Vec3{0,0,0})
    testing.expect_value(t,buffer.indices[0],u32(1))
    testing.expect_value(t,buffer.uvs[1],geom.Vec2{0,0})
    testing.expect_value(t,len(buffer.normals),len(buffer.positions))
    testing.expect(t,buffer.normals[1].y>0.2,"missing normals are usable for generated geometry")
    geom.mesh_buffer_clear(&buffer)
    stored,colliding:=assets_collision(&assets,id,.None,.Mesh,&buffer)
    testing.expect(t,stored && colliding && len(buffer.indices)==6)
    revision:=assets.structure
    testing.expect(t,assets_mesh_release(&assets,id))
    testing.expect(t,!assets_mesh_generated(&assets,id))
    testing.expect_value(t,len(assets_mesh_disabled_edges(&assets,id)),0)
    _,found=assets_heightfield(&assets,id)
    testing.expect(t,!found && assets.structure>revision)
    geom.mesh_buffer_clear(&buffer)
    testing.expect(t,!assets_geometry(&assets,id,.None,&buffer))
    testing.expect_value(t,len(buffer.positions),0)
    next,added:=assets_mesh_generate(&assets,mesh)
    testing.expect(t,added && next!=id && assets_mesh_generated(&assets,next))
    testing.expect(t,!assets_geometry(&assets,next,.None,&buffer),"preview geometry is not retained on the CPU by default")
}

@(test)
generated_heightfield_rejects_invalid_samples_without_registering_an_asset :: proc(t:^testing.T) {
    assets:Assets
    if !testing.expect(t,assets_init(&assets,{root="assets",capacity=4})) {return}
    defer assets_destroy(&assets)
    mesh:=geom.Mesh{positions={{0,0,0},{1,0,0},{0,0,1}},indices={0,2,1}}
    heights:=[4]f32{0,0,0,0}
    cases:=[?]Assets_Heightfield{
        {heights[:],1,4,{1,1,1},{},nil,nil,nil,nil},
        {heights[:],2,3,{1,1,1},{},nil,nil,nil,nil},
        {heights[:],max(int),2,{1,1,1},{},nil,nil,nil,nil},
        {heights[:],2,2,{1,0,1},{},nil,nil,nil,nil},
        {heights[:],2,2,{1,1,1},{transmute(f32)u32(0x7f800000),0,0},nil,nil,nil,nil},
        {heights[:],2,2,{1,1,1},{},{0,0},nil,nil,nil},
        {heights[:],2,2,{1,1,1},{},{0,2,0,0},nil,nil,nil},
        {heights[:],2,2,{1,1,1},{},nil,{0,0},nil,nil},
        {heights[:],2,2,{1,1,1},{},nil,{2},nil,nil},

        {heights[:],2,2,{1,1,1},{},nil,nil,nil,{0}},
        {heights[:],2,2,{1,1,1},{},nil,nil,{base.Asset_Id{1,0},base.Asset_Id{2,0}},{2}},
        {heights[:],2,2,{1,1,1},{},nil,nil,{base.Asset_Id{1,0}},{0,0}},
    }
    for &field in cases {
        _,created:=assets_mesh_generate(&assets,mesh,options={heightfield=&field})
        testing.expect(t,!created)
    }
    heights[1]=transmute(f32)u32(0x7fc00000)
    field:=Assets_Heightfield{heights[:],2,2,{1,1,1},{},nil,nil,nil,nil}
    _,created:=assets_mesh_generate(&assets,mesh,options={heightfield=&field})
    testing.expect(t,!created)
    testing.expect_value(t,assets.stats.generated,0)
    _,created=assets_mesh_generate(&assets,mesh,options={collision=true,disabled_edges={8}})
    testing.expect(t,!created)
    _,created=assets_mesh_generate(&assets,mesh,options={collision=true,disabled_edges={0,0}})
    testing.expect(t,!created)
}

@(test)
generated_releases_log_invalidates_only_known_ids_and_falls_back_when_outdated :: proc(t:^testing.T) {
    assets:Assets
    if !testing.expect(t,assets_init(&assets,{root="assets",capacity=4})) {return}
    defer assets_destroy(&assets)
    mesh:=geom.Mesh{positions={{0,0,0},{1,0,0},{0,0,1}},indices={0,2,1}}
    first:=assets.structure
    id,created:=assets_mesh_generate(&assets,mesh)
    if !testing.expect(t,created && assets_mesh_release(&assets,id)) {return}
    changes,local:=assets_structure_changes(&assets,first)
    testing.expect(t,local && len(changes)==1 && changes[0].id==id)
    for _ in 0..<ASSETS_STRUCTURE_LOG {
        id,created=assets_mesh_generate(&assets,mesh)
        testing.expect(t,created && assets_mesh_release(&assets,id))
    }
    _,local=assets_structure_changes(&assets,first)
    testing.expect(t,!local,"a stale consumer refreshes after the bounded log was overwritten")
    previous:=assets.structure
    assets_structure_changed(&assets)
    changes,local=assets_structure_changes(&assets,previous)
    testing.expect(t,local && len(changes)==1 && changes[0].id=={},"a general asset change explicitly asks consumers to rebuild")
}

@(test)
generated_mesh_collides_with_the_collision_mesh_it_is_given :: proc(t:^testing.T) {
    assets:Assets
    if !testing.expect(t,assets_init(&assets,{root="assets",capacity=4})) {return}
    defer assets_destroy(&assets)
    drawn:=[4]geom.Vec3{{0,0,0},{2,0,0},{0,0,2},{2,0,2}}
    drawn_indices:=[6]u32{0,2,1,1,2,3}
    fine:geom.Mesh_Buffer;geom.mesh_buffer_init(&fine);defer geom.mesh_buffer_destroy(&fine)
    geom.plane_build(&fine,{2,2},2,2)
    edges:=make([]u8,len(fine.indices)/3);defer delete(edges)
    edges[1]=2
    mesh:=geom.Mesh{positions=drawn[:],indices=drawn_indices[:]}
    _,refused:=assets_mesh_generate(&assets,mesh,options={collision=true,collision_mesh=geom.mesh_buffer_view(&fine),disabled_edges={1,0}})
    testing.expect(t,!refused,"disabled edges are those of the collision mesh")
    id,created:=assets_mesh_generate(&assets,mesh,options={collision=true,collision_mesh=geom.mesh_buffer_view(&fine),disabled_edges=edges})
    if !testing.expect(t,created) {return}
    testing.expect_value(t,assets_mesh_disabled_edges(&assets,id)[1],u8(2))
    buffer:geom.Mesh_Buffer;geom.mesh_buffer_init(&buffer);defer geom.mesh_buffer_destroy(&buffer)
    stored,colliding:=assets_collision(&assets,id,.None,.Mesh,&buffer)
    testing.expect(t,stored && colliding)
    testing.expect_value(t,len(buffer.indices),len(fine.indices))
    testing.expect_value(t,len(buffer.positions),len(fine.positions))
}

// A far mesh a job encoded is published as any generated mesh, its box with
// it, and released with it.
@(test)
a_far_mesh_made_ahead_is_published_and_released :: proc(t:^testing.T) {
    assets:Assets
    if !testing.expect(t,assets_init(&assets,{root="assets",capacity=4})) {return}
    defer assets_destroy(&assets)
    positions:=[4]geom.Vec3{{0,0,0},{2,0,0},{0,0,2},{2,0,2}}
    indices:=[6]u32{0,2,1,1,2,3}
    made:Mesh_Render_Geometry
    assets_render_geometry_init(&made)
    defer assets_render_geometry_destroy(&made)
    normals:=[4]geom.Vec3{{0,1,0},{0,1,0},{0,1,0},{0,1,0}}
    testing.expect(t,assets_render_geometry_make({positions=positions[:],normals=normals[:],indices=indices[:]},nil,0,&made,assets_limits(&assets)))
    testing.expect(t,assets_render_geometry_rays(&made,assets_limits(&assets)))
    id,published:=assets_mesh_publish(&assets,&made)
    if !testing.expect(t,published && assets_mesh_generated(&assets,id)) {return}
    entry:=assets_mesh(&assets,id)
    testing.expect(t,entry!=nil && entry.bounds_max==[3]f32{2,0,2} && entry.index_count==6 && entry.vertex_count>=4)
    testing.expect(t,assets_mesh_release(&assets,id) && !assets_mesh_generated(&assets,id))
}
