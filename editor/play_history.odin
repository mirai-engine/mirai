package editor

import "core:hash/xxhash"
import "core:math"
import "core:mem"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"

// The past of a run, to go back to any frame it played, look at it and play
// on from there. Each frame leaves what it gave its World (host.Frame_Record:
// its time and its input), a few hundred bytes; the World itself is copied
// whole only now and then, as keyframes. Going to a frame takes the keyframe
// before it and plays again the frames between, as the rollback of the
// network does, with Time.resimulating: the fixed ticks are deterministic from
// a copy, so what comes out is what played. A hash of the transforms each
// frame left says whether it was. What an edit changes between frames is in
// no frame: a paused run that plays on after one keeps its World as a
// keyframe first. The frames span Play_History.seconds and
// the keyframes fit in Play_History.megabytes: what their copies take is
// counted, and they are spaced so that those that fit span that time. A run
// on the network keeps none: its past belongs to its server.

@(storage)
Play_History :: struct {
    on:bool,
    seconds:f32,   // of the past a run keeps
    megabytes:int, // the copies of a run take at most
}
PLAY_HISTORY_DEFAULT :: Play_History{on=true,seconds=10,megabytes=256}

// Frames a second the ring of frames holds room for, at most.
@(private) HISTORY_FRAME_RATE :: 240

Run_History :: struct {
    frames:[]History_Frame,
    frame_first,frame_count:int, // the oldest frame kept and how many are
    serial:u64,      // of the newest frame kept: frames count from 1 since the run began
    at:u64,          // the frame the World is at; serial while it plays on
    keys:[]History_Slot,
    first,count:int, // the oldest keyframe and how many are kept
    limit:int,       // the keyframes the budget leaves; len(keys) until it is reached
    interval:u64,    // ticks from one keyframe to the next
    measured:bool,   // the first keyframe said what one takes, and so the interval
    budget:i64,      // bytes of the keyframes
    tracker:mem.Tracking_Allocator, // of every keyframe: what they take
    failed:bool,     // a copy found no memory: the ring keeps what it has
    fingerprint:u64, // of the tables of the World as the frame it is at left them
    held:bool,       // paused since the last frame: an edit may have changed it
}

History_Frame :: struct {
    record:host.Frame_Record,
    tick:u64,      // the World after the frame
    seconds:f64,
    hash:u64,      // of the transforms it left
}

History_Slot :: struct {
    world:rawptr, // nil: never used
    marks:[]core.Copy_Mark,
    frame:u64,    // it is the World after that frame
    tick:u64,
    seconds:f64,
    accumulator:f64, // Frame_Time.accumulator, which the copy does not carry
    edited:bool,     // made from an edit while paused: the frames before it do not lead to it
}

@(private)
history_bytes :: proc(h:^Run_History) -> i64 {return h.tracker.current_memory_allocated}

// The ring of a run, made the first time it keeps a frame; nil when the run
// keeps none.
@(private)
history_of :: proc(s:^Session,r:^Run) -> ^Run_History {
    if r.history!=nil {return r.history}
    p:=s.play_history
    if p==nil || !p.on || r.history_off {return nil}
    if network:=core.world_storage_of(run_ref(s,r),core.Network);network!=nil && network.role!=.Standalone {return nil}
    rate:=s.app.tick_dt>0?1/s.app.tick_dt:f32(core.SIMULATION_SETTINGS_DEFAULT.tick_rate)
    keys:=clamp(int(math.round(p.seconds*rate)),2,36000)
    frames:=clamp(int(math.ceil(p.seconds*HISTORY_FRAME_RATE)),2,HISTORY_FRAME_RATE*600)
    h,error:=new(Run_History,s.app.allocator)
    if error!=nil {r.history_off=true;return nil}
    h.keys,error=make([]History_Slot,keys,s.app.allocator)
    if error==nil {h.frames,error=make([]History_Frame,frames,s.app.allocator)}
    if error!=nil {
        delete(h.keys,s.app.allocator)
        free(h,s.app.allocator)
        r.history_off=true
        return nil
    }
    h.limit,h.interval=keys,1
    // A run paused before its first frame, as play.step pauses it, holds from then on.
    h.held=play_paused(s)
    h.budget=i64(max(p.megabytes,1))*1024*1024
    mem.tracking_allocator_init(&h.tracker,s.app.allocator,s.app.allocator)
    r.history=h
    return h
}

history_free :: proc(s:^Session,r:^Run) {
    h:=r.history
    if h==nil {return}
    for &slot in h.keys {history_slot_free(s,h,&slot)}
    delete(h.keys,s.app.allocator)
    delete(h.frames,s.app.allocator)
    mem.tracking_allocator_destroy(&h.tracker)
    free(h,s.app.allocator)
    r.history=nil
}

@(private)
history_slot_free :: proc(s:^Session,h:^Run_History,slot:^History_Slot) {
    if slot.world!=nil {
        s.info.destroy[.World](slot.world)
        mem.free(slot.world,mem.tracking_allocator(&h.tracker))
    }
    delete(slot.marks,mem.tracking_allocator(&h.tracker))
    slot^={}
}

// The n-th keyframe and the n-th frame kept, from the oldest.
@(private)
history_at :: proc "contextless" (h:^Run_History,n:int) -> ^History_Slot {return &h.keys[(h.first+n)%len(h.keys)]}
@(private)
history_frame_at :: proc "contextless" (h:^Run_History,n:int) -> ^History_Frame {return &h.frames[(h.frame_first+n)%len(h.frames)]}

// The frame of a serial while it is kept; nil otherwise.
@(private)
history_frame_of :: proc "contextless" (h:^Run_History,serial:u64) -> ^History_Frame {
    if h==nil || h.frame_count==0 || serial==0 || serial>h.serial || serial+u64(h.frame_count)<=h.serial {return nil}
    return history_frame_at(h,h.frame_count-1-int(h.serial-serial))
}

// A walk over the frames kept after a first one, up to a tick: what looking at
// the past plays, a sample every some ticks.
History_Walk :: struct {
    h:^Run_History,
    at:u64, // the serial of the frame it gave last
    to:u64,
    every:u64,
    last:u64, // the tick of the frame that was due last
}

history_walk :: proc "contextless" (h:^Run_History,first,to,every:u64) -> History_Walk {
    return {h=h,at=first,to=to,every=every,last=history_frame_of(h,first).tick}
}

// The next frame up to the tick to, and whether it is due: every ticks past
// the last that was.
history_walk_next :: proc "contextless" (walk:^History_Walk) -> (f:^History_Frame,due,more:bool) {
    walk.at+=1
    if walk.at>walk.h.serial {return}
    f=history_frame_of(walk.h,walk.at)
    if f==nil || f.tick>walk.to {return nil,false,false}
    due=f.tick>=walk.last+walk.every
    if due {walk.last=f.tick}
    return f,due,true
}

// What says that a replay left the World as the frame did.
@(private)
history_hash :: proc(w:core.World_Ref) -> u64 {
    h:=u64(0)
    if t:=core.world_storage_of(w,core.Time);t!=nil {h=t.tick}
    if transforms:=core.world_table_of(w,core.Transform);transforms!=nil && len(transforms.values)>0 {
        h~=xxhash.XXH3_64_default(mem.slice_to_bytes(transforms.values[:]))
    }
    return h
}

// What says that something wrote the World: the versions and layouts of its
// tables and the entities alive.
@(private)
history_fingerprint :: proc(w:core.World_Ref) -> u64 {
    key:=u64(core.world_entities(w).alive)
    for &info in w.info.tables {
        if info.place!=w.place {continue}
        t:=core.world_table_at(w,&info)
        key=base.hash_u64(key~t.version~base.hash_u64(t.layout))
    }
    return key
}

// Drops the past after the frame the World is at.
@(private)
history_branch :: proc(h:^Run_History) {
    if h.at>=h.serial {return}
    h.frame_count-=int(h.serial-h.at)
    h.serial=h.at
    for h.count>0 && history_at(h,h.count-1).frame>h.at {h.count-=1}
}

// Before a frame of a run that was paused: a World that an edit changed since
// the frame it is at becomes that frame, as a keyframe, and the past after it
// goes. Going back to it then finds the edit. Content that loaded again since
// that frame is an edit too, while the run plays or not: the frames before it
// read what it replaced.
history_before :: proc(s:^Session,r:^Run) {
    h:=r.history
    if h==nil {return}
    f:=history_frame_of(h,h.at)
    reloaded:=f!=nil && host.content_reloaded_after(s.app,f.record.content)
    if !reloaded && !h.held && r.owner==0 {return}
    if r.owner==0 && !play_paused(s) {h.held=false}
    w:=run_ref(s,r)
    fingerprint:=history_fingerprint(w)
    t:=core.world_storage_of(w,core.Time)
    if !reloaded && fingerprint==h.fingerprint || f==nil || t==nil {return}
    history_branch(h)
    if h.count>0 && history_at(h,h.count-1).frame==h.at {h.count-=1}
    history_key(s,h,w,t,edited=true)
    f.hash=history_hash(w)
    h.fingerprint=fingerprint
}

// The paused run plays on: from the newest frame it played, or with here from
// the frame it is at, without the past after it.
history_resume :: proc(s:^Session,r:^Run,here:bool) {
    h:=r.history
    if h==nil {return}
    if here {
        history_branch(h)
    } else if h.at<h.serial && !history_seek(s,r,h.serial).ok {
        notify(s,"No memory to go back to the newest frame: the game plays on from here")
    }
}

// Keeps the frame a run just played, with what it gave its World. A frame
// played after going back drops the past that was after it. Now and then the
// World is copied as a keyframe.
history_frame :: proc(s:^Session,r:^Run,record:^host.Frame_Record) {
    w:=run_ref(s,r)
    t:=core.world_storage_of(w,core.Time)
    if t==nil {return}
    h:=history_of(s,r)
    if h==nil {return}
    history_branch(h)
    if h.frame_count==len(h.frames) {
        h.frame_first=(h.frame_first+1)%len(h.frames)
        h.frame_count-=1
    }
    h.serial+=1
    h.at=h.serial
    h.frame_count+=1
    history_frame_at(h,h.frame_count-1)^={record=record^,tick=t.tick,seconds=t.seconds,hash=history_hash(w)}
    h.fingerprint=history_fingerprint(w)
    // A keyframe whose frames after it are gone leads nowhere but to itself.
    oldest:=h.serial+1-u64(h.frame_count)
    for h.count>1 && history_at(h,1).frame<=oldest {
        h.first=(h.first+1)%len(h.keys)
        h.count-=1
    }
    if h.count>0 && t.tick<history_at(h,h.count-1).tick+h.interval {return}
    history_key(s,h,w,t)
}

// Copies the World of a run as the keyframe of the frame it is at.
@(private)
history_key :: proc(s:^Session,h:^Run_History,w:core.World_Ref,t:^core.Time,edited:=false) {
    zone:base.Profile_Scope
    if host.profile_active(s.app) {zone=base.profile_begin(&s.app.profiler.profile,host.PROFILE_MAIN,"history")}
    defer base.profile_end(zone)
    allocator:=mem.tracking_allocator(&h.tracker)
    if h.count==h.limit {
        // The oldest copy becomes the newest: its World is copied over again.
        oldest:=history_at(h,0)
        h.first=(h.first+1)%len(h.keys)
        h.count-=1
        if next:=history_at(h,h.count);next!=oldest {next^,oldest^=oldest^,next^}
    }
    slot:=history_at(h,h.count)
    copied:=false
    {
        context.allocator=allocator
        if slot.world==nil {
            data,error:=mem.alloc(max(s.info.sizes[.World],1),max(s.info.aligns[.World],1),allocator)
            if error==nil && data!=nil {
                slot.world=data
                marks,marks_error:=make([]core.Copy_Mark,len(s.info.tables),allocator)
                slot.marks=marks
                if marks_error!=nil || !s.info.init[.World](data,allocator) {history_slot_free(s,h,slot)}
            }
        }
        if slot.world!=nil {
            copied=s.info.copy_changed!=nil?s.info.copy_changed(slot.world,w.data,slot.marks):s.info.copy(slot.world,w.data)
        }
    }
    if !copied {
        // Without memory for it the ring keeps what it has, smaller.
        history_slot_free(s,h,slot)
        h.limit=max(h.count,1)
        h.failed=true
        return
    }
    slot.frame,slot.tick,slot.seconds,slot.edited=h.serial,t.tick,t.seconds,edited
    if f:=core.world_storage_of(w,core.Frame_Time);f!=nil {slot.accumulator=f.accumulator}
    h.count+=1
    if !h.measured {
        // The keyframes the budget holds span the time asked for, spaced as they must.
        h.measured=true
        fit:=max(int(h.budget/max(history_bytes(h),1)),2)
        if fit<len(h.keys) {
            h.interval=u64((len(h.keys)+fit-1)/fit)
            h.limit=fit
        }
    }
    // Over the budget, the oldest copies go and their slots stay empty.
    for history_bytes(h)>h.budget && h.count>1 {
        history_slot_free(s,h,history_at(h,0))
        h.first=(h.first+1)%len(h.keys)
        h.count-=1
        h.limit=h.count
    }
}

// The frame that first reached the newest tick at or before tick, among
// those it can go to: where going to that tick lands. 0 when none.
history_frame_for :: proc(h:^Run_History,tick:u64) -> u64 {
    if h==nil || h.count==0 {return 0}
    oldest:=history_at(h,0).frame
    found:=u64(0)
    for serial:=h.serial;serial>=oldest && serial>0;serial-=1 {
        f:=history_frame_of(h,serial)
        if f==nil {break}
        if f.tick>tick {continue}
        if found!=0 && f.tick<history_frame_of(h,found).tick {break}
        found=serial
    }
    return found
}

// The frame that first reached a tick after tick; 0 when none.
history_frame_after :: proc(h:^Run_History,tick:u64) -> u64 {
    if h==nil || h.count==0 {return 0}
    for serial:=history_at(h,0).frame;serial<=h.serial;serial+=1 {
        if f:=history_frame_of(h,serial);f!=nil && f.tick>tick {return serial}
    }
    return 0
}

History_Seek :: struct {
    ok:bool,
    replayed:int,  // frames played again
    matches:bool,  // what they left is what played
}

// The World of a run goes to the frame serial: from where it is when that is
// at or before it and after the keyframe that leads there, or else from that
// keyframe, playing the frames between again. Not ok when the frame cannot
// be reached, or without memory for the copy: then the run stays as it was.
history_seek :: proc(s:^Session,r:^Run,serial:u64) -> (result:History_Seek) {
    h:=r.history
    if h==nil || h.count==0 || serial==0 || serial>h.serial {return}
    key:^History_Slot
    for n:=h.count-1;n>=0;n-=1 {
        if slot:=history_at(h,n);slot.frame<=serial {key=slot;break}
    }
    if key==nil {return}
    if (h.at<key.frame || h.at>serial) && !history_load(s,r,key) {return}
    w:=run_ref(s,r)
    kept:=extras_mark(s.app)
    for h.at<serial {
        f:=history_frame_of(h,h.at+1)
        if f==nil || !history_replay(s,r,f) {break}
        result.replayed+=1
    }
    extras_drop(s.app,kept)
    s.view_cut=true
    h.fingerprint=history_fingerprint(w)
    result.ok=h.at==serial
    reached:=history_frame_of(h,h.at)
    result.matches=result.ok && (reached==nil || reached.hash==history_hash(w))
    return
}

// The World of a run becomes the keyframe; false without memory, and then it stays as it was.
@(private)
history_load :: proc(s:^Session,r:^Run,key:^History_Slot) -> bool {
    h:=r.history
    w:=run_ref(s,r)
    if !host.app_world_replace(s.app,r.world,key.world) {return false}
    for n in 0..<h.count {
        if other:=history_at(h,n);other!=key {core.copy_marks_follow(w,key.marks,other.marks)}
    }
    core.copy_marks_follow(w,key.marks,key.marks)
    if f:=core.world_storage_of(w,core.Frame_Time);f!=nil {f.accumulator=key.accumulator}
    h.at=key.frame
    return true
}

// The frame after the one the World of a run is at, played again: no sound,
// no message to the network, no problem counted twice. What it adds to the
// frame of the editor is the caller's to drop.
@(private)
history_replay :: proc(s:^Session,r:^Run,f:^History_Frame) -> bool {
    t:=core.world_storage_of(run_ref(s,r),core.Time)
    if t==nil {return false}
    t.resimulating=true
    host.app_game_frame(s.app,r.world,host.ALL_PHASES-{.Render},replay=&f.record)
    t.resimulating=false
    r.history.at+=1
    return true
}

// The World of a run and where its history was, kept while its past is
// looked at on it and put back after.
History_Saved :: struct {
    world:rawptr,
    at:u64,
    edited:bool, // an edit since the frame it is at that the next frame keeps
    frame:core.Frame_Time,
    view_cut:bool,
}

// Copies the World of a run to look at its past and put it back after with
// history_restore; false without memory, and then nothing changed.
history_save :: proc(s:^Session,r:^Run) -> (saved:History_Saved,ok:bool) {
    h:=r.history
    if h==nil {return}
    allocator:=s.app.allocator
    context.allocator=allocator
    data,error:=mem.alloc(max(s.info.sizes[.World],1),max(s.info.aligns[.World],1),allocator)
    if error!=nil || data==nil {return}
    if !s.info.init[.World](data,allocator) || !s.info.copy(data,r.world) {
        s.info.destroy[.World](data)
        mem.free(data,allocator)
        return
    }
    w:=run_ref(s,r)
    saved={world=data,at=h.at,edited=history_fingerprint(w)!=h.fingerprint,view_cut=s.view_cut}
    if f:=core.world_storage_of(w,core.Frame_Time);f!=nil {saved.frame=f^}
    return saved,true
}

// Puts back the World history_save kept, without allocating.
history_restore :: proc(s:^Session,r:^Run,saved:^History_Saved) {
    if saved.world==nil {return}
    s.info.swap(r.world,saved.world)
    s.info.destroy[.World](saved.world)
    mem.free(saved.world,s.app.allocator)
    w:=run_ref(s,r)
    if f:=core.world_storage_of(w,core.Frame_Time);f!=nil {f^=saved.frame}
    h:=r.history
    h.at=saved.at
    // The swap gave the tables new versions: what says an edit is still there is kept as it was.
    h.fingerprint=history_fingerprint(w)
    if saved.edited {h.fingerprint=~h.fingerprint}
    s.view_cut=saved.view_cut
    saved.world=nil
}

// What the history of a run spans: the oldest tick it can go to and the
// newest it played, and their seconds.
history_span :: proc(h:^Run_History) -> (oldest,newest:u64,from,to:f64,ok:bool) {
    if h==nil || h.count==0 || h.frame_count==0 {return}
    a:=history_at(h,0)
    b:=history_frame_at(h,h.frame_count-1)
    return a.tick,b.tick,a.seconds,b.seconds,true
}
