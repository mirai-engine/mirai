package editor

import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:editor/api"
import "mirai:std/base"

// What the world says without drawing: an entity off, hidden or without a
// mesh is not in the image, its box is where it is, and one that needs the
// cull of a frame asks for the GPU.
@(test)
render_inspect_says_why_an_entity_is_not_drawn_before_any_frame :: proc(t:^testing.T) {
    f:=new(Spatial_Fixture);defer free(f)
    if !spatial_open(t,f) {return}
    defer spatial_close(f)
    core.add(&f.w.disabled,f.crate,core.Disabled{})
    core.add(&f.w.hidden,f.boulder,{})
    core.settle(&f.info,&f.w,nil)
    method:=api.Method{params_id=Api_Render_Inspect_Params,result_id=Api_Render_Inspect_Result}
    params:Api_Render_Inspect_Params
    inspect :: proc(f:^Spatial_Fixture,method:^api.Method,params:^Api_Render_Inspect_Params,name:string) -> (result:Api_Render_Inspect_Result,call:api.Call) {
        base.text_set(params.entity[:],name)
        call=spatial_call(f,api_render_inspect,method,params,&result,`{"entity":"x"}`)
        call.params,call.result=nil,nil
        return
    }
    cases:=[?]struct{name:string,reason:Api_Render_Culled,mesh:bool,low,high:[3]f32}{
        {"Lamp",.No_Mesh,false,{3,2,0},{3,2,0}},
        {"Lid",.Disabled,true,{-0.5,3.5,-0.5},{0.5,4.5,0.5}}, // off with the crate above it
        {"Boulder",.Hidden,true,{19.5,4.5,-0.5},{20.5,5.5,0.5}},
    }
    for c in cases {
        result,call:=inspect(f,&method,&params,c.name)
        testing.expectf(t,!call.failed,"%s: %s",c.name,call.error.message)
        testing.expectf(t,result.culled_reason==c.reason && !result.visible && result.lod==-1 && result.has_mesh==c.mesh,"%s: %v",c.name,result)
        testing.expectf(t,near3(result.aabb_min,c.low) && near3(result.aabb_max,c.high),"%s: box %v %v",c.name,result.aabb_min,result.aabb_max)
        testing.expectf(t,result.name==c.name && result.id!=0,"%s: %s",c.name,result.name)
        testing.expectf(t,len(result.materials)==(c.mesh?1:0),"%s: %d materials",c.name,len(result.materials))
    }
    _,call:=inspect(f,&method,&params,"Floor")
    testing.expectf(t,call.failed && strings.contains(call.error.message,"--no-gpu"),"one on with a mesh needs the frames of the GPU: %s",call.error.message)
    _,call=inspect(f,&method,&params,"Nobody")
    testing.expect(t,call.failed && call.error.code==api.INVALID_PARAMS,call.error.message)
}
