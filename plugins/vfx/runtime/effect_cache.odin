package vfx

import "mirai:host"
import "mirai:std/base"
import "plugins:vfx/runtime/effect"

Effect_Stamp :: struct {inputs:u64,users:int}

@(private)
effects_read :: proc(sync:^Particle_Sync,assets:^host.Assets) {
    if assets==nil || sync.effects_revision==assets.revision {return}
    sync.effects_revision=assets.revision
    for id,&stamp in sync.effects {stamp.inputs=effect_inputs(assets,id)}
}

@(private)
effect_stamp :: proc(sync:^Particle_Sync,assets:^host.Assets,id:base.Asset_Id) -> u64 {
    if assets==nil || id=={} {return 0}
    if stamp,kept:=sync.effects[id];kept {return stamp.inputs}
    inputs:=effect_inputs(assets,id)
    if _,err:=map_insert(&sync.effects,id,Effect_Stamp{inputs=inputs});err!=nil {return inputs}
    return inputs
}

@(private)
effect_drop :: proc(sync:^Particle_Sync,id:base.Asset_Id) {
    if stamp:=&sync.effects[id];stamp!=nil {stamp.users-=1}
}

@(private)
effects_prune :: proc(sync:^Particle_Sync) {
    stale:[dynamic]base.Asset_Id
    stale.allocator=context.temp_allocator
    for id,stamp in sync.effects {
        if stamp.users<=0 {append(&stale,id)}
    }
    for id in stale {delete_key(&sync.effects,id)}
}

@(private)
effect_inputs :: proc(assets:^host.Assets,id:base.Asset_Id) -> u64 {
    hash:=u64(1)
    if file:=host.assets_document(assets,id,effect.PARTICLE_KIND);file!=nil {
        hash=base.hash_combine(hash,file.blob.header.content_hash)
    }
    if view,ok:=effect_view(assets,id);ok {
        hash=effect_layer_inputs(assets,&view.info,hash)
        for &layer in view.layers {hash=effect_layer_inputs(assets,&layer,hash)}
    }
    return hash
}

@(private)
effect_layer_inputs :: proc(assets:^host.Assets,layer:^effect.Particle_Info,hash:u64) -> u64 {
    key:=effect_mesh_inputs(assets,layer,hash)
    if layer.sub_particle!={} {
        if sub:=host.assets_document(assets,layer.sub_particle,effect.PARTICLE_KIND);sub!=nil {
            key=base.hash_combine(key,sub.blob.header.content_hash)
        }
        if view,ok:=effect_view(assets,layer.sub_particle);ok {
            key=effect_mesh_inputs(assets,&view.info,key)
        }
    }
    return key
}

@(private)
effect_mesh_inputs :: proc(assets:^host.Assets,info:^effect.Particle_Info,hash:u64) -> u64 {
    key:=hash
    if info.material!={} {
        key=base.hash_combine(key,u64(host.assets_material_row(assets,info.material)))
        if found:=host.assets_material(assets,info.material);found!=nil {
            key=base.hash_combine(key,u64(found.info.alpha_mode))
        }
    }
    for id in info.meshes {
        if id=={} {continue}
        mesh:=host.assets_mesh(assets,id)
        key=base.hash_combine(key,u64(mesh.handle) if mesh!=nil else 0)
        if mesh!=nil && info.material=={} {
            for material in mesh.slot_materials[:mesh.slot_count] {
                if row:=host.assets_material(assets,material);row!=nil {
                    key=base.hash_combine(key,u64(row.info.alpha_mode))
                }
            }
        }
    }
    return key
}
