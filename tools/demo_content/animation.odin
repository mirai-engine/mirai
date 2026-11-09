package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:cook/import/sources"
import "mirai:core"
import game "mirai:demo/game"
import cam "mirai:engine/camera"
import gui "mirai:engine/gui"
import inp "mirai:engine/input"
import render "mirai:engine/render"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:ui"
import anim "plugins:animation/runtime"
import phys "plugins:physics/runtime"

@(private)
rig_path :: proc(model:^importer.Imported_Model,name:string) -> string {
    for &bone in model.skeletons[0].bones {if base.text_get(bone.name[:])==name {return base.text_get(bone.path[:])}}
    return name
}

// The walkway of the gallery runs toward -Z from where the player starts; the stations alternate
// on its left and right, one row every GALLERY_ROW meters.
@(private) GALLERY_SIDE :: 5.5 // m from the center of the walkway to a station
@(private) GALLERY_ROW :: 5
@(private) GALLERY_STATIONS :: 23


// The turn of an actor that looks toward +Z of the world.
GALLERY_TOWARD_PLUS_Z :: mm.Quat(quaternion(w=0,x=0,y=1,z=0))

// Where a station stands: its actor faces the walkway, and along is the walkway's direction.
@(private)
Gallery_Place :: struct {origin:mm.Vec3,facing:mm.Quat,toward,along:mm.Vec3}

@(private)
gallery_place :: proc(index:int) -> Gallery_Place {
    side:=f32(-1) if index%2==0 else 1
    return {{side*GALLERY_SIDE,0,2-f32(index/2)*GALLERY_ROW},mm.quat_axis_angle({0,1,0},side*mm.PI*.5),{-side,0,0},{0,0,-1}}
}

// What the stations of the gallery share while the scene is written.
@(private)
Gallery_Build :: struct {
    o:^Out,
    s:^asset.Scene_Builder,
    model:^importer.Imported_Model,
    source:string,
    clip:base.Asset_Id,
    label,panel:base.Asset_Id,
    next:int,
}

@(private)
gallery_next :: proc(g:^Gallery_Build) -> Gallery_Place {place:=gallery_place(g.next);g.next+=1;return place}

@(private)
gallery_actor :: proc(o:^Out,s:^asset.Scene_Builder,model:^importer.Imported_Model,source,name:string,position:mm.Vec3,facing:mm.Quat=1,clip:base.Asset_Id={},clip_name:string="walk",body_only:=false) -> base.Entity_Id {
    root:=asset.builder_entity(s,name,{position=position})
    placed:=core.Transform{position,facing,{1,1,1}};asset.builder_set(s,root,placed)
    // The first mesh of the model makes the actor its rig; any other follows its pose.
    shown:=false
    for node in model.nodes {
        if node.mesh<0 {continue}
        mesh:=render.Mesh_Renderer{mesh=imported_id(o,source,asset.KIND_MESH,model.meshes[node.mesh].name)}
        if !shown {asset.builder_set(s,root,mesh);shown=true;continue}
        if body_only {break}
        transform:=node.transform
        parent:=node.parent
        for parent>=0 {transform=mm.transform_compose(model.nodes[parent].transform,transform);parent=model.nodes[parent].parent}
        draw:=asset.builder_entity(s,node.name,{position=transform.position,scale=transform.scale},root)
        local:=core.Transform(transform);asset.builder_set(s,draw,local)
        asset.builder_set(s,draw,mesh)
        asset.builder_set(s,draw,anim.Pose_Source{rig=core.Entity(root)})
    }
    if clip!={} {value:=anim.ANIMATION_DEFAULT;value.asset=clip;value.fade=.35;base.text_set(value.clip[:],clip_name);asset.builder_set(s,root,value)}
    return root
}

@(private)
gallery_mirai :: proc(g:^Gallery_Build,name:string,position:mm.Vec3,facing:mm.Quat,clip_name:string="walk") -> base.Entity_Id {
    return gallery_actor(g.o,g.s,g.model,g.source,name,position,facing,g.clip,clip_name)
}

// A clip over the one of the actor, authored on its Animation.
@(private)
gallery_layer :: proc(s:^asset.Scene_Builder,root:base.Entity_Id,clip:string,layer:int,over:="",sync:=false,weight:f32=1,fade:f32=.25) {
    value,found:=asset.scene_get(&s.scene,root,"Animation",anim.Animation)
    if !found || !anim.animation_play(&value,clip,fade,layer=layer,over=over,sync=sync,weight=weight) {s.failed=true;return}
    asset.builder_set(s,root,value)
}

@(private)
gallery_label_asset :: proc(o:^Out) -> base.Asset_Id {
    texts:=make([dynamic]u8,context.temp_allocator)
    id:=asset.content_id(PROJECT,"ui","animation_gallery_label")
    data:=ui.Tree_Data{text=texts[:],
        styles={{},{fill={17,24,35,235},radius=6},{text={size=17,color={255,255,255,255}}},{text={size=12,color={170,200,235,255}}}},
        nodes={
            ui.tree_node_record(&texts,-1,{kind=.Box,name="panel",style=1,layout={width=ui.fixed(330),height=ui.fixed(64),direction=.Column,padding=ui.padding_all(7),gap=5}}),
            ui.tree_node_record(&texts,0,{kind=.Text,name="title",style=2,bind_text="Gallery_Label.title"}),
            ui.tree_node_record(&texts,0,{kind=.Text,name="detail",style=3,bind_text="Gallery_Label.detail"}),
        },
    }
    asset.content_check(&o.content,"assets/ui/animation_gallery_label.ui",host.ui_tree_save(path(o,"assets/ui/animation_gallery_label.ui"),&o.content.types,id,data))
    return id
}

// The adjustable panel of a station: its rows and buttons are what Gallery_Panel holds, which the
// game fills for the kind of its station; a slider moves its row between 0 and 1.
@(private)
gallery_panel_asset :: proc(o:^Out) -> base.Asset_Id {
    texts:=make([dynamic]u8,context.temp_allocator)
    id:=asset.content_id(PROJECT,"ui","animation_gallery_panel")
    control:=ui.Node_Style{text={size=14,color={255,255,255,255},align_x=.Center,align_y=.Center},fill={34,44,64,255},stroke={90,120,170,255},mark={110,170,255,255},track={52,60,80,255},knob={235,240,250,255},radius=6,stroke_width=1}
    styles:=[]ui.Node_Style{
        {},
        {fill={14,19,29,238},stroke={80,105,150,255},stroke_width=1,radius=10},
        {text={size=17,color={255,255,255,255}}},
        {text={size=13,color={175,200,235,255}}},
        control,
        {text={size=12,color={130,150,180,255}}},
    }
    variants:=[]ui.Tree_Style_Variant{
        ui.tree_variant_record(4,"",{.Hovered},{fields={.Stroke},values={stroke={160,195,255,255}}}),
        ui.tree_variant_record(4,"",{.Pressed},{fields={.Fill},values={fill={70,100,170,255}}}),
    }
    data:=ui.Tree_Data{text=texts[:],styles=styles,variants=variants,
        nodes={
            ui.tree_node_record(&texts,-1,{kind=.Box,name="panel",style=1,layout={width=ui.fixed(300),direction=.Column,padding=ui.padding_all(12),gap=8}}),
            ui.tree_node_record(&texts,0,{kind=.Text,name="title",style=2,bind_text="Gallery_Panel.title"}),
            ui.tree_node_record(&texts,0,{kind=.List,name="rows",bind_items="Gallery_Panel.rows",bind_value="Gallery_Panel.row_count",layout={width=ui.GROW,direction=.Column,gap=6}}),
            ui.tree_node_record(&texts,2,{kind=.Box,name="row",layout={width=ui.GROW,direction=.Column,gap=3}}),
            ui.tree_node_record(&texts,3,{kind=.Box,name="heading",layout={width=ui.GROW,gap=6}}),
            ui.tree_node_record(&texts,4,{kind=.Text,name="label",style=3,bind_text="label",layout={width=ui.GROW}}),
            ui.tree_node_record(&texts,4,{kind=.Text,name="readout",style=3,bind_text="readout"}),
            ui.tree_node_record(&texts,3,{kind=.Slider,name="value",style=4,bind_value="value",range={0,1,.01},layout={width=ui.GROW,height=ui.fixed(20)}}),
            ui.tree_node_record(&texts,0,{kind=.List,name="buttons",bind_items="Gallery_Panel.buttons",bind_value="Gallery_Panel.button_count",layout={width=ui.GROW,direction=.Grid,columns=2,gap=6}}),
            ui.tree_node_record(&texts,8,{kind=.Button,name="button",style=4,bind_text="label",layout={width=ui.fixed(132),height=ui.fixed(30)}}),
            ui.tree_node_record(&texts,0,{kind=.Text,name="hint",style=5,bind_text="Gallery_Panel.hint"}),
        },
    }
    asset.content_check(&o.content,"assets/ui/animation_gallery_panel.ui",host.ui_tree_save(path(o,"assets/ui/animation_gallery_panel.ui"),&o.content.types,id,data))
    return id
}

// The station of an actor: what the game does with it, its plaque at the walkway and, if it can
// be adjusted, its panel and the camera that frames both while it is adjusted.
@(private)
gallery_item :: proc(g:^Gallery_Build,root:base.Entity_Id,kind:game.Gallery_Kind,place:Gallery_Place,title,detail:string,indicator:base.Entity_Id=0,target:base.Entity_Id=0,adjustable:=false,stride:f32=0) {
    s:=g.s
    item:=game.Animation_Gallery{kind=kind,origin=place.origin,stride=stride,indicator=core.Entity(indicator),target=core.Entity(target)}
    base.text_set(item.title[:],title);base.text_set(item.detail[:],detail)
    asset.builder_set(s,root,item)
    sign:=asset.builder_entity(s,fmt.tprintf("%s plaque",title),{position=place.origin+place.toward*2.1+mm.Vec3{0,.32,0}})
    text:=game.Gallery_Label{};base.text_set(text.title[:],title);base.text_set(text.detail[:],detail)
    asset.builder_set(s,sign,text)
    widget:=gui.WORLD_WIDGET_DEFAULT;widget.asset=g.label;widget.size=game.GALLERY_PLAQUE_SIZE;widget.scale=.0062;widget.passive=true
    asset.builder_set(s,sign,widget)
    plate:=asset.builder_entity(s,fmt.tprintf("%s floor",title),{position=place.origin+mm.Vec3{0,.006,0},scale={3.6,.012,3.6}})
    asset.builder_set(s,plate,render.Mesh_Renderer{shape=.Cylinder});asset.builder_set(s,plate,render.Tint{color={.2,.27,.36,1} if adjustable else {.17,.21,.27,1}})
    if !adjustable {return}
    focus:=place.origin-place.along*.9
    view:=asset.builder_entity(s,fmt.tprintf("%s view",title),{position=focus+place.toward*3.7+mm.Vec3{0,1.75,0}})
    placed:=core.Transform{focus+place.toward*3.7+mm.Vec3{0,1.75,0},mm.quat_look(focus+mm.Vec3{0,1.1,0}-(focus+place.toward*3.7+mm.Vec3{0,1.75,0}),{0,1,0}),{1,1,1}}
    asset.builder_set(s,view,placed)
    lens:=render.CAMERA_DEFAULT;lens.active=false;lens.fov=55*mm.RAD_PER_DEG;asset.builder_set(s,view,lens)
    panel:=asset.builder_entity(s,fmt.tprintf("%s panel",title),{position=place.origin-place.along*1.85+place.toward*.5+mm.Vec3{0,1.35,0}})
    value:=game.Gallery_Panel{station=core.Entity(root),camera=core.Entity(view)}
    base.text_set(value.title[:],title)
    asset.builder_set(s,panel,value)
    widget=gui.WORLD_WIDGET_DEFAULT;widget.asset=g.panel;widget.size={};widget.scale=.0052
    asset.builder_set(s,panel,widget)
}

@(private)
gallery_cube :: proc(s:^asset.Scene_Builder,name:string,position,scale:mm.Vec3,color:mm.Vec4,solid:bool=false,rotation:mm.Quat=1) -> base.Entity_Id {
    value:=asset.builder_entity(s,name,{position=position,scale=scale})
    if rotation!=1 {placed:=core.Transform{position,rotation,scale};asset.builder_set(s,value,placed)}
    asset.builder_set(s,value,render.Mesh_Renderer{shape=.Cube});asset.builder_set(s,value,render.Tint{color=color})
    if solid {collider:=phys.COLLIDER_DEFAULT;asset.builder_set(s,value,collider)}
    return value
}

// The sun alone lights the gallery: a sun of 2 is noon.
@(private)
GALLERY_LIGHT :: Light_Units{nits=NOON/(2*math.PI)}
GALLERY_BATON :: mm.Vec3{.04,.3,.04} // m, the baton held in the grip of the hand, along its Y

// The sky, the sun, the floor with its walkway and the camera that sees the gallery whole.
@(private)
gallery_environment :: proc(o:^Out,s:^asset.Scene_Builder) -> base.Entity_Id {
    environment,turn,to_sun,disc:=sky_of(o,.Day,SCENE_SUN,GALLERY_LIGHT,2)
    sky_set(s,&environment,turn,render.EXPOSURE_DEFAULT)
    sun:=asset.builder_entity(s,"Sun",{position={0,6,0}})
    pose:=sun_pose(to_sun,{0,6,0})
    asset.builder_set(s,sun,pose)
    asset.builder_set(s,sun,render.Sun{color={1,.94,.85},illuminance=lux(GALLERY_LIGHT,2),disc=disc})
    rows:=f32((GALLERY_STATIONS+1)/2)
    length:=rows*GALLERY_ROW+14
    middle:=game.GALLERY_START.z+3-length*.5
    gallery_cube(s,"Floor",{0,-.1,middle},{2*GALLERY_SIDE+9,.2,length},{.13,.16,.2,1},true)
    gallery_cube(s,"Walkway",{0,.003,middle},{3.2,.006,length},{.2,.23,.28,1})
    position:=mm.Vec3{0,13,game.GALLERY_START.z+6}
    camera:=asset.builder_entity(s,"Gallery camera",{position=position})
    placed:=core.Transform{position,mm.quat_look(mm.Vec3{0,0,middle*.5}-position,{0,1,0}),{1,1,1}}
    asset.builder_set(s,camera,placed)
    settings:=render.CAMERA_DEFAULT;settings.fov=55*mm.RAD_PER_DEG
    asset.builder_set(s,camera,settings)
    return camera
}

// The right hand of an actor reaches a target in front of it, in line with its forearm, its head
// looks at the target within a limit and a baton lies in the grip of its hand, against the palm.
@(private)
gallery_hand_ik :: proc(g:^Gallery_Build,root:base.Entity_Id,place:Gallery_Place) -> base.Entity_Id {
    o,s:=g.o,g.s
    at:=proc(place:Gallery_Place,local:mm.Vec3) -> mm.Vec3 {return place.origin+mm.quat_rotate(place.facing,local)}
    reach:=at(place,{.42,1.3,-.42})
    target:=asset.builder_entity(s,"Right hand target",{position=reach,scale={.075,.075,.075}})
    asset.builder_set(s,target,render.Mesh_Renderer{shape=.Sphere});asset.builder_set(s,target,render.Tint{color={1,.3,.05,1},emission=nits(GALLERY_LIGHT,{2,.3,0})})
    ik:=anim.IK_CONSTRAINT_DEFAULT;ik.rig,ik.target,ik.hold=core.Entity(root),anim.spatial_point(reach),.Joint
    ik.root,ik.joint,ik.end=anim.bone_ref("RightArm"),anim.bone_ref("RightForeArm"),anim.bone_ref("RightHand")
    ik.pole=at(place,{.9,.9,.6})
    rig,_:=mirai_rig(g.model)
    head:=mirai_bone(g.model,"Head")
    look:=anim.LOOK_CONSTRAINT_DEFAULT;look.rig,look.bone=core.Entity(root),anim.bone_ref("Head");look.target=ik.target
    look.forward,look.max_angle=linalg.normalize0(mm.quat_rotate(mm.quat_inverse(rig.rest_world[head].rotation),mm.Vec3{0,0,-1})),.6
    limit:=anim.ROTATION_CONSTRAINT_DEFAULT;limit.rig,limit.bone=core.Entity(root),anim.bone_ref("Head");limit.max_swing,limit.min_twist,limit.max_twist=.35,-.6,.6
    gallery_profile(o,s,root,"mirai_constraints",{ik={ik},look={look},limits={limit}})
    baton:=gallery_cube(s,"Socket baton",{},{1,1,1},{.2,1,.4,1})
    // The grip is on the palm, so the baton lies on it by half its thickness.
    socket:=anim.BONE_ATTACHMENT_DEFAULT;socket.rig=core.Entity(root);base.text_set(socket.socket[:],"grip_right")
    socket.offset.position,socket.offset.scale={0,0,GALLERY_BATON.z*.5},GALLERY_BATON
    asset.builder_set(s,baton,socket)
    return target
}

// The clips of the source hold each hand 25 to 50 degrees off its bind, bent out of line with the
// forearm: its rotations turn around the bind instead of around their mean.
@(private)
mirai_hands :: proc(model:^importer.Imported_Model,rig:Mirai_Rig,clip:^asset.Animation_Clip_Desc) {
    paths:=[2]string{rig_path(model,"LeftHand"),rig_path(model,"RightHand")}
    bones:=[2]int{mirai_bone(model,"LeftHand"),mirai_bone(model,"RightHand")}
    tracks:=make([]asset.Animation_Track_Desc,len(clip.tracks),context.temp_allocator);copy(tracks,clip.tracks)
    for &track in tracks {
        for hand,side in paths {
            if track.target!=hand || track.property!=.Rotation || bones[side]<0 || len(track.keys)==0 {continue}
            mean:mm.Vec4
            for key in track.keys {mean+=key.value if linalg.dot(key.value,track.keys[0].value)>=0 else -key.value}
            around:=mm.quat_inverse(lib.vec4_quat(linalg.normalize0(mean)))
            keys:=make([]lib.Keyframe,len(track.keys),context.temp_allocator);copy(keys,track.keys)
            for &key in keys {key.value=lib.quat_vec4(linalg.normalize(rig.rest[bones[side]].rotation*around*lib.vec4_quat(key.value)))}
            track.keys=keys
        }
    }
    clip.tracks=tracks
}

// The locomotion clips of Mirai with its hands in line and those on the ground lowered to its floor:
// retargeting raised it above the height of its feet at rest. It returns them for the gallery
// clips made from them.
@(private)
mirai_animation :: proc(o:^Out,model:^importer.Imported_Model) -> (id:base.Asset_Id,clips:[]asset.Animation_Clip_Desc) {
    id=asset.content_id(PROJECT,"animation","mirai_locomotion")
    bones:=model.skeletons[0].bones
    rig,valid:=mirai_rig(model)
    ground_bones:=[4]int{mirai_bone(model,"LeftFoot"),mirai_bone(model,"LeftToeBase"),mirai_bone(model,"RightFoot"),mirai_bone(model,"RightToeBase")}
    hips:=mirai_bone(model,"Hips")
    if hips<0 || !valid {o.content.failed=true;return}
    for bone in ground_bones {if bone<0 {o.content.failed=true;return}}
    clips=make([]asset.Animation_Clip_Desc,len(model.animations),context.temp_allocator)
    copy(clips,model.animations)
    skeleton:=imported_id(o,"source/models/mirai/mirai.glb",asset.KIND_SKELETON,model.skeletons[0].name)
    for &clip in clips {
        clip.skeleton=skeleton
        mirai_hands(model,rig,&clip)
        if clip.name!="idle" && clip.name!="walk" && clip.name!="land" {continue}
        hip_track:=-1
        for track,i in clip.tracks {if track.target==rig_path(model,"Hips") && track.property==.Position {hip_track=i}}
        if hip_track<0 {o.content.failed=true;return}
        frames,times,sampled:=mirai_clip_frames(rig,clip,60)
        if !sampled {o.content.failed=true;return}
        keys:=make([]lib.Keyframe,len(frames),context.temp_allocator)
        for world,frame in frames {
            // The lowest ankle or toe stays at its rest height without changing X/Z.
            lift:=max(f32)
            for bone in ground_bones {lift=min(lift,world[bone].position.y-rig.rest_world[bone].position.y)}
            parent:=bones[hips].parent
            placed:=world[hips].position-mm.Vec3{0,lift,0}
            point:=mm.transform_inverse_point(world[parent],placed) if parent>=0 else placed
            keys[frame]={time=times[frame],value={point.x,point.y,point.z,0},interpolation=.Linear}
        }
        adjusted:=make([]asset.Animation_Track_Desc,len(clip.tracks),context.temp_allocator)
        copy(adjusted,clip.tracks);adjusted[hip_track].keys=keys;clip.tracks=adjusted
    }
    asset.content_check(&o.content,"assets/animations/mirai_locomotion.anim",asset.animation_save(path(o,"assets/animations/mirai_locomotion.anim"),&o.content.types,{id=id,clips=clips}))
    return
}

@(private)
mirai_feet :: proc(model:^importer.Imported_Model) -> anim.Foot_Grounding {
    feet:=anim.FOOT_GROUNDING_DEFAULT;feet.count=2;feet.body=anim.bone_ref("Hips")
    feet.global_contact=0;feet.max_rise=.15;feet.trace_above=.55;feet.trace_below=.9;feet.blend_time=.08
    bones:=model.skeletons[0].bones
    rest:=make([]mm.Transform,len(bones),context.temp_allocator)
    for bone,i in bones {
        rest[i]={bone.translation,bone.rotation,bone.scale}
        if bone.parent>=0 {rest[i]=mm.transform_compose(rest[bone.parent],rest[i])}
    }
    for side,i in ([]string{"Left","Right"}) {
        leg:=anim.GROUNDED_LEG_DEFAULT
        leg.hip=anim.bone_ref(fmt.tprintf("%sUpLeg",side));leg.knee=anim.bone_ref(fmt.tprintf("%sLeg",side));leg.foot=anim.bone_ref(fmt.tprintf("%sFoot",side))
        leg.contact_bone=anim.bone_ref(fmt.tprintf("%sToeBase",side))
        leg.pole_offset={};leg.max_distance=.55;leg.contact_height=.04;leg.plant_speed=.6
        for &bone,j in bones {
            if base.text_get(bone.name[:])==fmt.tprintf("%sFoot",side) {
                leg.foot_up=mm.quat_rotate(conj(rest[j].rotation),{0,1,0})
                leg.sole_height=max(0,rest[j].position.y)
            }
            if base.text_get(bone.name[:])==fmt.tprintf("%sToeBase",side) {leg.contact_offset=max(0,rest[j].position.y)}
        }
        feet.legs[i]=leg
    }
    return feet
}

@(private)
gallery_save :: proc(o:^Out,s:^asset.Scene_Builder,name:string) {
    s.scene.info.id_counter=max(s.scene.info.id_counter,u64(s.next))
    file:=fmt.tprintf("assets/scenes/%s.scene",name)
    asset.builder_save(s,path(o,file))
}

@(private)
gallery_profile :: proc(o:^Out,s:^asset.Scene_Builder,root:base.Entity_Id,name:string,profile:anim.Pose_Profile) {
    id:=asset.content_id(PROJECT,"pose",name)
    asset.content_check(&o.content,name,anim.pose_profile_save(path(o,fmt.tprintf("assets/animations/%s.pose",name)),&o.content.types,id,profile))
    config:=anim.POSE_MODIFIERS_DEFAULT;config.profile=id
    asset.builder_set(s,root,config)
}

// A body that moves by the root motion of its clips instead of what it is asked.
@(private)
gallery_motor :: proc(s:^asset.Scene_Builder,entity:base.Entity_Id) {
    character:=phys.character_default();character.move_relative_to=.Game
    walk:=phys.WALK_DEFAULT;walk.max_speed=10;walk.acceleration=1000;walk.braking=1000
    capsule:=phys.collider_character()
    motor:=game.ANIMATION_MOTOR_DEFAULT;asset.builder_set(s,entity,character);asset.builder_set(s,entity,walk);asset.builder_set(s,entity,capsule);asset.builder_set(s,entity,motor)
}

// The animation gallery: one hall that Mirai walks, with a station per feature. Every station
// plays on its own from the start; at those with a panel, E frames it and frees the pointer for
// its sliders and buttons.
write_animation_scene :: proc(o:^Out) {
    source:="source/models/mirai/mirai.glb"
    model,error:=importer.import_model(path(o,source),sources.FORMATS[:],{root=fmt.tprintf("%s/demo",o.root)})
    if error.code!=.None {fmt.eprintln(error.message);o.content.failed=true;return}
    defer importer.model_destroy(&model)
    locomotion,locomotion_clips:=mirai_animation(o,&model)
    if o.content.failed {return}
    clip,stride,stride_time:=mirai_gallery_animation(o,&model,locomotion_clips)
    if o.content.failed {return}
    programs:=gallery_program_assets(o,&model,clip,stride_time)
    matching:=gallery_mirai_matching(o,locomotion)
    s:asset.Scene_Builder;asset.builder_init(&s,&o.content,asset.KIND_SCENE,asset.content_id(PROJECT,"scene","animation"));defer asset.builder_destroy(&s)
    g:=Gallery_Build{o=o,s=&s,model=&model,source=source,clip=clip,label=gallery_label_asset(o),panel=gallery_panel_asset(o)}
    gallery_environment(o,&s)
    shoulder:=rig_path(&model,"LeftShoulder")

    place:=gallery_next(&g)
    root:=gallery_mirai(&g,"Mirai clip playback",place.origin,place.facing)
    gallery_item(&g,root,.Direct,place,"1.1  Clip playback","walk / wave / backwards, crossfaded",adjustable=true)

    place=gallery_next(&g)
    root=gallery_mirai(&g,"Mirai events and curves",place.origin,place.facing)
    indicator:=asset.builder_entity(&s,"Event curve indicator",{position=place.origin+mm.Vec3{0,2.15,0},scale={.2,.2,.2}})
    asset.builder_set(&s,indicator,render.Mesh_Renderer{shape=.Sphere});asset.builder_set(&s,indicator,render.Tint{color={1,.6,.1,1},emission=nits(GALLERY_LIGHT,{1,.2,0})})
    gallery_item(&g,root,.Events,place,"1.2  Events and curves","step markers / the pulse curve sizes the ball",indicator)

    place=gallery_next(&g)
    root=gallery_mirai(&g,"Mirai root motion",place.origin,GALLERY_TOWARD_PLUS_Z,"stride")
    {value,_:=asset.scene_get(&s.scene,root,"Animation",anim.Animation);value.root_motion=.In_Place;asset.builder_set(&s,root,value)}
    gallery_item(&g,root,.Root_Motion,place,"1.3  Root motion","the hips of the stride move the actor")

    place=gallery_next(&g)
    sequence:=gallery_cube(&s,"Sequence platform",place.origin+mm.Vec3{0,.3,0},{1.2,.25,1.2},{.2,.65,.9,1})
    path_value:=anim.keyframe_path_default();path_value.count=3;path_value.relative=true;path_value.loop=.Ping_Pong
    path_value.frames[0].hold=.5;path_value.frames[1].pose.position={0,1,0};path_value.frames[1].duration=1.5;path_value.frames[1].ease=.Sine_In_Out;path_value.frames[1].hold=.5
    path_value.frames[2].pose.position={0,.5,-.6};path_value.frames[2].pose.rotation=mm.quat_axis_angle({0,1,0},mm.PI*.5);path_value.frames[2].duration=1;path_value.frames[2].hold=.5
    path_value.frames[2].pose.scale={1.4,1,1.4}
    asset.builder_set(&s,sequence,path_value)
    gallery_item(&g,sequence,.Sequence,place,"1.4  Transform sequence","3 frames / holds / easing / ping-pong",adjustable=true)

    place=gallery_next(&g)
    root=gallery_mirai(&g,"Mirai greeting layer",place.origin,place.facing)
    gallery_layer(&s,root,"wave",layer=1,over=shoulder,fade=.35)
    gallery_item(&g,root,.Layered,place,"2.1  Layer over the shoulder","the wave moves only the left arm of the walk",adjustable=true)

    place=gallery_next(&g)
    root=gallery_mirai(&g,"Mirai synchronized strides",place.origin,place.facing)
    gallery_layer(&s,root,"jog",layer=1,sync=true,weight=.5)
    gallery_item(&g,root,.Sync,place,"2.2  Synchronized layer","walk and jog keep their steps together",adjustable=true)

    place=gallery_next(&g)
    root=gallery_mirai(&g,"Mirai additive wave",place.origin,place.facing)
    {
        value:=anim.ANIMATION_DEFAULT;value.asset=programs.additive
        _,wave:=game.gallery_automatic(.Additive,0);anim.animation_parameter(&value,game.GALLERY_WAVE,wave)
        asset.builder_set(&s,root,value)
    }
    gallery_item(&g,root,.Additive,place,"2.3  Additive wave","a wave space added over the walk",adjustable=true)

    place=gallery_next(&g)
    root=gallery_mirai(&g,"Mirai greeting graph",place.origin,place.facing)
    {
        value:=anim.ANIMATION_DEFAULT;value.asset,value.actions=programs.graph,programs.actions
        _,wave:=game.gallery_automatic(.Graph,0);anim.animation_parameter(&value,game.GALLERY_WAVE,wave)
        asset.builder_set(&s,root,value)
    }
    gallery_item(&g,root,.Graph,place,"2.4  Graph and action","a weighted layer of the graph and the Greet action",adjustable=true)

    place=gallery_next(&g)
    root=gallery_mirai(&g,"Mirai named actions",place.origin,place.facing,"idle")
    {
        value:=anim.ANIMATION_DEFAULT;value.asset,value.actions=clip,programs.actions;base.text_set(value.clip[:],"idle")
        asset.builder_set(&s,root,value);gallery_motor(&s,root)
    }
    gallery_item(&g,root,.Actions,place,"2.5  Named actions","Greet on the arm, Step with root motion",adjustable=true)

    place=gallery_next(&g)
    root=gallery_mirai(&g,"Mirai matching by speed",place.origin,place.facing)
    {
        value:=anim.ANIMATION_DEFAULT;value.asset=programs.matching;value.root_motion=.In_Place
        asset.builder_set(&s,root,value)
    }
    gallery_item(&g,root,.Matching,place,"3.1  Motion matching","the speed asked picks idle, walk or jog",adjustable=true)

    place=gallery_next(&g)
    root=gallery_mirai_physical(&g,"Mirai slope walk",place.origin+mm.Vec3{0,.05,1.2},matching,programs.locomotion)
    gallery_item(&g,root,.Walker,place,"3.2  Physics, slope and foot IK","matching from its Character / feet on the ground")
    gallery_cube(&s,"Slope",place.origin+mm.Vec3{0,.27,0},{2,.2,4},{.2,.28,.35,1},true,mm.quat_from_euler({.12,0,0}))
    for j in 0..<3 {gallery_cube(&s,fmt.tprintf("Stair %d",j),place.origin+mm.Vec3{0,.15+f32(j)*.1,-1.1-f32(j)*.3},{2,.3+f32(j)*.2,.3},{.25,.35,.4,1},true)}

    place=gallery_next(&g)
    root=gallery_mirai_physical(&g,"Mirai physical jump and fall",place.origin+mm.Vec3{0,.05,1.2},matching,programs.locomotion)
    gallery_item(&g,root,.Jumper,place,"3.3  Jump, fall and land","entry clips of falling and walking")
    gallery_cube(&s,"Jump obstacle",place.origin+mm.Vec3{0,.225,0},{1.4,.45,.35},{.35,.25,.16,1},true)

    place=gallery_next(&g)
    root=gallery_mirai(&g,"Mirai warp to a target",game.gallery_warp_start({origin=place.origin,stride=stride}),GALLERY_TOWARD_PLUS_Z,"idle")
    {
        value:=anim.ANIMATION_DEFAULT;value.asset,value.motion=clip,programs.reach;value.root_motion=.In_Place;base.text_set(value.clip[:],"idle")
        asset.builder_set(&s,root,value);gallery_motor(&s,root)
    }
    goal:=gallery_cube(&s,"Reach goal",place.origin+mm.Vec3{0,.1,.3*stride},{.16,.2,.16},{1,.5,.08,1})
    gallery_item(&g,root,.Warp,place,"3.4  Warp to a target","the stride stretches or shrinks to end at the goal",goal,adjustable=true,stride=stride)

    place=gallery_next(&g)
    root=gallery_mirai(&g,"Mirai constraints",place.origin,place.facing,"idle")
    target:=gallery_hand_ik(&g,root,place)
    gallery_item(&g,root,.IK,place,"4.1  Look, limit, IK and socket","hand reaches the ball / head looks / baton",target=target,adjustable=true)

    place=gallery_next(&g)
    root=gallery_mirai(&g,"Mirai retarget source",place.origin-place.along*.8,place.facing)
    tall:=gallery_actor(o,&s,&model,source,"Tall Mirai retarget",place.origin+place.along*.8,place.facing,body_only=true)
    gallery_retarget(o,&s,&model,source,tall)
    gallery_item(&g,tall,.Retarget,place,"4.2  Retarget proportions","its walk baked for longer legs and body")

    rig_places:[3]Gallery_Place
    for &value in rig_places {value=gallery_next(&g)}
    gallery_rigs(&g,rig_places)

    place=gallery_next(&g)
    spider:=gallery_spider(&g,place)

    morph_places:[3]Gallery_Place
    for &value in morph_places {value=gallery_next(&g)}
    gallery_morphs(&g,morph_places)

    place=gallery_next(&g)
    for period,i in ([2]u16{1,4}) {
        root=gallery_mirai(&g,fmt.tprintf("Mirai presentation every %d frames",period),place.origin+place.along*(f32(i)*1.6-.8),place.facing)
        policy:=anim.ANIMATION_BUDGET_DEFAULT;policy.period=period;policy.significance=2 if i==0 else .5;asset.builder_set(&s,root,policy)
        if i==1 {gallery_item(&g,root,.Budget,place,"5.5  Presentation budget","the far one is presented every 4 frames")}
    }

    player:=gallery_mirai_physical(&g,"Mirai",game.GALLERY_START,matching,programs.locomotion,1)
    gallery_player(&s,player,spider)
    if g.next!=GALLERY_STATIONS {fmt.eprintfln("demo_content: the gallery placed %d stations, not %d",g.next,GALLERY_STATIONS);o.content.failed=true}
    gallery_save(o,&s,"animation")
}
