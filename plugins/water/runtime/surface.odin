package water

import "core:math"
import "core:math/linalg"
import "core:mem"
import "mirai:core"
import render "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import geom "mirai:std/geom"
import mm "mirai:std/math"
import phys "plugins:physics/runtime"

// The surface of a plane of water: a grid around the camera, finest at its
// middle, whose rings double their cells outwards. The cells of a ring next
// to the finer level take its vertices on that side, so no edge of one level
// ends in the middle of an edge of the other.

SURFACE_CELL :: f32(0.5) // m, of the finest level
SURFACE_HALF :: 32       // cells of a level from its middle to its edge
SURFACE_LEVELS :: 9      // the last reaches SURFACE_CELL*SURFACE_HALF*2^(SURFACE_LEVELS-1) from the middle
SURFACE_STEP :: SURFACE_CELL*8 // m the grid moves by as it follows the camera

// The vertices and triangles of the grid, facing +Y, in metres around its middle.
surface_build :: proc(out:^geom.Mesh_Buffer) {
    clear(&out.positions);clear(&out.normals);clear(&out.uvs);clear(&out.colors);clear(&out.indices);clear(&out.materials)
    // Vertices by their place in cells of the finest level.
    at:=make(map[[2]i32]u32,context.temp_allocator)
    vertex :: proc(out:^geom.Mesh_Buffer,at:^map[[2]i32]u32,x,z:i32) -> u32 {
        if index,found:=at[{x,z}];found {return index}
        index:=u32(len(out.positions))
        p:=geom.Vec3{f32(x)*SURFACE_CELL,0,f32(z)*SURFACE_CELL}
        append(&out.positions,p)
        append(&out.normals,geom.Vec3{0,1,0})
        append(&out.uvs,geom.Vec2{p.x,p.z})
        at[{x,z}]=index
        return index
    }
    // Counter-clockwise seen from above, as plane_build.
    triangle :: proc(out:^geom.Mesh_Buffer,at:^map[[2]i32]u32,a,b,c:[2]i32) {
        append(&out.indices,vertex(out,at,a.x,a.y),vertex(out,at,c.x,c.y),vertex(out,at,b.x,b.y))
    }
    for level in 0..<SURFACE_LEVELS {
        size:=i32(1)<<u32(level) // of a cell of the level, in cells of the finest
        for j in -SURFACE_HALF..<SURFACE_HALF {
            for i in -SURFACE_HALF..<SURFACE_HALF {
                // The hole of a ring is the level inside it.
                inner:=level>0 && i>= -SURFACE_HALF/2 && i<SURFACE_HALF/2 && j>= -SURFACE_HALF/2 && j<SURFACE_HALF/2
                if inner {continue}
                x0,z0,x1,z1:=i32(i)*size,i32(j)*size,i32(i+1)*size,i32(j+1)*size
                p00,p10,p11,p01:=[2]i32{x0,z0},[2]i32{x1,z0},[2]i32{x1,z1},[2]i32{x0,z1}
                // The side of the cell on the finer level, with the vertex in its middle.
                half:=size/2
                side:=-1
                if level>0 {
                    in_x:=i>= -SURFACE_HALF/2 && i<SURFACE_HALF/2
                    in_z:=j>= -SURFACE_HALF/2 && j<SURFACE_HALF/2
                    if in_x && j==SURFACE_HALF/2 {side=0}       // the hole under its -Z side
                    if in_x && j== -SURFACE_HALF/2-1 {side=1}   // over its +Z side
                    if in_z && i==SURFACE_HALF/2 {side=2}       // beside its -X side
                    if in_z && i== -SURFACE_HALF/2-1 {side=3}   // beside its +X side
                }
                switch side {
                case 0:
                    m:=[2]i32{x0+half,z0}
                    triangle(out,&at,m,p10,p11);triangle(out,&at,m,p11,p01);triangle(out,&at,m,p01,p00)
                case 1:
                    m:=[2]i32{x0+half,z1}
                    triangle(out,&at,m,p01,p00);triangle(out,&at,m,p00,p10);triangle(out,&at,m,p10,p11)
                case 2:
                    m:=[2]i32{x0,z0+half}
                    triangle(out,&at,m,p00,p10);triangle(out,&at,m,p10,p11);triangle(out,&at,m,p11,p01)
                case 3:
                    m:=[2]i32{x1,z0+half}
                    triangle(out,&at,m,p11,p01);triangle(out,&at,m,p01,p00);triangle(out,&at,m,p00,p10)
                case:
                    triangle(out,&at,p00,p10,p11);triangle(out,&at,p00,p11,p01)
                }
            }
        }
    }
}

// water_sheet.comp.slang Sheet_Params.
@(private)
Gpu_Sheet :: struct {
    rest,written,count:u32,
    bodies:u32,     // the plane, then the dry boxes
    eye:[2]f32,     // x and z of the camera from the middle of the grid
    cell:f32,
    half_cells:f32,
    loop:u32,       // points of the loop of a lake; 0 for a plane
    _:[3]u32,
}

// The grid of a plane drawn through a deformable copy of it, which the stage
// water_sheet writes on the waves of the plane and down to the floors of the
// dry boxes that cross it: in every frame while it has waves, and only when
// the grid or the boxes move while it has none.
@(private)
Sheet :: struct {
    entity:core.Entity,
    source,mesh:render.Mesh_Handle, // the grid, and the copy of it the stage writes
    middle:[3]f32,  // of the grid in the world, on the still surface, when it was last written
    eye:[2]f32,
    body:int,       // of the plane among the bodies of the frame
    key:u64,        // of what it was last written from, without waves
    made:u64,       // of the vertex buffer it was last written in
    seen:u64,
    write:bool,     // written in this frame
    valid:bool,
    loop:[phys.FLUID_PATH_POINTS][2]f32, // x and z of the points of the loop of a lake in the world
    loop_count:int,
}

// The floor and the top of a dry box of the frame, from its row of height.
@(private)
dry_span :: proc "contextless" (b:Gpu_Body) -> (floor,top:f32) {
    up:=b.to_box[1]
    if !(abs(up.y)>0) {return}
    a,c:=(-0.5-up.w)/up.y,(0.5-up.w)/up.y
    return min(a,c),max(a,c)
}

// Whether a dry box of the frame takes out of a water of lower priority some of the surface its waves can be at.
@(private)
dry_crosses :: proc "contextless" (state:^Water_Gpu,dry,plane:int) -> bool {
    d,p:=state.bodies[dry],state.bodies[plane]
    if !(d.surface.z>0.5) || p.surface.z>0.5 || !(d.surface.w>p.surface.w) {return false}
    reach:=phys.waves_reach(state.waves[plane])
    floor,top:=dry_span(d)
    return floor<p.surface.x+reach && top>p.surface.x-reach
}

// Whether a dry box of the frame crosses the surface of some water.
@(private)
crosses_water :: proc "contextless" (state:^Water_Gpu,dry:int) -> bool {
    for j in 0..<state.count {if dry_crosses(state,dry,j) {return true}}
    return false
}

// The grid of the plane `body` of the frame around the camera: as it is generated while the plane is still
// and no dry box crosses it, else through its sheet. That of a lake (a prism of the physics) only through
// its sheet, which ends at its loop.
@(private)
sheet_place :: proc(state:^Water_Gpu,assets:^host.Assets,renderer:^render.Renderer,extras:^host.Frame_Extras,view:core.View,body:int,e:core.Entity,material:u32,physics:core.Ref(phys.Physics_State)={},lake:^phys.Fluid_Info=nil) {
    top:=state.bodies[body].surface.x
    middle:=[3]f32{math.round(view.position.x/SURFACE_STEP)*SURFACE_STEP,top,math.round(view.position.z/SURFACE_STEP)*SURFACE_STEP}
    instance,usable:=render.mesh_instance(assets,{mesh=state.surface},mm.transform_matrix({middle,1,1}))
    if !usable {return}
    instance.material=render.Material_Handle(material)
    instance.object_id,instance.copy_owner=u64(e),base.name_hash("water")
    bounded:=lake!=nil
    points:[phys.FLUID_PATH_POINTS]mm.Path_Point
    loop:=points[:bounded?phys.fluid_path(physics,lake.fluid,&points):0]
    if bounded && len(loop)<3 {return}
    drawn:=!bounded
    defer if drawn {render.instance_add(extras,instance)}
    moving:=state.waves[body].count>0
    lowest:=f32(0)
    cut:=bounded
    key:=base.hash64(mem.ptr_to_bytes(&middle))
    if bounded {key=base.hash64(mem.slice_to_bytes(loop),key)}
    for j in 0..<state.count {
        if !dry_crosses(state,j,body) {continue}
        cut=true
        floor,_:=dry_span(state.bodies[j])
        lowest=min(lowest,floor-top)
        key=base.hash64(mem.ptr_to_bytes(&state.bodies[j]),key)
    }
    if !moving && !cut {return}
    if state.sheet_pipeline==0 {state.sheet_pipeline=render.stage_pipeline(renderer,{stage=.Geometry,shader="water_sheet",name="water sheet"})}
    if state.sheet_pipeline==0 {return}
    at:=-1
    for &sheet,i in state.sheets {
        if sheet.valid && sheet.entity==e {at=i;break}
        if !sheet.valid && at<0 {at=i}
    }
    if at<0 {return}
    sheet:=&state.sheets[at]
    if sheet.valid && (sheet.entity!=e || sheet.source!=instance.mesh) {
        render.mesh_remove(renderer,sheet.mesh)
        sheet^={}
    }
    if !sheet.valid {
        mesh,created:=render.deformable_create(renderer,instance.mesh)
        if !created {return}
        sheet^={entity=e,source=instance.mesh,mesh=mesh,valid=true}
    }
    sheet.seen,sheet.write=state.frame,false
    made:=render.vertices_made(renderer)
    if moving || key!=sheet.key || made!=sheet.made || body!=sheet.body {
        rest_min,rest_max,known:=render.mesh_bounds(renderer,sheet.source)
        if !known {return}
        reach:=phys.waves_reach(state.waves[body])
        bounds_min:=[3]f32{rest_min.x-reach,min(lowest,-reach),rest_min.z-reach}
        bounds_max:=[3]f32{rest_max.x+reach,reach,rest_max.z+reach}
        if bounded {
            // Within its loop.
            low,high:=[2]f32{max(f32),max(f32)},[2]f32{-max(f32),-max(f32)}
            for p,i in loop {
                sheet.loop[i]=p.position.xz
                low,high=linalg.min(low,p.position.xz),linalg.max(high,p.position.xz)
            }
            sheet.loop_count=len(loop)
            bounds_min.xz=linalg.max(bounds_min.xz,low-middle.xz)
            bounds_max.xz=linalg.min(bounds_max.xz,high-middle.xz)
            if !(bounds_min.x<=bounds_max.x && bounds_min.z<=bounds_max.z) {return}
        } else {sheet.loop_count=0}
        if !render.deformable_update(renderer,sheet.mesh,bounds_min,bounds_max) {return}
        sheet.key,sheet.made,sheet.middle,sheet.body,sheet.write=key,made,middle,body,true
        sheet.eye={view.position.x-middle.x,view.position.z-middle.z}
    }
    // Drawn as last written, which is where the grid is.
    if sheet.middle!=middle {return}
    instance.mesh=sheet.mesh
    drawn=true
}

// The sheets no plane drew in this frame go; those written in it get the pass that writes them.
@(private)
sheets_release :: proc(state:^Water_Gpu,renderer:^render.Renderer) {
    writing:=false
    for &sheet in state.sheets {
        if !sheet.valid {continue}
        if sheet.seen!=state.frame {
            render.mesh_remove(renderer,sheet.mesh)
            sheet={}
            continue
        }
        writing||=sheet.write
    }
    if writing && renderer!=nil {render.frame_pass(renderer,.Geometry,sheet_record,state)}
}

@(private)
sheet_record :: proc(pass:^render.Pass,user:rawptr) {
    state:=cast(^Water_Gpu)user
    if !render.pass_vertices_begin(pass,"water sheet") {return}
    render.pass_pipeline(pass,state.sheet_pipeline)
    for &sheet in state.sheets {
        if !sheet.valid || !sheet.write || sheet.body>=state.count {continue}
        written,rest,count,_,known:=render.pass_deformable(pass,sheet.mesh)
        if !known {continue}
        relative:=bodies_relative(state,sheet.middle)
        bodies:[CAPACITY]Gpu_Body
        bodies[0]=relative[sheet.body]
        n:=1
        for j in 0..<state.count {
            if !dry_crosses(state,j,sheet.body) {continue}
            bodies[n]=relative[j]
            n+=1
        }
        params:=Gpu_Sheet{rest=rest,written=written,count=count,bodies=u32(n),eye=sheet.eye,cell=SURFACE_CELL,half_cells=SURFACE_HALF,loop=u32(sheet.loop_count)}
        // The loop relative to the middle of the grid; one point for a plane, which reads none.
        loop:[phys.FLUID_PATH_POINTS][2]f32
        for p,i in sheet.loop[:sheet.loop_count] {loop[i]=p-sheet.middle.xz}
        if render.pass_params(pass,&params,size_of(params)) && render.pass_upload(pass,4,&bodies,n*size_of(Gpu_Body)) && render.pass_upload(pass,5,&loop,max(sheet.loop_count,1)*size_of([2]f32)) {
            render.pass_dispatch(pass,(count+63)/64)
        }

    }
}
