package terrain_editor

import "core:fmt"
import "mirai:core"
import "mirai:editor"
import terrain "plugins:terrain/runtime"
import "mirai:std/base"

@(private)
terrain_limits :: proc(world:core.World_Ref) -> terrain.Terrain_Settings {
    settings:=terrain.TERRAIN_SETTINGS_DEFAULT
    configured:=core.world_storage_of(world,terrain.Terrain_Settings)
    // The capacities are those the data was made with; the distances, the ones in effect now.
    if data:=core.world_storage_of(world,terrain.Terrain_Data);data!=nil && data.ready {
        settings=data.settings
    } else if configured!=nil {
        if configured.sources!=0 {settings.sources=configured.sources}
        if configured.chunks!=0 {settings.chunks=configured.chunks}
        if configured.samples!=0 {settings.samples=configured.samples}
    }
    if configured!=nil {settings.lod_distance,settings.collision_distance,settings.resident_distance=configured.lod_distance,configured.collision_distance,configured.resident_distance}
    return settings
}

// The samples Terrain_Settings.samples leaves for a source, without the one it replaces.
@(private)
terrain_samples_left :: proc(world:core.World_Ref,replace_id:base.Asset_Id) -> int {
    settings:=terrain_limits(world)
    available:=int(settings.samples)
    if data:=core.world_storage_of(world,terrain.Terrain_Data);data!=nil {
        for &entry in data.entries {if entry.id!=replace_id {available-=terrain.source_cost(&entry.source)}}
    }
    return max(available,0)
}

// Whether a source fits Terrain_Settings with the loaded ones. A terrain shows
// coarser nodes of its tree past the pieces of Terrain_Settings.chunks, and
// its nearest chunks take the colliders Physics_Settings has room for: only
// its samples can fail.
@(private)
terrain_budget :: proc(s:^editor.Session,world:core.World_Ref,source:^terrain.Source,replace_id:base.Asset_Id={}) -> bool {
    settings:=terrain_limits(world)
    sources:=1
    if data:=core.world_storage_of(world,terrain.Terrain_Data);data!=nil {
        for &entry in data.entries {if entry.id!=replace_id {sources+=1}}
    }
    if sources>int(settings.sources) {editor.notify(s,fmt.tprintf("Terrain needs %d sources; the limit is %d",sources,settings.sources));return false}
    cost:=terrain.source_cost(source)
    available:=terrain_samples_left(world,replace_id)
    if cost>available {editor.notify(s,fmt.tprintf("Terrain needs %d samples; %d are available",cost,available));return false}
    return true
}
