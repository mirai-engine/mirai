package main

import inp "mirai:engine/input"
import "core:fmt"
import "core:os"
import "mirai:asset"
import "mirai:core"
import game "mirai:demo/game"
import destruct "plugins:destruct/runtime"
import gui "mirai:engine/gui"
import phys "plugins:physics/runtime"
import render "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"
import "mirai:ui"
import cache "plugins:physics_cache/runtime"
import fields "plugins:physics_fields/runtime"
import vfx "plugins:vfx/runtime"
import "plugins:vfx/runtime/effect"

@(private)
Physics_Sources :: struct {bricks,wall,hierarchy,mixed,cache,bricks_mesh,wall_mesh,hierarchy_mesh,mixed_mesh:base.Asset_Id}

@(private)
physics_source_save :: proc(o:^Out,b:^asset.Fracture_Builder,name:string) -> (fracture,mesh:base.Asset_Id) {
    fracture,mesh=id_of("fracture",name),id_of("mesh",name)
    check(o,fmt.tprintf("%s.fracture",name),asset.fracture_save(path(o,fmt.tprintf("assets/physics_gallery/%s.fracture",name)),&o.types,asset.fracture_builder_desc(b,fracture,mesh)))
    indices:=make([dynamic]u32,context.temp_allocator)
    for piece in b.pieces {for index in b.indices[piece.first_index:][:piece.index_count] {append(&indices,piece.first_vertex+index)}}
    mesh_write_built(o,fmt.tprintf("%s.mesh",name),fmt.tprintf("assets/physics_gallery/%s.mesh",name),{id=mesh,slots={{id=0,material=game.material_asset("Bricks")},{id=1,material=game.material_asset("Cobblestone")}}},{vertices=b.vertices[:]},indices[:])
    return
}

@(private)
physics_sources :: proc(o:^Out) -> Physics_Sources {
    os.make_directory_all(path(o,"assets/physics_gallery"))
    result:Physics_Sources
    cube:geom.Mesh_Buffer;geom.mesh_buffer_init(&cube);defer geom.mesh_buffer_destroy(&cube)
    geom.cube_build(&cube)
    b:asset.Fracture_Builder;asset.fracture_builder_init(&b);defer asset.fracture_builder_destroy(&b)
    for y in 0..<2 {for x in 0..<4 {
        pose:=mm.Transform{{f32(x)*.62-.93,f32(y)*.57+.285,0},1,{.6,.55,.65}}
        _,error:=asset.fracture_piece_add(&b,geom.mesh_buffer_view(&cube),pose)
        if error!=.None {o.failed=true;return result}
    }}
    check(o,"bricks proximity",asset.fracture_connect_proximity(&b,.04,.3,60))
    result.bricks,result.bricks_mesh=physics_source_save(o,&b,"bricks")
    asset.fracture_cluster_add(&b,-1,150);asset.fracture_cluster_add(&b,0,100);asset.fracture_cluster_add(&b,0,100)
    for &piece,at in b.pieces {piece.cluster=1 if at%4<2 else 2}
    result.hierarchy,result.hierarchy_mesh=physics_source_save(o,&b,"hierarchy")
    result.cache=physics_cache_bake(o,result.hierarchy,result.hierarchy_mesh)
    mixed:asset.Fracture_Builder;asset.fracture_builder_init(&mixed);defer asset.fracture_builder_destroy(&mixed)
    if !physics_mixed_build(&mixed,geom.mesh_buffer_view(&cube)) {o.failed=true;return result}
    result.mixed,result.mixed_mesh=physics_source_save(o,&mixed,"mixed_bricks")
    clear(&b.vertices);clear(&b.indices);clear(&b.pieces);clear(&b.connections);clear(&b.clusters)
    for y in 0..<4 {for x in 0..<4 {
        _,error:=asset.fracture_piece_add(&b,geom.mesh_buffer_view(&cube),{{f32(x)*.52-.78,f32(y)*.52+.26,0},1,{.5,.5,.4}},anchor=y==0)
        if error!=.None {o.failed=true;return result}
    }}
    check(o,"wall proximity",asset.fracture_connect_proximity(&b,.04,.2,35))
    result.wall,result.wall_mesh=physics_source_save(o,&b,"wall")
    return result
}

@(private)
physics_mixed_build :: proc(b:^asset.Fracture_Builder,cube:geom.Mesh) -> bool {
    for y in 0..<2 {for x in 0..<4 {
        size:=mm.Vec3{.35,.35,.35} if y==1 && x>=2 else mm.Vec3{.6,.55,.65}
        height:=size.y/2 if y==0 else .57+size.y/2
        _,error:=asset.fracture_piece_add(b,cube,{{f32(x)*.62-.93,height,0},1,size},anchor=y==0)
        if error!=.None {return false}
    }}
    return asset.fracture_connect_proximity(b,.04,.3,60)==.None
}

@(private)
physics_burst :: proc(o:^Out) {
    os.make_directory_all(path(o,"assets/physics_gallery"))
    dust:=effect.PARTICLE_DEFAULTS;dust.duration=.05;dust.rate=0;dust.bursts[0]={count=50,cycles=1}
    dust.shape=.Sphere;dust.shape_size={.5,.5,.5};dust.lifetime={1.5,2};dust.speed={.7,1.4};dust.size={.15,.25};dust.gravity=.1
    dust.colors={{.9,.72,.42,.85},{1,.9,.65,.65}};dust.drag=1
    id:=id_of("particle","physics_dust")
    check(o,"physics dust",effect.particle_save(path(o,"assets/physics_gallery/physics_dust.particle"),&o.types,{id=id,info=dust}))
    s:Scene_Out;asset.scene_init(&s.scene,&o.types,asset.KIND_PREFAB,game.PHYSICS_GALLERY_BURST);defer asset.scene_destroy(&s.scene)
    e:=entity(&s,"Fracture dust")
    put(&s,e,"Particle_Emitter",&vfx.Particle_Emitter{particle=id,active=true,destroy_when_done=true})
    if s.failed {o.failed=true;return}
    check(o,"physics burst prefab",asset.scene_save(&s.scene,path(o,"assets/physics_gallery/physics_burst.prefab")))
}

@(private)
physics_gallery_item :: proc(s:^Scene_Out,label:base.Asset_Id,station:u32,title,detail:string,origin:mm.Vec3,target:base.Entity_Id=0,secondary:base.Entity_Id=0,field:base.Entity_Id=0) {
    holder:=entity(s,fmt.tprintf("Station %02d %s",station+1,title),origin)
    item:=game.Physics_Gallery{station=station,origin=origin,target=core.Entity(target),secondary=core.Entity(secondary),field=core.Entity(field)}
    if station==1 || station==9 {item.fade_seconds=2}
    base.text_set(item.title[:],title);base.text_set(item.detail[:],detail);put(s,holder,"Physics_Gallery",&item)
    sign:=entity(s,fmt.tprintf("Label %02d",station+1),origin+mm.Vec3{0,-.7,2.8})
    text:=game.Gallery_Label{};base.text_set(text.title[:],fmt.tprintf("%02d  %s",station+1,title));base.text_set(text.detail[:],detail)
    put(s,sign,"Gallery_Label",&text)
    widget:=gui.WORLD_WIDGET_DEFAULT;widget.asset=label;widget.size={380,88};widget.scale=.008;widget.passive=true
    put(s,sign,"World_Widget",&widget)
}

@(private)
physics_gallery_label :: proc(o:^Out) -> base.Asset_Id {
    texts:=make([dynamic]u8,context.temp_allocator)
    id:=id_of("ui","physics_gallery_label")
    data:=ui.Tree_Data{text=texts[:],
        styles={{},{fill={17,24,35,235},radius=6},{text={size=16,color={255,255,255,255},wrap=.Words}},{text={size=12,color={170,200,235,255},wrap=.Words}}},
        nodes={
            ui.tree_node_record(&texts,-1,{kind=.Box,name="panel",style=1,layout={width=ui.fixed(380),height=ui.fixed(88),direction=.Column,padding=ui.padding_all(7),gap=4}}),
            ui.tree_node_record(&texts,0,{kind=.Text,name="title",style=2,bind_text="Gallery_Label.title",layout={width=ui.fixed(366)}}),
            ui.tree_node_record(&texts,0,{kind=.Text,name="detail",style=3,bind_text="Gallery_Label.detail",layout={width=ui.fixed(366)}}),
        },
    }
    check(o,"physics gallery labels",host.ui_tree_save(path(o,"assets/physics_gallery/physics_gallery_label.ui"),&o.types,id,data))
    return id
}

@(private)
physics_gallery_breakable :: proc(s:^Scene_Out,name:string,position:mm.Vec3,source,mesh:base.Asset_Id,anchored:=false,parent:base.Entity_Id=0) -> base.Entity_Id {
    e:=entity(s,name,position,parent=parent)
    config:=destruct.destructible(16,anchored);config.fracture,config.strength=source,60;config.impact_damage=false;config.debris_volume=0
    config.interior=game.material_asset("Cobblestone")
    pieces:=destruct.collider_fracture();pieces.density=160
    put(s,e,"Destructible",&config)
    put(s,e,"Collider",&pieces)
    renderer:=render.Mesh_Renderer{mesh=mesh};renderer.materials[0],renderer.materials[1]=game.material_asset("Bricks"),game.material_asset("Cobblestone")
    put(s,e,"Mesh_Renderer",&renderer)
    return e
}

@(private)
physics_gallery_primitive :: proc(s:^Scene_Out,name:string,position,size:mm.Vec3,shape:render.Shape,collider:phys.Collider,color:mm.Vec4,mass:f32=2) -> base.Entity_Id {
    e:=entity(s,name,position,size)
    put(s,e,"Mesh_Renderer",&render.Mesh_Renderer{shape=shape});put(s,e,"Tint",&render.Tint{color=color})
    rigid:=phys.RIGID_BODY_DYNAMIC;rigid.mass=mass;rigid.bullet=true
    collider:=collider
    put(s,e,"Rigid_Body",&rigid);put(s,e,"Collider",&collider)
    return e
}

write_physics_gallery :: proc(o:^Out) {
    sources:=physics_sources(o);physics_burst(o)
    s:Scene_Out;asset.scene_init(&s.scene,&o.types,asset.KIND_SCENE,id_of("scene","physics"));defer asset.scene_destroy(&s.scene)
    // The sun alone lights the gallery: a sun of 3 is noon.
    u:=daylight(3)
    // Two stops over the meter: the gallery as bright as the demo has it.
    environment:=render.SKY_DEFAULT;environment.luminance,environment.background=nits(u,{.4,.52,.72}),nits(u,{.0019,.0026,.0045})
    exposure:=render.EXPOSURE_DEFAULT
    exposure.compensation=1
    sky_set(&s,&environment,0,exposure)
    sun:=entity(&s,"Sun")
    sun_placed:=sun_pose(render.SUN_DIRECTION)
    put(&s,sun,"Transform",&sun_placed)
    put(&s,sun,"Sun",&render.Sun{color={1,.94,.85},illuminance=lux(u,3)})
    gallery_cube(&s,"Gallery floor",{0,-.25,-20},{36,.5,51},{.1,.14,.2,1},true)
    label:=physics_gallery_label(o)
    titles:=[18]string{"Collision primitives","Size and debris","Convex generation","Convex hierarchy","Combined fractures","Mesh and point operations","Proximity graph","Interior materials","Collider friction and restitution","Removal","Fracture events and VFX","Internal / rest strain","Persistent fields","External strain","Field destruction","Moving parent and anchors","Destructible constraints","Baked cuts and destruction"}
    details:=[18]string{
        "Box, sphere and capsule. E: radial impulse with mass independent velocity change.",
        "Large leaves keep full collision; small leaves become cosmetic debris. E: release; small pieces fade after six seconds.",
        "Convex leaf hulls with explicit vertex budget. E: slice the closed mesh.",
        "Root -> two clusters -> eight leaves. Each E releases one level. Collision uses leaf hulls.",
        "Authored brick fracture plus runtime plane cuts. E alternates vertical and horizontal slicing.",
        "Odin authors piece transforms and adjacency. E: slice while preserving UVs and colors.",
        "Separated meshes joined by cooked triangle distance proximity. E: strain.",
        "Cut caps use a separate interior material slot. E: cut and expose the inside.",
        "Collider coefficients control sliding and bounce. E launches a sphere, box and capsule with different values.",
        "Detached fragments remain six seconds, fade for two, then expire. E: release; R: repeat.",
        "A fracture event starts a particle prefab. E: break the wall with cosmetic dust.",
        "Suspended collection. First E stores rest strain; second E releases pieces to gravity without an impulse.",
        "Persistent directional box force, constant falloff. E toggles the field; no strain.",
        "Break bond strength with strain independent of impulse. E: release without launching.",
        "Rotated box field uses common falloff. E toggles independent force and strain.",
        "Kinematic anchors follow a moving parent. E: detach pieces into dynamic bodies.",
        "Spherical constraint joins proxy and rigid body. E: break; joint follows the retained group.",
        "Recorded cuts create new meshes; fragments fall and retire. Visual playback only. E restarts forward / reverse.",
    }
    for station in 0..<18 {
        origin:=mm.Vec3{f32(station%4)*8-12,1,-f32(station/4)*8}
        gallery_cube(&s,fmt.tprintf("Station platform %02d",station+1),origin+mm.Vec3{0,-.9,0},{6,.15,6},{.18,.25,.35,1},true)
        target,secondary,field:base.Entity_Id
        switch station {
        case 0,8,12:
            sphere:=phys.collider_sphere(.5);capsule:=phys.collider_capsule(.3,.35);box:=phys.collider_box({.5,.5,.5})
            if station==8 {sphere.restitution=1;box.friction=0;capsule.friction=1}
            target=physics_gallery_primitive(&s,"Sphere",origin+mm.Vec3{-1,1,0},{.7,.7,.7},.Sphere,sphere,{.1,.6,1,1})
            physics_gallery_primitive(&s,"Box",origin+mm.Vec3{0,1,0},{.7,.7,.7},.Cube,box,{1,.45,.15,1})
            physics_gallery_primitive(&s,"Capsule",origin+mm.Vec3{1,1,0},{.7,.7,.7},.Capsule,capsule,{.25,1,.55,1})
            if station==12 {field=entity(&s,"Directional box field",origin);f:=fields.PHYSICS_FIELD_DEFAULT;f.shape=.Box;f.direction=.Directional;f.half_extents={2,3,2};f.force=50;f.falloff=.Constant;put(&s,field,"Physics_Field",&f);turn_off(&s,field,"Physics_Field")}
        case 17:
            target=entity(&s,"Baked geometry playback",origin-mm.Vec3{0,1,0})
            player:=cache.GEOMETRY_PLAYBACK_DEFAULT;player.source=sources.cache;player.playing=false;player.loop=false
            put(&s,target,"Geometry_Playback",&player)
        case 15:
            parent:=entity(&s,"Moving anchor parent",origin-mm.Vec3{0,.7,0})
            put(&s,parent,"Physics_Gallery_Motion",&game.Physics_Gallery_Motion{origin=origin-mm.Vec3{0,.7,0},axis={1,0,0},amplitude=.7,frequency=1})
            target=physics_gallery_breakable(&s,"Moving anchored wall",{},sources.wall,sources.wall_mesh,true,parent)
            config:=destruct.destructible();config.fracture=sources.wall;config.follow_parent=true;config.anchored=true;config.impact_damage=false;config.debris_volume=0;put(&s,target,"Destructible",&config)
        case 16:
            secondary=physics_gallery_primitive(&s,"Constraint cube",origin+mm.Vec3{0,2,0},{.4,.4,.4},.Cube,phys.collider_box({.5,.5,.5}),{.9,.9,.3,1},10)
            target=physics_gallery_breakable(&s,"Constrained collection",origin+mm.Vec3{0,0,0},sources.bricks,sources.bricks_mesh)
            joint:=phys.joint_spherical(core.Entity(secondary),{0,1.2,0},1)
            put(&s,target,"Joint",&joint)
        case:
            source,mesh:=sources.bricks,sources.bricks_mesh
            if station==3 {source,mesh=sources.hierarchy,sources.hierarchy_mesh}
            if station==1 {source,mesh=sources.mixed,sources.mixed_mesh}
            offset:=mm.Vec3{0,1,0} if station==11 else mm.Vec3{0,-.825,0} if station==1 else mm.Vec3{0,-.7,0}
            target=physics_gallery_breakable(&s,"Collection",origin+offset,source,mesh)
            config:=destruct.destructible();config.fracture,config.strength=source,60;config.impact_damage=false;config.debris_volume=0;config.interior=game.material_asset("Cobblestone")
            if station==1 {config.debris_volume=.1;config.debris_lifetime=8}
            if station==11 {config.kinematic=true}
            if station==2 {config.hull_vertices=8}
            if station==9 {
                config.removal_lifetime=8
                tint:=render.TINT_DEFAULT;put(&s,target,"Tint",&tint)
            }
            put(&s,target,"Destructible",&config)
            if station==14 {field=entity(&s,"Destructive box field",origin);f:=fields.PHYSICS_FIELD_DEFAULT;f.shape=.Box;f.half_extents={1,2,1};f.strain=400;f.force=30;put(&s,field,"Physics_Field",&f);turn_off(&s,field,"Physics_Field");put(&s,field,"Transform",&core.Transform{origin,mm.quat_axis_angle({0,1,0},.4),{1,1,1}})}
        }
        physics_gallery_item(&s,label,u32(station),titles[station],details[station],origin,target,secondary,field)
    }
    origin:=mm.Vec3{4,1,-32};rig:=physics_ragdoll_station(o,&s,origin)
    physics_gallery_item(&s,label,18,"Ragdoll: animation and physics","A right-arm wave drives seven skinned bodies. Animated follows the clip; Driven uses motors; Simulated releases them. E advances the mode.",origin,rig)
    physics_gallery_extra(&s,label)
    camera:=entity(&s,"Physics gallery camera",{0,29,28});pose:=core.Transform{{0,29,28},mm.quat_look(mm.Vec3{0,0,-18}-mm.Vec3{0,29,28},{0,1,0}),{1,1,1}}
    camera_config,view:=render.CAMERA_DEFAULT,game.PHYSICS_GALLERY_VIEW_DEFAULT
    put(&s,camera,"Transform",&pose);put(&s,camera,"Camera",&camera_config);put(&s,camera,"Physics_Gallery_View",&view)
    if s.failed {fmt.eprintln("demo_content: physics gallery could not be built");o.failed=true;return}
    check(o,game.PHYSICS_GALLERY_SCENE,asset.scene_save(&s.scene,path(o,"assets/"+game.PHYSICS_GALLERY_SCENE)))
}

@(private)
physics_gallery_extra :: proc(s:^Scene_Out,label:base.Asset_Id) {
    origin:=mm.Vec3{-12,1,-40}
    prior:base.Entity_Id
    for part in 0..<7 {
        e:=physics_gallery_primitive(s,fmt.tprintf("Chain link %d",part),origin+mm.Vec3{f32(part)*.42-1.26,1.5,0},{.4,.4,.4},.Cube,phys.collider_box({.5,.5,.5}),{.75,.8,.9,1})
        joint:=phys.joint_spherical(core.Entity(prior),{-.525,0,0})
        put(s,e,"Joint",&joint);prior=e
    }
    physics_gallery_item(s,label,19,"Constraint chain and CCD","Seven linked rigid bodies with bullet motion. E launches the chain; R restores it.",origin,prior)
    origin={-4,1,-40}
    body:=physics_gallery_primitive(s,"Six axis driven body",origin+mm.Vec3{0,1,0},{.7,.7,.7},.Cube,phys.collider_box({.5,.5,.5}),{.9,.3,.2,1},2)
    joint:=phys.joint_sixdof(core.NONE)
    phys.joint_drive_pose(&joint,{.5,.2,0},mm.quat_axis_angle({0,0,1},.4),4,1,500,500)
    put(s,body,"Joint",&joint)
    physics_gallery_item(s,label,20,"Six axis motor","Linear and angular D6 drives target a pose. E disturbs the body; the drives restore it.",origin,body)
    origin={4,1,-40}
    e:=entity(s,"Physical character",origin-mm.Vec3{0,.8,0})
    character,capsule,walk:=phys.character_default(),phys.collider_character(),phys.WALK_DEFAULT
    put(s,e,"Character",&character);put(s,e,"Walk",&walk);put(s,e,"Collider",&capsule)
    visual:=entity(s,"Character capsule",{0,.9,0},{.6,1.5,.6},e);put(s,visual,"Mesh_Renderer",&render.Mesh_Renderer{shape=.Capsule});put(s,visual,"Tint",&render.Tint{color={.2,.9,.7,1}})
    gallery_cube(s,"Character step",origin+mm.Vec3{1,-.6,0},{.6,.4,2},{.3,.5,.6,1},true)
    physics_gallery_item(s,label,21,"Physical character","Physical capsule shares solver contacts. E launches it with the public radial impulse API.",origin,e)
    origin={12,1,-40}
    pool:=entity(s,"Water pool",{12,0.6,-40})
    water:=phys.fluid_volume_box({2.5,0.6,2.5},1000)
    put(s,pool,"Fluid_Volume",&water)
    bell:=entity(s,"Dry bell",{13.4,0.6,-41.4})
    air:=phys.fluid_volume_dry({0.8,0.8,0.8})
    put(s,bell,"Fluid_Volume",&air)
    floater:=physics_gallery_floating(s,"Half the density of water",origin+mm.Vec3{-1.2,0.5,1},{.7,.7,.7},.Cube,phys.collider_box({.5,.5,.5}),500,{.9,.75,.35,1})
    physics_gallery_floating(s,"Light cylinder",origin+mm.Vec3{0,0.6,1.2},{.5,.9,.5},.Cylinder,phys.collider_cylinder(.5,.5),300,{.5,.8,1,1})
    physics_gallery_floating(s,"Capsule",origin+mm.Vec3{-1,0.6,-1},{.5,.5,.5},.Capsule,phys.collider_capsule(.5,.5),700,{.3,1,.6,1})
    physics_gallery_floating(s,"Stone",origin+mm.Vec3{0,0.8,0},{.45,.45,.45},.Sphere,phys.collider_sphere(.5),2500,{.6,.6,.65,1})
    physics_gallery_floating(s,"Box in the dry bell",origin+mm.Vec3{1.4,1.2,-1.4},{.5,.5,.5},.Cube,phys.collider_box({.5,.5,.5}),500,{1,.5,.3,1})
    physics_gallery_item(s,label,22,"Fluid volumes and buoyancy","A pool of water: bodies float by their density, the stone sinks, and the air of a dry bell keeps the water out. E throws them up.",origin,floater)
}

@(private)
physics_gallery_floating :: proc(s:^Scene_Out,name:string,position,size:mm.Vec3,shape:render.Shape,collider:phys.Collider,density:f32,color:mm.Vec4) -> base.Entity_Id {
    collider:=collider
    collider.density=density
    return physics_gallery_primitive(s,name,position,size,shape,collider,color,0)
}
