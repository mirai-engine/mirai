package foliage

import "base:runtime"
import "core:math"
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
// prefab) and frame size in each world, when a type first shows it, and made
// again when it changes, as any cooking: the frames by the render of the
// thumbnails (render.impostor_capture), the crown from the triangles of the
// mesh (crown_build). A cell decides by its distance to the streaming sources
// which of the two the rays meet: its mesh within the distance where the
// mesh is gone, its crown past it.

IMPOSTOR_GRID :: 8         // frames a side of the atlas of an impostor
IMPOSTOR_FRAME_MIN :: 32   // pixels a side of a frame, at least
IMPOSTOR_FRAME_MAX :: 256  // and at most
// Pixels a unit of tangent across the view for which the frames are as sharp
// as the mesh where it gives way to them: 1440 lines over 60 degrees.
IMPOSTOR_FOCAL :: f32(1250)
IMPOSTOR_BLEND :: f32(0.1) // of the impostor distance: how far past it the mesh fades out while the impostor shows
IMPOSTOR_BUFFER :: "foliage impostors"
IMPOSTOR_VISIBLE :: "foliage impostors visible"
IMPOSTOR_DRAW :: "foliage impostors draw"
IMPOSTOR_SLOTS_MIN :: 4096 // instances the buffer holds at least
IMPOSTOR_NONE :: 0xFFFFFFFF // the row of a place of the buffer that holds no instance

// What a far form is made of: the asset a type shows, and the pixels a side
// of each of its frames.
Kind_Key :: struct {
    id:base.Asset_Id,
    frame:u32,
}

// What a type shows far away, kept by the asset it shows.
Resident_Kind :: struct {
    key:Kind_Key,
    made:bool,                                  // its impostor and its crown were asked for
    color,normal,surface:render.Texture_Handle, // its frames; none when they could not be made
    sphere:[4]f32,                              // centre and radius of its frames, in the space of the type
    low,high:[3]f32,                            // the box of its mesh, which the batches of its mesh fade by
    albedo:[3]f32,                              // the mean base color of its frames, linear: what rays see of its crown
    transmission:[3]f32,                        // the color of the light its leaves let through
    crown:base.Asset_Id,                        // the mesh rays meet far away; none without dense voxels
    crown_positions:[][3]f32,                   // its triangles, which the crown of a cell is made of
    crown_indices:[]u32,
    bake:^Kind_Bake,                            // what a job makes of it; nil once the renderer has it
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

// The pixels a side of the frames of a type whose parts span a box of that
// diagonal at scale 1: those its largest instance spans where its mesh gives
// way to them, in a power of two.
impostor_frame :: proc "contextless" (t:Foliage_Type,diagonal:f32) -> u32 {
    across:=diagonal*max(t.scale[1],t.scale[1]*t.height[1])
    pixels:=across/max(t.impostor_distance,1e-3)*IMPOSTOR_FOCAL
    frame:=u32(IMPOSTOR_FRAME_MIN)
    for frame<IMPOSTOR_FRAME_MAX && f32(frame)<pixels {frame*=2}
    return frame
}

// The pixels a side of the frames of a type of those parts (impostor_frame).
kind_frame :: proc(renderer:^render.Renderer,t:Foliage_Type,parts:[]Part_Draw) -> u32 {
    low,high:=[3]f32{max(f32),max(f32),max(f32)},[3]f32{min(f32),min(f32),min(f32)}
    for part in parts {
        a,b,known:=render.mesh_bounds(renderer,part.desc.mesh)
        if !known {continue}
        a,b=box_placed(part.placement,a,b)
        low,high=linalg.min(low,a),linalg.max(high,b)
    }
    return impostor_frame(t,low.x<=high.x?linalg.length(high-low):0)
}

kind_find :: proc(resident:^Foliage_Resident,key:Kind_Key) -> ^Resident_Kind {
    for &kind in resident.kinds {if kind.key==key {return &kind}}
    return nil
}

// The kind of an asset, made the first time a type shows it: a load
// transaction that draws its frames and takes its triangles in a frame, and
// fills out the frames, builds their levels and the crown in a job, given to
// the renderer in a later frame. KINDS_A_FRAME of those steps a frame; -1
// while it waits for one, or for its job.
kind_ensure :: proc(resident:^Foliage_Resident,assets:^host.Assets,renderer:^render.Renderer,job_system:^jobs.Job_System,allocator:runtime.Allocator,key:Kind_Key,parts:[]Part_Draw,problems:^core.Problems,e:core.Entity) -> int {
    for &kind,i in resident.kinds {
        if kind.key!=key {continue}
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
    if _,error:=append(&resident.kinds,Resident_Kind{key=key});error!=nil {memory_problem(problems,e,"the far form of a type");return -1}
    kind:=&resident.kinds[len(resident.kinds)-1]
    if !kind_make(kind,assets,renderer,job_system,parts) {
        pop(&resident.kinds)
        memory_problem(problems,e,"the far form of a type")
        return -1
    }
    return kind.bake==nil?len(resident.kinds)-1:-1
}

kind_ready :: proc "contextless" (kind:^Resident_Kind) -> bool {return kind!=nil && kind.color!=0 && kind.normal!=0 && kind.surface!=0}

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
    color,normal,surface:render.Texture_Data,
    albedo:[3]f32,
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
    bake.images,bake.captured=render.impostor_capture(renderer,pieces[:],IMPOSTOR_GRID,kind.key.frame,heap)
    if bake.captured {
        kind.sphere={bake.images.center.x,bake.images.center.y,bake.images.center.z,bake.images.radius}
        kind.transmission=bake.images.transmission
    }
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

// A job: the frames of a kind filled out and built into levels, their mean
// color, and its crown.
@(private)
kind_bake :: proc(bake:^Kind_Bake,worker:int) {
    context.allocator=runtime.heap_allocator()
    if bake.captured {
        bake.albedo=frames_albedo(bake.images.color)
        render.impostor_dilate(&bake.images)
        side:=int(bake.images.grid*bake.images.frame)
        color,color_built:=render.texture_build({pixels=bake.images.color,width=side,height=side,srgb=true,alpha_coverage=0.5},bake.max_size)
        normal,normal_built:=render.texture_build({pixels=bake.images.normal,width=side,height=side,normal_map=true},bake.max_size)
        surface,surface_built:=render.texture_build({pixels=bake.images.surface,width=side,height=side},bake.max_size)
        bake.color,bake.normal,bake.surface,bake.built=color,normal,surface,color_built && normal_built && surface_built
    }
    bake.crowned=len(bake.indices)>0 && crown_build(bake.positions[:],bake.indices[:],&bake.crown)
    bake.meshed=bake.crowned && host.assets_render_geometry_make(geom.mesh_buffer_view(&bake.crown),nil,0,&bake.made,bake.limits)
}

// The mean base color of the covered texels of frames (sRGB, RGBA8), linear;
// mid grey where none is covered.
frames_albedo :: proc "contextless" (color:[]u8) -> [3]f32 {
    sum:[3]f64
    count:f64
    for i:=0;i+3<len(color);i+=4 {
        if color[i+3]==0 {continue}
        for c in 0..<3 {
            s:=f64(color[i+c])/255
            sum[c]+=s<=0.04045?s/12.92:math.pow((s+0.055)/1.055,2.4)
        }
        count+=1
    }
    if count==0 {return {0.5,0.5,0.5}}
    return {f32(sum[0]/count),f32(sum[1]/count),f32(sum[2]/count)}
}

// Gives the renderer what the job of a kind made.
@(private)
kind_finish :: proc(assets:^host.Assets,renderer:^render.Renderer,allocator:runtime.Allocator,kind:^Resident_Kind) -> (enough:bool) {
    enough=true
    bake:=kind.bake
    if bake.built {
        kind.color,_=render.texture_add_built(renderer,bake.color,"foliage impostor color")
        kind.normal,_=render.texture_add_built(renderer,bake.normal,"foliage impostor normal")
        kind.surface,_=render.texture_add_built(renderer,bake.surface,"foliage impostor surface")
        kind.albedo=bake.albedo
        if kind.color==0 || kind.normal==0 || kind.surface==0 {
            for texture in ([]render.Texture_Handle{kind.color,kind.normal,kind.surface}) {if texture!=0 {render.texture_remove(renderer,texture)}}
            kind.color,kind.normal,kind.surface=0,0,0
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
    render.texture_data_destroy(&bake.surface,heap)
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
        for texture in ([]render.Texture_Handle{kind.color,kind.normal,kind.surface}) {if texture!=0 {render.texture_remove(app.renderer,texture)}}
        if kind.crown!={} && app.assets!=nil {host.assets_mesh_release(app.assets,kind.crown)}
    }
    if app!=nil {delete(kind.crown_positions,app.allocator);delete(kind.crown_indices,app.allocator)}
    kind^={key=kind.key}
}

// What the shaders read (foliage_impostor.slang): an instance relative to
// the anchor of all of them, and its row: the slot of its Foliage
// (Resident_Owner.slot) in the high half, the index of its type in the low.
Impostor_Instance :: struct {
    position:[3]f32,
    rotation:u32,
    scale:[4]u16,
    row:u32,
    color:u32, // its tint and wetness (render.batch_color)
}
#assert(size_of(Impostor_Instance)==32)

Impostor_Row :: struct {
    sphere:[4]f32,
    low,high:[4]f32,     // w: where the mesh fades out, and where it is gone
    frames:[4]u32,       // the textures of color, of normal and of surface; frames a side | pixels a side of a frame << 16
    far:[4]f32,          // where the impostor fades out, and where it is gone (0: never)
    transmission:[4]f32, // the color of the light its leaves let through
}

// A run of the instances of the buffer that a cell holds.
Impostor_Block :: struct {
    first,count,capacity:u32,
    used:bool,
}

// The impostors of the world, in the buffer of the world by blocks, one a
// cell: a cell that changes writes its block alone, and the buffer keeps
// what it held until the next draw takes the change. Each view culls them on
// the GPU (foliage_impostor_cull.comp) and draws those it sees.
Impostor_Draw :: struct {
    instances:[dynamic]Impostor_Instance, // what the buffer holds; IMPOSTOR_NONE rows where no block is
    blocks:[dynamic]Impostor_Block,
    writes:[dynamic][2]u32, // first and count of the instances the buffer is to take
    rows:[dynamic]Impostor_Row,
    bases:[dynamic]u32,     // the first row of each slot of a Foliage
    anchor:[3]f32,          // a multiple of render.ORIGIN_STEP the positions are from
    count:int,              // instances its blocks hold
    capacity:u64,           // bytes of the buffer
    whole:bool,             // the buffer was made again: it holds nothing until all of them are written
}

impostor_draw_destroy :: proc(d:^Impostor_Draw) {
    delete(d.instances);delete(d.blocks);delete(d.writes);delete(d.rows);delete(d.bases)
    d^={}
}

// Forgets every block: the cells that held them are gone.
impostor_draw_clear :: proc(d:^Impostor_Draw) {
    clear(&d.instances);clear(&d.blocks);clear(&d.writes)
    d.count=0
}

// Gives the block of a cell (block: its index plus one, 0 for none) the
// instances given, placed in the world: in its own room while they fit, else
// in a free block or a new one at the end, and the old one goes. False
// without memory, with the block as it was.
impostors_set :: proc(d:^Impostor_Draw,block:^u32,given:[]Impostor_Instance) -> bool {
    n:=u32(len(given))
    if n==0 {
        impostors_free(d,block)
        return true
    }
    if len(d.instances)==0 {
        p:=given[0].position
        d.anchor={f32(i64(p.x/render.ORIGIN_STEP))*render.ORIGIN_STEP,f32(i64(p.y/render.ORIGIN_STEP))*render.ORIGIN_STEP,f32(i64(p.z/render.ORIGIN_STEP))*render.ORIGIN_STEP}
    }
    at:=-1
    if block^>0 && n<=d.blocks[block^-1].capacity {at=int(block^-1)}
    if at<0 {
        for b,i in d.blocks {
            if !b.used && b.capacity>=n && b.capacity<=2*n {at=i;break}
        }
        if at<0 {
            first:=len(d.instances)
            if resize(&d.instances,first+int(n))!=nil {return false}
            if _,error:=append(&d.blocks,Impostor_Block{first=u32(first),capacity=n});error!=nil {
                base.truncate(&d.instances,first)
                return false
            }
            at=len(d.blocks)-1
        }
        d.blocks[at].used,d.blocks[at].count=true,0
        impostors_free(d,block)
    }
    if _,error:=append(&d.writes,[2]u32{d.blocks[at].first,max(n,d.blocks[at].count)});error!=nil {
        if d.blocks[at].count==0 {d.blocks[at].used=false}
        return false
    }
    b:=&d.blocks[at]
    for g,k in given {
        d.instances[b.first+u32(k)]=g
        d.instances[b.first+u32(k)].position=g.position-d.anchor
    }
    for k in n..<b.count {d.instances[b.first+k].row=IMPOSTOR_NONE}
    d.count+=int(n)-int(b.count)
    b.count=n
    block^=u32(at+1)
    return true
}

// Lets go of the block of a cell: what it held is drawn no more, and the
// free blocks at the end give their room back.
impostors_free :: proc(d:^Impostor_Draw,block:^u32) {
    if block^==0 {return}
    b:=&d.blocks[block^-1]
    block^=0
    for k in 0..<b.count {d.instances[b.first+k].row=IMPOSTOR_NONE}
    if b.count>0 {append(&d.writes,[2]u32{b.first,b.count})}
    d.count-=int(b.count)
    b.count,b.used=0,false
    for len(d.blocks)>0 && !d.blocks[len(d.blocks)-1].used {
        last:=pop(&d.blocks)
        base.truncate(&d.instances,int(last.first))
    }
}

// The row of a type of a Foliage: its frames and the distances that fade
// them in and out, scaled as the meshes are (Foliage_Resident.detail). Zero,
// and never drawn, for a type without them.
impostor_row :: proc(resident:^Foliage_Resident,t:^Foliage_Type,key:Kind_Key) -> (row:Impostor_Row) {
    if !type_far(t^) {return}
    kind:=kind_find(resident,key)
    if !kind_ready(kind) {return}
    distance:=resident.detail[1]
    fade,cull:=mesh_distances(t^,true)
    row.sphere=kind.sphere
    row.low={kind.low.x,kind.low.y,kind.low.z,fade*distance}
    row.high={kind.high.x,kind.high.y,kind.high.z,cull*distance}
    row.frames={render.texture_index(kind.color),render.texture_index(kind.normal),render.texture_index(kind.surface),IMPOSTOR_GRID | key.frame<<16}
    row.far={t.fade_distance*distance,t.cull_distance*distance,0,0}
    row.transmission={kind.transmission.x,kind.transmission.y,kind.transmission.z,0}
    return
}

// The rows of the types of every Foliage, those of each from the base of its slot.
impostor_rows_build :: proc(resident:^Foliage_Resident,data:^Foliage_Data) {
    d:=&resident.impostors
    clear(&d.rows);clear(&d.bases)
    for &owner in resident.owners {
        entry:=data_find(data,owner.source)
        if entry==nil {continue}
        if int(owner.slot)>=len(d.bases) && resize(&d.bases,int(owner.slot)+1)!=nil {return}
        d.bases[owner.slot]=u32(len(d.rows))
        for &t,i in entry.source.types {append(&d.rows,impostor_row(resident,&t,i<len(owner.kinds)?owner.kinds[i]:{}))}
    }
}

// The impostors of the world into the G-buffer of each view: what changed
// goes to the buffer, a dispatch keeps those in the band of their type and
// in the view, and one draw makes a quad of each.
@(private)
foliage_impostors_record :: proc(pass:^render.Pass,user:rawptr) {
    resident:=cast(^Foliage_Resident)user
    d:=&resident.impostors
    if pass.world!=render.world_key(resident.world) || d.count==0 || len(d.rows)==0 || len(d.bases)==0 {return}
    draw:=render.pass_gbuffer_pipeline(pass,"foliage_impostor","foliage impostors","foliage_impostor")
    cull:=render.pass_stage_pipeline(pass,{stage=.Simulate,shader="foliage_impostor_cull",name="foliage impostor cull"})
    if draw==0 || cull==0 {return}
    held:=u64(len(d.instances))
    slots:=d.capacity/size_of(Impostor_Instance)
    if slots<held || slots>4*held && slots>IMPOSTOR_SLOTS_MIN {
        slots=IMPOSTOR_SLOTS_MIN
        for slots<held {slots*=2}
        d.capacity=slots*size_of(Impostor_Instance)
    }
    instances:=render.Buffer_Desc{name=IMPOSTOR_BUFFER,size=d.capacity}
    visible:=render.Buffer_Desc{name=IMPOSTOR_VISIBLE,size=slots*4}
    args:=render.Buffer_Desc{name=IMPOSTOR_DRAW,size=16}
    ok,made:=render.pass_buffer(pass,0,instances)
    if !ok {return}
    if made {
        d.whole=true
        clear(&d.writes)
        append(&d.writes,[2]u32{0,u32(held)})
    }
    // What does not fit in the memory of the frame waits for the next one.
    kept:=0
    for w in d.writes {
        if u64(w[0])>=held {continue}
        count:=min(w[1],u32(held)-w[0])
        if count==0 {continue}
        if render.pass_buffer_write(pass,instances,u64(w[0])*size_of(Impostor_Instance),&d.instances[w[0]],int(count)*size_of(Impostor_Instance)) {
            if w[0]==0 && u64(count)==held {d.whole=false}
            continue
        }
        d.writes[kept]=w
        kept+=1
    }
    base.truncate(&d.writes,kept)
    if d.whole {return}
    seen,_:=render.pass_buffer(pass,1,visible)
    counted,_:=render.pass_buffer(pass,2,args)
    start:=[4]u32{6,0,0,0}
    if !seen || !counted || !render.pass_buffer_write(pass,args,0,&start,size_of(start)) {return}
    rows,uploaded:=render.pass_rows_upload(pass,raw_data(d.rows),len(d.rows)*size_of(Impostor_Row))
    bases,based:=render.pass_rows_upload(pass,raw_data(d.bases),len(d.bases)*size_of(u32))
    if !uploaded || !based {return}
    anchor:=render.origin_point(d.anchor,pass.origin)
    Params :: struct {anchor:[4]f32,count:[4]u32}
    params:=Params{anchor={anchor.x,anchor.y,anchor.z,0},count={u32(held),0,0,0}}
    render.pass_pipeline(pass,cull)
    render.pass_rows(pass,3,rows)
    render.pass_rows(pass,4,bases)
    if !render.pass_params(pass,&params,size_of(params)) {return}
    render.pass_dispatch(pass,(u32(held)+63)/64)
    render.pass_gbuffer_begin(pass,"foliage impostors")
    render.pass_pipeline(pass,draw)
    render.pass_buffer(pass,0,instances)
    render.pass_buffer(pass,1,visible)
    render.pass_rows(pass,3,rows)
    render.pass_rows(pass,4,bases)
    if render.pass_params(pass,&params,size_of(params)) {render.pass_draw_indirect(pass,args,0)}
    render.pass_end(pass)
}

// Past CELL_CROWN_REACH times the reach of the meshes of its types, a cell
// gives rays one crown for all the instances of its types that rays meet far
// in place of a crown each: one entry of the structure of rays a cell, and
// a BLAS of the cell, coarse and opaque, made as the crown of a type is
// (crown_build) of the crowns of its instances, in the space of its
// Foliage. Impostors still draw each instance.
CELL_CROWN_REACH :: f32(4)

// The crown of a cell, into out: of the crowns of the instances placed (in
// the space of their Foliage), each from the triangles of the crown of its
// type, crowns[type] (type: the index of the type); a type without them
// gives none. False when there is nothing to cover.
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

// What rays meet of the crown of a type: it casts shadows if the type does,
// and reflections and indirect light see it, in the mean color of its
// frames, if they see the type.
crown_flags :: proc "contextless" (t:^Foliage_Type) -> (flags:render.Batch_Flags) {
    flags={.Rays_Only}
    if t.casts_shadow {flags+={.Casts_Shadow}}
    if t.ray_visible {flags+={.Ray_Visible}}
    return
}
