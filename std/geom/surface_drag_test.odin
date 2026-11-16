package geom

import "core:testing"
import mm "mirai:std/math"

@(test)
surface_drag_does_not_turn_the_tip_from_a_tiny_mouse_movement :: proc(t:^testing.T) {
    mesh,out:Mesh_Buffer
    mesh_buffer_init(&mesh);mesh_buffer_init(&out)
    defer mesh_buffer_destroy(&mesh);defer mesh_buffer_destroy(&out)
    plane_build(&mesh,{4,4},8,8)
    work:Mesh_Surface_Workspace;mesh_surface_workspace_init(&work);defer mesh_surface_workspace_destroy(&work)
    delta:=Vec3{0.0001,0,0}
    _,error:=mesh_surface_edit(&work,mesh_buffer_view(&mesh),{kind=.Drag,normal={0,1,0},delta=delta,radius=2,amount=1,hardness=0.5},&out)
    if !testing.expect_value(t,error,Mesh_Surface_Error.None) {return}
    largest:=f64(0)
    for p,i in mesh.positions {largest=max(largest,dlength(dvec(out.positions[i])-dvec(p)))}
    testing.expect(t,largest<=dlength(dvec(delta))*1.01)
    for value in ([4]f32{f32(0h7fc00000),f32(0h7f800000),2,-2}) {
        _,error=mesh_surface_edit(&work,mesh_buffer_view(&mesh),{kind=.Drag,rotation=quaternion(w=value,x=0,y=0,z=0),delta=delta,radius=2,amount=1},&out)
        testing.expect_value(t,error,Mesh_Surface_Error.Invalid_Brush)
        testing.expect_value(t,len(out.positions),0)
    }
}

@(test)
surface_hardness_moves_the_tip_rigidly_and_blends_into_the_surrounding_mesh :: proc(t:^testing.T) {
    mesh,out:Mesh_Buffer
    mesh_buffer_init(&mesh);mesh_buffer_init(&out)
    defer mesh_buffer_destroy(&mesh);defer mesh_buffer_destroy(&out)
    plane_build(&mesh,{4,4},8,8)
    work:Mesh_Surface_Workspace;mesh_surface_workspace_init(&work);defer mesh_surface_workspace_destroy(&work)
    _,error:=mesh_surface_edit(&work,mesh_buffer_view(&mesh),{kind=.Sculpt,normal={0,1,0},radius=2,amount=3,hardness=0.5},&out)
    testing.expect_value(t,error,Mesh_Surface_Error.None)
    for p,i in mesh.positions {
        distance:=dlength(dvec(p))
        if distance<=1 {testing.expect_value(t,out.positions[i],p+Vec3{0,3,0})}
        if distance>=2 {testing.expect_value(t,out.positions[i],p)}
        if distance>1 && distance<2 {testing.expect(t,out.positions[i].y>0 && out.positions[i].y<3)}
    }
}

@(test)
surface_drag_turns_the_tip_with_the_path_and_keeps_its_cross_section :: proc(t:^testing.T) {
    mesh,out:Mesh_Buffer
    mesh_buffer_init(&mesh);mesh_buffer_init(&out)
    defer mesh_buffer_destroy(&mesh);defer mesh_buffer_destroy(&out)
    plane_build(&mesh,{4,4},8,8)
    work:Mesh_Surface_Workspace;mesh_surface_workspace_init(&work);defer mesh_surface_workspace_destroy(&work)
    _,error:=mesh_surface_edit(&work,mesh_buffer_view(&mesh),{kind=.Drag,rotation=mm.quat_between({0,1,0},{1,0,0}),delta={1,0,0},radius=2,amount=1,hardness=0.5},&out)
    testing.expect_value(t,error,Mesh_Surface_Error.None)
    for p,i in mesh.positions {
        if dlength(dvec(p))<=1 {
            testing.expect(t,dlength(dvec(out.positions[i])-DVec3{1,-f64(p.x),f64(p.z)})<1e-5)
        }
        if dlength(dvec(p))>=2 {testing.expect_value(t,out.positions[i],p)}
    }
}
