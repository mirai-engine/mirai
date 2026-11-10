package water

import "core:math"
import "core:math/linalg"
import "mirai:asset"
import "mirai:core"
import render "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import geom "mirai:std/geom"
import mm "mirai:std/math"
import fog "plugins:fog/runtime"
import phys "plugins:physics/runtime"

// Water: the Fluid_Volume rows of the physics drawn as water, from the same
// fluids the physics floats bodies in. Each surface is a solid of the glass
// of the renderer: a plane, an open grid around the camera on its waves; a
// box, its cube. Under it, a medium of the fog plugin that takes the light of
// the sun that crosses it; the dry boxes take both out of where they are, and
// their floor of air under a surface is a surface of its own. The light of
// the sun on what is under the water carries caustics. A volume draws as
// WATER_DEFAULT unless its entity has a Water.

CAPACITY :: 8 // fluids and dry boxes a frame draws
SURFACE_PROGRAM :: "Water_Surface"
WATER_IOR :: f32(1.333)
CAUSTIC_TEXELS :: 256 // across the caustic pattern
LENS_WIDTH :: f32(0.01) // m of the surface over and under the near plane where its line shows on the lens

@(component,description="How the water of the Fluid_Volume of this entity looks: the material of its surface, and of its solid what it absorbs and scatters. A Fluid_Volume without it looks as the default.")
Water :: struct {
    material:base.Asset_Id,                          // of its surface and its solid; zero: a glass of water with the program of Water_Settings and the values below
    attenuation_color:[3]f32 `mirai:"color"`,        // what the water leaves of white light that crosses attenuation_distance of it
    attenuation_distance:f32 `mirai:"min=0,unit=m"`,
    scatter_color:[3]f32 `mirai:"color"`,            // of what it stops, the share it scatters towards the eye
    shafts:f32 `mirai:"min=0,unit=1/m"`,             // how much of the light of the sun it scatters in shafts, behind what stands in its way
    caustics:f32 `mirai:"min=0,max=4"`,              // how much the pattern of light under the surface changes the light of the sun
}

// The Surface program of the water without a material of its own; "" is
// SURFACE_PROGRAM. Another plugin that draws more on that surface names its
// own program here, one that takes the parameters of Water_Surface; a name no
// program has is SURFACE_PROGRAM.
@(storage,setting)
Water_Settings :: struct {
    surface_program:[asset.MATERIAL_NAME_BYTES]u8 `mirai:"text"`,
}

WATER_DEFAULT :: Water{attenuation_color={0.3,0.7,0.75},attenuation_distance=4,scatter_color={0.1,0.6,0.7},shafts=0.03,caustics=1}

// water_waves.slang Water_Body: a fluid or a dry box of the frame.
@(private)
Gpu_Body :: struct {
    to_box:[3][4]f32, // rows: from the world to its box, whose sides are 1
    surface:[4]f32,   // x the height of its still surface, y 1 for a plane, z 1 for a dry box, w priority
    look:[4]f32,      // x caustics, y 1/m it takes of white light, z the index of refraction of its surface, w its waves
    waves:[phys.FLUID_WAVES][4]f32, // physics.Wave_Term: k along x and z, amplitude, across
    phases:[2][4]f32, // of each wave, at the origin of the pass and the time of the frame
}
#assert(size_of(Gpu_Body)==240)

// water_light.comp.slang Water_Params.
@(private)
Gpu_Params :: struct {
    count:u32,
    texels:u32,
    lens:f32,
    ior:f32, // of the surface the caustic pattern is made for
}

@(storage,host)
Water_Gpu :: struct {
    surface:base.Asset_Id, // the generated grid of the planes
    made:bool,             // surface was asked for
    pipelines:[3]render.Pipeline, // the caustic pattern, the light under the water, the line on the lens
    bodies:[CAPACITY]Gpu_Body,
    waves:[CAPACITY]phys.Surface_Waves, // of each body, in the world
    count:int,
    time:f64,     // s of the simulation the waves of the frame are at
    caustic:bool, // some fluid of the frame has caustics
    ior:f32,      // of the first fluid of the frame with caustics
    looks:[CAPACITY]Water_Look,
    look_count:int,
    air:u32,       // the row of the air of a dry box the camera is in; 0 until one is
    looks_seen:u64, // the versions of the Water rows and of the assets the looks were made with
    sheets:[CAPACITY]Sheet,
    sheet_pipeline:render.Pipeline,
    frame:u64,
}

// The material of a volume, made again only when its Water or the assets change.
@(private)
Water_Look :: struct {
    entity:core.Entity,
    row:u32,
    ior:f32,
}

// The row of the material of a volume and the index of refraction of its surface.
@(private)
look_of :: proc(state:^Water_Gpu,app:^host.App,e:core.Entity,look:Water,program:string) -> Water_Look {
    for known in state.looks[:state.look_count] {if known.entity==e {return known}}
    made:=Water_Look{entity=e,ior=WATER_IOR}
    if look.material!={} {
        made.row=host.assets_material_row(app.assets,look.material)
        made.ior=max(host.assets_material_values(app.assets,made.row).ior,1)
    } else {made.row,_=default_material(app,look,program)}
    // A material not loaded yet is asked for again.
    if made.row!=0 && state.look_count<CAPACITY {
        state.looks[state.look_count]=made
        state.look_count+=1
    }
    return made
}

// The row of the material of a surface without one of its own: a solid of
// glass that absorbs and scatters as its Water says, with the Surface program
// named (Water_Settings).
@(private)
default_material :: proc(app:^host.App,look:Water,name:string) -> (row:u32,ok:bool) {
    desc:=host.assets_material_values(app.assets,0)
    desc.roughness,desc.transmission,desc.ior,desc.thickness=0.02,1,WATER_IOR,1
    desc.attenuation_color,desc.attenuation_distance,desc.scatter_color=look.attenuation_color,look.attenuation_distance,look.scatter_color
    name:=name
    program:=render.program_find(app.assets,name,.Surface) if name!="" else nil
    if program==nil {name,program=SURFACE_PROGRAM,render.program_find(app.assets,SURFACE_PROGRAM,.Surface)}
    if program!=nil {
        desc.program_id=program.id
        desc.custom_params=render.program_defaults(program)
        base.text_set(desc.program[:],name)
    }
    return host.assets_material_derive(app.assets,desc)
}

// The bodies of the frame for its shaders, whose places are relative to an
// origin (that the renderer draws from, or the middle of a sheet): built in
// the world, they move by it, and the phases of their waves are measured
// from it at the time of the frame.
@(private)
bodies_relative :: proc "contextless" (state:^Water_Gpu,origin:[3]f32) -> (bodies:[CAPACITY]Gpu_Body) {
    for b,i in state.bodies[:state.count] {
        bodies[i]=b
        bodies[i].to_box=render.origin_from_world(b.to_box,origin)
        bodies[i].surface.x=render.origin_point({0,b.surface.x,0},origin).y
        terms,count:=phys.wave_terms(&state.waves[i],state.time,{f64(origin.x),f64(origin.z)})
        for term,k in terms[:count] {
            bodies[i].waves[k]={term.k.x,term.k.y,term.amplitude,term.across}
            bodies[i].phases[k/4][k%4]=term.phase
        }
    }
    return
}

// 1/m the water takes of white light: the mean of what its attenuation takes of each channel.
@(private)
extinction :: proc "contextless" (look:Water) -> f32 {
    if !(look.attenuation_distance>0) {return 0}
    c:=look.attenuation_color
    taken:=-(math.ln(max(c.r,1e-4))+math.ln(max(c.g,1e-4))+math.ln(max(c.b,1e-4)))/3
    return taken/look.attenuation_distance
}

// The box of a fluid of the physics, whose sides are its scale.
@(private)
fluid_box :: proc "contextless" (desc:phys.Fluid_Desc) -> mm.Transform {
    return {desc.position,mm.quat_axis_angle({0,1,0},desc.yaw),2*desc.half_extents}
}

// How deep a plane reaches under its surface for its medium, and how far sideways from the camera.
PLANE_DEPTH :: f32(2048)
PLANE_REACH :: f32(8192)

// The time the waves show in a frame: that of the simulation the poses of its bodies are drawn at, between
// its last two steps; without playing, the clock of the application, for the waves to move in the editor.
@(private)
waves_time :: proc(physics:core.Ref(phys.Physics_State),time:core.Time,frame:core.Frame_Time,app:^host.App) -> f64 {
    if !time.playing {return app.seconds}
    return phys.fluid_time(physics)-f64((1-frame.alpha)*time.dt)
}

// The water of the frame: its surfaces as instances, its media into the fog,
// the passes of the light under it and what goes over its glass.
@(step="render",loops="game editor",before="render_sync")
water_render :: proc(
    state:^Water_Gpu,media:^fog.Fog_Media,waters:core.Read(Water),physics:core.Ref(phys.Physics_State),
    settings:Water_Settings,view:core.View,app:^host.App,time:core.Time,frame:core.Frame_Time,
) {
    state.count,state.caustic,state.ior=0,false,WATER_IOR
    state.frame+=1
    defer sheets_release(state,app)
    if app.renderer==nil || app.assets==nil {return}
    found:[CAPACITY]phys.Fluid_Info
    far:=f32(1e30)
    count:=min(phys.fluids_in(physics,{{-far,-far,-far},{far,far,far}},found[:]),CAPACITY)
    if count==0 {return}
    if !state.made {
        state.made=true
        buffer:geom.Mesh_Buffer
        defer geom.mesh_buffer_destroy(&buffer)
        surface_build(&buffer)
        // u along x and v along z: the bitangent, along +Z, is -cross(normal, tangent).
        tangents:=make([][4]f32,len(buffer.positions),context.temp_allocator)
        for &t in tangents {t={1,0,0,-1}}
        state.surface,_=host.assets_mesh_generate(app.assets,geom.mesh_buffer_view(&buffer),options={no_lods=true,tangents=tangents})
    }
    // A derived row lasts while the rounds of the assets keep it: a new round asks for them again.
    settings:=settings
    program:=base.text_get(settings.surface_program[:])
    if seen:=core.version(waters)+core.layout(waters)+app.assets.revision+app.assets.appearance+base.name_hash(program);seen!=state.looks_seen {
        state.looks_seen,state.look_count,state.air=seen,0,0
    }
    state.time=waves_time(physics,time,frame,app)
    lens:=false
    materials:[CAPACITY]u32
    kept:[CAPACITY]phys.Fluid_Info
    for info in found[:count] {
        desc:=info.desc
        look,custom:=core.get(waters,info.entity)
        if !custom {look=WATER_DEFAULT}
        dry:=desc.density<=0
        made:=look_of(state,app,info.entity,look,program)
        body:Gpu_Body
        box:=fluid_box(desc)
        top:=info.top
        reach:=phys.waves_reach(desc.waves)
        if desc.shape==.Plane {
            // The plane follows the camera: its grid by whole steps, its medium as it is, from under its troughs.
            box={{view.position.x,top-reach-0.5*PLANE_DEPTH,view.position.z},1,{2*PLANE_REACH,PLANE_DEPTH,2*PLANE_REACH}}
        } else if !dry {
            if instance,usable:=render.mesh_instance(app.assets,{shape=.Cube},mm.transform_matrix(box));usable {
                instance.material=render.Material_Handle(made.row)
                instance.object_id,instance.copy_owner=u64(info.entity),base.name_hash("water")
                render.instance_add(app,instance)
            }
        }
        if dry && phys.fluid_holds(physics,info.fluid,view.position) {
            // The camera in a dry box is in its air: a solid of glass that bends and holds nothing, which the
            // glass takes for the one the camera is in instead of the water around it.
            if state.air==0 {
                air:=host.assets_material_values(app.assets,0)
                air.roughness,air.transmission,air.ior,air.thickness=0,1,1,1
                state.air,_=host.assets_material_derive(app.assets,air)
            }
            if state.air!=0 {
                if instance,usable:=render.mesh_instance(app.assets,{shape=.Cube},mm.transform_matrix(box));usable {
                    instance.material=render.Material_Handle(state.air)
                    instance.object_id,instance.copy_owner=u64(info.entity),base.name_hash("water air")
                    render.instance_add(app,instance)
                }
            }
        }
        if !dry {
            // The solid of the glass absorbs what the view crosses along its bent way and scatters the light
            // around; the fog scatters the light of the sun in the water, with its shafts, and takes what the
            // water takes of it on its way down.
            fog.medium_add(media,{box=box,density=extinction(look),color=look.scatter_color,anisotropy=0.6,priority=desc.priority,carved=true,sun_only=true,shade=extinction(look),glass=true})
        } else {
            fog.medium_add(media,{box=box,priority=desc.priority,dry=true})
        }
        to_world:=mm.transform_matrix(box)
        if abs(linalg.determinant(to_world))<1e-12 {continue}
        body.to_box=mm.mat4_rows(linalg.inverse(to_world))
        body.surface={top,desc.shape==.Plane?1:0,dry?1:0,f32(desc.priority)}
        body.look={max(look.caustics,0),extinction(look),made.ior,f32(desc.waves.count)}
        if !state.caustic && !dry && look.caustics>0 {state.caustic,state.ior=true,made.ior}
        lens||=!dry && abs(view.position.y-top)<=LENS_WIDTH+reach+lens_reach(view)
        materials[state.count]=made.row
        kept[state.count]=info
        state.waves[state.count]=desc.waves
        state.bodies[state.count]=body
        state.count+=1
    }
    for info,i in kept[:state.count] {
        desc:=info.desc
        if desc.shape==.Plane {
            sheet_place(state,app,view,i,info.entity,materials[i])
        } else if desc.density<=0 && !crosses_plane(state,i) && floor_in_fluid(physics,desc) {
            // The floor of the air of a dry box in a fluid is a surface of that fluid, seen from over it; where the
            // box crosses the surface of a plane, the sheet of the plane goes down to it instead.
            box:=fluid_box(desc)
            floor:=mm.Transform{desc.position-{0,desc.half_extents.y,0},box.rotation,{box.scale.x,1,box.scale.z}}
            if instance,usable:=render.mesh_instance(app.assets,{shape=.Plane},mm.transform_matrix(floor));usable {
                instance.material=render.Material_Handle(materials[i])
                instance.object_id,instance.copy_owner=u64(info.entity),base.name_hash("water floor")
                render.instance_add(app,instance)
            }
        }
    }
    if state.count==0 {return}
    state.pipelines={
        render.stage_pipeline(app,{stage=.Lit,shader="water_caustics",name="water caustics"}),
        render.stage_pipeline(app,{stage=.Lit,shader="water_light",name="water light"}),
        render.stage_pipeline(app,{stage=.Blend,shader="water_over",name="water over",blend=.Alpha}),
    }
    if state.caustic && state.pipelines[0]!=0 && state.pipelines[1]!=0 {render.frame_pass(app,.Lit,caustics_record,state)}
    // Over the glass: the line of a surface the near plane may cross.
    if state.pipelines[2]!=0 && lens {render.frame_pass(app,.Blend,over_record,state)}
}

// How far from the eye of a view its near plane reaches within the image: where a surface can cross the lens.
@(private)
lens_reach :: proc "contextless" (view:core.View) -> f32 {
    aspect:=view.size.y>0?view.size.x/view.size.y:1
    across:=[2]f32{aspect*(1+abs(view.shift.x)),1+abs(view.shift.y)}
    switch view.projection {
    case .Perspective:
        t:=math.tan(0.5*view.fov)
        return view.near*math.sqrt(1+t*t*(across.x*across.x+across.y*across.y))
    case .Orthographic:
        return view.near+0.5*view.height*math.sqrt(across.x*across.x+across.y*across.y)
    case .Custom:
    }
    return max(f32)
}

// Whether the floor of a dry box is a surface of a fluid: as the physics finds it, the fluid under the floor
// and taken out by the box over it.
@(private)
floor_in_fluid :: proc(physics:core.Ref(phys.Physics_State),dry:phys.Fluid_Desc) -> bool {
    FLOOR_PROBE :: f32(1e-3) // m under and over the floor where the fluid is looked for
    floor:=dry.position-{0,dry.half_extents.y,0}
    under,_,wet:=phys.fluid_at(physics,floor-{0,FLOOR_PROBE,0})
    over,_,found:=phys.fluid_at(physics,floor+{0,FLOOR_PROBE,0})
    return wet && under.density>0 && found && over.fluid==under.fluid && over.density==0
}

@(private)
caustics_record :: proc(pass:^render.Pass,user:rawptr) {
    state:=cast(^Water_Gpu)user
    // On the opaque scene: nothing of it is in front of glass.
    if pass.glass==.Front {return}
    params:=Gpu_Params{count=u32(state.count),texels=CAUSTIC_TEXELS,lens=LENS_WIDTH,ior=state.ior}
    pattern:=render.Pass_Texture_Desc{name="water caustics",format=.R16_Float,width=CAUSTIC_TEXELS,height=CAUSTIC_TEXELS}
    // The pattern the surface gives the light of the sun at a depth, which repeats across it.
    render.pass_timestamp(pass,"water caustics")
    if ok,_:=render.pass_texture(pass,0,pattern);!ok {return}
    render.pass_pipeline(pass,state.pipelines[0])
    if !render.pass_params(pass,&params,size_of(params)) {return}
    render.pass_dispatch(pass,(CAUSTIC_TEXELS+7)/8,(CAUSTIC_TEXELS+7)/8)
    // Over the direct light of what is under the water.
    render.pass_image_bind(pass,0)
    render.pass_texture_sample(pass,1,pattern)
    render.pass_surface_read(pass,2,.Linear_Depth)
    render.pass_surface_read(pass,3,.Direct)
    render.pass_timestamp(pass,"water light")
    render.pass_pipeline(pass,state.pipelines[1])
    if !bodies_bind(pass,state) {return}
    render.pass_dispatch(pass,(pass.width+7)/8,(pass.height+7)/8)
}

@(private)
over_record :: proc(pass:^render.Pass,user:rawptr) {
    state:=cast(^Water_Gpu)user
    if pass.glass==.Behind {return}
    render.pass_blend_begin(pass,"water over")
    render.pass_pipeline(pass,state.pipelines[2])
    if bodies_bind(pass,state) {render.pass_draw(pass,3)}
    render.pass_end(pass)
}

// Binds what water.slang declares for the stages of the water (WATER_STAGE):
// the constants of the pass and the bodies of the frame, relative to its
// origin. A pass of another plugin over the water binds them with this after
// its pipeline.
bodies_bind :: proc(pass:^render.Pass,state:^Water_Gpu) -> bool {
    params:=Gpu_Params{count=u32(state.count),texels=CAUSTIC_TEXELS,lens=LENS_WIDTH,ior=state.ior}
    bodies:=bodies_relative(state,pass.origin)
    return render.pass_params(pass,&params,size_of(params)) && render.pass_upload(pass,4,&bodies,state.count*size_of(Gpu_Body))
}
