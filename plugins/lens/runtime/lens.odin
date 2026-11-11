package lens

import "core:math"
import "mirai:core"
import camera "mirai:engine/camera"
import render "mirai:engine/render"
import volume "mirai:engine/volume"

// What a lens does to the image besides exposing it: the depth of field of
// its aperture, the motion blur of its shutter, the light it scatters around
// what is bright (bloom), the falloff of the light towards its corners
// (vignette), its radial distortion and the fringes of its colors. Each view
// takes them from the Lens of its camera or, without one, from the
// Lens_Volume where it is; aperture and shutter are those of the Exposure the
// view takes, so the image keeps the depth of field and the blur of the
// exposure it shows. The passes run on the resolved image of each view,
// before the PostProcess stack and the tonemap (the Post stage), and cost
// nothing while every effect is off.

// The largest radius of a circle of confusion, as a share of the height of
// the image: what is further off focus blurs as much.
COC_MAX :: f32(0.02)
// The largest radius of the blur of what moves, as a share of the height of
// the image; also the side of the tiles of the motion blur.
MOTION_MAX :: f32(0.035)
// Pixels of the layer of the depth of field on a side of a tile, whose widest
// foreground says how far the pixels of the tiles around it gather
// (lens.slang LENS_DOF_TILE): as wide as the largest circle in the layer.
DOF_TILE :: 32
// Levels of the bloom from half the size of the image: the last is a 128th of it.
BLOOM_LEVELS :: 7

@(component,description="How the camera of its entity makes its image besides exposing it: depth of field focused at a distance with the aperture of its Exposure, motion blur over its shutter time, bloom, vignette, distortion and color fringes. It replaces the Lens_Volume where the camera is.")
Lens :: struct {
    depth_of_field:bool,                             // blurs what is off focus as the aperture (f-number) of the exposure of the view does
    focus:f32 `mirai:"min=0,unit=m"`,                // distance along the view that is sharp
    sensor:f32 `mirai:"min=0,unit=m"`,               // height of the sensor: with the field of view, the focal length; 0.024 is full frame
    motion_blur:bool,                                // blurs what moves on the image over the shutter time of the exposure of the view
    bloom:f32 `mirai:"min=0,max=1"`,                 // share of the light the lens scatters around where it falls; 0.04 is a clean lens
    vignette:f32 `mirai:"min=0,max=1"`,              // how much of the natural falloff towards the corners (cos^4 of the angle off the axis) the image takes
    distortion:f32 `mirai:"min=-0.5,max=0.5"`,       // radial, at the corners: below 0 barrel, above 0 pincushion; the image keeps filling the view
    chromatic_aberration:f32 `mirai:"min=0,max=0.05"`, // red farther from the center than green and blue nearer, by this share of the distance
}

LENS_DEFAULT :: Lens{focus=10,sensor=0.024}

@(component,description="How the views look through their lens where its Volume is: depth of field, motion blur, bloom, vignette, distortion and color fringes. Without a Volume, in the whole world. A camera with its own Lens keeps it.")
Lens_Volume :: struct {
    lens:Lens `mirai:"section=Lens"`,
}

LENS_VOLUME_DEFAULT :: Lens_Volume{lens=LENS_DEFAULT}

// A volume that replaces blends the numbers of what is below into its own by
// its weight and takes its switches past half; one that adds adds its effects
// and turns on its switches past half.
lens_mix :: proc(value:^Lens_Volume,by:Lens_Volume,weight:f32,add:bool) {
    v,b:=&value.lens,by.lens
    if add {
        v.bloom+=b.bloom*weight;v.vignette+=b.vignette*weight
        v.distortion+=b.distortion*weight;v.chromatic_aberration+=b.chromatic_aberration*weight
        if weight>=0.5 {v.depth_of_field||=b.depth_of_field;v.motion_blur||=b.motion_blur}
        return
    }
    lerp :: proc "contextless" (a:^f32,b,w:f32) {a^+=(b-a^)*w}
    lerp(&v.focus,b.focus,weight);lerp(&v.sensor,b.sensor,weight)
    lerp(&v.bloom,b.bloom,weight);lerp(&v.vignette,b.vignette,weight)
    lerp(&v.distortion,b.distortion,weight);lerp(&v.chromatic_aberration,b.chromatic_aberration,weight)
    if weight>=0.5 {v.depth_of_field,v.motion_blur=b.depth_of_field,b.motion_blur}
}

// The lens of a view and the aperture and shutter of its exposure.
View_Lens :: struct {
    lens:Lens,
    aperture:f32, // f-number
    shutter:f32,  // seconds
    used:bool,    // some effect is on
}

Lens_Pass :: enum u8 {Dof_Prefilter,Dof_Tiles,Dof_Bokeh,Dof_Filter,Dof_Apply,Motion_Tiles,Motion_Neighbors,Motion_Blur,Bloom_Down,Bloom_Up,Final}
LENS_SHADERS :: [Lens_Pass]string{
    .Dof_Prefilter="lens_dof_prefilter",.Dof_Tiles="lens_dof_tiles",.Dof_Bokeh="lens_dof_bokeh",.Dof_Filter="lens_dof_filter",.Dof_Apply="lens_dof_apply",
    .Motion_Tiles="lens_motion_tiles",.Motion_Neighbors="lens_motion_neighbors",.Motion_Blur="lens_motion_blur",
    .Bloom_Down="lens_bloom_down",.Bloom_Up="lens_bloom_up",.Final="lens_final",
}

// What the passes of the frame draw with, for each view by its Camera.slot.
@(storage,host)
Lens_Gpu :: struct {
    pipelines:[Lens_Pass]render.Pipeline,
    views:[1+len(camera.Local_Views{}.items)]View_Lens,
}

// lens.slang Lens_Params.
@(private)
Gpu_Params :: struct {
    image:[4]f32,  // xy size of the image, zw its inverse
    target:[4]f32, // xy size of what the dispatch writes, zw its inverse
    dof:[4]f32,    // x radius of the circle of confusion of what is infinitely far, pixels of the image; y focus distance, m; z the largest radius, pixels
    motion:[4]f32, // x the share of the motion of a frame the shutter sees; y the largest radius and the side of a tile, pixels; zw tiles
    effects:[4]f32, // x bloom, y its levels, z vignette, w distortion
    optics:[4]f32, // x chromatic aberration, y tan of half the vertical field, z aspect, w the scale that keeps the image filling the view
    level:[4]u32,  // x the mip written, y 1 when it is read from the image
}
#assert(size_of(Gpu_Params)==112)

// The lens of the view of the frame and of each local view, and the passes
// that draw them.
@(step="render",loops="game editor")
lens_render :: proc(
    state:^Lens_Gpu,lenses:^core.Table(Lens,.Read),zones:^core.Table(Lens_Volume,.Read),places:^core.Table(volume.Volume,.Read),worlds:^core.Table(core.World_Transform,.Read),
    exposures:^core.Table(render.Exposure,.Read),view_volumes:^core.Table(render.View_Volume,.Read),view:core.View,locals:core.Ref(camera.Local_Views),renderer:^render.Renderer,
) {
    state.views={}
    if renderer==nil || core.count(lenses)==0 && core.count(zones)==0 {return}
    used:=false
    state.views[0]=view_lens(lenses,zones,places,worlds,exposures,view_volumes,view)
    used||=state.views[0].used
    for local,slot in locals.items {
        if int(local.slot)!=slot+1 {continue}
        state.views[slot+1]=view_lens(lenses,zones,places,worlds,exposures,view_volumes,local)
        used||=state.views[slot+1].used
    }
    if !used {return}
    shaders:=LENS_SHADERS
    for &pipeline,pass in state.pipelines {
        pipeline=render.stage_pipeline(renderer,{stage=.Post,shader=shaders[pass],name=shaders[pass]})
        // 0 while the shaders in use have no lens: a generation made without the plugin.
        if pipeline==0 {return}
    }
    render.frame_pass(renderer,.Post,lens_record,state)
}

// How a view looks through its lens: its camera's own, or the one of where it is.
view_lens :: proc(
    lenses:^core.Table(Lens,$A),zones:^core.Table(Lens_Volume,$B),places:^core.Table(volume.Volume,$C),worlds:^core.Table(core.World_Transform,$D),
    exposures:^core.Table(render.Exposure,$E),view_volumes:^core.Table(render.View_Volume,$F),view:core.View,
) -> (v:View_Lens) {
    own:=false
    if view.camera!=core.NONE {
        if l,has:=core.get(lenses,view.camera);has {v.lens,own=l,true}
    }
    if !own {v.lens=volume.at(places,worlds,zones,view.position,LENS_VOLUME_DEFAULT,lens_mix).lens}
    exposure:render.Exposure
    if e,has:=core.get(exposures,view.camera);view.camera!=core.NONE && has {exposure=e} else {exposure=render.view_volume_at(view_volumes,places,worlds,view.position).exposure}
    v.aperture,v.shutter=exposure.aperture,exposure.shutter
    l:=v.lens
    v.used=l.depth_of_field || l.motion_blur && v.shutter>0 || final_used(l)
    return
}

@(private)
final_used :: proc "contextless" (l:Lens) -> bool {
    return l.bloom>0 || l.vignette>0 || l.distortion!=0 || l.chromatic_aberration>0
}

// The radius of the circle of confusion of what is infinitely far, in pixels
// of an image height pixels tall, for a camera of vertical field fov_y
// (degrees) through a lens with that sensor and f-number focused at focus.
// What lies at distance d blurs by this times |1 - focus/d|.
coc_infinity :: proc "contextless" (fov_y,sensor,aperture,focus:f32,height:u32) -> f32 {
    if !(fov_y>0) || !(sensor>0) || !(aperture>0) {return 0}
    focal:=0.5*sensor/math.tan(fov_y*math.PI/360)
    focus:=max(focus,focal*1.01)
    diameter:=focal*focal/(aperture*(focus-focal))
    return 0.5*diameter/sensor*f32(height)
}

@(private)
groups :: proc "contextless" (n:u32) -> u32 {return (n+7)/8}

@(private)
sizes :: proc "contextless" (width,height:u32) -> [4]f32 {return {f32(width),f32(height),1/f32(width),1/f32(height)}}

@(private)
lens_record :: proc(pass:^render.Pass,user:rawptr) {
    state:=cast(^Lens_Gpu)user
    slot:=int(pass.camera.slot)
    if slot>=len(state.views) || !state.views[slot].used {return}
    v:=state.views[slot]
    l:=v.lens
    width,height:=pass.output_width,pass.output_height
    if width<2 || height<2 {return}
    params:=Gpu_Params{image=sizes(width,height)}
    if l.depth_of_field && pass.camera.projection==.Perspective {
        radius:=coc_infinity(pass.camera.fov_y,l.sensor,max(v.aperture,0.5),l.focus,height)
        // What is nearest, at the near plane, blurs most: past the focus by focus/near - 1 times what is infinitely far.
        widest:=min(radius*max(1,l.focus/max(pass.camera.near,0.01)-1),COC_MAX*f32(height))
        if widest>=0.5 && !lens_dof(pass,state,&params,radius,widest,l.focus) {return}
    }
    if l.motion_blur && v.shutter>0 && pass.delta_time>0 {
        if !lens_motion(pass,state,&params,v.shutter/pass.delta_time) {return}
    }
    if final_used(l) {lens_final(pass,state,&params,l)}
}

// Depth of field: a layer of half the size gathers what each pixel sees off
// focus, behind it and in front, and the image takes it where its own circle
// of confusion is wider than a pixel or what is in front blurs over it.
@(private)
lens_dof :: proc(pass:^render.Pass,state:^Lens_Gpu,params:^Gpu_Params,radius,widest,focus:f32) -> bool {
    width,height:=pass.output_width,pass.output_height
    half_width,half_height:=(width+1)/2,(height+1)/2
    tiles_x,tiles_y:=(half_width+DOF_TILE-1)/DOF_TILE,(half_height+DOF_TILE-1)/DOF_TILE
    params.dof={radius,focus,widest,0}
    layer:=render.Pass_Texture_Desc{name="lens dof",format=.RGBA16_Float,width=half_width,height=half_height}
    tiles:=render.Pass_Texture_Desc{name="lens dof tiles",format=.R16_Float,width=tiles_x,height=tiles_y}
    bokeh:=render.Pass_Texture_Desc{name="lens bokeh",format=.RGBA16_Float,width=half_width,height=half_height}
    params.target=sizes(half_width,half_height)
    render.pass_timestamp(pass,"lens dof")
    render.pass_image_bind(pass,0)
    render.pass_surface_read(pass,1,.Linear_Depth)
    if ok,_:=render.pass_texture(pass,2,layer);!ok {return false}
    if !dispatch(pass,state.pipelines[.Dof_Prefilter],params,groups(half_width),groups(half_height)) {return false}
    render.pass_texture(pass,0,layer)
    if ok,_:=render.pass_texture(pass,1,tiles);!ok {return false}
    if !dispatch(pass,state.pipelines[.Dof_Tiles],params,tiles_x,tiles_y) {return false}
    if ok,_:=render.pass_texture(pass,1,bokeh);!ok {return false}
    render.pass_texture(pass,2,tiles)
    if !dispatch(pass,state.pipelines[.Dof_Bokeh],params,groups(half_width),groups(half_height)) {return false}
    render.pass_texture(pass,0,bokeh)
    render.pass_texture(pass,1,layer)
    if !dispatch(pass,state.pipelines[.Dof_Filter],params,groups(half_width),groups(half_height)) {return false}
    if !render.pass_image_write(pass,0,1) {return false}
    render.pass_texture(pass,2,layer)
    render.pass_surface_read(pass,3,.Linear_Depth)
    params.target=params.image
    return dispatch(pass,state.pipelines[.Dof_Apply],params,groups(width),groups(height))
}

// Motion blur: the largest motion of each tile and of the tiles around it
// says how far each pixel looks along it; each sample counts as far as its own
// blur, or the pixel's, reaches it, by which of the two is in front.
@(private)
lens_motion :: proc(pass:^render.Pass,state:^Lens_Gpu,params:^Gpu_Params,share:f32) -> bool {
    width,height:=pass.output_width,pass.output_height
    tile:=max(u32(math.ceil(MOTION_MAX*f32(height))),8)
    tiles_x,tiles_y:=(width+tile-1)/tile,(height+tile-1)/tile
    params.motion={share,f32(tile),f32(tiles_x),f32(tiles_y)}
    tiles:=render.Pass_Texture_Desc{name="lens tiles",format=.RG16_Float,width=tiles_x,height=tiles_y}
    neighbors:=render.Pass_Texture_Desc{name="lens neighbors",format=.RG16_Float,width=tiles_x,height=tiles_y}
    params.target=sizes(tiles_x,tiles_y)
    render.pass_timestamp(pass,"lens motion")
    render.pass_surface_read(pass,0,.Motion)
    render.pass_surface_read(pass,1,.Linear_Depth)
    if ok,_:=render.pass_texture(pass,2,tiles);!ok {return false}
    if !dispatch(pass,state.pipelines[.Motion_Tiles],params,tiles_x,tiles_y) {return false}
    render.pass_texture(pass,0,tiles)
    if ok,_:=render.pass_texture(pass,1,neighbors);!ok {return false}
    if !dispatch(pass,state.pipelines[.Motion_Neighbors],params,groups(tiles_x),groups(tiles_y)) {return false}
    if !render.pass_image_write(pass,0,1) {return false}
    render.pass_surface_read(pass,2,.Motion)
    render.pass_surface_read(pass,3,.Linear_Depth)
    render.pass_texture(pass,4,neighbors)
    params.target=params.image
    return dispatch(pass,state.pipelines[.Motion_Blur],params,groups(width),groups(height))
}

// Bloom down a chain of levels from half the size of the image and back up,
// each level adding the wider ones; then, in one pass over the image, the
// bloom, the distortion with the fringes of the colors and the vignette.
@(private)
lens_final :: proc(pass:^render.Pass,state:^Lens_Gpu,params:^Gpu_Params,l:Lens) {
    width,height:=pass.output_width,pass.output_height
    half_width,half_height:=(width+1)/2,(height+1)/2
    chain:=render.Pass_Texture_Desc{name="lens bloom",format=.RGBA16_Float,width=half_width,height=half_height,mips=BLOOM_LEVELS}
    levels:=u32(0)
    if l.bloom>0 {
        levels=BLOOM_LEVELS
        for level in u32(1)..<BLOOM_LEVELS {
            if half_width>>level==0 && half_height>>level==0 {levels=level;break}
        }
        render.pass_timestamp(pass,"lens bloom")
        for level in 0..<levels {
            if level==0 {render.pass_image_bind(pass,0)} else {render.pass_texture(pass,0,chain)}
            if ok,_:=render.pass_texture(pass,1,chain,mip=i32(level));!ok {return}
            w,h:=max(half_width>>level,1),max(half_height>>level,1)
            params.target=sizes(w,h)
            params.level={level,level==0?1:0,0,0}
            if !dispatch(pass,state.pipelines[.Bloom_Down],params,groups(w),groups(h)) {return}
        }
        for level:=int(levels)-2;level>=0;level-=1 {
            render.pass_texture(pass,0,chain)
            render.pass_texture(pass,1,chain,mip=i32(level))
            w,h:=max(half_width>>u32(level),1),max(half_height>>u32(level),1)
            params.target=sizes(w,h)
            params.level={u32(level),0,0,0}
            if !dispatch(pass,state.pipelines[.Bloom_Up],params,groups(w),groups(h)) {return}
        }
    }
    distortion:=clamp(l.distortion,-0.5,0.5)
    aberration:=clamp(l.chromatic_aberration,0,0.05)
    tan_half:=math.tan(pass.camera.fov_y*math.PI/360) if pass.camera.projection==.Perspective && pass.camera.fov_y>0 else 0
    params.effects={clamp(l.bloom,0,1),f32(levels),clamp(l.vignette,0,1),distortion}
    params.optics={aberration,tan_half,f32(width)/f32(height),1/((1+max(distortion,0))*(1+aberration))}
    params.target=params.image
    render.pass_timestamp(pass,"lens")
    // Without bloom the chain is not there: its slot reads the image, which the pass leaves alone.
    if levels>0 {render.pass_texture(pass,2,chain)} else {render.pass_image_bind(pass,2)}
    if !render.pass_image_write(pass,0,1) {return}
    dispatch(pass,state.pipelines[.Final],params,groups(width),groups(height))
}

@(private)
dispatch :: proc(pass:^render.Pass,pipeline:render.Pipeline,params:^Gpu_Params,x,y:u32) -> bool {
    render.pass_pipeline(pass,pipeline)
    if !render.pass_params(pass,params,size_of(Gpu_Params)) {return false}
    render.pass_dispatch(pass,x,y)
    return true
}
