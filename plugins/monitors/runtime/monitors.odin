package monitors

import "core:math"
import "core:math/linalg"
import "mirai:core"
import volume "mirai:engine/volume"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"

// Screens that show what a camera sees. The image of a camera is a feed:
// one more view of the frame, with everything a view has, shared by the
// screens that show that camera with the same shape. It is drawn at the size
// it is seen with: of the levels of its image, each half the one before, the
// smallest that still gives a texel to every pixel of the screen that shows
// it largest. With no screen in sight it keeps its smallest level, a few
// times a second, so that what reflects a screen still sees it alive.

LEVELS :: 4
FEED_CAPACITY :: 8
// Images a level is drawn before the screens show it: its histories settle unseen.
WARM_IMAGES :: 8
// How much rarer the images of a feed no screen in sight shows.
UNSEEN_INTERVAL :: 4
// A level is taken for a smaller one when the smaller one has this many texels to a pixel.
SHRINK_MARGIN :: 1.25
LEVEL_MIN_SIZE :: 16

@(component,description="Shows what a camera sees on a material slot of the mesh of this entity, as light it emits, drawn at the size it is seen with.")
Screen :: struct {
    camera:core.Entity,                  // the entity with the Camera it shows
    width:u32 `mirai:"min=16,max=4096"`, // of the image at its largest
    height:u32 `mirai:"min=16,max=4096"`,
    interval:u32,                        // frames from an image to the next; 0: every frame
    light:bool,                          // without screen GI, traced reflections or soft shadows
    slot:u32,                            // the material slot of the mesh that shows the image
    brightness:f32 `mirai:"min=0"`,    // the luminance of its white, nits
}

// A monitor of 200 nits.
SCREEN_DEFAULT :: Screen{width=1280,height=720,light=true,brightness=200}

// What the screens of a frame ask of a camera: one image for those of the
// same shape, as large, as often and as complete as the one that asks most.
@(private)
Asked :: struct {
    camera:core.Entity,
    width,height,interval:u32,
    light:bool,
    pixels:f32, // the widest a screen in sight shows it; 0: none in sight
    place:int,  // in Monitors.fed; -1: none
}

// The images of a feed. They are kept when the feed goes, for the next one
// of its size; a feed of another size that needs the place removes them.
@(private)
Fed :: struct {
    entity:core.Entity, // the camera
    width,height:u32, // of level 0; 0: never used
    textures:[LEVELS]erender.Texture_Handle,
    drawn:[LEVELS]u64, // the frame each level was last drawn in; 0: never
    shown:int,         // the level the screens show
    next:int,          // the level drawn to take its place; -1: none
    warmed:int,        // images the next level has
    seen:u64,
}

@(storage,host)
Monitors :: struct {
    fed:[FEED_CAPACITY]Fed,
    frame:u64,
}

@(private)
fed_forget :: proc(renderer:^erender.Renderer,fed:^Fed) {
    for texture in fed.textures {if texture!=0 {erender.view_texture_remove(renderer,texture)}}
    fed^={}
}

// The levels an image of that size has: none smaller than LEVEL_MIN_SIZE.
@(private)
levels_of :: proc "contextless" (width,height:u32) -> int {
    count:=1
    for count<LEVELS && min(width,height)>>uint(count)>=LEVEL_MIN_SIZE {count+=1}
    return count
}

// How wide the box of a mesh is in the view, in pixels where it is nearest,
// and whether any of it is inside the view.
@(private)
box_in_view :: proc(view:core.View,size:[2]f32,world:mm.Transform,bounds_min,bounds_max:[3]f32) -> (pixels:f32,inside:bool) {
    half:=0.5*linalg.abs((bounds_max-bounds_min)*world.scale)
    center:=mm.transform_point(world,0.5*(bounds_min+bounds_max))
    eye:=mm.quat_rotate(conj(world.rotation),view.position-center)
    nearest:=linalg.clamp(eye,-half,half)
    distance:=max(linalg.length(eye-nearest),view.near,1e-3)
    tangent:=math.tan(0.5*(view.fov>0?view.fov:math.PI/3))
    per_metre:=size.y/(2*tangent*distance)
    if view.projection==.Orthographic && view.height>0 {per_metre=size.y/view.height}
    pixels=2*max(half.x,half.y,half.z)*per_metre
    radius:=linalg.length(half)
    v:=mm.quat_rotate(conj(view.rotation),center-view.position)
    depth:=-v.z
    aspect:=size.x/max(size.y,1)
    if view.projection==.Orthographic && view.height>0 {
        inside=depth>-radius && abs(v.y)<=0.5*view.height+radius && abs(v.x)<=0.5*view.height*aspect+radius
        return
    }
    tangent_x:=tangent*aspect
    inside=depth>-radius && abs(v.x)-depth*tangent_x<=radius*math.sqrt(1+tangent_x*tangent_x) && abs(v.y)-depth*tangent<=radius*math.sqrt(1+tangent*tangent)
    return
}

// The feed of the screens of a frame that a screen shares; -1: none yet.
@(private)
asked_of :: proc "contextless" (asked:[]Asked,screen:Screen) -> int {
    for a,i in asked {
        if a.camera==screen.camera && u64(a.width)*u64(screen.height)==u64(screen.width)*u64(a.height) {return i}
    }
    return -1
}

// What the screens ask of their cameras into the frame, each feed at the
// level its screens ask for, and the screens drawn with the image of theirs.
@(step="render",loops="game editor",before="render_sync")
monitors_render :: proc(
    state:^Monitors,screens:^core.Table(Screen,.Read),cameras:^core.Table(erender.Camera,.Read),exposures:^core.Table(erender.Exposure,.Read),
    meshes:^core.Table(erender.Mesh_Renderer,.Read),worlds:^core.Table(core.World_Transform,.Read),parents:^core.Table(core.Parent,.Read),
    looks:^core.Table(erender.Material_Values,.Read),hidden:^core.Table(erender.Hidden,.Read),
    highlights:^core.Table(erender.Highlight,.Read),outlines:^core.Table(erender.Outline,.Read),offsets:^core.Table(erender.Draw_Offset,.Read),layers:^core.Table(erender.Layers,.Read),
    view:core.View,app:^host.App,frame:core.Frame_Time,view_volumes:^core.Table(erender.View_Volume,.Read),volumes:^core.Table(volume.Volume,.Read),
    locals:^core.Table(core.Transform,.Read),
) {
    if app.renderer==nil || app.assets==nil {return}
    state.frame+=1
    if core.count(screens)==0 {
        for &fed in state.fed {fed.entity=core.NONE}
        return
    }
    size:=view.size
    if size.x<=0 || size.y<=0 {size={f32(app.drawable.x),f32(app.drawable.y)}}
    asked:[FEED_CAPACITY]Asked
    count:=0
    for row in 0..<core.count(screens) {
        e:=core.entity_at(screens,row)
        screen:=core.at(screens,row)
        static,has_mesh:=core.get(meshes,e)
        world,placed:=core.get(worlds,e)
        if screen.width<LEVEL_MIN_SIZE || screen.height<LEVEL_MIN_SIZE || !core.has(cameras,screen.camera) || !core.has(worlds,screen.camera) {continue}
        if !has_mesh || !placed || erender.is_hidden(hidden,parents,e) {continue}
        mesh:=static.mesh!={}?host.assets_mesh(app.assets,static.mesh):host.assets_shape(app.assets,static.shape)
        if mesh==nil || mesh.handle==host.ASSETS_MESH_NONE {continue}
        bounds_min,bounds_max,known:=erender.mesh_bounds(app.renderer,mesh.handle)
        if !known {continue}
        at:=asked_of(asked[:count],screen)
        if at<0 {
            if count>=len(asked) {continue}
            at=count
            count+=1
            asked[at]={camera=screen.camera,width=screen.width,height=screen.height,interval=screen.interval,light=screen.light,place=-1}
        } else {
            a:=&asked[at]
            a.width,a.height=max(a.width,screen.width),max(a.height,screen.height)
            a.interval,a.light=min(a.interval,screen.interval),a.light && screen.light
        }
        // A screen out of sight asks for no size, but its feed stays alive.
        if pixels,inside:=box_in_view(view,size,world.transform,bounds_min,bounds_max);inside {asked[at].pixels=max(asked[at].pixels,pixels)}
    }
    // Each feed with the images of its size: its own, or those a feed that is gone left.
    for &a in asked[:count] {
        for &fed,i in state.fed {
            if fed.entity==a.camera && fed.width==a.width && fed.height==a.height && fed.seen!=state.frame {a.place=i;fed.seen=state.frame;break}
        }
    }
    for &a in asked[:count] {
        if a.place>=0 {continue}
        // A place no feed has: one with images of this size, else an empty one, else any.
        at:=-1
        for &fed,i in state.fed {
            if fed.seen==state.frame {continue}
            if fed.width==a.width && fed.height==a.height {at=i;break}
            if at<0 || (fed.width==0 && state.fed[at].width!=0) {at=i}
        }
        if at<0 {continue}
        fed:=&state.fed[at]
        if fed.width!=a.width || fed.height!=a.height {fed_forget(app.renderer,fed)}
        fed.entity,fed.width,fed.height,fed.seen=a.camera,a.width,a.height,state.frame
        fed.drawn,fed.shown,fed.next,fed.warmed={},-1,-1,0
        a.place=at
    }
    for &fed in state.fed {if fed.seen!=state.frame {fed.entity=core.NONE}}

    for a,index in asked[:count] {
        if a.place<0 {continue}
        fed:=&state.fed[a.place]
        levels:=levels_of(fed.width,fed.height)
        // The smallest level with a texel to every pixel, and the smallest with room to spare.
        exact,spare:=0,0
        for level in 0..<levels {
            if f32(fed.width>>uint(level))>=a.pixels {exact=level}
            if f32(fed.width>>uint(level))>=a.pixels*SHRINK_MARGIN {spare=level}
        }
        wanted:=fed.shown
        if fed.shown<0 || exact<fed.shown {wanted=exact} else if spare>fed.shown {wanted=spare}
        if fed.shown<0 {fed.shown=wanted}
        if wanted==fed.shown {fed.next=-1} else if wanted!=fed.next {fed.next,fed.warmed=wanted,0}
        interval:=u64(max(a.interval,1))
        if a.pixels==0 {interval*=UNSEEN_INTERVAL}
        if fed.drawn[fed.shown]!=0 && (state.frame+u64(index))%interval!=0 {continue}
        for level in ([2]int{fed.shown,fed.next}) {
            if level<0 {continue}
            width,height:=fed.width>>uint(level),fed.height>>uint(level)
            if fed.textures[level]==0 {
                texture,made:=erender.view_texture_add(app.renderer,width,height,"feed")
                if !made {continue}
                fed.textures[level]=texture
            }
            seen:core.View
            erender.view_of_camera(&seen,cameras,exposures,worlds,a.camera,{f32(width),f32(height)})
            erender.view_volume_expose(&seen,view_volumes,volumes,worlds)
            // A level left alone for long has histories of another moment.
            stale:=fed.drawn[level]==0 || state.frame-fed.drawn[level]>interval*UNSEEN_INTERVAL+1
            if !erender.view_texture_draw(&app.extras,fed.textures[level],seen,width,height,stale,erender.pipeline_standard(app.renderer,a.light?.Light:.Full)) {continue}
            fed.drawn[level]=state.frame
            if level==fed.next {fed.warmed+=1}
        }
        if fed.next>=0 && fed.warmed>=WARM_IMAGES {fed.shown,fed.next=fed.next,-1}
    }

    for row in 0..<core.count(screens) {
        e:=core.entity_at(screens,row)
        screen:=core.at(screens,row)
        feed:=screen.width>=LEVEL_MIN_SIZE && screen.height>=LEVEL_MIN_SIZE?asked_of(asked[:count],screen):-1
        if feed<0 || asked[feed].place<0 {continue}
        fed:=&state.fed[asked[feed].place]
        static,has_mesh:=core.get(meshes,e)
        world,placed:=core.get(worlds,e)
        if fed.shown<0 || fed.textures[fed.shown]==0 || !has_mesh || !placed || erender.is_hidden(hidden,parents,e) {continue}
        look:=erender.MATERIAL_VALUES_DEFAULT
        if value,exists:=core.get(looks,e);exists {look=value}
        // The slot of the screen gives the image as its light, and reflects none.
        slot:=int(min(screen.slot,erender.MATERIAL_SLOTS-1))
        erender.material_texture(&look,base.name_hash("maps.emission"),slot,{},fed.textures[fed.shown])
        erender.material_texture(&look,base.name_hash("maps.base_color"),slot,{})
        erender.material_value(&look,"emission",screen.brightness,slot)
        erender.material_value(&look,"base_color",0,slot)
        anchor,transform:=erender.instance_place(world,frame,offsets,parents,worlds,locals,cameras,e)
        shown,usable:=erender.mesh_instance(app.assets,static,transform,look)
        shown.anchor=anchor
        if !usable {continue}
        shown.object_id=u64(e)
        shown.copy_owner,shown.replace_source=base.name_hash("monitors"),true
        shown.highlight=erender.instance_outline(highlights,outlines,e)
        if in_layers,exists:=core.get(layers,e);exists {shown.layers=in_layers.mask}
        erender.instance_add(&app.extras,shown)
    }
}
