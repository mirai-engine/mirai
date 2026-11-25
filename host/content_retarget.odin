package host

import "mirai:asset"
import anim "mirai:std/anim"
import "mirai:std/base"
import "mirai:std/jobs"

// The clips of an .anim as a rig of a skeleton they were not made on plays them: its retarget
// onto that skeleton (asset.animation_retarget). It is an entry of the animations of the content
// under the id of the retarget (asset.animation_retarget_id), whose Content_Animation.id is that
// of the .anim, so its clips, names and markers are those of the .anim. It loads as an .anim does
// (content_animation_start): the cooked .anim a cook wrote for it (a shipped game), else the
// compression App.animation_cache keeps of it, else it is made in a job from the .anim and the
// skeletons, never on the thread that asks, and taken at the start of a frame. While it is made it
// is pending; one that cannot be made fails, and never plays the clips as they are. It is made
// again when the .anim or a skeleton changes (content_retarget_stamp).
//
// The retargets the content holds stay within App.retarget_budget bytes: one that does not fit
// evicts those nothing asked for in the last CONTENT_RETARGET_IDLE frames, the longest idle first,
// and fails with Budget when that is not enough; it is tried again once there is room. Asking for
// a retarget (content_animation_retarget) marks it used.

CONTENT_RETARGET_BUDGET :: 64<<20
// Frames (app_content_adopt) after which a retarget nothing asked for may be evicted: longer than
// the frames between two ticks of a world.
CONTENT_RETARGET_IDLE :: 120

Content_Retarget :: struct {
    skeleton:base.Asset_Id, // what it plays on; {}: the entry is an .anim
    key:base.Asset_Id,      // asset.animation_retarget_id: its id in the index
    stamp:u64,              // content_retarget_stamp when it was asked for or made again
    direct:bool,            // its clips bind by name: the .anim plays as it is
    failure:asset.Animation_Retarget_Failure,
    failed:base.Asset_Id,   // the skeleton the failure is about
    used:u64,               // Content.frame when it was last asked for
    bytes:int,              // what its library holds (content_animation_bytes)
    need:int,               // of a Budget failure: the bytes it did not find
}

// Why a retarget cannot play, and the skeleton that is about.
Content_Retarget_Fault :: struct {
    failure:asset.Animation_Retarget_Failure,
    skeleton:base.Asset_Id,
}

// The library a rig of `skeleton` plays the .anim `id` as: the .anim itself when its clips bind
// there by name, else its retarget. Call it only for an .anim with clips of another skeleton
// (asset.animation_retarget_needed): it keeps an entry for the pair. nil while it is made
// (pending) and when it fails (fault); the .anim itself still loading is pending too.
content_animation_retarget :: proc(app:^App,id,skeleton:base.Asset_Id) -> (content:^Content_Animation,pending:bool,fault:Content_Retarget_Fault) {
    c:=app_content(app)
    if c==nil || id=={} || skeleton=={} {return}
    key:=asset.animation_retarget_id(id,skeleton)
    entry,fresh:=content_slot(c,&c.animations,key,.Animation)
    if entry==nil {fault={.Out_Of_Memory,skeleton};return}
    if fresh {
        entry.id,entry.retarget=id,{skeleton=skeleton,key=key}
        entry.retarget.stamp=content_retarget_stamp(app.assets,id,skeleton)
        if !content_animation_start(app,entry) {entry.retarget.failure=.Invalid;content_loaded(c,entry,false)}
    }
    asked:=entry.retarget.used!=c.frame
    entry.retarget.used=c.frame
    // A retarget that found no room is made again once there is, looked at once a frame.
    if asked && entry.failed && entry.retarget.failure==.Budget && entry.load==nil && content_retarget_fits(app,entry.retarget.need) {
        if !content_animation_start(app,entry) {entry.retarget.failure=.Invalid}
    }
    if content_animation_entry_pending(c,entry) {pending=true;return}
    if entry.failed {fault={entry.retarget.failure,entry.retarget.failed};return}
    if entry.retarget.direct {
        content=content_animation(app,id)
        pending=content==nil && content_animation_pending(app,id)
        return
    }
    return entry,false,{}
}

// The retarget of `id` onto `skeleton` the content holds, as it is: nil when it holds none, it is
// pending or failed, or it is the .anim itself. Neither starts it nor marks it used.
content_animation_retargeted :: proc "contextless" (app:^App,id,skeleton:base.Asset_Id) -> ^Content_Animation {
    c:=app.content
    if c==nil || id=={} || skeleton=={} {return nil}
    ref,known:=c.index[asset.animation_retarget_id(id,skeleton)]
    if !known || ref.kind!=.Animation {return nil}
    entry:=&c.animations[ref.index]
    if entry.failed || entry.retarget.direct || content_animation_entry_pending(c,entry) {return nil}
    return entry
}

// content_animation_retarget for whoever needs it now, as an API call or a test: it waits for the
// job that makes it and takes it, between frames.
content_animation_retarget_wait :: proc(app:^App,id,skeleton:base.Asset_Id) -> (content:^Content_Animation,fault:Content_Retarget_Fault) {
    pending:bool
    content,pending,fault=content_animation_retarget(app,id,skeleton)
    if !pending {return}
    if ref,known:=app.content.index[asset.animation_retarget_id(id,skeleton)];known {
        entry:=&app.content.animations[ref.index]
        if entry.load!=nil {
            jobs.wait(&app.jobs,jobs.OWNER,&entry.load.counter)
            content_animation_finish(app,entry,job=true)
        }
    }
    content,pending,fault=content_animation_retarget(app,id,skeleton)
    return
}

// What the files a retarget is made of are now: the .anim, the skeletons its clips name (its
// dependencies in the registry) and the skeleton it plays on, each as the registry lists it or
// missing.
content_retarget_stamp :: proc(a:^Assets,id,skeleton:base.Asset_Id) -> u64 {
    if a==nil {return 0}
    record :: proc(a:^Assets,stamp:u64,id:base.Asset_Id) -> u64 {
        found,present:=asset.registry_find(&a.registry,id)
        stamp:=base.hash_combine(base.hash_combine(stamp,id[0]),id[1])
        if !present {return base.hash_combine(stamp,0x6d697373696e67)}
        return base.hash_combine(base.hash_combine(base.hash_combine(stamp,u64(found.size)),u64(found.time)),found.content_hash)
    }
    stamp:=record(a,asset.ANIMATION_RETARGET_VERSION,id)
    stamp=record(a,stamp,skeleton)
    if found,present:=asset.registry_find(&a.registry,id);present {
        for needed in asset.registry_dependencies(&a.registry,found) {stamp=record(a,stamp,needed)}
    }
    return stamp
}

// What the library of an animation holds, its tables included.
content_animation_bytes :: proc "contextless" (content:^Content_Animation) -> int {
    bytes:=anim.library_resident_bytes(&content.lib)
    bytes+=len(content.roots)*size_of(asset.Animation_Root)+len(content.markers)*size_of(Content_Marker)
    bytes+=len(content.names)*asset.ANIMATION_NAME_CAPACITY+len(content.skeletons)*size_of(base.Asset_Id)
    return bytes+len(content.morphs)*size_of(Content_Morph)+len(content.fields)*size_of(Content_Field)
}

@(private="file")
content_retarget_budget :: proc "contextless" (app:^App) -> int {
    return app.retarget_budget if app.retarget_budget>0 else CONTENT_RETARGET_BUDGET
}

// Whether `bytes` fit within the budget, once the retargets idle long enough are evicted.
@(private="file")
content_retarget_fits :: proc(app:^App,bytes:int) -> bool {
    c:=app.content
    free:=content_retarget_budget(app)-c.retarget_bytes
    for &entry in c.animations {
        if content_retarget_idle(c,&entry) {free+=entry.retarget.bytes}
    }
    return bytes<=free
}

@(private="file")
content_retarget_idle :: proc "contextless" (c:^Content,entry:^Content_Animation) -> bool {
    return entry.retarget.skeleton!={} && entry.retarget.bytes>0 && entry.load==nil && c.frame-entry.retarget.used>=CONTENT_RETARGET_IDLE
}

// Makes room for `bytes` more for `taker`, evicting the other retargets idle longest; false,
// evicting none, when even all those idle would not make it. An evicted retarget leaves the
// content as one never asked for: asking for it again makes it again.
@(private="file")
content_retarget_room :: proc(app:^App,taker:^Content_Animation,bytes:int) -> bool {
    c:=app.content
    budget:=content_retarget_budget(app)
    if c.retarget_bytes+bytes<=budget {return true}
    if !content_retarget_fits(app,bytes+(taker.retarget.bytes if content_retarget_idle(c,taker) else 0)) {return false}
    for c.retarget_bytes+bytes>budget {
        oldest:=-1
        for &entry,i in c.animations {
            if &entry==taker || !content_retarget_idle(c,&entry) {continue}
            if oldest<0 || entry.retarget.used<c.animations[oldest].retarget.used {oldest=i}
        }
        if oldest<0 {return false}
        entry:=&c.animations[oldest]
        key:=entry.retarget.key
        content_animation_free(c,entry)
        entry^={}
        delete_key(&c.index,key)
        append(&c.free[.Animation],u32(oldest))
        c.stats.evicted+=1
        // What plays the evicted one finds it gone, as when content unloads.
        c.generations+=1
    }
    return true
}

// Takes what the ended load of a retarget made, into entry: true when it plays a library, which
// content_animation_finish then takes. A retarget whose clips bind by name plays the .anim; one
// that failed, or does not fit in the budget, plays nothing and frees what it held, whatever it
// was before.
@(private)
content_retarget_finish :: proc(app:^App,entry:^Content_Animation,load:^Content_Animation_Load,first:bool) -> bool {
    c:=app.content
    entry.retarget.direct,entry.retarget.failure,entry.retarget.failed,entry.retarget.need=load.retarget.direct,load.retarget.failure,load.retarget.failed,0
    if !load.ok && entry.retarget.failure==.None {entry.retarget.failure=.Invalid}
    if load.ok && !load.retarget.direct {
        bytes:=content_animation_bytes(&load.built)
        if content_retarget_room(app,entry,bytes-entry.retarget.bytes) {return true}
        entry.retarget.failure,entry.retarget.failed,entry.retarget.need=.Budget,entry.retarget.skeleton,bytes
    }
    content_animation_free(c,entry)
    ok:=load.ok && entry.retarget.failure==.None
    if first {content_loaded(c,entry,ok)} else {content_reloaded(c,entry);entry.failed=!ok}
    return false
}

// Whether the compression of the cache of a retarget holds the clips, names and markers of its
// .anim.
@(private)
content_retarget_cache_matches :: proc(source,cached:asset.Animation_View) -> bool {
    if len(cached.clips)!=len(source.clips) || len(cached.markers)!=len(source.markers) {return false}
    for clip,i in source.clips {
        other:=cached.clips[i]
        if other.name!=clip.name || other.first_marker!=clip.first_marker || other.marker_count!=clip.marker_count {return false}
    }
    for marker,i in source.markers {
        if cached.markers[i]!=marker {return false}
    }
    return true
}
