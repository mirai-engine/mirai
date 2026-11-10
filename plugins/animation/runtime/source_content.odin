package anim

import "core:mem"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import "base:runtime"

// An Animation whose .match, action set or the spaces of its layers name clips
// of several .anim plays one library that joins them, prepared once per set of
// sources and shared by every entity and world. Its primary source is the
// animation of its asset: its clips keep their names, those of another source
// are named by source_clip_name.

ANIMATION_SOURCES :: 64
SOURCE_CACHE_CAPACITY :: 256
SOURCE_DEPENDENCIES :: ANIMATION_SOURCES+STACK_LAYERS+2
// Joined libraries count their generations from here, apart from those of host content.
SOURCE_GENERATION :: u32(1)<<31

Source_Error :: enum u8 {None,Invalid,Alias_Collision,Out_Of_Memory}
Source_Dependency :: struct {id:base.Asset_Id,size,time:i64,present:bool}
// The sources of one Animation asset, library and actions, found again when one of the files
// they were read from changes.
Source_Plan :: struct {
    key:[3]base.Asset_Id,
    primary:base.Asset_Id,
    dependencies:[]Source_Dependency,
    set:u32,                // in sets + 1; 0 plays the primary source alone
    checked:u64,            // Assets.revision + 1
    content_generation:u32, // Content.generations it was checked against
    valid:bool,
}
Source_Set :: struct {
    primary:base.Asset_Id,
    ids:[]base.Asset_Id,
    generations:[]u32, // of each source when joined
    content:host.Content_Animation,
    clip_sources:[]base.Asset_Id, // of each clip of content
}
@(storage,host,free="source_assets_free")
Source_Assets :: struct {allocator:mem.Allocator,plans:[dynamic]Source_Plan,sets:[dynamic]Source_Set,generations:u32}

source_assets_free :: proc(cache:^Source_Assets) {
    if cache==nil {return}
    allocator:=cache.allocator if cache.allocator.procedure!=nil else context.allocator
    for plan in cache.plans {delete(plan.dependencies,allocator)}
    for &set in cache.sets {source_set_free(&set,allocator)}
    delete(cache.plans);delete(cache.sets);cache^={}
}

// The source of a clip reference: its own, else the override of the Animation (library), else
// the one its definition inherits.
source_effective :: proc "contextless" (explicit,inherited,override:base.Asset_Id) -> base.Asset_Id {
    if explicit!={} {return explicit}
    return override if override!={} else inherited
}

// The name of clip `name` of `source` in a library whose primary source is `primary`.
source_clip_name :: proc "contextless" (primary,source:base.Asset_Id,name:u64) -> u64 {
    if source=={} || source==primary {return name}
    return base.hash_combine(name,base.hash_combine(source[0],source[1])~u64(0x414e494d534f5552))
}

// The name a clip has in its own source.
source_clip_label :: proc "contextless" (content:^host.Content_Animation,clip:lib.Clip) -> [asset.ANIMATION_NAME_CAPACITY]u8 {
    if content==nil || content.clip_count<=0 || !lib.clip_valid(&content.lib,clip) {return {}}
    index:=(int(clip)-1)%content.clip_count
    return content.names[index] if index<len(content.names) else {}
}

// The .anim of a clip of what `state` plays.
source_clip_source :: proc "contextless" (cache:^Source_Assets,state:^Playing,clip:lib.Clip) -> base.Asset_Id {
    set:=source_playing_set(cache,state)
    if set==nil {return state.asset if state!=nil else {}}
    if set.content.clip_count<=0 || !lib.clip_valid(&set.content.lib,clip) {return {}}
    return set.clip_sources[(int(clip)-1)%set.content.clip_count]
}

// The sources joined in what `state` plays; empty when it plays one.
source_ids :: proc "contextless" (cache:^Source_Assets,state:^Playing) -> []base.Asset_Id {
    set:=source_playing_set(cache,state)
    return set.ids if set!=nil else nil
}

// The library `state` plays: the joined one of its plan, else the content of its asset.
animation_playing_content :: proc(cache:^Source_Assets,app:^host.App,state:^Playing) -> ^host.Content_Animation {
    if state==nil || app==nil {return nil}
    if set:=source_playing_set(cache,state);set!=nil {return &set.content}
    return host.content_animation(app,state.asset)
}

// The library an Animation plays, joining the sources of its .match and its action set when there
// are several. A tick whose assets did not change reuses the plan without reading them.
animation_content :: proc(cache:^Source_Assets,app:^host.App,state:^Playing,description:Animation,blends:^Blend_Assets=nil,matches:^Match_Assets=nil,actions:^Action_Runtime=nil) -> (content:^host.Content_Animation,error:Program_Error) {
    if app.assets==nil || state==nil {return nil,.Invalid_Asset}
    if description.asset=={} {state.source_plan=0;return nil,.None}
    if record,present:=asset.registry_find(&app.assets.registry,description.asset);present && record.kind==BLEND_KIND {state.source_plan=0;return nil,.Layer_Space}
    if cache==nil {
        primary:=description.asset
        if record,present:=asset.registry_find(&app.assets.registry,description.asset);present {
            if record.kind==MATCH_KIND {
                match:=match_content(matches,app.assets,app.allocator,description.asset);if match==nil {return nil,.Invalid_Asset}
                primary=source_effective({},match.profile.info.animation,description.library)
            }
        }
        state.source_plan=0
        return source_single(app,primary)
    }
    if cache.allocator.procedure==nil {cache.allocator=app.allocator}
    context.allocator=cache.allocator
    key:=[3]base.Asset_Id{description.asset,description.library,description.actions}
    at:=int(state.source_plan)-1
    if at<0 || at>=len(cache.plans) || cache.plans[at].key!=key {at=-1;for plan,i in cache.plans {if plan.key==key {at=i;break}}}
    if at<0 {
        if len(cache.plans)>=SOURCE_CACHE_CAPACITY || !program_array_reserve(&cache.plans,len(cache.plans)+1) {return nil,.Out_Of_Memory}
        at=len(cache.plans)
        if append(&cache.plans,Source_Plan{key=key})!=1 {return nil,.Out_Of_Memory}
    }
    plan:=&cache.plans[at]
    content_generation:=app.content.generations if app.content!=nil else 0
    if plan.valid && plan.checked==assets_stamp(app.assets) && plan.content_generation==content_generation {
        state.source_plan=u32(at+1)
        return source_plan_content(cache,app,plan)
    }
    changed:=!plan.valid
    if !changed && plan.checked!=assets_stamp(app.assets) {for dependency in plan.dependencies {if source_dependency(app.assets,dependency.id)!=dependency {changed=true;break}}}
    ids:[ANIMATION_SOURCES]base.Asset_Id;count:=0
    dependencies:[SOURCE_DEPENDENCIES]Source_Dependency;dependency_count:=0
    primary:=plan.primary
    if changed {
        ok:bool
        primary,ok=source_collect(app.assets,app.allocator,description,state.entity,blends,matches,actions,&ids,&count,&dependencies,&dependency_count)
        if !ok {return nil,.Invalid_Asset}
    } else if plan.set>0 {set:=cache.sets[plan.set-1];count=len(set.ids);copy(ids[:],set.ids)} else {ids[0]=primary;count=1}
    copied:[]Source_Dependency
    if changed {
        allocation:mem.Allocator_Error
        copied,allocation=make([]Source_Dependency,dependency_count,cache.allocator)
        if allocation!=nil {return nil,.Out_Of_Memory}
        copy(copied,dependencies[:dependency_count])
    }
    set,prepared:=source_set_prepare(cache,app,primary,ids[:count])
    if prepared!=.None {delete(copied,cache.allocator);return nil,prepared}
    if changed {delete(plan.dependencies,cache.allocator);plan.dependencies=copied}
    plan.primary,plan.set,plan.checked,plan.valid,plan.content_generation=primary,set,assets_stamp(app.assets),true,content_generation
    state.source_plan=u32(at+1)
    return source_plan_content(cache,app,plan)
}

// While a source of what an Animation now names still has its first load under way, the library
// of the plan it played before, with the asset and library that plan was made for. None when it
// played nothing, or its actions asset changed: those actions name clips of the new sources.
source_previous :: proc(cache:^Source_Assets,app:^host.App,state:^Playing,description:Animation) -> (content:^host.Content_Animation,played,library:base.Asset_Id,kept:bool) {
    if cache==nil || app==nil || state==nil || state.source_plan==0 || int(state.source_plan)>len(cache.plans) {return}
    plan:=&cache.plans[state.source_plan-1]
    if !plan.valid || plan.key[2]!=description.actions || plan.key==([3]base.Asset_Id{description.asset,description.library,description.actions}) {return}
    found,error:=source_plan_content(cache,app,plan)
    if error!=.None || found==nil {return}
    return found,plan.key[0],plan.key[1],true
}

// Gives the markers of a joined library the clip names and .anim of their sources.
source_markers_resolve :: proc "contextless" (cache:^Source_Assets,state:^Playing,markers:[]Animation_Event) {
    set:=source_playing_set(cache,state)
    if set==nil {return}
    content:=&set.content
    for &marker in markers {
        if marker.kind!=.Marker {continue}
        for clip,i in content.lib.clips[:content.clip_count] {
            if clip.name!=marker.clip {continue}
            marker.clip=base.name_hash(base.text_get(content.names[i][:]))
            marker.animation=set.clip_sources[i]
            break
        }
    }
}

// Joins the resident libraries of `sources` into `set`, which keeps what it had when this fails.
source_join :: proc(cache:^Source_Assets,set:^Source_Set,primary:base.Asset_Id,sources:[]host.Content_Animation) -> Source_Error {
    if cache==nil || set==nil || primary=={} || len(sources)<2 {return .Invalid}
    allocator:=cache.allocator if cache.allocator.procedure!=nil else context.allocator
    desc:=lib.Library_Desc{allocator=allocator}
    count,marker_names,streams,morphs,fields:=0,0,0,0,0
    found:=false
    for source,i in sources {
        if source.id=={} || source.clip_count<0 || source.clip_count>len(source.names) || source.clip_count>len(source.roots) || source.lib.key_count<0 || source.lib.key_count>len(source.lib.keys) || source.lib.track_count<0 || source.lib.track_count>len(source.lib.tracks) || source.lib.marker_count<0 || source.lib.marker_count>len(source.lib.markers) || source.lib.stream_bytes<0 || source.lib.stream_bytes>0 && source.lib.stream_bytes+lib.STREAM_PADDING>len(source.lib.streams) || source.clip_count>source.lib.clip_count || source.clip_count>len(source.lib.clips) {return .Invalid}
        for previous in sources[:i] {if previous.id==source.id {return .Invalid}}
        found ||= source.id==primary
        count+=source.clip_count;marker_names+=len(source.markers);streams+=source.lib.stream_bytes;morphs+=len(source.morphs);fields+=len(source.fields)
        desc.max_keys+=source.lib.key_count;desc.max_tracks+=source.lib.track_count;desc.max_markers+=source.lib.marker_count
    }
    if !found || count==0 {return .Invalid}
    desc.max_clips=count*2;desc.max_keys=max(desc.max_keys,1);desc.max_tracks=max(desc.max_tracks,1)
    desc.max_stream_bytes=streams
    next:Source_Set
    published:=false
    defer {if !published {source_set_free(&next,allocator)}}
    if !lib.library_init(&next.content.lib,desc) {return .Out_Of_Memory}
    e1,e2,e3,e4,e5,e6:mem.Allocator_Error
    next.content.markers,e1=make([]u64,marker_names,allocator)
    next.content.names,e2=make([][asset.ANIMATION_NAME_CAPACITY]u8,count,allocator)
    next.content.roots,e3=make([]asset.Animation_Root,count,allocator)
    next.clip_sources,e4=make([]base.Asset_Id,count,allocator)
    next.content.morphs,e5=make([]host.Content_Morph,morphs,allocator)
    next.content.fields,e6=make([]host.Content_Field,fields,allocator)
    if e1!=nil || e2!=nil || e3!=nil || e4!=nil || e5!=nil || e6!=nil {return .Out_Of_Memory}
    joined:=&next.content
    key_at,track_at,marker_at,name_at,clip_at,stream_at,morph_at,field_at:=0,0,0,0,0,0,0,0
    for source in sources {
        copy(joined.morphs[morph_at:],source.morphs);morph_at+=len(source.morphs)
        copy(joined.fields[field_at:],source.fields);field_at+=len(source.fields)
        copy(joined.lib.keys[key_at:],source.lib.keys[:source.lib.key_count])
        copy(joined.lib.streams[stream_at:],source.lib.streams[:source.lib.stream_bytes])
        copy(joined.markers[name_at:],source.markers)
        for track,j in source.lib.tracks[:source.lib.track_count] {
            track:=track
            track.first+=u32(stream_at if track.encoding==.Sampled else key_at)
            joined.lib.tracks[track_at+j]=track
        }
        for marker,j in source.lib.markers[:source.lib.marker_count] {
            marker:=marker
            if int(marker.id)>=len(source.markers) {return .Invalid}
            marker.id+=u32(name_at);joined.lib.markers[marker_at+j]=marker
        }
        for clip,j in source.lib.clips[:source.clip_count] {
            clip:=clip
            clip.name=source_clip_name(primary,source.id,base.name_hash(base.text_get(source.names[j][:])))
            for previous in joined.lib.clips[:clip_at] {if previous.name==clip.name {return .Alias_Collision}}
            clip.first_track+=u32(track_at);clip.first_marker+=u32(marker_at);clip.loop=.Once
            if clip.stream_bytes>0 {clip.stream+=u32(stream_at)}
            joined.lib.clips[clip_at]=clip;joined.names[clip_at]=source.names[j];joined.roots[clip_at]=source.roots[j]
            next.clip_sources[clip_at]=source.id;clip_at+=1
        }
        key_at+=source.lib.key_count;track_at+=source.lib.track_count;marker_at+=source.lib.marker_count
        name_at+=len(source.markers);stream_at+=source.lib.stream_bytes
    }
    joined.lib.key_count,joined.lib.track_count,joined.lib.marker_count=key_at,track_at,marker_at
    joined.lib.stream_bytes=stream_at
    host.content_animation_loops(&joined.lib,count);joined.lib.prepared=true;joined.clip_count=count
    cache.generations+=1
    joined.id,joined.generation=primary,SOURCE_GENERATION|cache.generations
    next.primary,next.ids,next.generations=set.primary,set.ids,set.generations
    set.ids,set.generations=nil,nil
    source_set_free(set,allocator);set^=next;published=true
    return .None
}

@(private)
source_set_free :: proc(set:^Source_Set,allocator:mem.Allocator) {
    lib.library_destroy(&set.content.lib)
    delete(set.content.markers,allocator);delete(set.content.names,allocator);delete(set.content.roots,allocator);delete(set.content.morphs,allocator);delete(set.content.fields,allocator)
    delete(set.clip_sources,allocator);delete(set.ids,allocator);delete(set.generations,allocator)
    set^={}
}

@(private)
source_playing_set :: proc "contextless" (cache:^Source_Assets,state:^Playing) -> ^Source_Set {
    if cache==nil || state==nil || state.source_plan==0 || int(state.source_plan)>len(cache.plans) {return nil}
    plan:=&cache.plans[state.source_plan-1]
    if !plan.valid || plan.primary!=state.asset || plan.set==0 || int(plan.set)>len(cache.sets) {return nil}
    return &cache.sets[plan.set-1]
}

@(private)
source_plan_content :: proc(cache:^Source_Assets,app:^host.App,plan:^Source_Plan) -> (^host.Content_Animation,Program_Error) {
    if plan.set>0 {return &cache.sets[plan.set-1].content,.None}
    return source_single(app,plan.primary)
}

// The library of one .anim; Pending while its first load compresses.
@(private)
source_single :: proc(app:^host.App,id:base.Asset_Id) -> (^host.Content_Animation,Program_Error) {
    content:=host.content_animation(app,id)
    if content==nil && host.content_animation_pending(app,id) {return nil,.Pending}
    return content,.None
}

@(private)
source_dependency :: proc(assets:^host.Assets,id:base.Asset_Id) -> Source_Dependency {
    record,present:=asset.registry_find(&assets.registry,id)
    return {id=id,size=record.size if present else 0,time=record.time if present else 0,present=present}
}
@(private)
source_dependency_add :: proc(assets:^host.Assets,rows:^[SOURCE_DEPENDENCIES]Source_Dependency,count:^int,id:base.Asset_Id) -> bool {
    if id=={} {return false}
    for row in rows[:count^] {if row.id==id {return true}}
    if count^>=len(rows) {return false}
    rows[count^]=source_dependency(assets,id);count^+=1;return true
}
@(private)
source_id_add :: proc(ids:^[ANIMATION_SOURCES]base.Asset_Id,count:^int,id:base.Asset_Id) -> bool {
    if id=={} {return false}
    for previous in ids[:count^] {if previous==id {return true}}
    if count^>=len(ids) {return false}
    ids[count^]=id;count^+=1;return true
}
@(private)
source_blend_collect :: proc(profile:Blend_Profile,override:base.Asset_Id,ids:^[ANIMATION_SOURCES]base.Asset_Id,count:^int) -> bool {
    for sample in profile.samples {if !source_id_add(ids,count,source_effective(sample.animation,profile.info.animation,override)) {return false}}
    return true
}

@(private)
source_collect :: proc(assets:^host.Assets,allocator:runtime.Allocator,description:Animation,entity:core.Entity,blends:^Blend_Assets,matches:^Match_Assets,actions:^Action_Runtime,ids:^[ANIMATION_SOURCES]base.Asset_Id,count:^int,dependencies:^[SOURCE_DEPENDENCIES]Source_Dependency,dependency_count:^int) -> (primary:base.Asset_Id,ok:bool) {
    if !source_dependency_add(assets,dependencies,dependency_count,description.asset) {return}
    record,present:=asset.registry_find(&assets.registry,description.asset)
    kind:=record.kind if present else asset.KIND_ANIMATION
    primary=description.asset
    switch kind {
    case MATCH_KIND:
        match:=match_content(matches,assets,allocator,description.asset);if match==nil {return}
        primary=source_effective({},match.profile.info.animation,description.library)
        if !source_id_add(ids,count,primary) {return}
        for clip in match.profile.clips {if !source_id_add(ids,count,source_effective(clip.animation,match.profile.info.animation,description.library)) {return}}
    case asset.KIND_ANIMATION:
        if description.library!={} || !source_id_add(ids,count,primary) {return}
    case: return
    }
    if description.actions!={} {
        if !source_dependency_add(assets,dependencies,dependency_count,description.actions) {return}
        active:=action_state(actions,entity)
        if active==nil || active.plan<0 || int(active.plan)>=len(actions.plans) {return}
        profile:=actions.plans[active.plan].profile
        for action in profile.actions {if !source_id_add(ids,count,source_effective(action.animation,profile.info.animation,description.library)) {return}}
        for layer in profile.layers {
            if layer.clip[0]!=0 || layer.reference_clip[0]!=0 {if !source_id_add(ids,count,source_effective(layer.animation,profile.info.animation,description.library)) {return}}
            if layer.space=={} {continue}
            if !source_dependency_add(assets,dependencies,dependency_count,layer.space) {return}
            // A space that cannot be read is the problem of its layer, not of what the entity plays.
            if blend:=blend_content(blends,assets,allocator,layer.space);blend!=nil && !source_blend_collect(blend.profile,description.library,ids,count) {return}
        }
    }
    for id in ids[:count^] {if !source_dependency_add(assets,dependencies,dependency_count,id) {return}}
    // The primary source stays first and the rest are sorted, so equal sets share one library.
    for i in 2..<count^ {
        j:=i
        for j>1 && (ids[j][0]<ids[j-1][0] || ids[j][0]==ids[j-1][0] && ids[j][1]<ids[j-1][1]) {ids[j],ids[j-1]=ids[j-1],ids[j];j-=1}
    }
    return primary,true
}

@(private)
source_set_find :: proc(cache:^Source_Assets,primary:base.Asset_Id,ids:[]base.Asset_Id) -> int {
    for set,i in cache.sets {
        if set.primary!=primary || len(set.ids)!=len(ids) {continue}
        same:=true;for id,j in ids {if set.ids[j]!=id {same=false;break}}
        if same {return i}
    }
    return -1
}

@(private)
source_set_prepare :: proc(cache:^Source_Assets,app:^host.App,primary:base.Asset_Id,ids:[]base.Asset_Id) -> (u32,Program_Error) {
    sources:[ANIMATION_SOURCES]host.Content_Animation
    pending:=false
    for id,i in ids {
        content:=host.content_animation(app,id)
        if content!=nil {sources[i]=content^;continue}
        if !host.content_animation_pending(app,id) {return 0,.Invalid_Asset}
        pending=true
    }
    if pending {return 0,.Pending}
    if len(ids)==1 {return 0,.None}
    joined :: proc(error:Source_Error) -> Program_Error {return .None if error==.None else .Out_Of_Memory if error==.Out_Of_Memory else .Invalid_Asset}
    at:=source_set_find(cache,primary,ids)
    if at>=0 {
        set:=&cache.sets[at];same:=true
        for source,i in sources[:len(ids)] {if source.generation!=set.generations[i] {same=false;break}}
        if same {return u32(at+1),.None}
        if error:=joined(source_join(cache,set,primary,sources[:len(ids)]));error!=.None {return 0,error}
        for source,i in sources[:len(ids)] {set.generations[i]=source.generation}
        return u32(at+1),.None
    }
    if len(cache.sets)>=SOURCE_CACHE_CAPACITY || !program_array_reserve(&cache.sets,len(cache.sets)+1) {return 0,.Out_Of_Memory}
    next:=Source_Set{primary=primary};published:=false
    defer {if !published {source_set_free(&next,cache.allocator)}}
    e1,e2:mem.Allocator_Error
    next.ids,e1=make([]base.Asset_Id,len(ids),cache.allocator)
    next.generations,e2=make([]u32,len(ids),cache.allocator)
    if e1!=nil || e2!=nil {return 0,.Out_Of_Memory}
    copy(next.ids,ids)
    for source,i in sources[:len(ids)] {next.generations[i]=source.generation}
    if error:=joined(source_join(cache,&next,primary,sources[:len(ids)]));error!=.None {return 0,error}
    append(&cache.sets,next);published=true
    return u32(len(cache.sets)),.None
}
