package gui

import "core:math"
import "core:reflect"
import "mirai:core"
import audio "mirai:engine/audio"
import inp "mirai:engine/input"
import render "mirai:engine/render"
import volume "mirai:engine/volume"
import "mirai:host"
import gpu "mirai:render"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:ui"

// What the interfaces of a context read of the game (ui.Game_Source.user):
// the input of its player, the textures, the cameras, the particles and the
// sounds. Bound again every frame its context is built.
Source :: struct {
    gui:^Gui,
    app:^host.App,
    surface:^Surface,
    building:^Instance, // the interface being built: one that shows a camera or particles is not drawn again from what it drew
    effects:^UI_Effects,
    sounds:^audio.Sound_Requests,
    player:int,
    seat:core.Entity,  // of a local player
    gamepad:int,       // of the player; -1: any
    bindings:^inp.Input_Map,
    actions:^inp.Actions, // of the frame, for the window
    seat_state:^inp.Seats, // whose blocks the interface being built reads its actions past
    seats:^core.Table(inp.Seat,.Read),
    cameras:^core.Table(render.Camera,.Read),
    exposures:^core.Table(render.Exposure,.Read),
    view_volumes:^core.Table(render.View_Volume,.Read),
    zones:volume.Where, // where the View_Volumes are
    pixels:f32,        // device pixels per layout unit
    pack:^host.Content_Prompts,  // of UI_Settings.prompts; nil: the prompts are drawn
}

// A camera an interface shows, drawn into a texture of its size.
View_Texture :: struct {
    camera:core.Entity,
    size:[2]u32,
    texture:render.Texture_Handle,
    view:core.View,
    drawn:u64,  // the frame it was drawn last; one not drawn in a frame goes
}

VIEW_PIXELS :: 4096 // the widest a camera is drawn into an interface
PARTICLE_PIXELS :: 2048 // the widest particles are drawn into an interface
PARTICLE_VIEW_METERS :: f32(2) // what a Particles node shows of its effect, from bottom to top, around the emitter

// A particle effect an interface shows, drawn into a texture of its size.
Particle_Texture :: struct {
    key:u64,    // the element that shows it, in the context of its player
    size:[2]u32,
    texture:render.Texture_Handle,
    drawn:u64,  // the frame it was shown last; one not shown in a frame goes
}

@(private)
source_bind :: proc(
    s:^Surface,gui:^Gui,app:^host.App,p:int,seat_state:core.Ref(inp.Seats),seats:^core.Table(inp.Seat,.Read),bindings:core.Ref(inp.Input_Map),
    actions:core.Ref(inp.Frame_Actions),cameras:^core.Table(render.Camera,.Read),exposures:^core.Table(render.Exposure,.Read),
    view_volumes:^core.Table(render.View_Volume,.Read),zones:volume.Where,settings:UI_Settings,preferences:UI_Preferences,gamepad:int,effects:^UI_Effects,sounds:^audio.Sound_Requests,
) {
    seat:=p>0?inp.local_seat(seats,p-1):core.NONE
    settings,preferences:=settings,preferences
    s.source={
        gui=gui,app=app,surface=s,effects=effects,sounds=sounds,player=p,seat=seat,gamepad=gamepad,bindings=bindings.ptr,actions=&actions.ptr.slots[clamp(seat_state.focus,0,inp.LOCAL_CAPACITY-1)],seat_state=seat_state.ptr,seats=seats,
        cameras=cameras,exposures=exposures,view_volumes=view_volumes,zones=zones,pixels=s.key.scale*max(app.density,0.01),
        pack=host.content_prompts(app,settings.prompts),
    }
    s.ctx.game={
        user=&s.source,family=s.family,prompts=source_prompts,action=source_action,texts=host.app_texts(app),language=ui_language(&settings,&preferences),
        texture=source_texture,view=source_view,particles=source_particles,sound=source_sound,
    }
    s.ctx.draw_user,s.ctx.draw_user_data=source_draw,&s.source
}

// The procedure @(draw) of the game a Draw node names; nil: the game declares none of that name.
@(private)
draw_named :: proc(info:^core.World_Info,name:u64) -> proc(ctx:^ui.Context,node:ui.Draw_Node) {
    if info==nil || name==0 {return nil}
    for &declared in info.draws {
        if declared.call!=nil && base.name_hash(declared.name)==name {return cast(proc(ctx:^ui.Context,node:ui.Draw_Node))declared.call}
    }
    return nil
}

@(private)
source_draw :: proc(user:rawptr,ctx:^ui.Context,node:ui.Draw_Node) {
    src:=(^Source)(user)
    if draw:=draw_named(src.app.info,node.name);draw!=nil {draw(ctx,node)}
}

// The input action whose name has this name_hash, from the names of Action.
@(private)
action_named :: proc(gui:^Gui,info:^core.World_Info,hash:u64) -> (action:inp.Action,ok:bool) {
    if !gui.actions_ready {
        gui.actions_ready=true
        for entry in core.names_of(info,inp.Action) {
            if entry.value>=0 && entry.value<inp.ACTION_CAPACITY {append(&gui.actions,Action_Name{base.name_hash(entry.name),inp.Action(entry.value)})}
        }
    }
    for named in gui.actions {
        if named.hash==hash {return named.action,true}
    }
    return
}

@(private)
source_prompts :: proc(user:rawptr,action:u64,family:ui.Prompt_Family,out:[]ui.Prompt) -> int {
    src:=(^Source)(user)
    if src.bindings==nil {return 0}
    found,named:=action_named(src.gui,src.app.info,action)
    if !named {return 0}
    count:=prompts_of(src.bindings,found,family,src.gamepad,out)
    for &prompt in out[:count] {prompt=prompt_shown(src.app.assets,src.app.renderer,&src.gui.settings,src.pack,prompt)}
    return count
}

// A prompt with its image: the one the settings give its input, or else that
// of the pack (UI_Settings.prompts); without either it is drawn.
prompt_shown :: proc(assets:^host.Assets,renderer:^render.Renderer,settings:^UI_Settings,pack:^host.Content_Prompts,prompt:ui.Prompt) -> ui.Prompt {
    prompt:=prompt
    if at:=prompt_image_find(settings,prompt.family,prompt.input,prompt.text);at>=0 && assets!=nil && renderer!=nil {
        if texture:=host.assets_texture_image(assets,settings.prompt_images[at].texture);texture!=nil && texture.height>0 {
            prompt.quad,prompt.aspect=image_quad(renderer,texture.handle),f32(texture.width)/f32(texture.height)
            return prompt
        }
    }
    if found,ok:=host.prompts_find(pack,assets,prompt.family,prompt.input,prompt.text);ok {return found}
    return prompt
}

// The prompts of the bindings of an action as a family shows them: keys and
// mouse for the keyboard, the controls of the gamepad (-1: any) for the
// others. Four d-pad buttons of one binding are the d-pad; the two axes of
// a stick, or of the mouse, one prompt. A chord comes first, with a Plus
// after each of its inputs.
prompts_of :: proc(m:^inp.Input_Map,action:inp.Action,family:ui.Prompt_Family,gamepad:int,out:[]ui.Prompt) -> (count:int) {
    add :: proc(out:[]ui.Prompt,count:^int,prompt:ui.Prompt) {
        for p in out[:count^] {
            if p.input==prompt.input && p.text==prompt.text && prompt.input!=.Plus {return}
        }
        if count^<len(out) {out[count^]=prompt;count^+=1}
    }
    keyboard:=family==.Keyboard
    if int(action)>=inp.ACTION_CAPACITY {return}
    for &binding in inp.action_bindings(&m.actions[action]) {
        codes:=inp.binding_inputs(&binding)
        if !keyboard {
            if binding.gamepad!=0 && gamepad>=0 && int(binding.gamepad)-1!=gamepad {continue}
        }
        // A binding with a chord shows when the family shows all it holds and some of the rest.
        if chord:=inp.chord_inputs(&binding);len(chord)>0 {
            shown:=false
            for code in codes {_,on:=prompt_input(code,keyboard);shown||=on}
            for code in chord {_,on:=prompt_input(code,keyboard);shown&&=on}
            if !shown {continue}
            for code in chord {
                input,_:=prompt_input(code,keyboard)
                prompt:=ui.Prompt{family=family,input=input}
                if input==.Key {prompt.text=reflect.enum_string(code)}
                add(out,&count,prompt)
                add(out,&count,{family=family,input=.Plus})
            }
        }
        if !keyboard {
            dpad:=len(codes)==4
            for code in codes {dpad&&=code>=.Dpad_Up && code<=.Dpad_Right}
            if dpad {
                add(out,&count,{family=family,input=.Dpad})
                continue
            }
        }
        for code in codes {
            input,shown:=prompt_input(code,keyboard)
            if !shown {continue}
            prompt:=ui.Prompt{family=family,input=input}
            if input==.Key {prompt.text=reflect.enum_string(code)}
            add(out,&count,prompt)
        }
    }
    return
}

// The prompt of one input of a binding, when the family shows it.
prompt_input :: proc "contextless" (code:inp.Input_Code,keyboard:bool) -> (input:ui.Prompt_Input,shown:bool) {
    device,index:=inp.code_device(code)
    #partial switch device {
    case .Key:
        return .Key,keyboard
    case .Mouse_Button:
        #partial switch core.Mouse_Button(index) {
        case .Left:   return .Mouse_Left,keyboard
        case .Right:  return .Mouse_Right,keyboard
        case .Middle: return .Mouse_Middle,keyboard
        }
    case .Mouse_Axis:
        axis:=inp.Mouse_Axis(index)
        return axis==.X || axis==.Y?.Mouse_Move:.Mouse_Wheel,keyboard
    case .Gamepad_Button:
        BUTTONS :: #partial [core.Gamepad_Button]ui.Prompt_Input{
            .South=.South,.East=.East,.West=.West,.North=.North,.Back=.Back,.Start=.Start,
            .Left_Stick=.Stick_Left_Press,.Right_Stick=.Stick_Right_Press,.Left_Shoulder=.Shoulder_Left,.Right_Shoulder=.Shoulder_Right,
            .Dpad_Up=.Dpad_Up,.Dpad_Down=.Dpad_Down,.Dpad_Left=.Dpad_Left,.Dpad_Right=.Dpad_Right,
        }
        button:=core.Gamepad_Button(index)
        if button==.Guide {return}
        buttons:=BUTTONS
        return buttons[button],!keyboard
    case .Gamepad_Axis:
        AXES :: [core.Gamepad_Axis]ui.Prompt_Input{
            .Left_X=.Stick_Left,.Left_Y=.Stick_Left,.Right_X=.Stick_Right,.Right_Y=.Stick_Right,.Left_Trigger=.Trigger_Left,.Right_Trigger=.Trigger_Right,
        }
        axes:=AXES
        return axes[core.Gamepad_Axis(index)],!keyboard
    }
    return
}

// Whether an action is held and was pressed: of the frame of the focused slot for the window, of
// the tick of its seat for a local player, past the block of the Modal screen
// being built: what a Modal takes from the game its own buttons still get.
@(private)
source_action :: proc(user:rawptr,action:u64) -> (down,pressed:bool) {
    src:=(^Source)(user)
    found:=action_named(src.gui,src.app.info,action) or_return
    state:inp.Action_State
    if src.player>0 {
        owner:=src.building!=nil?src.building.entity:core.NONE
        state=inp.seat_action_for(src.seat_state,src.seats,src.seat,found,owner)
    } else if src.actions!=nil {
        state=inp.action(src.actions,found)
    }
    return state.down,state.pressed
}

@(private)
source_texture :: proc(user:rawptr,id:base.Asset_Id) -> ui.Quad {
    src:=(^Source)(user)
    app:=src.app
    if app.assets==nil || app.renderer==nil {return {}}
    texture:=host.assets_texture_image(app.assets,id)
    if texture==nil {return {}}
    return image_quad(app.renderer,texture.handle)
}

// The quad that shows a texture of the renderer whole; none without a
// renderer or for a texture it does not have.
image_quad :: proc(renderer:^render.Renderer,texture:render.Texture_Handle) -> ui.Quad {
    if renderer==nil {return {}}
    index:=gpu.ui_image(renderer,texture)
    if index==0 {return {}}
    return ui.quad_whole(.Image,index&~gpu.UI_MATERIAL_IMAGE_BIT)
}

// What a camera sees at a size in layout units: a texture of the Gui for
// that camera and size, drawn once in each frame that shows it.
@(private)
source_view :: proc(user:rawptr,camera:base.Entity,size:[2]f32) -> ui.Quad {
    src:=(^Source)(user)
    gui,app:=src.gui,src.app
    if app.renderer==nil {return {}}
    pixels:=[2]u32{u32(clamp(math.ceil(size.x*src.pixels),1,VIEW_PIXELS)),u32(clamp(math.ceil(size.y*src.pixels),1,VIEW_PIXELS))}
    at:=-1
    for view,i in gui.views_shown {
        if view.camera!=camera {continue}
        if view.size==pixels {at=i;break}
        if view.drawn!=gui.frame && at<0 {at=i}
    }
    // Another size of a camera not drawn yet in this frame takes its texture.
    if at>=0 && gui.views_shown[at].size!=pixels {
        render.view_texture_remove(app.renderer,gui.views_shown[at].texture)
        unordered_remove(&gui.views_shown,at)
        at=-1
    }
    if at<0 {
        if len(gui.views_shown)>=VIEW_CAPACITY {return {}}
        texture,added:=render.view_texture_add(app.renderer,pixels.x,pixels.y,"ui view")
        if !added {return {}}
        append(&gui.views_shown,View_Texture{camera=camera,size=pixels,texture=texture})
        at=len(gui.views_shown)-1
    }
    found:=&gui.views_shown[at]
    src.surface.viewed=true
    if src.building!=nil {src.building.live=true}
    if found.drawn!=gui.frame {
        found.drawn=gui.frame
        render.view_of_camera(&found.view,src.cameras,src.exposures,src.zones.worlds,camera,{f32(pixels.x),f32(pixels.y)})
        render.view_volume_expose(&found.view,src.view_volumes,src.zones)
        render.view_texture_draw(&app.extras,found.texture,found.view,pixels.x,pixels.y,found.view.cut)
    }
    return image_quad(app.renderer,found.texture)
}

// The cameras no interface showed this frame let go of their textures.
@(private)
views_sweep :: proc(gui:^Gui,renderer:^render.Renderer) {
    #reverse for view,i in gui.views_shown {
        if view.drawn==gui.frame {continue}
        render.view_texture_remove(renderer,view.texture)
        unordered_remove(&gui.views_shown,i)
    }
}

// A particle effect playing in a rectangle of a size in layout units: an
// effect of the world drawn alone into a texture of the Gui for the element
// id, in each frame that shows it (UI_Effects, and an effect view of the
// renderer seen by an orthographic camera that frames
// PARTICLE_VIEW_METERS of it).
@(private)
source_particles :: proc(user:rawptr,id:ui.Id,effect:base.Asset_Id,size:[2]f32) -> ui.Quad {
    src:=(^Source)(user)
    gui,app:=src.gui,src.app
    if app.renderer==nil || src.effects==nil {return {}}
    pixels:=[2]u32{u32(clamp(math.ceil(size.x*src.pixels),1,PARTICLE_PIXELS)),u32(clamp(math.ceil(size.y*src.pixels),1,PARTICLE_PIXELS))}
    key:=base.hash_combine(u64(id),u64(src.player))
    at,free:=-1,-1
    for &shown,i in gui.particles {
        if shown.texture==0 {
            if free<0 {free=i}
        } else if shown.key==key {at=i}
    }
    if at>=0 && gui.particles[at].size!=pixels {
        render.ui_texture_remove(app.renderer,gui.particles[at].texture)
        gui.particles[at]={}
        free,at=at,-1
    }
    if at<0 {
        if free<0 {return {}}
        texture,added:=render.ui_texture_add(app.renderer,pixels.x,pixels.y,"ui particles",effects=true)
        if !added {return {}}
        gui.particles[free]={key=key,size=pixels,texture=texture}
        at=free
    }
    shown:=&gui.particles[at]
    src.surface.viewed=true
    if src.building!=nil {src.building.live=true}
    if shown.drawn!=gui.frame {
        shown.drawn=gui.frame
        core.push(&src.effects.queue,UI_Effect{key=key,effect=effect,view=shown.texture})
        camera:=gpu.Camera{
            position={0,0,2*PARTICLE_VIEW_METERS},forward=mm.FORWARD,up={0,1,0},fov_y=60,near=0.01,far=8*PARTICLE_VIEW_METERS,
            projection=.Orthographic,height=PARTICLE_VIEW_METERS,
        }
        host.extras_effect_view_add(&app.extras,{texture=shown.texture,camera=camera})
    }
    return image_quad(app.renderer,shown.texture)
}

// The particle effects no interface showed this frame let go of their textures.
@(private)
particles_sweep :: proc(gui:^Gui,renderer:^render.Renderer) {
    for &shown in gui.particles {
        if shown.texture==0 || shown.drawn==gui.frame {continue}
        render.ui_texture_remove(renderer,shown.texture)
        shown={}
    }
}

@(private)
source_sound :: proc(user:rawptr,id:base.Asset_Id) {
    src:=(^Source)(user)
    audio.play(src.sounds,id,bus=audio.BUS_UI)
}
