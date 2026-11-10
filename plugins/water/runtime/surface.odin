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
// Of what the heights of the waves change a metre, how much more a triangle of the border of a ring leans than
// one of its cells, and a wave that fades out along a ring than one that does not.
@(private) SHEET_BORDER :: f32(1.3)
@(private) SHEET_FADE :: f32(1.16)
@(private) SHEET_SQUEEZE :: f32(0.9) // the most of a metre the waves may squeeze a triangle for the sheet to say how steep it is

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
}

// The floor and the top of a dry box of the frame, from its row of height.
@(private)
dry_span :: proc "contextless" (b:Gpu_Body) -> (floor,top:f32) {
    up:=b.to_box[1]
    if !(abs(up.y)>0) {return}
    a,c:=(-0.5-up.w)/up.y,(0.5-up.w)/up.y
    return min(a,c),max(a,c)
}

// Whether a dry box of the frame takes out of a plane of lower priority some of the surface its waves can be at.
@(private)
dry_crosses :: proc "contextless" (state:^Water_Gpu,dry,plane:int) -> bool {
    d,p:=state.bodies[dry],state.bodies[plane]
    if !(d.surface.z>0.5) || !(p.surface.y>0.5) || !(d.surface.w>p.surface.w) {return false}
    reach:=phys.waves_reach(state.waves[plane])
    floor,top:=dry_span(d)
    return floor<p.surface.x+reach && top>p.surface.x-reach
}

// The box around the middle of the grid of a plane where a dry box of the frame that crosses its surface gives
// its sheet walls: the box, and as far around it as the vertices of the ring it is in go onto its walls
// (water_sheet.comp).
@(private)
dry_walls :: proc "contextless" (dry:Gpu_Body,middle:[3]f32) -> (low,high:[3]f32) {
    r:=dry.to_box
    to_world:=linalg.inverse(mm.Mat4{r[0].x,r[0].y,r[0].z,r[0].w,r[1].x,r[1].y,r[1].z,r[1].w,r[2].x,r[2].y,r[2].z,r[2].w,0,0,0,1})
    low,high=max(f32),-max(f32)
    for i in 0..<8 {
        corner:=[4]f32{i&1==0?-0.5:0.5,i&2==0?-0.5:0.5,i&4==0?-0.5:0.5,1}
        p:=(to_world*corner).xyz-middle
        low,high=linalg.min(low,p),linalg.max(high,p)
    }
    far:=max(abs(low.x),abs(low.z),abs(high.x),abs(high.z))
    ring:=SURFACE_CELL*math.pow(2,max(0,math.ceil(math.log2(max(far,1e-6)/(SURFACE_CELL*SURFACE_HALF)))))
    return low-{1.5*ring,0,1.5*ring},high+{1.5*ring,0,1.5*ring}
}

// Whether a dry box of the frame crosses the surface of some plane.
@(private)
crosses_plane :: proc "contextless" (state:^Water_Gpu,dry:int) -> bool {
    for j in 0..<state.count {if dry_crosses(state,dry,j) {return true}}
    return false
}

// The grid of the plane `body` of the frame around the camera: as it is generated while the plane is still
// and no dry box crosses it, else through its sheet.
@(private)
sheet_place :: proc(state:^Water_Gpu,app:^host.App,view:core.View,body:int,e:core.Entity,material:u32) {
    top:=state.bodies[body].surface.x
    middle:=[3]f32{math.round(view.position.x/SURFACE_STEP)*SURFACE_STEP,top,math.round(view.position.z/SURFACE_STEP)*SURFACE_STEP}
    instance,usable:=render.mesh_instance(app.assets,{mesh=state.surface},mm.transform_matrix({middle,1,1}))
    if !usable {return}
    instance.material=render.Material_Handle(material)
    instance.object_id,instance.copy_owner=u64(e),base.name_hash("water")
    defer render.instance_add(app,instance)
    moving:=state.waves[body].count>0
    lowest:=f32(0)
    cut:=false
    // Where the sheet goes down the walls of the dry boxes that cross it, around its middle: none yet.
    walls_min,walls_max:=[3]f32{1,1,1},[3]f32{-1,-1,-1}
    key:=base.hash64(mem.ptr_to_bytes(&middle))
    for j in 0..<state.count {
        if !dry_crosses(state,j,body) {continue}
        floor,_:=dry_span(state.bodies[j])
        lowest=min(lowest,floor-top)
        key=base.hash64(mem.ptr_to_bytes(&state.bodies[j]),key)
        low,high:=dry_walls(state.bodies[j],middle)
        if !cut {walls_min,walls_max=low,high}
        walls_min,walls_max=linalg.min(walls_min,low),linalg.max(walls_max,high)
        cut=true
    }
    if !moving && !cut {return}
    if state.sheet_pipeline==0 {state.sheet_pipeline=render.stage_pipeline(app,{stage=.Geometry,shader="water_sheet",name="water sheet"})}
    if state.sheet_pipeline==0 {return}
    at:=-1
    for &sheet,i in state.sheets {
        if sheet.valid && sheet.entity==e {at=i;break}
        if !sheet.valid && at<0 {at=i}
    }
    if at<0 {return}
    sheet:=&state.sheets[at]
    if sheet.valid && (sheet.entity!=e || sheet.source!=instance.mesh) {
        render.mesh_remove(app,sheet.mesh)
        sheet^={}
    }
    if !sheet.valid {
        mesh,created:=render.deformable_create(app,instance.mesh)
        if !created {return}
        sheet^={entity=e,source=instance.mesh,mesh=mesh,valid=true}
    }
    sheet.seen,sheet.write=state.frame,false
    made:=render.vertices_made(app)
    if moving || key!=sheet.key || made!=sheet.made || body!=sheet.body {
        rest_min,rest_max,known:=render.mesh_bounds(app,sheet.source)
        if !known {return}
        reach:=phys.waves_reach(state.waves[body])
        bounds_min:=[3]f32{rest_min.x-reach,min(lowest,-reach),rest_min.z-reach}
        bounds_max:=[3]f32{rest_max.x+reach,reach,rest_max.z+reach}
        // How steep the triangles of the grid get with their vertices on the waves: as the heights of the waves
        // between them, more where a wave fades out along a ring and in the triangles of the borders of the
        // rings, and by how much the waves squeeze them sideways. Past SHEET_SQUEEZE it says nothing.
        rise,moved:=phys.waves_slope(state.waves[body])
        shape:=render.Sheet{rise=-1}
        if squeeze:=SHEET_BORDER*moved;squeeze<SHEET_SQUEEZE {
            // As far out as the waves move the water sideways, and as high and low as they take the surface.
            if cut {
                walls_min,walls_max=walls_min-reach,walls_max+reach
                walls_min.y,walls_max.y=min(walls_min.y,-reach),max(walls_max.y,reach)
            }
            shape={rise=SHEET_BORDER*SHEET_FADE*rise/(1-squeeze),walls_min=walls_min,walls_max=walls_max}
        }
        if !render.deformable_update(app,sheet.mesh,bounds_min,bounds_max,&shape) {return}
        sheet.key,sheet.made,sheet.middle,sheet.body,sheet.write=key,made,middle,body,true
        sheet.eye={view.position.x-middle.x,view.position.z-middle.z}
    }
    // Drawn as last written, which is where the grid is.
    if sheet.middle!=middle {return}
    instance.mesh=sheet.mesh
}

// The sheets no plane drew in this frame go; those written in it get the pass that writes them.
@(private)
sheets_release :: proc(state:^Water_Gpu,app:^host.App) {
    writing:=false
    for &sheet in state.sheets {
        if !sheet.valid {continue}
        if sheet.seen!=state.frame {
            render.mesh_remove(app,sheet.mesh)
            sheet={}
            continue
        }
        writing||=sheet.write
    }
    if writing && app.renderer!=nil {render.frame_pass(app,.Geometry,sheet_record,state)}
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
        params:=Gpu_Sheet{rest=rest,written=written,count=count,bodies=u32(n),eye=sheet.eye,cell=SURFACE_CELL,half_cells=SURFACE_HALF}
        if render.pass_params(pass,&params,size_of(params)) && render.pass_upload(pass,4,&bodies,n*size_of(Gpu_Body)) {
            render.pass_dispatch(pass,(count+63)/64)
        }
    }
}
