package anim

import "core:mem"
import "mirai:asset"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"

// The weight of a target of a mesh is, in order: the mesh's own, the
// entity's Default, the animation's curve "<path>/@morph/<target>" over them
// by its weight, plus the correctives of its rig that name the target, then
// the entity's Override or Additive. Without a path (none in Morph_Weights and
// no Animation_Target) a target takes the first curve of the animation that
// ends in "/@morph/<target>", whatever its path. Without either curve it
// takes the curve named as the target.
Morph_Weight_Mode :: enum u8 {Default,Override,Additive}

@(component,description="Morph target weights this entity sets by name over those of its mesh. Default is the weight at rest, which animation replaces; Override replaces the animated weight; Additive adds to it.")
Morph_Weights :: struct {
    source:core.Entity,                 // whose animation drives the weights; NONE: the rig of its Pose_Source, or its nearest animated ancestor
    path:[asset.NODE_PATH_CAPACITY]u8 `mirai:"text,hidden"`, // of its curves; empty: that of its Animation_Target, or without one any path
    names:[asset.MORPH_WEIGHTS]u64 `mirai:"hidden"`, // base.name_hash of a target; 0: a free entry
    values:[asset.MORPH_WEIGHTS]f32 `mirai:"hidden"`,
    modes:[asset.MORPH_WEIGHTS]Morph_Weight_Mode `mirai:"hidden"`,
}

// Sets the weight of a target by name. False for an empty name, a value that
// is not finite, or with every entry taken by other targets.
morph_weight_set :: proc(weights:^Morph_Weights,name:string,value:f32,mode:Morph_Weight_Mode=.Override) -> bool {
    if weights==nil || name=="" || !finite(value) || mode>max(Morph_Weight_Mode) {return false}
    key:=base.name_hash(name)
    free:=-1
    for entry,i in weights.names {
        if entry==key {weights.values[i],weights.modes[i]=value,mode;return true}
        if entry==0 && free<0 {free=i}
    }
    if free<0 {return false}
    weights.names[free],weights.values[free],weights.modes[free]=key,value,mode
    return true
}

// Gives the weight of a target back to its mesh and its animation.
morph_weight_clear :: proc(weights:^Morph_Weights,name:string) {
    if weights==nil {return}
    key:=base.name_hash(name)
    for &entry,i in weights.names {if entry==key {entry,weights.values[i],weights.modes[i]=0,0,.Default}}
}

Morph_Error :: enum u8 {
    None,
    Invalid_Weights, // a name repeated, a value that is not finite or a mode out of range
    Unknown_Target,  // an entry names no target of the mesh; the others apply
    Out_Of_Memory,
    Invalid_Value,   // a composed weight is not finite: the last ones stay
}

Morph_Playing :: struct {
    entity,source:core.Entity,
    mesh:base.Asset_Id,
    rig:u32,     // row of Skin_Runtime.rigs
    revision:u64,  // of that rig when it was bound
    stamp:u64,     // of the row of Morph_Weights it was bound to; 0: none
    path:u64,      // base.name_hash of the path of its curves
    by_name:bool,  // without a path: each target takes the curve of its name
    seen:u64,
    error:Morph_Error,
    unknown:u16,   // entries of Morph_Weights that name no target
    curve_asset:base.Asset_Id,
    curve_generation:u32,
    curve_count:int,       // of the source when curve_rows were found; -1: find them again
    curve_layout:u64,      // of the source when curve_rows were found
    tracks:[dynamic]u64,   // the curve of each target
    names:[dynamic]u64,    // base.name_hash of the name of each target, which correctives name
    entries:[dynamic]i8,   // the entry of Morph_Weights of each target; -1: none
    curve_rows:[dynamic]i32,
    current,previous:[dynamic]f32, // of each target, at the end of this tick and of the one before
}

@(storage,free="morph_playback_free")
Morph_Playback :: struct {
    states:[dynamic]Morph_Playing,
    rows:[dynamic]i32, // 1 + the state of each entity index; 0: none
    inputs:[9]u64,     // what the states were found with
    frame:u64,
}

// Reports why the morph weights of an entity are not all its own in this tick.
@(private)
morph_problem :: proc(problems:^core.Problems,e:core.Entity,error:Morph_Error,unknown:u16) {
    switch error {
    case .None:
    case .Invalid_Weights:
        core.report(problems,e,"animation.morph_weights","Morph_Weights of this entity repeats a name, has a value that is not finite or a mode out of range, so none of its entries applies; fix them")
    case .Unknown_Target:
        core.report(problems,e,"animation.morph_target","%d entries of Morph_Weights of this entity name no morph target of its mesh and do nothing; name targets of the mesh (animation.inspect lists them)",unknown)
    case .Out_Of_Memory:
        memory_problem(problems,e,"its morph weights")
    case .Invalid_Value:
        core.report(problems,e,"animation.morph_value","a morph weight of this entity came out not finite, so the last ones stay: a curve of its animation, a corrective or Morph_Weights gives a value that is not finite; find which with animation.inspect")
    }
}

morph_playback_free :: proc(playback:^Morph_Playback) {
    for &state in playback.states {morph_playing_free(&state)}
    delete(playback.states);delete(playback.rows);playback^={}
}

@(private)
morph_playing_free :: proc(state:^Morph_Playing) {
    delete(state.tracks);delete(state.names);delete(state.entries);delete(state.curve_rows);delete(state.current);delete(state.previous)
    state^={}
}

@(private)
morph_playing :: proc(playback:^Morph_Playback,entity:core.Entity) -> ^Morph_Playing {
    if playback==nil {return nil}
    index:=core.entity_index(entity)
    if index>=len(playback.rows) {return nil}
    row:=int(playback.rows[index])-1
    if row<0 || row>=len(playback.states) || playback.states[row].entity!=entity {return nil}
    return &playback.states[row]
}

// What the last tick composed for an entity: the weights of its targets in the order of
// its mesh, which borrow the playback until its next tick, and what they were bound to.
Morph_State :: struct {
    weights:[]f32,
    mesh:base.Asset_Id,
    source:core.Entity,
    stamp:u64, // of its row of Morph_Weights + 1; 0: none
    error:Morph_Error,
    unknown:u16,
}
animation_morph_state :: proc(playback:^Morph_Playback,entity:core.Entity) -> (state:Morph_State,ok:bool) {
    playing:=morph_playing(playback,entity)
    if playing==nil {return}
    return {playing.current[:],playing.mesh,playing.source,playing.stamp,playing.error,playing.unknown},true
}

// Invalid_Weights for a name repeated, a value that is not finite or a mode out of range;
// else Unknown_Target with the entries that name none of `targets`.
morph_weights_check :: proc(weights:Morph_Weights,targets:[]asset.Morph_Target) -> (error:Morph_Error,unknown:u16) {
    weights:=weights
    for entry,i in weights.names {
        if entry==0 {continue}
        if !finite(weights.values[i]) || weights.modes[i]>max(Morph_Weight_Mode) {error=.Invalid_Weights}
        for other in weights.names[:i] {if other==entry {error=.Invalid_Weights}}
        known:=false
        for &target in targets {known ||= base.name_hash(base.text_get(target.name[:]))==entry}
        if !known {unknown+=1}
    }
    if error==.None && unknown>0 {error=.Unknown_Target}
    return
}

// The targets of a mesh as the renderer deforms them: a range of deltas of
// each vertex of the mesh, of every level, by target.
@(private)
morph_rig_read :: proc(rig:^Skin_Rig,view:asset.Mesh_View,allocator:mem.Allocator) -> bool {
    if len(view.morphs)==0 {return true}
    vertices:=len(view.vertices)
    error:mem.Allocator_Error
    rig.morphs,error=make([]asset.Morph_Target,len(view.morphs),allocator);if error!=nil {return false}
    copy(rig.morphs,view.morphs)
    rig.morph.count,rig.morph.step=u32(len(view.morphs)),view.morph_step
    rig.morph.ranges,error=make([]erender.Morph_Range,vertices,allocator);if error!=nil {return false}
    total:=0
    for delta in view.morph_deltas {
        if int(delta.vertex)>=vertices {continue}
        rig.morph.ranges[delta.vertex].count+=1;total+=1
    }
    rig.morph.deltas,error=make([]erender.Morph_Delta,total,allocator);if error!=nil {return false}
    first:u32
    for &range in rig.morph.ranges {range.first=first;first+=range.count;range.count=0}
    for target,t in view.morphs {
        for delta in view.morph_deltas[target.first:][:target.count] {
            if int(delta.vertex)>=vertices {continue}
            range:=&rig.morph.ranges[delta.vertex]
            rig.morph.deltas[range.first+range.count]={position=delta.position,normal=delta.normal,tangent=delta.tangent,target=u32(t)}
            range.count+=1
        }
    }
    return true
}

// Whose animation drives the weights of an entity: the one named, itself
// when it is a rig that follows another, the rig of its Pose_Source, or its
// nearest animated ancestor.
morph_source :: proc(entity:core.Entity,config:Morph_Weights,animations:^core.Table(Animation,$A),sources:^core.Table(Pose_Source,$B),parents:^core.Table(core.Parent,$C),playback:^Playback=nil) -> core.Entity {
    if config.source!=core.NONE {return config.source}
    if playback!=nil {if own:=constraint_playing(playback,entity);own!=nil && own.leader!=core.NONE {return entity}}
    if source,has:=core.get(sources,entity);has {return source.rig}
    return core.ancestor_with(parents,animations,entity)
}

// Binds the targets of a rig to the entries of Morph_Weights and to the
// names of their curves; weights start at the mesh's when its rig changed.
@(private)
morph_bind :: proc(state:^Morph_Playing,rig:^Skin_Rig,config:Morph_Weights,path:string,stamp:u64) -> bool {
    config:=config
    count:=len(rig.morphs)
    fresh:=len(state.current)!=count || state.mesh!=rig.id || state.revision!=rig.revision
    // Room first, so that without memory nothing changes.
    if reserve(&state.current,count)!=nil || reserve(&state.previous,count)!=nil || reserve(&state.tracks,count)!=nil || reserve(&state.names,count)!=nil || reserve(&state.entries,count)!=nil || reserve(&state.curve_rows,count)!=nil ||
       resize(&state.current,count)!=nil || resize(&state.previous,count)!=nil || resize(&state.tracks,count)!=nil || resize(&state.names,count)!=nil || resize(&state.entries,count)!=nil || resize(&state.curve_rows,count)!=nil {
        state.error=.Out_Of_Memory
        return false
    }
    path_hash:=base.name_hash(path)
    renamed:=fresh || state.path!=path_hash
    state.error,state.unknown=morph_weights_check(config,rig.morphs)
    for &target,t in rig.morphs {
        name:=base.text_get(target.name[:])
        key:=base.name_hash(name)
        state.names[t]=key
        state.entries[t]=-1
        if state.error!=.Invalid_Weights {for entry,i in config.names {if entry==key {state.entries[t]=i8(i);break}}}
        if renamed {
            curve:[256+8+64]u8
            n:=copy(curve[:],path);n+=copy(curve[n:],"/@morph/");n+=copy(curve[n:],name)
            state.tracks[t]=base.name_hash(string(curve[:n]))
        }
        if fresh {state.current[t],state.previous[t]=target.weight,target.weight}
    }
    if renamed {state.curve_count=-1}
    state.mesh,state.revision,state.stamp,state.path,state.by_name=rig.id,rig.revision,stamp,path_hash,path==""
    return true
}

// Composes the weights of the targets of every mesh that has them, from its
// mesh, its Morph_Weights and the curves of the animation that drives it.
@(step="fixed",loops="game editor",stage="react")
animation_morph :: proc(
    meshes:^core.Table(erender.Mesh_Renderer,.Read),configs:^core.Table(Morph_Weights,.Read),animations:^core.Table(Animation,.Read),
    targets:^core.Table(Animation_Target,.Read),sources:^core.Table(Pose_Source,.Read),parents:^core.Table(core.Parent,.Read),
    playback:core.Ref(Playback),modifiers:core.Ref(Modifier_Runtime),cache:^Skin_Runtime,state:^Morph_Playback,libraries:^Source_Assets,app:^host.App,time:core.Time,
    problems:^core.Problems,
) {
    if app.assets==nil {return}
    context.allocator=app.allocator
    cache.allocator=app.allocator
    state.frame+=1
    inputs:=[9]u64{core.layout(meshes),core.version(meshes),core.layout(configs),core.layout(animations),core.version(parents),core.layout(sources),core.version(sources),core.layout(targets),assets_stamp(app.assets)}
    if state.inputs!=inputs {
        found:=true
        for row in 0..<core.count(meshes) {
            entity:=core.entity_at(meshes,row)
            mesh:=core.at(meshes,row).mesh
            if mesh=={} {continue}
            index:=skin_rig_load(cache,app.assets,app.allocator,mesh,problems,entity)
            if index==max(u32) {found=false;continue}
            if len(cache.rigs[index].morphs)==0 {continue}
            playing:=morph_playing(state,entity)
            if playing==nil {
                entity_index:=int(core.entity_index(entity))
                if entity_index>=len(state.rows) && resize(&state.rows,entity_index+1)!=nil {memory_problem(problems,entity,"its morph weights");found=false;continue}
                if _,error:=append(&state.states,Morph_Playing{entity=entity,curve_count=-1});error!=nil {memory_problem(problems,entity,"its morph weights");found=false;continue}
                state.rows[entity_index]=i32(len(state.states))
                playing=&state.states[len(state.states)-1]
            }
            playing.rig,playing.seen=index,state.frame
        }
        kept:=0
        for &playing,i in state.states {
            index:=core.entity_index(playing.entity)
            if playing.seen!=state.frame && found {state.rows[index]=0;morph_playing_free(&playing);continue}
            if kept!=i {state.states[kept]=playing}
            state.rows[index]=i32(kept+1)
            kept+=1
        }
        base.truncate(&state.states,kept)
        if found {state.inputs=inputs}
    }
    for &playing in state.states {
        if int(playing.rig)>=len(cache.rigs) {continue}
        rig:=&cache.rigs[playing.rig]
        config:Morph_Weights
        stamp:u64
        if row:=core.row_of(configs,playing.entity);row>=0 {config=core.at(configs,row);stamp=core.stamp(configs,row)+1}
        path:=base.text_get(config.path[:])
        if path=="" {if target,has:=core.get(targets,playing.entity);has {path=base.text_get(target.path[:])}}
        if playing.stamp!=stamp || playing.mesh!=rig.id || playing.revision!=rig.revision || playing.path!=base.name_hash(path) {
            if !morph_bind(&playing,rig,config,path,stamp) {playing.stamp=0;morph_problem(problems,playing.entity,playing.error,playing.unknown);continue}
            if playing.error!=.None {morph_problem(problems,playing.entity,playing.error,playing.unknown)}
        }
        playing.source=morph_source(playing.entity,config,animations,sources,parents,playback.ptr)
        copy(playing.previous[:],playing.current[:])
        source:=constraint_playing(playback.ptr,playing.source)
        if source!=nil && (source.seen!=playback.ptr.frame || !source.curves_ready) {source=nil}
        content:=animation_playing_content(libraries,app,source) if source!=nil && playing.by_name else nil
        if !morph_compose(&playing,rig,config,source,modifiers.ptr,content) {playing.error=.Invalid_Value;morph_problem(problems,playing.entity,.Invalid_Value,0)}
        if !time.playing {copy(playing.previous[:],playing.current[:])}
    }
}

@(private)
morph_compose :: proc(playing:^Morph_Playing,rig:^Skin_Rig,config:Morph_Weights,source:^Playing,modifiers:^Modifier_Runtime=nil,content:^host.Content_Animation=nil) -> bool {
    curves:=playing_curves(source) if source!=nil else nil
    layout:=source.curve_layout if source!=nil && source.driven_ready else 0
    if source!=nil && (playing.curve_asset!=source.asset || playing.curve_generation!=source.generation || playing.curve_count!=len(curves) || playing.curve_layout!=layout) {
        find :: proc(curves:[]Curve_Output,target:u64) -> i32 {
            for curve,c in curves {if curve.property==.Float && curve.slot==0 && curve.target==target {return i32(c)}}
            return -1
        }
        for &row,t in playing.curve_rows {
            row=-1
            if !playing.by_name {row=find(curves,playing.tracks[t])} else if content!=nil {
                for morph in content.morphs {if morph.target==playing.names[t] {if row=find(curves,morph.curve);row>=0 {break}}}
            }
            // Else a curve named as the target, as faces, their captures and curve drives name them.
            if row<0 {row=find(curves,playing.names[t])}
        }
        playing.curve_asset,playing.curve_generation,playing.curve_count,playing.curve_layout=source.asset,source.generation,len(curves),layout
    }
    ok:=true
    for &target,t in rig.morphs {
        value:=target.weight
        entry:=int(playing.entries[t])
        if entry>=0 && config.modes[entry]==.Default {value=config.values[entry]}
        if source!=nil {
            if row:=int(playing.curve_rows[t]);row>=0 && row<len(curves) {curve:=curves[row];value=curve.value.x+value*(1-curve.weight)}
        }
        value+=animation_corrective_curve(modifiers,playing.source,playing.names[t])
        if entry>=0 {
            #partial switch config.modes[entry] {
            case .Override: value=config.values[entry]
            case .Additive: value+=config.values[entry]
            }
        }
        if finite(value) {playing.current[t]=value} else {ok=false}
    }
    return ok
}
