package editor

import "core:fmt"
import "mirai:core"
import "mirai:editor/api"
import "mirai:engine/save"
import "mirai:host"
import "mirai:std/base"

// The saved games of the project through the agent API: the slots of the
// folder the game keeps them in (engine/save), read and deleted in Edit and
// in Play, and written and loaded in the game of the caller as the game asks
// for them, with a request of Save_Requests served by its loop.

API_SAVE_SLOTS :: 64
API_SAVE_FRAMES :: save.THUMBNAIL_WAIT+8 // frames a Play that goes on gets for a slot to be written with its thumbnail

Api_Save_Slot :: struct {
    name:[save.SLOT_CAPACITY]u8 `mirai:"text"`,
    kind:save.Slot_Kind,
    label:[save.LABEL_CAPACITY]u8 `mirai:"text,label=The one the game gave it"`,
    scene:base.Asset_Id `mirai:"label=The scene the world was; loading the slot makes it that scene again"`,
    scene_path:[API_PATH_BYTES]u8 `mirai:"text,label=Of that scene under the assets folder; empty when the assets do not have it"`,
    tick:u64 `mirai:"label=Of the world when it was written"`,
    seconds:f64 `mirai:"unit=s,label=Simulated by the world when it was written"`,
    played:f64 `mirai:"unit=s,label=Of play of its game"`,
    written:i64 `mirai:"unit=s,label=When it was written: since 1970 UTC"`,
    entities:u32,
    thumbnail:u32 `mirai:"label=Bytes of the PNG of the view of the player; 0: none"`,
    size:i64 `mirai:"label=Bytes of the file"`,
    version:u32 `mirai:"label=Of the save format of the engine that wrote it; 0: not a save"`,
    error:[256]u8 `mirai:"text,label=Why it does not load; empty when it loads"`,
}

Api_Save_List :: struct {
    folder:[API_PATH_BYTES]u8 `mirai:"text,label=Where the slots are kept"`,
    slots:[API_SAVE_SLOTS]Api_Save_Slot `mirai:"trim,label=By name; also those that do not load"`,
    more:bool `mirai:"label=The folder has more slots than these"`,
}

Api_Save_Slot_Params :: struct {
    slot:[save.SLOT_CAPACITY]u8 `mirai:"text,label=The name of the slot"`,
}

Api_Save_List_Params :: struct {
    slot:[save.SLOT_CAPACITY]u8 `mirai:"text,optional,label=Only the slot of this name; none: every slot"`,
}

Api_Save_Write_Params :: struct {
    slot:[save.SLOT_CAPACITY]u8 `mirai:"text,optional,label=The slot to write; empty: the oldest autosave for Autosave and checkpoint for Checkpoint"`,
    kind:save.Slot_Kind `mirai:"optional,label=Manual; Autosave or Checkpoint as the game writes them by itself"`,
    label:[save.LABEL_CAPACITY]u8 `mirai:"text,optional,label=Empty: the label of the game"`,
}

Api_Save_Deleted :: struct {
    slot:[save.SLOT_CAPACITY]u8 `mirai:"text"`,
}

@(private)
save_api_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="save.list",summary="The saved games of the project: each slot of the folder of its saves with what its header says without loading it, also those that do not load with why.",params=Api_Save_List_Params,result=Api_Save_List,flags={.Read_Only},run=api_save_list})
    api_register(s,st,{name="save.delete",summary="Deletes a saved game: through the game of the caller while it plays, as the game asks, otherwise its file.",params=Api_Save_Slot_Params,result=Api_Save_Deleted,flags={.Destructive},run=api_save_delete})
    api_register(s,st,{name="save.write",summary="Saves the game of the caller into a slot as the game asks for it and returns the slot once written. Needs Play.",params=Api_Save_Write_Params,result=Api_Save_Slot,run=api_save_write})
    api_register(s,st,{name="save.load",summary="Replaces the world of the game of the caller with a saved game as the game asks for it: its entities get new handles. Needs Play.",params=Api_Save_Slot_Params,result=Api_Save_Slot,flags={.Destructive},run=api_save_load})
}

// The state of the saves as the game has it, where it may have set its own
// folder; local, from the project, when the game has no save library.
@(private)
api_save_state :: proc(s:^Session,local:^save.Save_State) -> ^save.Save_State {
    if s.info!=nil && s.app.shared!=nil {
        if state:=core.world_storage_of(core.world_ref(s.app.shared,s.info,.Shared),save.Save_State);state!=nil {return state}
    }
    return local
}

@(private)
api_save_fail :: proc(call:^api.Call,slot:string,error:save.Error) {
    hint:=""
    #partial switch error {
    case .Not_Found:     hint="; save.list lists the slots there are"
    case .Corrupt,.Version: hint="; save.delete removes it"
    case .Invalid_Label: hint=fmt.tprintf(": use up to %d bytes",save.LABEL_CAPACITY-1)
    case .Failed:        hint="; engine.diagnostics has what the game reported"
    case .Write_Failed:  hint="; the folder of save.list must be writable"
    }
    code:=error==.Invalid_Slot || error==.Invalid_Label?api.INVALID_PARAMS:api.SERVER_ERROR
    api.call_failf(call,code,"%s: %s%s",slot if slot!="" else "the autosave",save.error_text(error),hint)
}

@(private)
api_save_slot_put :: proc(s:^Session,out:^Api_Save_Slot,slot:^save.Slot) {
    out.name=slot.name
    out.label=slot.label
    out.kind,out.scene=slot.kind,slot.scene
    if slot.scene!={} {base.text_set(out.scene_path[:],asset_path(s,slot.scene))}
    out.tick,out.seconds,out.played,out.written=slot.tick,slot.seconds,slot.played,slot.written
    out.entities,out.thumbnail,out.size,out.version=slot.entities,slot.thumbnail,slot.size,slot.version
    base.text_set(out.error[:],save.error_text(slot.error))
}

// The folder of the saves, or a failure that says why there is none.
@(private)
api_save_folder :: proc(s:^Session,call:^api.Call,state:^save.Save_State) -> (folder:string,ok:bool) {
    folder=save.folder(state,s.app)
    if folder=="" {api.call_fail(call,api.SERVER_ERROR,"The saves have no folder: they are kept in the user data folder of a project, so open the editor with --project");return}
    return folder,true
}

@(private)
api_save_list :: proc(s:^Session,call:^api.Call) {
    local:save.Save_State
    state:=api_save_state(s,&local)
    defer if state==&local {delete(local.folder,s.app.allocator)}
    folder,ok:=api_save_folder(s,call,state)
    if !ok {return}
    r:=api.call_result(call,Api_Save_List)
    base.text_set(r.folder[:],folder)
    if name:=base.text_get(api.call_params(call,Api_Save_List_Params).slot[:]);name!="" {
        slot:=save.slot_info(state,s.app,name)
        if slot.error==.Not_Found || slot.error==.Invalid_Slot {api_save_fail(call,name,slot.error);return}
        api_save_slot_put(s,&r.slots[0],&slot)
        return
    }
    found:=make([]save.Slot,API_SAVE_SLOTS+1,context.temp_allocator)
    count:=save.slots(state,s.app,found,all=true)
    r.more=count>API_SAVE_SLOTS
    for &slot,i in found[:min(count,API_SAVE_SLOTS)] {api_save_slot_put(s,&r.slots[i],&slot)}
}

@(private)
api_save_delete :: proc(s:^Session,call:^api.Call) {
    name:=base.text_get(api.call_params(call,Api_Save_Slot_Params).slot[:])
    local:save.Save_State
    state:=api_save_state(s,&local)
    defer if state==&local {delete(local.folder,s.app.allocator)}
    if _,ok:=api_save_folder(s,call,state);!ok {return}
    // A game that plays first writes what it has pending, which could bring the slot back.
    if r,own:=api_play_run(s,call);r!=nil && own && core.world_storage_of(run_ref(s,r),save.Save_Requests)!=nil {
        if _,asked:=api_save_ask(s,call,r,.Delete,name);!asked {return}
    } else if error:=save.delete_slot(state,s.app,name);error!=.None {
        api_save_fail(call,name,error)
        return
    }
    base.text_set(api.call_result(call,Api_Save_Deleted).slot[:],name)
}

@(private)
api_save_write :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Save_Write_Params)
    r,ok:=api_save_run(s,call)
    if !ok {return}
    name:=base.text_get(p.slot[:])
    if name=="" && p.kind==.Checkpoint {name=save.CHECKPOINT}
    result,asked:=api_save_ask(s,call,r,.Save,name,p.kind,base.text_get(p.label[:]))
    if asked {api_save_done(s,call,base.text_get(result.slot[:]))}
}

@(private)
api_save_load :: proc(s:^Session,call:^api.Call) {
    name:=base.text_get(api.call_params(call,Api_Save_Slot_Params).slot[:])
    r,ok:=api_save_run(s,call)
    if !ok {return}
    if _,asked:=api_save_ask(s,call,r,.Load,name);asked {api_save_done(s,call,name)}
}

// The game of the caller with the save library, or a failure that says why not.
@(private)
api_save_run :: proc(s:^Session,call:^api.Call) -> (r:^Run,ok:bool) {
    own:bool
    r,own=api_play_run(s,call)
    switch {
    case r==nil: api.call_fail(call,api.SERVER_ERROR,"No game is playing: start Play with play.start first; save.list and save.delete work without it")
    case !own: api_play_refused(call)
    case core.world_storage_of(run_ref(s,r),save.Save_Requests)==nil: api.call_fail(call,api.SERVER_ERROR,"The game of this project has no save library: generate the project again so that its world has engine/save")
    case: return r,true
    }
    return nil,false
}

// The header of the slot a request served, as the result of the call.
@(private)
api_save_done :: proc(s:^Session,call:^api.Call,name:string) {
    local:save.Save_State
    state:=api_save_state(s,&local)
    defer if state==&local {delete(local.folder,s.app.allocator)}
    slot:=save.slot_info(state,s.app,name)
    if slot.error!=.None {api_save_fail(call,name,slot.error);return}
    api_save_slot_put(s,api.call_result(call,Api_Save_Slot),&slot)
}

// Asks the game of a run what it would ask itself and advances it until the
// answer. The frame after serves the request; a slot is written a few frames
// later, with the thumbnail of the view in a Play that goes on. A run that
// advances only by steps (a paused Play, the run of a turn) gets one tick,
// and what it has to write is written then, without its thumbnail.
@(private)
api_save_ask :: proc(s:^Session,call:^api.Call,r:^Run,op:save.Op,slot:string,kind:=save.Slot_Kind.Manual,label:="") -> (result:save.Result,ok:bool) {
    owner:=r.owner
    if error:=save.request_error(op,slot,kind,label);error!=.None {
        api_save_fail(call,slot,error)
        return
    }
    save.request(core.world_storage_of(run_ref(s,r),save.Save_Requests),op,slot,kind,label)
    run:=r
    goes_on:=run_goes_on(s,run)
    for _ in 0..<(goes_on?API_SAVE_FRAMES:1) {
        if !goes_on {runs_tick_ask(s,owner,0,run.held_keys,run.held_buttons,{},{})}
        if api_frames(s,1,0)==0 {break}
        if run=run_find(s,owner);run==nil {
            api.call_fail(call,api.SERVER_ERROR,"The game stopped before it answered")
            return
        }
        if result,ok=api_save_answer(s,run,op,slot,kind);ok {break}
    }
    if !ok {
        save.writes_flush(host.app_world_storage(s.app,run.world,save.Save_Work),&s.app.jobs,core.world_storage_of(run_ref(s,run),save.Save_Results))
        if result,ok=api_save_answer(s,run,op,slot,kind);!ok {
            api.call_fail(call,api.SERVER_ERROR,"The game did not serve the request: its loop has no saves_serve; generate the project again")
            return
        }
    }
    if result.error!=.None {
        api_save_fail(call,base.text_get(result.slot[:]),result.error)
        return {},false
    }
    return result,true
}

// The Result of the game for a request, among those of the last frame.
@(private)
api_save_answer :: proc(s:^Session,r:^Run,op:save.Op,slot:string,kind:save.Slot_Kind) -> (result:save.Result,found:bool) {
    results:=core.world_storage_of(run_ref(s,r),save.Save_Results)
    if results==nil {return}
    for &answer in results.queue.items {
        if answer.op!=op {continue}
        if slot!="" && base.text_get(answer.slot[:])==slot {return answer,true}
        if slot=="" && answer.kind==kind {return answer,true}
    }
    return
}
