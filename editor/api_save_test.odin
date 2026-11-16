package editor

import "core:os"
import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:editor/api"
import "mirai:engine/save"
import "mirai:host"
import "mirai:std/base"

@(private)
@(test_world,host="Save_Api_Shared")
Save_Api_World :: struct {using world:Test_World}
@(private)
Save_Api_Shared :: struct {state:save.Save_State}

@(private="file")
save_api_call :: proc(s:^Session,run:proc(s:^Session,call:^api.Call),params:^$P,$R:typeid) -> (call:api.Call,result:^R) {
    method:=new(api.Method,context.temp_allocator)
    method^={params_id=P,result_id=R}
    result=new(R,context.temp_allocator)
    call={method=method,params=params,result=result,allocator=context.temp_allocator}
    run(s,&call)
    return
}

// In Edit the slots of the folder of the game read and delete, those that
// do not load with why; writing and loading ask for Play.
@(test)
save_methods_read_and_delete_slots_in_edit_and_ask_for_play_to_write :: proc(t:^testing.T) {
    dir:=base.test_folder(t,"save-api")
    if dir=="" {return}
    info,described:=test_info(t,Save_Api_World)
    if !described {return}
    defer test_info_destroy(&info)
    shared:Save_Api_Shared
    app:=host.App{info=&info,allocator=context.allocator,shared=&shared}
    save.folder_set(&shared.state,app.allocator,dir)
    defer delete(shared.state.folder)
    session:=Session{info=&info,app=&app}
    broken:=strings.concatenate({dir,"/broken",save.EXTENSION},context.temp_allocator)
    testing.expect(t,os.write_entire_file(broken,transmute([]u8)string("not a save"))==nil)
    testing.expect(t,os.write_entire_file(strings.concatenate({dir,"/notes.txt"},context.temp_allocator),{1})==nil)

    every:Api_Save_List_Params
    _,list:=save_api_call(&session,api_save_list,&every,Api_Save_List)
    testing.expect_value(t,base.text_get(list.folder[:]),dir)
    testing.expect_value(t,base.text_get(list.slots[0].name[:]),"broken")
    testing.expect_value(t,base.text_get(list.slots[0].error[:]),save.error_text(.Corrupt))
    testing.expect(t,list.slots[1].name[0]==0 && !list.more)

    params:Api_Save_Slot_Params
    base.text_set(params.slot[:],"broken")
    one:Api_Save_List_Params
    base.text_set(one.slot[:],"broken")
    call,_:=save_api_call(&session,api_save_list,&one,Api_Save_List)
    testing.expect(t,!call.failed)
    base.text_set(one.slot[:],"con")
    call,_=save_api_call(&session,api_save_list,&one,Api_Save_List)
    testing.expect(t,call.failed && call.error.code==api.INVALID_PARAMS)

    base.text_set(params.slot[:],"broken")
    deleted:^Api_Save_Deleted
    call,deleted=save_api_call(&session,api_save_delete,&params,Api_Save_Deleted)
    testing.expect(t,!call.failed && base.text_get(deleted.slot[:])=="broken" && !os.exists(broken))
    call,_=save_api_call(&session,api_save_delete,&params,Api_Save_Deleted)
    testing.expect(t,call.failed && strings.contains(call.error.message,"save.list"))

    call,_=save_api_call(&session,api_save_load,&params,Api_Save_Slot)
    testing.expect(t,call.failed && strings.contains(call.error.message,"play.start"))
    write:Api_Save_Write_Params
    call,_=save_api_call(&session,api_save_write,&write,Api_Save_Slot)
    testing.expect(t,call.failed && strings.contains(call.error.message,"play.start"))
}
