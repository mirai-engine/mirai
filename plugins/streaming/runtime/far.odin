package streaming

import "mirai:asset"
import "mirai:core"
import render "mirai:engine/render"
import scene "mirai:engine/scene"
import "mirai:host"
import "mirai:std/base"

// The far form of a section (its HLOD): while a section is not loaded and
// on, a proxy beside its reference shows the far mesh of its scene, which
// the render draws by the cut of its DAG and rays trace by its coarse cuts:
// what is not loaded is seen from afar and keeps shading what is below it.
// The far mesh is a derived asset of the scene (cook/far), an asset as any:
// a shipped game finds the one its cook wrote beside the scene, and a project
// that is not cooked, in the editor or a game, the one of the far cache of the
// project (project.FAR_CACHE) made of what the scene is now (asset.far_key),
// which the editor part of this plugin makes once. A game makes none.

// The far meshes of the scenes the references of the worlds of the
// application name, found again when the registry changes. A far mesh is read
// in jobs, those of loaded sections first, and shows once it is read: a
// loaded section stays as it is until its far mesh is there to take its
// place (scene.section_stay), and no frame reads it.
@(storage,host,free="streaming_far_free")
Streaming_Far :: struct {
    scenes:[dynamic]Far_Mesh,
    revision:u64, // of the registry when they were found
    shown:map[core.Entity]core.Entity, // the proxy of each reference, while a frame looks at them
}

FAR_WARMS :: 2 // far meshes read in jobs at once, by application

Far_Mesh :: struct {
    warm:^scene.Load_Job,     // reading the mesh in jobs
    scene,mesh:base.Asset_Id, // mesh: none until there is one; the last one found while the cache has none of what the scene is now
    key:u64,                  // of the cache (asset.far_key) of what the scene is now; 0: cooked
    missing:bool,             // a read of it ended without it: it shows nothing and keeps no section as it is until the registry changes
}

streaming_far_free :: proc(far:^Streaming_Far) {
    for s in far.scenes {scene.load_free(s.warm)}
    delete(far.scenes)
    delete(far.shown)
    far^={}
}

// The far mesh of a scene once it is read; none for one without static
// meshes, one whose far mesh was not made, or one still being read.
far_mesh :: proc(far:^Streaming_Far,a:^host.Assets,id:base.Asset_Id) -> base.Asset_Id {
    for s in far.scenes {if s.scene==id && s.warm==nil && s.mesh!={} && host.assets_loaded(a,s.mesh) {return s.mesh}}
    return {}
}

// Finds the far mesh of each scene again when the registry changed or a scene was added.
@(private)
far_find :: proc(far:^Streaming_Far,a:^host.Assets,added:bool) {
    if !added && a.registry.revision==far.revision {return}
    far.revision=a.registry.revision
    for &s in far.scenes {
        id:=asset.far_mesh_id(s.scene)
        if !a.indexed {
            s.key=asset.far_key(&a.registry,s.scene)
            id=asset.far_cache_id(s.key)
        }
        if _,found:=asset.registry_find(&a.registry,id);found {s.mesh,s.missing=id,false}
    }
}

// Reads in jobs the far meshes of the references that are not read, those of
// loaded sections first, and keeps each loaded section as it is until its far
// mesh is read.
@(private)
far_warm :: proc(far:^Streaming_Far,app:^host.App,references:^core.Table(scene.Scene_Reference,.Read),stays:^scene.Section_Stays) {
    a:=app.assets
    warming:=0
    for &s in far.scenes {
        if s.warm==nil {continue}
        if !scene.load_step(s.warm) {
            warming+=1
            continue
        }
        scene.load_free(s.warm)
        s.warm=nil
        s.missing=!host.assets_loaded(a,s.mesh)
    }
    for pass in 0..<2 {
        for row in 0..<core.count(references) {
            reference:=core.at(references,row)
            if (reference.loaded!={})!=(pass==0) {continue}
            for &s in far.scenes {
                if s.scene!=reference.scene || s.mesh=={} || s.missing || s.warm==nil && host.assets_loaded(a,s.mesh) {continue}
                if pass==0 {scene.section_stay(stays,core.entity_at(references,row))}
                if s.warm!=nil || warming>=FAR_WARMS {break}
                job,error:=scene.assets_warm_begin(app,{s.mesh})
                s.warm,s.missing=job,error!=.None
                if job!=nil {warming+=1}
                break
            }
        }
    }
}

// Each section that is not loaded and on shows the far mesh of its scene,
// beside its reference: under its parent, where it is. A proxy goes with its
// reference, when the section is on, and when its scene has no far mesh; one
// whose scene has another far mesh still being read keeps showing the one it
// has.
@(step="frame",loops="game editor",after="scene_sections")
streaming_far :: proc(
    world:core.World_Ref,app:^host.App,references:^core.Table(scene.Scene_Reference,.Read),views:core.Ref(scene.Section_Views),
    transforms:^core.Table(core.Transform),parents:^core.Table(core.Parent,.Read),proxies:^core.Table(scene.Section_Proxy,.Read),renderers:^core.Table(render.Mesh_Renderer,.Read),
    far:^Streaming_Far,stays:^scene.Section_Stays,
) {
    if far==nil || app==nil || app.assets==nil {return}
    a:=app.assets
    added:=false
    for row in 0..<core.count(references) {
        id:=core.at(references,row).scene
        known:=id=={}
        for s in far.scenes {known||=s.scene==id}
        if !known {
            append(&far.scenes,Far_Mesh{scene=id})
            added=true
        }
    }
    far_find(far,a,added)
    far_warm(far,app,references,stays)
    // The proxies there are, by reference; one that no longer shows what it should goes.
    clear(&far.shown)
    for row in 0..<core.count(proxies) {
        e:=core.entity_at(proxies,row)
        r:=core.at(proxies,row).reference
        reference,found:=core.get(references,r)
        mesh:=far_mesh(far,a,reference.scene) if found else {}
        renderer,_:=core.get(renderers,e)
        above,_:=core.get(parents,r)
        below,_:=core.get(parents,e)
        if !found || renderer.mesh!=mesh && (mesh!={} || !host.assets_loaded(a,renderer.mesh)) || above.entity!=below.entity || r in far.shown || !far_shows(views.ptr,r,reference) {
            core.world_destroy_tree(world,e)
            continue
        }
        far.shown[r]=e
    }
    c:=core.commands_of(world)
    for row in 0..<core.count(references) {
        e:=core.entity_at(references,row)
        reference:=core.at(references,row)
        mesh:=far_mesh(far,a,reference.scene)
        pose,posed:=core.get(transforms,e)
        if !posed {pose=core.TRANSFORM_IDENTITY}
        if proxy,has:=far.shown[e];has {
            // It follows its reference.
            if now:=core.edit(transforms,proxy);now!=nil {now^=pose}
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
