package portals

import "core:math"
import "core:math/linalg"
import "core:mem"
import "mirai:core"
import erender "mirai:engine/render"
import mm "mirai:std/math"

// The portals in the renderer. Every stage of every view gets the gates of
// the scene and the lights behind them in the constants of the view, which
// the hooks of portals_hooks.slang read. Each view also gets, in its Mask
// stage, a nested view for each portal it sees: the scene from the camera of
// the view carried through the portal, drawn in the pixels of its opening.

// Two portals in one room each bring its lights: twice the lights that reach them.
PORTAL_LIGHT_CAPACITY :: 16

// portals_frame.slang
@(private)
Gpu_Gate :: struct {
    to_local:[3][4]f32,
    through:[3][4]f32,
    shape:[4]f32,
}
@(private)
Gpu_Light :: struct {
    position_range,color_intensity,direction_cone,size,axis,extra:[4]f32,
}
@(private)
Gpu_Portals :: struct {
    count,light_count:u32,
    pad:[2]u32,
    gates:[PORTAL_CAPACITY]Gpu_Gate,
    lights:[PORTAL_LIGHT_CAPACITY]Gpu_Light,
}
#assert(size_of(Gpu_Portals)==16+PORTAL_CAPACITY*112+PORTAL_LIGHT_CAPACITY*96)

@(private)
Gate :: struct {
    entity:core.Entity,
    entrance,exit:mm.Transform, // as drawn; the entrance scaled to its opening
    through,previous:mm.Mat4, // carries what is in front of the portal to behind its exit, in this frame and in the last
    plane,exit_plane:[4]f32,   // of the opening and of that of the exit, facing their fronts
    corners:[4][3]f32,
    layers:u32,
}

@(storage,host)
Portals_Gpu :: struct {
    pipeline:erender.Pipeline, // of the masks, of this frame
    gates:[PORTAL_CAPACITY]Gate, // of this frame, as the gates of constants
    count:int,
    constants:Gpu_Portals,      // without the places of the gates, which each view gives them (constants_relative)
    last:[PORTAL_CAPACITY]Gate, // of the last frame
    last_count:int,
}

// A light behind a gate, kept among the strongest PORTAL_LIGHT_CAPACITY.
@(private)
light_keep :: proc(state:^Portals_Gpu,weights:^[PORTAL_LIGHT_CAPACITY]f32,weight:f32,light:Gpu_Light) {
    count:=int(state.constants.light_count)
    at:=count
    for at>0 && weights[at-1]<weight {at-=1}
    if at>=PORTAL_LIGHT_CAPACITY {return}
    count=min(count+1,PORTAL_LIGHT_CAPACITY)
    for i:=count-1;i>at;i-=1 {weights[i],state.constants.lights[i]=weights[i-1],state.constants.lights[i-1]}
    weights[at],state.constants.lights[at]=weight,light
    state.constants.light_count=u32(count)
}

// The portals of the world into the frame: its gates, the lights behind each
// one, and the pass that gives every view its nested views.
@(step="render",loops="game editor",after="render_sync")
portals_render :: proc(
    state:^Portals_Gpu,portals:core.Read(Portal),worlds:core.Read(core.World_Transform),
    suns:core.Read(erender.Sun),points:core.Read(erender.Point_Light),spots:core.Read(erender.Spot_Light),rects:core.Read(erender.Rect_Light),
    hidden:core.Read(erender.Hidden),parents:core.Read(core.Parent),renderer:^erender.Renderer,frame:core.Frame_Time,
) {
    state.last,state.last_count=state.gates,state.count
    state.count=0
    if core.count(portals)==0 {return}
    // 0 while the shaders in use have no portals.
    state.pipeline=erender.stage_pipeline(renderer,{stage=.Mask,shader="portal_mask",name="portal masks"})
    if state.pipeline==0 {return}
    state.constants={}
    exits,throughs:[PORTAL_CAPACITY]mm.Transform
    sizes:[PORTAL_CAPACITY][2]f32
    for row in 0..<core.count(portals) {
        if state.count>=PORTAL_CAPACITY {break}
        e:=core.entity_at(portals,row)
        portal:=core.at(portals,row)
        world,placed:=core.get(worlds,e)
        exit_world,has_exit:=core.get(worlds,portal.exit)
        if !placed || !has_exit || erender.is_hidden(hidden,parents,e) {continue}
        entrance,exit:=erender.drawn_transform(world,frame),erender.drawn_transform(exit_world,frame)
        size:=[2]f32{abs(entrance.scale.x),abs(entrance.scale.y)}
        _,invertible:=mm.transform_inverse_matrix({entrance.position,entrance.rotation,{size.x,size.y,1}})
        if size.x<1e-5 || size.y<1e-5 || !invertible {continue}
        through:=through_of(entrance,exit)
        normal,exit_normal:=mm.quat_rotate(entrance.rotation,[3]f32{0,0,1}),mm.quat_rotate(exit.rotation,[3]f32{0,0,1})
        gate:=&state.gates[state.count]
        gate^={
            entity=e,entrance={entrance.position,entrance.rotation,{size.x,size.y,1}},exit=exit,through=mm.transform_matrix(through),layers=portal.layers,
            plane={normal.x,normal.y,normal.z,-linalg.dot(normal,entrance.position)},
            exit_plane={exit_normal.x,exit_normal.y,exit_normal.z,-linalg.dot(exit_normal,exit.position)},
        }
        gate.previous=gate.through
        for last in state.last[:state.last_count] {if last.entity==e {gate.previous=last.through}}
        for &corner,i in gate.corners {
            corner=entrance.position+mm.quat_rotate(entrance.rotation,[3]f32{(i&1!=0?0.5:-0.5)*size.x,(i&2!=0?0.5:-0.5)*size.y,0})
        }
        state.constants.gates[state.count]={shape={portal.ellipse?1:0,0,0,0}}
        exits[state.count],throughs[state.count],sizes[state.count]=exit,through,size
        state.count+=1
    }
    state.constants.count=u32(state.count)
    if state.count==0 {return}

    // The lights in front of the exit of each gate, near enough to reach its opening, as they are seen from in front of the gate.
    gates:=Gate_Lights{state=state,exits=exits[:state.count],throughs=throughs[:state.count],sizes=sizes[:state.count]}
    sun_radius:=erender.sun_radius(renderer)
    for row in 0..<core.count(suns) {
        e:=core.entity_at(suns,row)
        sun:=core.at(suns,row)
        world,placed:=core.get(worlds,e)
        if !placed || sun.illuminance<=0 || erender.is_hidden(hidden,parents,e) {continue}
        to_sun:=mm.quat_rotate(world.rotation,[3]f32{0,0,1})
        power:=sun.illuminance*luma(sun.color)
        for gate in 0..<state.count {
            facing:=linalg.dot(mm.quat_rotate(exits[gate].rotation,[3]f32{0,0,1}),to_sun)
            if facing<=0.02 {continue}
            seen:=mm.quat_rotate(conj(throughs[gate].rotation),to_sun)
            light_keep(state,&gates.weights,power*facing*1e3,{position_range={seen.x,seen.y,seen.z,0},color_intensity={sun.color.r,sun.color.g,sun.color.b,sun.illuminance},direction_cone={0,0,0,erender.LIGHT_POINT},extra={sun_radius,f32(gate),0,0}})
        }
    }
    for row in 0..<core.count(points) {
        e:=core.entity_at(points,row)
        point:=core.at(points,row)
        if world,placed:=core.get(worlds,e);placed && !erender.is_hidden(hidden,parents,e) {
            gate_lights_add(&gates,erender.sphere_desc(world,point.color,point.intensity,point.range,point.radius),.Point)
        }
    }
    for row in 0..<core.count(spots) {
        e:=core.entity_at(spots,row)
        spot:=core.at(spots,row)
        if world,placed:=core.get(worlds,e);placed && !erender.is_hidden(hidden,parents,e) {
            desc:=erender.sphere_desc(world,spot.color,spot.intensity,spot.range,spot.radius)
            desc.direction,desc.cone=mm.quat_forward(world.rotation),spot.angle
            gate_lights_add(&gates,desc,.Spot)
        }
    }
    for row in 0..<core.count(rects) {
        e:=core.entity_at(rects,row)
        if world,placed:=core.get(worlds,e);placed && !erender.is_hidden(hidden,parents,e) {
            gate_lights_add(&gates,erender.rect_desc(world,core.at(rects,row)),.Rect)
        }
    }
    erender.frame_pass(renderer,.Mask,portals_record,state)
}

// The constants of the portals for a view whose places are relative to
// origin, as its shaders are: each gate from where its ends are, and the
// lights behind them, but the sun, which is a direction.
@(private)
constants_relative :: proc "contextless" (state:^Portals_Gpu,origin:[3]f32) -> (c:Gpu_Portals) {
    c=state.constants
    for &gate,i in state.gates[:state.count] {
        entrance,exit:=gate.entrance,gate.exit
        entrance.position=erender.origin_point(entrance.position,origin)
        exit.position=erender.origin_point(exit.position,origin)
        to_local,_:=mm.transform_inverse_matrix(entrance)
        c.gates[i].to_local=mm.mat4_rows(to_local)
        c.gates[i].through=mm.mat4_rows(mm.transform_matrix(through_of(entrance,exit)))
    }
    for &light in c.lights[:c.light_count] {
        if light.position_range.w>0 {light.position_range.xyz=erender.origin_point(light.position_range.xyz,origin)}
    }
    return
}

@(private)
portals_record :: proc(pass:^erender.Pass,user:rawptr) {
    state:=cast(^Portals_Gpu)user
    data:=erender.pass_extension_data(pass,"portals")
    if len(data)<size_of(Gpu_Portals) || state.pipeline==0 {return}
    constants:=constants_relative(state,pass.origin)
    mem.copy(raw_data(data),&constants,size_of(Gpu_Portals))
    of :: proc(gate:^Gate,origin:[3]f32) -> (plane:[4]f32,corners:[4][3]f32,view:erender.Nested_View) {
        // The plane of the opening, relative to the origin as the eye is.
        plane=erender.origin_plane_through(gate.plane,gate.entrance.position,origin)
        return plane,gate.corners,{to_world=gate.through,previous=gate.previous,clip_plane=gate.exit_plane,layers=gate.layers,opening=gate.plane}
    }
    faces:[erender.NESTED_VIEW_CAPACITY]erender.Nested_Face
    drawn:=erender.pass_nested_faces(pass,state.gates[:state.count],of,&faces)
    if len(drawn)==0 {return}
    erender.pass_mask_begin(pass,"portal masks")
    erender.pass_pipeline(pass,state.pipeline)
    for item in drawn {
        Params :: struct {gate,index,pad0,pad1:u32}
        params:=Params{gate=u32(item.item),index=item.index}
        erender.pass_scissor(pass,item.rect)
        if erender.pass_params(pass,&params,size_of(Params)) {erender.pass_draw(pass,3)}
    }
    erender.pass_scissor(pass,{})
    erender.pass_end(pass)
}

@(private)
luma :: proc "contextless" (color:[3]f32) -> f32 {return 0.2126*color.r+0.7152*color.g+0.0722*color.b}

// The gates of this frame, and the weights of the lights kept behind them.
@(private)
Gate_Lights :: struct {
    state:^Portals_Gpu,
    exits,throughs:[]mm.Transform,
    sizes:[][2]f32,
    weights:[PORTAL_LIGHT_CAPACITY]f32,
}

@(private)
Gate_Light_Kind :: enum u8 {Point,Spot,Rect}

// A light of the world behind every gate whose opening it reaches.
@(private)
gate_lights_add :: proc(g:^Gate_Lights,light:erender.Light_Desc,kind:Gate_Light_Kind) {
    if light.intensity<=0 {return}
    power:=light.intensity*luma(light.color)
    for gate in 0..<len(g.exits) {
        exit,through:=g.exits[gate],g.throughs[gate]
        local:=mm.quat_rotate(conj(exit.rotation),light.position-exit.position)
        if local.z<=0.01 {continue}
        nearest:=[3]f32{clamp(local.x,-0.5*g.sizes[gate].x,0.5*g.sizes[gate].x),clamp(local.y,-0.5*g.sizes[gate].y,0.5*g.sizes[gate].y),0}
        distance:=linalg.length(local-nearest)
        if distance>=light.range {continue}
        // A rectangle lights one side: the opening has to be on it.
        if kind==.Rect && linalg.dot(light.direction,exit.position+mm.quat_rotate(exit.rotation,nearest)-light.position)<=0 {continue}
        back:=conj(through.rotation)
        seen:=mm.quat_rotate(back,light.position-through.position)
        direction,axis:=mm.quat_rotate(back,light.direction),mm.quat_rotate(back,light.axis)
        cone:=[4]f32{0,0,0,erender.LIGHT_POINT}
        size:=[4]f32{light.radius,0.5*light.length,0,0}
        extra:=[4]f32{light.radius+0.5*light.length,f32(gate),0,0}
        switch kind {
        case .Point:
        case .Spot: cone={direction.x,direction.y,direction.z,math.cos(light.cone)}
        case .Rect:
            cone={direction.x,direction.y,direction.z,erender.LIGHT_RECT}
            size={0,0.5*light.size.x,0.5*light.size.y,0}
            extra.x=0.5*linalg.length(light.size)
        }
        light_keep(g.state,&g.weights,power/(1+distance*distance),{position_range={seen.x,seen.y,seen.z,light.range},color_intensity={light.color.r,light.color.g,light.color.b,light.intensity},direction_cone=cone,size=size,axis={axis.x,axis.y,axis.z,0},extra=extra})
    }
}
