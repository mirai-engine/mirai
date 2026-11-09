package animation_editor

import "base:runtime"
import "core:fmt"
import "core:strings"
import "mirai:editor/api"
import "mirai:editor"
import "mirai:std/base"
import "mirai:std/serial"

Authoring_Write_Result :: struct {
    asset:base.Asset_Id,
    path:[1024]u8 `mirai:"text"`,
    dry_run:bool `mirai:"optional,label=Only on a dry run: nothing was written"`,
    replaced:bool `mirai:"optional,label=The path already held one: it was replaced whole, keeping its id"`,
}
Authoring_Page :: struct($T:typeid) {index:u32,value:T}

authoring_method_register :: proc(s:^editor.Session,desc:editor.Api_Method,T:typeid,info:^runtime.Type_Info) {
    desc:=desc
    desc.result,desc.result_info,desc.writes_result=T,info,true
    editor.api_method_register(s,desc)
}

@(private)
// Fails a call with where (path), what (code), what was expected and found,
// and how to correct it: fix, or the usual correction of the code.
authoring_failure :: proc(call:^api.Call,path,code,expected,actual,message:string,rpc_code:=api.INVALID_PARAMS,fix:="") {
    writer:serial.Writer
    serial.writer_init(&writer,256,call.allocator)
    defer serial.writer_destroy(&writer)
    serial.text_write_raw(&writer,"{")
    api.write_text(&writer,"path",path,true)
    api.write_text(&writer,"code",code)
    api.write_text(&writer,"expected",expected)
    api.write_text(&writer,"actual",actual)
    api.write_text(&writer,"fix",fix if fix!="" else authoring_fix(code,path,expected))
    serial.text_write_raw(&writer,"}")
    api.call_fail(call,rpc_code,message,string(serial.writer_bytes(&writer)))
}

// The usual correction of an error code.
@(private)
authoring_fix :: proc(code,path,expected:string) -> string {
    switch code {
    case "Runtime_Required": return "Start Play or Simulation, or use animation.preview on a copy"
    case "Missing_Entity": return "Use an id from scene.inspect"
    case "Missing_Component": return "Assign playback first with animation.play"
    case "Invalid_Asset","Missing_Asset": return "Use the path or the id of an asset of the expected kind"
    case "Already_Exists": return "Choose another path, or edit the existing asset"
    case "Missing_Part": return "Detect the body with skeleton.body.detect or set the part with skeleton.body.set"
    case "Missing_Clip": return "Use a clip name from animation.asset.inspect with section clips"
    }
    return fmt.tprintf("Pass %s at %s",expected,path)
}
