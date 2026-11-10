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
// application name, found again when the registry changes.
@(storage,host)
Streaming_Far :: struct {
    scenes:[dynamic]Far_Mesh,
    revision:u64, // of the registry when they were found
}

Far_Mesh :: struct {
    scene,mesh:base.Asset_Id, // mesh: none until there is one; the last one found while the cache has none of what the scene is now
    key:u64,                  // of the cache (asset.far_key) of what the scene is now; 0: cooked
}

// The far mesh of a scene; none for one without static meshes, or one whose
// far mesh was not made.
far_mesh :: proc(far:^Streaming_Far,id:base.Asset_Id) -> base.Asset_Id {
    for s in far.scenes {if s.scene==id {return s.mesh}}
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
        if _,found:=asset.registry_find(&a.registry,id);found {s.mesh=id}
    }
}

// Each section that is not loaded and on shows the far mesh of its scene,
// beside its reference: under its parent, where it is. A proxy goes with its
// reference, when the section is on, and when its scene has no far mesh.
@(step="frame",loops="game editor")
streaming_far :: proc(
    world:core.World_Ref,app:^host.App,references:core.Read(scene.Scene_Reference),views:core.Ref(scene.Section_Views),
    transforms:^core.Table(core.Transform),parents:core.Read(core.Parent),proxies:core.Read(scene.Section_Proxy),renderers:core.Read(render.Mesh_Renderer),
    far:^Streaming_Far,
) {
    if far==nil || app==nil || app.assets==nil {return}
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
    far_find(far,app.assets,added)
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
        pose,posed:=core.get(transforms,e)
        if !posed {pose=core.TRANSFORM_IDENTITY}
        if proxy,has:=shown[e];has {
            // It follows its reference.
            if now,has:=core.get(transforms,proxy);has && now!=pose {core.edit(transforms,proxy)^=pose}
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
