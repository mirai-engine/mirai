package foliage

import "base:runtime"
import "core:math/linalg"
import "mirai:core"
import render "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/geom"
import "mirai:std/jobs"
import mm "mirai:std/math"

// The far form of a type with an impostor distance: past it its mesh gives
// way to an octahedral impostor, which the Gbuffer stage draws (the fade of
// the mesh and the appearance of the impostor share the pattern of the
// batches, so the instance stays whole), and the rays meet its crown instead
// of its leaves. Both are made once per asset a type shows (its mesh or its
// prefab) in each world, when a type first shows it, and made again when it
// changes, as any cooking: the frames by the render of the thumbnails
// (render.impostor_capture), the crown from the triangles of the mesh
// (crown_build). A cell decides by its distance to the streaming sources
// which of the two the rays meet: its mesh within the distance where the
// mesh is gone, its crown past it.

IMPOSTOR_GRID :: 8      // frames a side of the atlas of an impostor
IMPOSTOR_FRAME :: 128   // pixels a side of a frame
IMPOSTOR_BLEND :: f32(0.1) // of the impostor distance: how far past it the mesh fades out while the impostor shows
IMPOSTOR_BUFFER :: "foliage impostors"
IMPOSTOR_UPLOAD :: 4<<20 // bytes of instances a frame uploads at most

// What a type shows far away, kept by the asset it shows.
Resident_Kind :: struct {
    id:base.Asset_Id,
    made:bool,                          // its impostor and its crown were asked for
    color,normal:render.Texture_Handle, // its frames; none when they could not be made
    sphere:[4]f32,                      // centre and radius of its frames, in the space of the type
    low,high:[3]f32,                    // the box of its mesh, which the batches of its mesh fade by
    crown:base.Asset_Id,                // the mesh rays meet far away; none without dense voxels
    crown_positions:[][3]f32,           // its triangles, which the crown of a cell is made of
    crown_indices:[]u32,
    bake:^Kind_Bake,                    // what a job makes of it; nil once the renderer has it
}

// Whether the mesh of a type gives way to an impostor before it is gone.
type_far :: proc "contextless" (t:Foliage_Type) -> bool {
    return t.impostor_distance>0 && (t.cull_distance<=0 || t.impostor_distance<t.cull_distance)
}

// Where the mesh of a type starts to fade out and where it is gone: those of
// the type, or with a far form, the impostor distance and IMPOSTOR_BLEND past it.
mesh_distances :: proc "contextless" (t:Foliage_Type,far:bool) -> (fade,cull:f32) {
    if !far {return t.fade_distance,t.cull_distance}
    fade,cull=t.impostor_distance,t.impostor_distance*(1+IMPOSTOR_BLEND)
    if t.cull_distance>0 {cull=min(cull,t.cull_distance)}
    return
}

kind_find :: proc(resident:^Foliage_Resident,id:base.Asset_Id) -> ^Resident_Kind {
    for &kind in resident.kinds {if kind.id==id {return &kind}}
    return nil
}

// The kind of an asset, made the first time a type shows it: a load
// transaction that draws its frames and takes its triangles in a frame, and
// fills out the frames, builds their levels and the crown in a job, given to
// the renderer in a later frame. KINDS_A_FRAME of those steps a frame; -1
// while it waits for one, or for its job.
kind_ensure :: proc(resident:^Foliage_Resident,assets:^host.Assets,renderer:^render.Renderer,job_system:^jobs.Job_System,allocator:runtime.Allocator,id:base.Asset_Id,parts:[]Part_Draw,problems:^core.Problems,e:core.Entity) -> int {
    for &kind,i in resident.kinds {
        if kind.id!=id {continue}
        if kind.bake==nil {return i}
        if jobs.pending(&kind.bake.counter) || resident.kinds_left<=0 {return -1}
        resident.kinds_left-=1
        if !kind_finish(assets,renderer,allocator,&kind) {memory_problem(problems,e,"the crown of the far form of a type: its cells cast no shadow from afar")}
        return i
    }
    if resident.kinds_left<=0 {return -1}
    // Drawing its frames is the work of a frame: no cell is built with it.
    resident.kinds_left-=1
    resident.instances_left=0
    if _,error:=append(&resident.kinds,Resident_Kind{id=id});error!=nil {memory_problem(problems,e,"the far form of a type");return -1}
    kind:=&resident.kinds[len(resident.kinds)-1]
    if !kind_make(kind,assets,renderer,job_system,parts) {
        pop(&resident.kinds)
        memory_problem(problems,e,"the far form of a type")
        return -1
    }
    return kind.bake==nil?len(resident.kinds)-1:-1
}

kind_ready :: proc "contextless" (kind:^Resident_Kind) -> bool {return kind!=nil && kind.color!=0 && kind.normal!=0}

// The box of a box of its own space under a transform.
@(private)
box_placed :: proc "contextless" (placement:mm.Mat4,low,high:[3]f32) -> (a,b:[3]f32) {
    a,b={max(f32),max(f32),max(f32)},{min(f32),min(f32),min(f32)}
    for corner in 0..<8 {
        p:=[3]f32{corner&1!=0?high.x:low.x,corner&2!=0?high.y:low.y,corner&4!=0?high.z:low.z}
        q:=(placement*[4]f32{p.x,p.y,p.z,1}).xyz
        a,b=linalg.min(a,q),linalg.max(b,q)
    }
    return
}

// What a job makes of a kind, apart from the main thread: its frames filled
// out and their levels, and its crown from the triangles of its meshes, with
// the geometry the renderer takes of it.
Kind_Bake :: struct {
    images:render.Impostor_Images,
    captured:bool,
    max_size:int, // render.texture_max_size when its frames were drawn
    color,normal:render.Texture_Data,
    built:bool,
    positions:[dynamic][3]f32, // the triangles of its meshes, in the space of the type
    indices:[dynamic]u32,
    crown:geom.Mesh_Buffer,
    crowned:bool,
    limits:host.Assets_Limits, // of the assets when its frames were drawn
    made:host.Mesh_Render_Geometry,
    meshed:bool,
    counter:jobs.Counter,
}

@(private)
kind_make :: proc(kind:^Resident_Kind,assets:^host.Assets,renderer:^render.Renderer,job_system:^jobs.Job_System,parts:[]Part_Draw) -> (enough:bool) {
    kind.made=true
    if len(parts)==0 {return true}
    pieces:=make([dynamic]render.Impostor_Part,0,len(parts),context.temp_allocator)
    low,high:=[3]f32{max(f32),max(f32),max(f32)},[3]f32{min(f32),min(f32),min(f32)}
    for part in parts {
        a,b,known:=render.mesh_bounds(renderer,part.desc.mesh)
        if !known {return true}
        a,b=box_placed(part.placement,a,b)
        low,high=linalg.min(low,a),linalg.max(high,b)
        append(&pieces,render.Impostor_Part{mesh=part.desc.mesh,placement=part.placement,material=part.desc.material,slot_materials=part.desc.slot_materials})
    }
    kind.low,kind.high=low,high
    heap:=runtime.heap_allocator()
    bake,error:=new(Kind_Bake,heap)
    if error!=nil {return false}
    bake.positions=make([dynamic][3]f32,heap)
    bake.indices=make([dynamic]u32,heap)
    geom.mesh_buffer_init(&bake.crown,heap)
    host.assets_render_geometry_init(&bake.made,heap)
    if assets!=nil {bake.limits=host.assets_limits(assets)}
    bake.images,bake.captured=render.impostor_capture(renderer,pieces[:],IMPOSTOR_GRID,IMPOSTOR_FRAME,heap)
    if bake.captured {kind.sphere={bake.images.center.x,bake.images.center.y,bake.images.center.z,bake.images.radius}}
    bake.max_size=render.texture_max_size(renderer)
    for part in parts {
        first:=len(bake.positions)
        if !render.mesh_triangles(renderer,part.desc.mesh,&bake.positions,&bake.indices) {
            clear(&bake.positions);clear(&bake.indices)
            break
        }
        if part.identity {continue}
        for &p in bake.positions[first:] {p=(part.placement*[4]f32{p.x,p.y,p.z,1}).xyz}
    }
    kind.bake=bake
    if jobs.worker_count(job_system)>1 {jobs.run(job_system,jobs.OWNER,.Background,kind_bake,bake,&bake.counter)} else {kind_bake(bake,jobs.OWNER)}
    return true
}

// A job: the frames of a kind filled out and built into levels, and its crown.
@(private)
kind_bake :: proc(bake:^Kind_Bake,worker:int) {
    context.allocator=runtime.heap_allocator()
    if bake.captured {
        render.impostor_dilate(&bake.images)
        side:=int(bake.images.grid*bake.images.frame)
        color,color_built:=render.texture_build({pixels=bake.images.color,width=side,height=side,srgb=true,alpha_coverage=0.5},bake.max_size)
        normal,normal_built:=render.texture_build({pixels=bake.images.normal,width=side,height=side,normal_map=true},bake.max_size)
        bake.color,bake.normal,bake.built=color,normal,color_built && normal_built
    }
    bake.crowned=len(bake.indices)>0 && crown_build(bake.positions[:],bake.indices[:],&bake.crown)
    bake.meshed=bake.crowned && host.assets_render_geometry_make(geom.mesh_buffer_view(&bake.crown),nil,0,&bake.made,bake.limits)
}

// Gives the renderer what the job of a kind made.
@(private)
kind_finish :: proc(assets:^host.Assets,renderer:^render.Renderer,allocator:runtime.Allocator,kind:^Resident_Kind) -> (enough:bool) {
    enough=true
    bake:=kind.bake
    if bake.built {
        kind.color,_=render.texture_add_built(renderer,bake.color,"foliage impostor color")
        kind.normal,_=render.texture_add_built(renderer,bake.normal,"foliage impostor normal")
        if kind.color==0 || kind.normal==0 {
            if kind.color!=0 {render.texture_remove(renderer,kind.color)}
            if kind.normal!=0 {render.texture_remove(renderer,kind.normal)}
            kind.color,kind.normal=0,0
        }
    }
    if bake.meshed && assets!=nil {
        shape:=&bake.crown
        kind.crown,_=host.assets_mesh_publish(assets,&bake.made)
        positions,positions_error:=make([][3]f32,len(shape.positions),allocator)
        indices,indices_error:=make([]u32,len(shape.indices),allocator)
        if positions_error!=nil || indices_error!=nil {
            delete(positions,allocator);delete(indices,allocator)
            enough=false
        } else {
            for p,i in shape.positions {positions[i]=p}
            copy(indices,shape.indices[:])
            kind.crown_positions,kind.crown_indices=positions,indices
        }
    }
    kind_bake_free(kind)
    return
}

@(private)
kind_bake_free :: proc(kind:^Resident_Kind) {
    bake:=kind.bake
    if bake==nil {return}
    heap:=runtime.heap_allocator()
    render.impostor_images_destroy(&bake.images,heap)
    render.texture_data_destroy(&bake.color,heap)
    render.texture_data_destroy(&bake.normal,heap)
    delete(bake.positions);delete(bake.indices)
    geom.mesh_buffer_destroy(&bake.crown)
    host.assets_render_geometry_destroy(&bake.made)
    free(bake,heap)
    kind.bake=nil
}

kind_free :: proc(app:^host.App,kind:^Resident_Kind) {
    if kind.bake!=nil {
        if app!=nil && jobs.pending(&kind.bake.counter) {jobs.wait(&app.jobs,jobs.OWNER,&kind.bake.counter)}
        kind_bake_free(kind)
    }
    if app!=nil {
        if kind.color!=0 {render.texture_remove(app.renderer,kind.color)}
        if kind.normal!=0 {render.texture_remove(app.renderer,kind.normal)}
        if kind.crown!={} && app.assets!=nil {host.assets_mesh_release(app.assets,kind.crown)}
    }
    if app!=nil {delete(kind.crown_positions,app.allocator);delete(kind.crown_indices,app.allocator)}
    kind^={id=kind.id}
}

// An impostor of a cell: an instance of its type as its batches place it
// (in the world), and the index of the type in its source.
Impostor_Placed :: struct {
    instance:render.Batch_Instance,
    type:u32,
}

// What the shaders read (foliage_impostor.slang): an instance relative to
// the anchor of all of them, and the row of its Foliage and type.
Impostor_Instance :: struct {
    position:[3]f32,
    rotation,scale,row:u32,
}
#assert(size_of(Impostor_Instance)==24)

Impostor_Row :: struct {
    sphere:[4]f32,
    low,high:[4]f32, // w: where the mesh fades out, and where it is gone
    frames:[4]u32,   // the textures of color and of normal, frames a side, pixels a side of a frame
    far:[4]f32,      // where the impostor fades out, and where it is gone (0: never)
}

// The impostors of the world: the rows of every type of every Foliage, the
// instances of every resident cell, and what of them the buffer of the world holds.
Impostor_Draw :: struct {
    instances:[dynamic]Impostor_Instance,
    rows:[dynamic]Impostor_Row,
    anchor:[3]f32,  // a multiple of render.ORIGIN_STEP the positions are from
    count:int,      // the instances to draw
    written:int,    // of them, those the buffer holds
    capacity:u64,   // bytes of the buffer
    dirty:bool,     // the impostors of a cell changed: built again
}

impostor_draw_destroy :: proc(d:^Impostor_Draw) {
    delete(d.instances);delete(d.rows)
    d^={}
}

// The row of a type of a Foliage: its frames and the distances that fade
// them in and out, scaled as the meshes are (Foliage_Resident.detail). Zero,
// and never drawn, for a type without them.
impostor_row :: proc(resident:^Foliage_Resident,t:^Foliage_Type) -> (row:Impostor_Row) {
    if !type_far(t^) {return}
    id:=t.mesh if t.mesh!={} else t.prefab
    kind:=kind_find(resident,id)
    if !kind_ready(kind) {return}
    distance:=resident.detail[1]
    fade,cull:=mesh_distances(t^,true)
    row.sphere=kind.sphere
    row.low={kind.low.x,kind.low.y,kind.low.z,fade*distance}
    row.high={kind.high.x,kind.high.y,kind.high.z,cull*distance}
    row.frames={render.texture_index(kind.color),render.texture_index(kind.normal),IMPOSTOR_GRID,IMPOSTOR_FRAME}
    row.far={t.fade_distance*distance,t.cull_distance*distance,0,0}
    return
}

// The rows and instances of the impostors of every resident cell of each
// Foliage, from the anchor nearest the first of them.
impostors_build :: proc(resident:^Foliage_Resident,data:^Foliage_Data) {
    d:=&resident.impostors
    d.dirty=false
    clear(&d.instances);clear(&d.rows)
    anchored:=false
    for &owner in resident.owners {
        entry:=data_find(data,owner.source)
        if entry==nil {continue}
        base_row:=u32(len(d.rows))
        for &t in entry.source.types {append(&d.rows,impostor_row(resident,&t))}
        for &cell in owner.cells {
            for placed in cell.impostors {
                if int(placed.type)>=len(entry.source.types) {continue}
                if !anchored {
                    p:=placed.instance.position
                    d.anchor={f32(i64(p.x/render.ORIGIN_STEP))*render.ORIGIN_STEP,f32(i64(p.y/render.ORIGIN_STEP))*render.ORIGIN_STEP,f32(i64(p.z/render.ORIGIN_STEP))*render.ORIGIN_STEP}
                    anchored=true
                }
                b:=placed.instance
                append(&d.instances,Impostor_Instance{position=b.position-d.anchor,rotation=b.rotation,scale=b.scale,row=base_row+placed.type})
            }
        }
    }
    d.count,d.written=len(d.instances),0
    need:=u64(max(d.count,1)*size_of(Impostor_Instance))
    if d.capacity<need || d.capacity>4*need && d.capacity>64<<10 {
        d.capacity=64<<10
        for d.capacity<need {d.capacity*=2}
        // A multiple of the instance and of 4 bytes, as a buffer of the world takes it.
        d.capacity-=d.capacity%size_of(Impostor_Instance)
        for d.capacity<need {d.capacity+=size_of(Impostor_Instance)}
    }
}

// The impostors of the world into the G-buffer of each view: one quad an
// instance, which the shaders leave out where its mesh is still whole.
@(private)
foliage_impostors_record :: proc(pass:^render.Pass,user:rawptr) {
    resident:=cast(^Foliage_Resident)user
    d:=&resident.impostors
    if pass.world!=render.world_key(resident.world) || d.count==0 || len(d.rows)==0 {return}
    pipeline:=render.pass_gbuffer_pipeline(pass,"foliage_impostor","foliage impostors","foliage_impostor")
    if pipeline==0 {return}
    desc:=render.Buffer_Desc{name=IMPOSTOR_BUFFER,size=d.capacity}
    ok,made:=render.pass_buffer(pass,0,desc)
    if !ok {return}
    if made {d.written=0}
    if d.written<d.count {
        n:=min(d.count-d.written,IMPOSTOR_UPLOAD/size_of(Impostor_Instance))
        if render.pass_buffer_write(pass,desc,u64(d.written*size_of(Impostor_Instance)),&d.instances[d.written],n*size_of(Impostor_Instance)) {d.written+=n}
    }
    if d.written==0 {return}
    rows,uploaded:=render.pass_rows_upload(pass,raw_data(d.rows),len(d.rows)*size_of(Impostor_Row))
    if !uploaded {return}
    render.pass_gbuffer_begin(pass,"foliage impostors")
    render.pass_pipeline(pass,pipeline)
    render.pass_buffer(pass,0,desc)
    render.pass_rows(pass,1,rows)
    anchor:=render.origin_point(d.anchor,pass.origin)
    params:=[4]f32{anchor.x,anchor.y,anchor.z,0}
    if render.pass_params(pass,&params,size_of(params)) {render.pass_draw(pass,6,u32(d.written))}
    render.pass_end(pass)
}

// Past CELL_CROWN_REACH times the reach of the meshes of its types, a cell
// gives rays one crown for all the instances of its types that cast shadows
// in place of a crown each: one entry of the structure of rays a cell, and
// a BLAS of the cell, coarse and opaque, made as the crown of a type is
// (crown_build) of the crowns of its instances, in the space of its
// Foliage. Impostors still draw each instance.
CELL_CROWN_REACH :: f32(4)

// The crown of a cell, into out: of the crowns of the instances placed (in
// the space of their Foliage), each from the triangles of the crown of its
// type, crowns[type] (type: the index of the type); a type without them
// gives none. False when there is
// nothing to cover.
cell_crown_build :: proc(placed:[]Placed,crowns:[]Crown_Triangles,out:^geom.Mesh_Buffer) -> bool {
    positions:=make([dynamic][3]f32,context.temp_allocator)
    indices:=make([dynamic]u32,context.temp_allocator)
    for p in placed {
        if int(p.type)>=len(crowns) {continue}
        c:=crowns[p.type]
        if len(c.indices)==0 {continue}
        first:=u32(len(positions))
        for v in c.positions {
            scaled:=[3]f32{v.x*p.scale[0],v.y*p.scale[1],v.z*p.scale[0]}
            append(&positions,p.position+mm.quat_rotate(p.rotation,scaled))
        }
        for index in c.indices {append(&indices,first+index)}
    }
    return crown_build(positions[:],indices[:],out)
}

// The triangles of the crown of a type, as its far form keeps them.
Crown_Triangles :: struct {
    positions:[][3]f32,
    indices:[]u32,
}
