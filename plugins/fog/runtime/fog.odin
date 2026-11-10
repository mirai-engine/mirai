package fog

import "core:math"
import "core:math/linalg"
import "mirai:core"
import volume "mirai:engine/volume"
import render "mirai:engine/render"
import "mirai:host"
import mm "mirai:std/math"

// Volumetric fog: a medium where the Volume of its entity says (without one,
// the whole world) that dims what is behind it and shows the light that
// crosses it, with the shafts that what stands in the way of the sun and the
// lights cuts in it. Each view lights a
// grid of cells along its frustum (froxels), keeps their light over frames
// and lays it over the lit opaque scene; with glass in view, what lies behind
// its nearest layer before the glass and what lies in front over it. Past the
// grid the same media go on to the depth of each pixel and to the sky, in
// closed form, lit by the sun without shadows and by the light around. Its cost depends
// neither on the resolution of the view nor on how many lights there are.
// Other plugins add media of their own to a frame (Fog_Media): the water
// under a surface, which takes the light of the sun that crosses it, and the
// dry boxes that take it out.

CAPACITY :: 16      // volumes a frame takes
GRID_COLUMNS :: 160 // across a view; its rows follow its proportion
GRID_PIXELS :: 8    // a narrower view has a column every this many pixels
GRID_SLICES :: 64   // along a view, thinner near the eye
DISTANCE :: f32(128)  // metres along the view the grid reaches: beyond it the media go on in closed form
FAR_SLICES :: 32        // past the grid, each further than the one before by the same ratio; the last goes on without end
FAR_REACH :: f32(32768) // metres along the view where the last of them begins
SLICE_SCALE :: f32(2) // metres: about where slices stop growing in step with the distance and start growing with it
HISTORY :: f32(0.9)   // the weight of what the frames before found

@(component,description="A medium that dims what is behind it and shows the light that crosses it, with the shafts of the sun and the lights. Fills the Volume of its entity, over what is below it or added to it; without a Volume, the whole world.")
Fog_Volume :: struct {
    density:f32 `mirai:"min=0,unit=1/m"`,        // of the light that crosses a metre of it, about the share it stops
    color:[3]f32 `mirai:"color"`,                // of what it stops, the share it scatters; it absorbs the rest
    anisotropy:f32 `mirai:"min=-0.95,max=0.95"`, // above 0 it scatters forward, and a shaft glows more seen towards its light; below 0, back
    falloff:f32 `mirai:"min=0,unit=1/m"`,        // it thins with the height over its base, the bottom of its Volume or its entity: by e every 1/falloff metres
    variable:bool,                               // its density varies from place to place, in wisps and banks that drift and change by themselves; density is their mean
    wisp_size:f32 `mirai:"min=0.1,unit=m"`,      // about how big its largest wisps are
    drift:[3]f32 `mirai:"unit=m/s"`,             // how fast its wisps move, and where to
}

FOG_VOLUME_DEFAULT :: Fog_Volume{density=0.05,color={1,1,1},anisotropy=0.5,wisp_size=1.5,drift={0.5,0.05,0.2}}

// The wisps of a variable volume are WISP_OCTAVES layers of noise, each
// smaller than the one before (fog.slang FOG_WISP_SIZES). Each moves with
// the drift times its share in WISP_DRIFT and on its own by WISP_CHANGE wisp
// sizes a second: the layers slide over each other and the wisps change
// shape as they go, with no wind.
WISP_OCTAVES :: 3
@(private) WISP_SIZES :: [WISP_OCTAVES]f32{1,0.47,0.22}
@(private) WISP_DRIFT :: [WISP_OCTAVES]f32{1,1.2,1.45}
@(private) WISP_CHANGE :: [WISP_OCTAVES][3]f32{{0,0.015,0.01},{0.04,-0.02,-0.03},{-0.05,0.03,0.06}}

// How often a cell behind everything a view sees is lit: it does not show,
// but it has its light when the camera moves and shows it.
Fog_Hidden :: enum u8 {
    Every_Frame,  // as the cells that show
    Every_Fourth, // one frame in four, by turns, keeping what it had in the others: what moving shows is as settled
    Never,        // what moving shows starts its light again, grainy for a few frames
}

@(storage,setting="machine")
Fog_Settings :: struct {
    hidden:Fog_Hidden,
}

FOG_SETTINGS_DEFAULT :: Fog_Settings{hidden=.Every_Fourth}

// fog.slang Fog_Volume.
@(private)
Gpu_Volume :: struct {
    volume:volume.Gpu_Volume,
    medium:[4]f32, // rgb what it scatters in a metre, a what it stops; of a variable one, the mean
    params:[4]f32, // x 1 over its wisp size (0: it does not vary), y anisotropy, z falloff, w the height of its base
    carve:[4]f32,  // x priority, y CARVE_* bits, z 1/m it takes of the light of the sun that crosses it
    cells:[WISP_OCTAVES][4]i32,  // xyz the cell of each layer of its wisps at the origin of the render now
    within:[WISP_OCTAVES][4]f32, // xyz where in that cell, 0 to 1
}

// fog.slang FOG_CARVE_*.
@(private) CARVE_DRY :: 1
@(private) CARVE_CARVED :: 2
@(private) CARVE_SUN_ONLY :: 4
@(private) CARVE_GLASS :: 8

// The volumes of the frame for its shaders, whose places are relative to the
// origin the renderer draws from: built in the world, they move by it. The
// layers of the wisps of each, where they are at the time of the frame.
@(private)
volumes_relative :: proc "contextless" (state:^Fog_Gpu,origin:[3]f32) -> (volumes:[CAPACITY]Gpu_Volume) {
    for v,i in state.volumes[:state.count] {
        volumes[i]=v
        volumes[i].volume=volume.gpu_volume_relative(v.volume,origin)
        volumes[i].params.w=render.origin_point({0,v.params.w,0},origin).y
        if v.params.x>0 {
            for k in 0..<WISP_OCTAVES {
                volumes[i].cells[k],volumes[i].within[k]=wisp_lattice(state.drift[i],1/f64(v.params.x),k,origin,state.time)
            }
        }
    }
    return
}
#assert(size_of(Gpu_Volume)==224)

// Where layer k of the wisps of a volume is at the origin of the render at a
// time, in cells of the layer: a place of the world p is in the layer at
// (p - its motion * time) / its cell. In f64 and apart from the whole cells,
// what a float would lose far from the centre of the world or after hours
// stays.
@(private)
wisp_lattice :: proc "contextless" (drift:[3]f32,wisp_size:f64,k:int,origin:[3]f32,time:f64) -> (cell:[4]i32,within:[4]f32) {
    sizes,shares,changes:=WISP_SIZES,WISP_DRIFT,WISP_CHANGE
    size:=wisp_size*f64(sizes[k])
    for axis in 0..<3 {
        motion:=f64(drift[axis])*f64(shares[k])+f64(changes[k][axis])*wisp_size
        at:=(f64(origin[axis])-motion*time)/size
        whole:=math.floor(at)
        cell[axis]=i32(i64(whole))
        within[axis]=f32(at-whole)
    }
    return
}

// A medium another plugin adds to a frame, before fog_render: a box of the
// world, which adds to the volumes of the world. A dry box holds no medium:
// it takes out of itself the media that carve and have a lower priority, and
// their shade.
Medium :: struct {
    box:mm.Transform,  // the box, whose sides are its scale
    density:f32,       // 1/m, of the light that crosses a metre of it, about the share it stops
    color:[3]f32,      // of what it stops, the share it scatters; it absorbs the rest
    anisotropy:f32,
    priority:i32,
    dry:bool,
    carved:bool,       // dry boxes of higher priority take it out
    sun_only:bool,     // the sun alone lights it, in shafts: the light around it is drawn by the plugin that adds it
    shade:f32,         // 1/m it takes of the light of the sun that crosses it: the medium and the surfaces in it are darker deeper
    glass:bool,        // the glass of its surface takes what it stops of the view: it adds its light, dimmed on its way to the eye in it, and dims nothing behind it
}

// fog.slang Fog_Params.
@(private)
Gpu_Params :: struct {
    grid:[4]u32, // columns, rows, slices, volumes
    kept:u32,    // the light of the frame before is there
    distance:f32,
    scale:f32,
    history:f32,
    hidden:u32,  // a cell behind everything seen is lit one frame in this many; 0: never
    dry:u32,     // some volume is a dry box
    shade:u32,   // some volume takes the light of the sun
    far:u32,     // slices past the grid
    reach:f32,   // metres along the view where the last of them begins
    side:u32,    // render.Glass_Side of the nearest layer of glass, where fog_apply lays the fog
    pad:[2]u32,
}
#assert(size_of(Gpu_Params)==64)

// What the passes of each view draw the fog of the frame with.
@(storage,host)
Fog_Gpu :: struct {
    pipelines:[5]render.Pipeline, // the farthest depth of each column and of those around it, the light of the grid, integrating it, laying it over the image
    volumes:[CAPACITY]Gpu_Volume,
    drift:[CAPACITY][3]f32, // of the wisps of each variable volume, m/s
    count:int,
    hidden:u32,
    time:f64,   // seconds of the world the frame shows
    dry:bool,   // some volume of the frame is a dry box
    shade:bool, // some volume of the frame takes the light of the sun
}

// The media other plugins add to the frame.
@(storage,queue)
Fog_Media :: struct {
    queue:core.Queue(Medium),
}

medium_add :: proc(media:^Fog_Media,medium:Medium) {core.push(&media.queue,medium)}

// The volumes of the world and, over them, the media of the frame into the frame.
@(step="render",loops="game editor",after="render_sync")
fog_render :: proc(
    state:^Fog_Gpu,volumes:core.Read(Fog_Volume),places:core.Read(volume.Volume),media:^Fog_Media,worlds:core.Read(core.World_Transform),
    hidden:core.Read(render.Hidden),parents:core.Read(core.Parent),settings:core.Ref(Fog_Settings),app:^host.App,
) {
    state.count,state.dry,state.shade=0,false,false
    periods:=[Fog_Hidden]u32{.Every_Frame=1,.Every_Fourth=4,.Never=0}
    state.hidden=periods[settings.hidden] if settings.hidden<=.Never else 1
    added:=core.take(&media.queue)
    if app.renderer==nil || core.count(volumes)==0 && len(added)==0 {return}
    // The media keep their room: the lowest priorities of the world are left out first.
    rows:[CAPACITY]i32
    for row in rows[:volume.ordered(places,worlds,volumes,rows[:CAPACITY-min(len(added),CAPACITY)])] {
        e:=core.entity_at(volumes,int(row))
        fog:=core.at(volumes,int(row))
        if !(fog.density>0) || render.is_hidden(hidden,parents,e) {continue}
        place,at,_:=volume.placed(places,worlds,e)
        volume_gpu(state,fog,place,at)
    }
    for medium in added {medium_gpu(state,medium)}
    fog_submit(state,app)
}

// A volume of the world placed at a pose into the frame.
@(private)
volume_gpu :: proc(state:^Fog_Gpu,fog:Fog_Volume,place:volume.Volume,at:mm.Transform) {
    if state.count>=CAPACITY {return}
    color:=linalg.clamp(fog.color,0,1)
    entry:=Gpu_Volume{
        volume=volume.gpu_volume(place,at),
        medium={color.r*fog.density,color.g*fog.density,color.b*fog.density,fog.density},
        params={fog.variable?1/max(fog.wisp_size,0.1):0,clamp(fog.anisotropy,-0.95,0.95),max(fog.falloff,0),at.position.y},
    }
    half:=entry.volume.shape.xyz
    if place.shape==.Box {
        // The base is the lowest corner of the box.
        low:=max(f32)
        for corner in 0..<8 {
            local:=[3]f32{corner&1!=0?half.x:-half.x,corner&2!=0?half.y:-half.y,corner&4!=0?half.z:-half.z}
            low=min(low,at.position.y+mm.quat_rotate(at.rotation,local).y)
        }
        entry.params.w=low
    } else if place.shape==.Sphere {
        entry.params.w=at.position.y-half.x
    }
    state.volumes[state.count]=entry
    state.drift[state.count]=fog.drift
    state.count+=1
}

// The volumes of the state into the frame, at the time of the world it shows.
@(private)
fog_submit :: proc(state:^Fog_Gpu,app:^host.App) {
    if state.count==0 {return}
    state.time=f64(app.time)
    // 0 while the shaders in use have no fog: a generation made without the plugin.
    state.pipelines={
        render.stage_pipeline(app,{stage=.Lit,shader="fog_far",name="fog far"}),
        render.stage_pipeline(app,{stage=.Lit,shader="fog_reach",name="fog reach"}),
        render.stage_pipeline(app,{stage=.Lit,shader="fog_light",name="fog light"}),
        render.stage_pipeline(app,{stage=.Lit,shader="fog_integrate",name="fog integrate"}),
        render.stage_pipeline(app,{stage=.Lit,shader="fog_apply",name="fog apply"}),
    }
    for pipeline in state.pipelines {if pipeline==0 {return}}
    render.frame_pass(app,.Lit,fog_record,state)
}

// A medium into the frame, a box that adds to what is there; false when the
// frame holds CAPACITY volumes already or its box has no size.
@(private)
medium_gpu :: proc(state:^Fog_Gpu,medium:Medium) -> bool {
    sides:=linalg.abs(medium.box.scale)
    if state.count>=CAPACITY || !(sides.x*sides.y*sides.z>0) {return false}
    density:=medium.dry?0:max(medium.density,0)
    color:=linalg.clamp(medium.color,0,1)
    low:=max(f32)
    for corner in 0..<8 {
        local:=[3]f32{f32(corner&1),f32(corner>>1&1),f32(corner>>2&1)}-0.5
        low=min(low,mm.transform_point(medium.box,local).y)
    }
    state.drift[state.count]={}
    state.volumes[state.count]={
        volume=volume.gpu_volume({shape=.Box,extents={0.5,0.5,0.5},mode=.Add},medium.box),
        medium={color.r*density,color.g*density,color.b*density,density},
        params={0,clamp(medium.anisotropy,-0.95,0.95),0,low},
        carve={f32(medium.priority),f32((medium.dry?u32(CARVE_DRY):0)|(medium.carved?u32(CARVE_CARVED):0)|(medium.sun_only?u32(CARVE_SUN_ONLY):0)|(medium.glass?u32(CARVE_GLASS):0)),medium.dry?0:max(medium.shade,0),0},
    }
    state.count+=1
    state.dry||=medium.dry
    state.shade||=medium.shade>0 && !medium.dry
    return true
}

// The grid of a view: a column every GRID_PIXELS pixels up to GRID_COLUMNS,
// and as many rows as keep its cells about square on the screen.
grid_size :: proc "contextless" (width,height:u32) -> [3]u32 {
    if width==0 || height==0 {return {}}
    columns:=clamp((width+GRID_PIXELS-1)/GRID_PIXELS,1,GRID_COLUMNS)
    return {columns,max(u32(math.round(f32(columns)*f32(height)/f32(width))),1),GRID_SLICES}
}

@(private)
fog_record :: proc(pass:^render.Pass,user:rawptr) {
    state:=cast(^Fog_Gpu)user
    grid:=grid_size(pass.width,pass.height)
    if grid.x==0 {return}
    light:=render.Pass_Texture_Desc{name="fog light",format=.RGBA16_Float,width=grid.x,height=grid.y,depth=grid.z,history=true}
    medium:=render.Pass_Texture_Desc{name="fog medium",format=.RGBA16_Float,width=grid.x,height=grid.y,depth=grid.z}
    seen:=render.Pass_Texture_Desc{name="fog seen",format=.RGBA16_Float,width=grid.x,height=grid.y,depth=grid.z+FAR_SLICES}
    far:=render.Pass_Texture_Desc{name="fog far",format=.R32_Float,width=grid.x,height=grid.y}
    reach:=render.Pass_Texture_Desc{name="fog reach",format=.R32_Float,width=grid.x,height=grid.y}
    params:=Gpu_Params{grid={grid.x,grid.y,grid.z,u32(state.count)},distance=DISTANCE,scale=SLICE_SCALE,history=HISTORY,hidden=state.hidden,dry=state.dry?1:0,shade=state.shade?1:0,far=FAR_SLICES,reach=FAR_REACH,side=u32(pass.glass)}
    // In front of glass the grid of the view is lit already: the fog from the eye to the glass goes over it.
    if pass.glass==.Front {
        volumes:=volumes_relative(state,pass.origin)
        fog_apply(pass,state,&params,&volumes,seen)
        return
    }
    // How far each column sees, and the columns around it: what lies behind is not seen.
    if state.hidden!=1 {
        render.pass_timestamp(pass,"fog far")
        render.pass_surface_read(pass,0,.Linear_Depth)
        if ok,_:=render.pass_texture(pass,1,far);!ok {return}
        render.pass_pipeline(pass,state.pipelines[0])
        if !render.pass_params(pass,&params,size_of(params)) {return}
        render.pass_dispatch(pass,grid.x,grid.y)
        render.pass_texture(pass,0,far)
        if ok,_:=render.pass_texture(pass,1,reach);!ok {return}
        render.pass_pipeline(pass,state.pipelines[1])
        if !render.pass_params(pass,&params,size_of(params)) {return}
        render.pass_dispatch(pass,(grid.x+7)/8,(grid.y+7)/8)
        render.pass_texture(pass,3,reach)
    } else {
        // Not read: every cell is lit.
        render.pass_surface_read(pass,3,.Linear_Depth)
    }
    // The medium of each cell, and its light with what the frame before found where it was then.
    now,kept:=render.pass_texture(pass,0,light)
    before,_:=render.pass_texture(pass,1,light,previous=true)
    held,_:=render.pass_texture(pass,4,medium)
    if !now || !before || !held {return}
    params.kept=kept?1:0
    render.pass_timestamp(pass,"fog light")
    render.pass_surface_read(pass,5,.Shadow_Atlas)
    render.pass_shadow_data(pass,6)
    render.pass_surface_read(pass,7,.Shadow_Tint)
    render.pass_surface_read(pass,8,.Shadow_Glass)
    render.pass_pipeline(pass,state.pipelines[2])
    volumes:=volumes_relative(state,pass.origin)
    if !render.pass_params(pass,&params,size_of(params)) || !render.pass_upload(pass,2,&volumes,state.count*size_of(Gpu_Volume)) {return}
    render.pass_dispatch(pass,(grid.x+3)/4,(grid.y+3)/4,(grid.z+3)/4)
    // From the eye along each column, through the grid and past it: the light that reaches it and what is let through.
    render.pass_texture(pass,0,light)
    if ok,_:=render.pass_texture(pass,1,seen);!ok {return}
    render.pass_texture(pass,2,medium)
    render.pass_timestamp(pass,"fog integrate")
    render.pass_pipeline(pass,state.pipelines[3])
    if !render.pass_params(pass,&params,size_of(params)) || !render.pass_upload(pass,3,&volumes,state.count*size_of(Gpu_Volume)) {return}
    render.pass_dispatch(pass,(grid.x+7)/8,(grid.y+7)/8)
    fog_apply(pass,state,&params,&volumes,seen)
}

// The fog over the image, to the depth of each pixel: with glass in view, on
// the side of its nearest layer of the pass.
@(private)
fog_apply :: proc(pass:^render.Pass,state:^Fog_Gpu,params:^Gpu_Params,volumes:^[CAPACITY]Gpu_Volume,seen:render.Pass_Texture_Desc) {
    render.pass_image_bind(pass,0)
    if ok,_:=render.pass_texture(pass,1,seen);!ok {return}
    render.pass_surface_read(pass,2,.Linear_Depth)
    render.pass_surface_read(pass,4,.Glass_Depth)
    render.pass_timestamp(pass,"fog over glass" if pass.glass==.Front else "fog apply")
    render.pass_pipeline(pass,state.pipelines[4])
    if !render.pass_params(pass,params,size_of(params^)) || !render.pass_upload(pass,3,volumes,state.count*size_of(Gpu_Volume)) {return}
    render.pass_dispatch(pass,(pass.width+7)/8,(pass.height+7)/8)
}
