package streaming

import "base:runtime"
import "core:math/linalg"
import "core:mem"
import "mirai:asset"
import "mirai:core"
import render "mirai:engine/render"
import scene "mirai:engine/scene"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/jobs"
import mm "mirai:std/math"

// The far form of a section (its HLOD): while a section is not loaded and
// on, a proxy beside its reference shows the far mesh of its scene, which
// the render draws by the cut of its DAG and rays trace by its coarse cuts:
// what is not loaded is seen from afar and keeps shading what is below it.
//
// The far mesh of a scene is made once per application, in jobs, the first
// time a reference shows it, of the meshes of the scene and of the scenes it
// references (asset.mesh_build_far), and made again when what it was made
// of changes, as any cooking: each asset it read is kept with its content
// hash, and a registry whose hash of one of them changed (or that now has
// one it lacked) makes it again, the proxies showing the one before until
// the new one is ready. What moves (a body or a character) and skinned
// meshes are left out.

// The angle a pixel spans, about: the parts of a far mesh are cut at what it
// spans at the active distance, where the proxy starts to show.
FAR_ANGLE :: f32(1.0/1024)
FAR_BUILDS :: 2 // far meshes made at once
FAR_RETIRE :: 4 // frames a far mesh made again stays for the proxies of every world to take the new one
// The components whose entities a far mesh leaves out, with what hangs from
// them: what is not drawn, and what moves (a body, a character).
FAR_LEFT_OUT :: [?]string{"Hidden","Drawn_Elsewhere","Disabled","Rigid_Body","Character"}

// What a far mesh was made of: an asset and its content hash, 0 when the
// registry had none.
Far_Read :: struct {id:base.Asset_Id,hash:u64}

// The far mesh of a scene.
Far_Scene :: struct {
    scene:base.Asset_Id,
    mesh:base.Asset_Id, // generated; none until made, or for a scene without static meshes
    made:bool,          // tried at least once
    error:f32,          // the error its parts were cut at
    read:[dynamic]Far_Read,
    build:^Far_Build,   // making it again
}

// A far mesh made again, released once the proxies took the new one.
Far_Retired :: struct {mesh:base.Asset_Id,frame:u64}

// The far meshes of the application, by scene.
@(storage,host,free="streaming_far_free")
Streaming_Far :: struct {
    app:^host.App,
    scenes:[dynamic]Far_Scene,
    retired:[dynamic]Far_Retired,
    revision:u64, // of the registry when the reads were last compared
}

streaming_far_free :: proc(far:^Streaming_Far) {
    assets:=far.app.assets if far.app!=nil else nil
    for &s in far.scenes {
        if s.build!=nil {far_build_free(far.app,s.build)}
        if s.mesh!={} && assets!=nil {host.assets_mesh_release(assets,s.mesh)}
        delete(s.read)
    }
    for r in far.retired {if assets!=nil {host.assets_mesh_release(assets,r.mesh)}}
    delete(far.scenes);delete(far.retired)
    far^={}
}

// A mesh of a scene placed in it, and the materials its renderer gives its slots.
Far_Gathered :: struct {
    mesh:base.Asset_Id,
    materials:[render.MATERIAL_SLOTS]base.Asset_Id,
    placement:matrix[4,4]f32,
}

// A scene a scene references, placed in it.
Far_Inner :: struct {
    scene:base.Asset_Id,
    placement:matrix[4,4]f32,
}

// What a scene gives its far mesh.
Far_Of_Scene :: struct {
    parts:[dynamic]Far_Gathered,
    inner:[dynamic]Far_Inner,
}

@(private)
Far_Mesh_Read :: struct {
    file:asset.Asset,
    view:asset.Mesh_View,
}

// Making a far mesh: the jobs read in rounds what the main thread finds for
// them (the scene, then its meshes and materials, then their textures) and
// build it once nothing is missing.
Far_Build :: struct {
    scene:base.Asset_Id,
    error:f32,
    limits:host.Assets_Limits,
    // Between rounds: what the main thread found, and what the round asks for.
    sources:[dynamic]host.Assets_Source,
    wanted:[dynamic]base.Asset_Id,
    asked:map[base.Asset_Id]bool,
    read:[dynamic]Far_Read,
    // Of the jobs, in arena.
    types:asset.Types,
    scenes:map[base.Asset_Id]Far_Of_Scene,
    meshes:map[base.Asset_Id]^Far_Mesh_Read,
    materials:map[base.Asset_Id]asset.Material_Info,
    textures:map[base.Asset_Id]^asset.Far_Texture,
    arena:mem.Dynamic_Arena,
    made:host.Mesh_Render_Geometry,
    done:bool,
    built:bool, // done with a mesh
    starved:bool, // a round had no memory for what it read: no mesh is made of it
    counter:jobs.Counter,
}

@(private)
far_build_new :: proc(scene_id:base.Asset_Id,error:f32,limits:host.Assets_Limits) -> ^Far_Build {
    heap:=runtime.heap_allocator()
    b,allocation_error:=new(Far_Build,heap)
    if allocation_error!=nil {return nil}
    b.scene,b.error,b.limits=scene_id,error,limits
    b.sources=make([dynamic]host.Assets_Source,heap)
    b.wanted=make([dynamic]base.Asset_Id,heap)
    b.asked=make(map[base.Asset_Id]bool,heap)
    b.read=make([dynamic]Far_Read,heap)
    mem.dynamic_arena_init(&b.arena,heap,heap)
    arena:=base.dynamic_arena_allocator(&b.arena)
    asset.types_init(&b.types,arena)
    b.scenes=make(map[base.Asset_Id]Far_Of_Scene,arena)
    b.meshes=make(map[base.Asset_Id]^Far_Mesh_Read,arena)
    b.materials=make(map[base.Asset_Id]asset.Material_Info,arena)
    b.textures=make(map[base.Asset_Id]^asset.Far_Texture,arena)
    host.assets_render_geometry_init(&b.made,heap)
    append(&b.wanted,scene_id)
    b.asked[scene_id]=true
    return b
}

@(private)
far_build_free :: proc(app:^host.App,b:^Far_Build) {
    if jobs.pending(&b.counter) && app!=nil {jobs.wait(&app.jobs,jobs.OWNER,&b.counter)}
    for &source in b.sources {host.assets_source_free(&source)}
    for _,m in b.meshes {asset.asset_close(&m.file)}
    delete(b.sources);delete(b.wanted);delete(b.asked);delete(b.read)
    host.assets_render_geometry_destroy(&b.made)
    mem.dynamic_arena_destroy(&b.arena)
    free(b,runtime.heap_allocator())
}

@(private)
far_build_release :: proc(data:rawptr) {far_build_free(nil,(^Far_Build)(data))}

@(private)
far_starved :: proc(problems:^core.Problems,a:^host.Assets,scene_id:base.Asset_Id) {
    name:[base.ASSET_ID_TEXT]u8
    core.report(problems,core.NONE,"streaming.memory","out of memory to make the far mesh of scene %s; it is made again: free memory",host.assets_name(a,scene_id,&name))
}

// A round of a build, on a job: opens what was found, asks for what is
// still missing and, with nothing missing, makes the far mesh.
@(private)
far_round :: proc(b:^Far_Build,worker:int) {
    context.allocator=base.dynamic_arena_allocator(&b.arena)
    for &source in b.sources {
        append(&b.read,Far_Read{source.id,source.hash})
        file:asset.Asset
        if host.assets_source_open(&source,&file)!=.None {continue}
        switch source.kind {
        case asset.KIND_SCENE:
            far_scene_read(b,source.id,&file)
            asset.asset_close(&file)
        case asset.KIND_MESH:
            m,allocation_error:=new(Far_Mesh_Read)
            if allocation_error!=nil {b.starved=true;asset.asset_close(&file);continue}
            m.file=file
            view,error:=asset.mesh_view(&m.file,&b.types)
            if error!=.None {asset.asset_close(&m.file);continue}
            m.view=view
            b.meshes[source.id]=m
        case asset.KIND_MATERIAL:
            if view,error:=asset.material_view(&file,&b.types);error==.None {
                info:=view.info^
                // A program reads its textures from its parameters: the one that names a base color is it.
                if base.text_get(info.program[:])!="" && info.maps.base_color.texture=={} {
                    if texture:=asset.far_base_parameter(view.parameters);texture!={} {info.maps.base_color={texture=texture,scale={1,1}}}
                }
                b.materials[source.id]=info
            }
            asset.asset_close(&file)
        case asset.KIND_TEXTURE:
            if view,error:=asset.texture_view(&file,&b.types);error==.None {
                if texture,ok:=asset.far_texture(view);ok {
                    if t,allocation_error:=new(asset.Far_Texture);allocation_error==nil {
                        t^=texture
                        b.textures[source.id]=t
                    } else {b.starved=true}
                }
            }
            asset.asset_close(&file)
        case:
            asset.asset_close(&file)
        }
    }
    for &source in b.sources {host.assets_source_free(&source)}
    clear(&b.sources)
    parts:=make([dynamic]Far_Gathered,context.temp_allocator)
    far_expand(b,b.scene,linalg.MATRIX4F32_IDENTITY,0,&parts)
    far_want_parts(b,parts[:])
    if len(b.wanted)>0 {return}
    b.built=!b.starved && far_make(b,parts[:])
    b.done=true
}

// Asks for an asset the build has not asked for.
@(private)
far_ask :: proc(b:^Far_Build,id:base.Asset_Id) {
    if id=={} || id in b.asked {return}
    b.asked[id]=true
    append(&b.wanted,id)
}

// The parts of a scene placed by placement, and those of the scenes it
// references, as far as they were read; asks for the scenes not yet read.
@(private)
far_expand :: proc(b:^Far_Build,id:base.Asset_Id,placement:matrix[4,4]f32,depth:int,out:^[dynamic]Far_Gathered) {
    of,read:=b.scenes[id]
    if !read {
        far_ask(b,id)
        return
    }
    for part in of.parts {
        placed:=part
        placed.placement=placement*part.placement
        append(out,placed)
    }
    if depth+1>=scene.REFERENCE_DEPTH {return}
    for inner in of.inner {far_expand(b,inner.scene,placement*inner.placement,depth+1,out)}
}

// Asks for the meshes of parts, the materials of their slots and the
// textures of those materials that the build has not asked for.
@(private)
far_want_parts :: proc(b:^Far_Build,parts:[]Far_Gathered) {
    for part in parts {
        m,read:=b.meshes[part.mesh]
        if !read {
            far_ask(b,part.mesh)
            continue
        }
        for slot,s in m.view.slots {
            material:=part.materials[s] if s<render.MATERIAL_SLOTS else {}
            if material=={} {material=slot.material}
            far_ask(b,material)
            if info,known:=b.materials[material];known {
                far_ask(b,info.maps.base_color.texture)
                far_ask(b,info.maps.metallic_roughness.texture)
                far_ask(b,info.maps.emission.texture)
            }
        }
    }
}

// What a scene gives its far mesh: each entity with a Mesh_Renderer that is
// on and drawn, placed in the scene, and each Scene_Reference; not what
// moves, nor what hangs from it.
@(private)
far_scene_read :: proc(b:^Far_Build,id:base.Asset_Id,file:^asset.Asset) {
    s:asset.Scene
    if asset.scene_from_asset(&s,&b.types,file)!=.None {return}
    defer asset.scene_destroy(&s)
    of:Far_Of_Scene
    of.parts=make([dynamic]Far_Gathered)
    of.inner=make([dynamic]Far_Inner)
    defer b.scenes[id]=of
    count:=asset.scene_entity_count(&s)
    ids,parents:=asset.scene_ids(&s),asset.scene_parents(&s)
    // Where each entity is in the scene, its parents before it whatever their rows.
    placements:=make([]matrix[4,4]f32,count,context.temp_allocator)
    placed:=make([]bool,count,context.temp_allocator)
    left:=make([]bool,count,context.temp_allocator) // left out with what hangs from it
    for name in FAR_LEFT_OUT {
        table,found:=asset.scene_component(&s,name)
        if !found {continue}
        for row in 0..<count {
            if _,has:=asset.scene_component_get(&s,table,ids[row]);has {left[row]=true}
        }
    }
    place :: proc(s:^asset.Scene,row:int,ids,parents:[]base.Entity_Id,placements:[]matrix[4,4]f32,placed,left:[]bool,depth:int) {
        if placed[row] || depth>1024 {return}
        identity:=core.TRANSFORM_IDENTITY
        local,found:=asset.scene_get(s,ids[row],"Transform",core.Transform,&identity)
        if !found {local=identity}
        m:=mm.transform_matrix(transmute(mm.Transform)local)
        if parent,has:=asset.scene_entity_find(s,parents[row]);has && parents[row]!=0 {
            place(s,parent,ids,parents,placements,placed,left,depth+1)
            m=placements[parent]*m
            left[row]||=left[parent]
        }
        placements[row]=m
        placed[row]=true
    }
    renderer_hash:=base.name_hash("Mesh_Renderer")
    for row in 0..<count {
        place(&s,row,ids,parents,placements,placed,left,0)
        if left[row] {continue}
        if renderer,has:=asset.scene_get(&s,ids[row],"Mesh_Renderer",render.Mesh_Renderer);has && renderer.mesh!={} && !asset.scene_component_off(&s,ids[row],renderer_hash) {
            append(&of.parts,Far_Gathered{mesh=renderer.mesh,materials=renderer.materials,placement=placements[row]})
        }
        if reference,has:=asset.scene_get(&s,ids[row],"Scene_Reference",scene.Scene_Reference);has && reference.scene!={} {
            append(&of.inner,Far_Inner{reference.scene,placements[row]})
        }
    }
}

// Makes the far mesh of parts into b.made, with its rays; false without
// static meshes or when it does not build.
@(private)
far_make :: proc(b:^Far_Build,parts:[]Far_Gathered) -> bool {
    far_parts:=make([dynamic]asset.Far_Part,context.temp_allocator)
    texture :: proc(b:^Far_Build,id:base.Asset_Id) -> ^asset.Far_Texture {
        if t,known:=b.textures[id];known {return t}
        return nil
    }
    for part in parts {
        m,read:=b.meshes[part.mesh]
        if !read || .Skinned in m.view.info.flags {continue}
        p:=asset.Far_Part{geometry=m.view.geometry,placement=part.placement}
        for slot,s in m.view.slots {
            if s>=asset.MESH_MAX_SLOTS {break}
            material:=part.materials[s] if s<render.MATERIAL_SLOTS else {}
            if material=={} {material=slot.material}
            info,known:=b.materials[material]
            if !known {info=asset.MATERIAL_DEFAULTS}
            p.materials[s]=asset.far_material(info,texture(b,info.maps.base_color.texture),texture(b,info.maps.metallic_roughness.texture),texture(b,info.maps.emission.texture))
        }
        if len(m.view.slots)==0 {p.materials[0]=asset.far_material(asset.MATERIAL_DEFAULTS,nil,nil,nil)}
        append(&far_parts,p)
    }
    if len(far_parts)==0 {return false}
    arena:=base.dynamic_arena_allocator(&b.made.arena)
    if !asset.mesh_build_far(far_parts[:],b.error,&b.made.geometry,arena) {return false}
    return host.assets_render_geometry_rays(&b.made,b.limits)
}

// The error the parts of a far mesh are cut at, by the active distance.
far_error :: proc "contextless" (s:Streaming_Settings) -> f32 {return max(s.active,1)*FAR_ANGLE}

// The far mesh of a scene: none until it is made.
far_mesh :: proc "contextless" (far:^Streaming_Far,id:base.Asset_Id) -> base.Asset_Id {
    for s in far.scenes {if s.scene==id {return s.mesh}}
    return {}
}

// Asks for the far mesh of a scene: made in jobs from here on.
far_want :: proc(far:^Streaming_Far,id:base.Asset_Id) {
    for s in far.scenes {if s.scene==id {return}}
    append(&far.scenes,Far_Scene{scene=id})
}

// Moves the builds on: gives each round what it asked for, publishes what
// is made, and makes again the far meshes whose reads changed.
far_update :: proc(far:^Streaming_Far,app:^host.App,error:f32,problems:^core.Problems) {
    a:=app.assets
    if a==nil || a.renderer==nil {return}
    far.app=app
    context.allocator=app.allocator
    for i:=len(far.retired)-1;i>=0;i-=1 {
        if app.stats.frames<far.retired[i].frame+FAR_RETIRE {continue}
        host.assets_mesh_release(a,far.retired[i].mesh)
        unordered_remove(&far.retired,i)
    }
    // What a far mesh was made of changed: it is made again.
    if revision:=a.registry.revision;revision!=far.revision {
        far.revision=revision
        for &s in far.scenes {
            if !s.made || s.build!=nil {continue}
            for r in s.read {
                hash:u64
                if file,found:=asset.registry_find(&a.registry,r.id);found {hash=file.content_hash}
                if hash!=r.hash {s.made=false;break}
            }
        }
    }
    building:=0
    for s in far.scenes {if s.build!=nil {building+=1}}
    for &s in far.scenes {
        if s.made && s.error!=error && s.build==nil {s.made=false}
        if s.made || s.build!=nil || building>=FAR_BUILDS {continue}
        s.build=far_build_new(s.scene,error,host.assets_limits(a))
        if s.build==nil {far_starved(problems,a,s.scene);continue}
        building+=1
    }
    for &s in far.scenes {
        b:=s.build
        if b==nil || jobs.pending(&b.counter) {continue}
        if b.done && b.starved {
            // The section keeps the far mesh it had, and a new build starts.
            far_starved(problems,a,s.scene)
            host.app_release(app,{far_build_release,b})
            s.build=nil
            continue
        }
        if b.done {
            mesh:base.Asset_Id
            if b.built {mesh,_=host.assets_mesh_publish(a,&b.made)}
            if s.mesh!={} {append(&far.retired,Far_Retired{s.mesh,app.stats.frames})}
            s.mesh,s.made,s.error=mesh,true,b.error
            clear(&s.read)
            // Asked and not found counts too: its arrival makes it again.
            for id in b.asked {
                hash:u64
                for r in b.read {if r.id==id {hash=r.hash;break}}
                append(&s.read,Far_Read{id,hash})
            }
            // Its jobs are done: what they read goes in a job too.
            host.app_release(app,{far_build_release,b})
            s.build=nil
            continue
        }
        for id in b.wanted {
            if source,found:=host.assets_source(a,id,runtime.heap_allocator());found {append(&b.sources,source)}
        }
        clear(&b.wanted)
        if jobs.worker_count(&app.jobs)>1 {jobs.run(&app.jobs,jobs.OWNER,far_round,b,&b.counter)} else {far_round(b,jobs.OWNER)}
    }
}

// Each section that is not loaded and on shows the far mesh of its scene,
// beside its reference: under its parent, where it is. A proxy goes with its
// reference, when the section is on, and when its scene has no far mesh.
@(step="frame",loops="game editor")
streaming_far :: proc(
    world:core.World_Ref,app:^host.App,references:core.Read(scene.Scene_Reference),views:core.Ref(scene.Section_Views),settings:core.Ref(Streaming_Settings),
    transforms:^core.Table(core.Transform),parents:core.Read(core.Parent),proxies:core.Read(scene.Section_Proxy),renderers:core.Read(render.Mesh_Renderer),far:^Streaming_Far,problems:^core.Problems,
) {
    if far==nil || app==nil {return}
    s:=settings.ptr!=nil?settings.ptr^:STREAMING_SETTINGS_DEFAULT
    for row in 0..<core.count(references) {
        reference:=core.at(references,row)
        if reference.scene!={} {far_want(far,reference.scene)}
    }
    far_update(far,app,far_error(s),problems)
    // The proxies there are, by reference; one that no longer shows what it should goes.
    shown:=make(map[core.Entity]core.Entity,context.temp_allocator)
    for row in 0..<core.count(proxies) {
        e:=core.entity_at(proxies,row)
        r:=core.at(proxies,row).reference
        reference,found:=core.get(references,r)
        mesh:=far_mesh(far,reference.scene) if found else {}
        renderer,_:=core.get(renderers,e)
        above,_:=core.get(parents,r)
        below,_:=core.get(parents,e)
        if !found || mesh=={} || renderer.mesh!=mesh || above.entity!=below.entity || r in shown || !far_shows(views.ptr,r,reference) {
            core.world_destroy_tree(world,e)
            continue
        }
        shown[r]=e
    }
    c:=core.commands_of(world)
    for row in 0..<core.count(references) {
        e:=core.entity_at(references,row)
        reference:=core.at(references,row)
        mesh:=far_mesh(far,reference.scene)
        pose,posed:=core.get(core.read(transforms),e)
        if !posed {pose=core.TRANSFORM_IDENTITY}
        if proxy,has:=shown[e];has {
            // It follows its reference.
            if now,has:=core.get(core.read(transforms),proxy);has && now!=pose {core.get(transforms,proxy)^=pose}
            continue
        }
        if mesh=={} || !far_shows(views.ptr,e,reference) {continue}
        proxy:=core.commands_create(c)
        above,_:=core.get(parents,e)
        if above.entity!=core.NONE {core.commands_add(c,proxy,core.Parent{above.entity,above.order})}
        core.commands_add(c,proxy,pose)
        core.commands_add(c,proxy,render.Mesh_Renderer{mesh=mesh})
        core.commands_add(c,proxy,scene.Section_Proxy{e})
    }
}

// Whether the section of reference e shows its far form: it is not loaded
// and on.
far_shows :: proc "contextless" (views:^scene.Section_Views,e:core.Entity,reference:scene.Scene_Reference) -> bool {
    return reference.scene!={} && (reference.loaded=={} || scene.section_wanted(views,e,reference)!=.Active)
}
