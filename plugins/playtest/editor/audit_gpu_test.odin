package playtest_editor

import "core:fmt"
import "core:testing"
import "mirai:asset"
import "mirai:host"
import "mirai:render"
import "mirai:render/abi"
import "mirai:rhi/shared_device"
import "mirai:std/base"

// A material, or the material of a post-process layer, that names a program
// the shaders do not have in its domain draws without it and is flagged; one
// the shaders have, or a Surface material with a PostProcess program, is not.
@(test)
a_material_whose_program_the_shaders_lack_is_flagged :: proc(t:^testing.T) {
    device:=shared_device.take_or_skip(t,hardware_rt=false)
    if device==nil {return}
    r:=new(render.Renderer);defer free(r)
    if !render.renderer_init(r,{device=device,width=64,height=64}) {testing.expect(t,false,r.error);return}
    defer render.renderer_destroy(r)
    text:=fmt.tprintf(`{{"version":%d,"programs":[{{"id":1,"name":"Shade","domain":"Surface","size":0,"parameters":[]}},{{"id":2,"name":"Streaks","domain":"Postprocess","size":0,"parameters":[]}}]}}`,abi.SHADER_CATALOG_VERSION)
    catalog,parsed:=render.program_catalog_parse(transmute([]u8)text)
    if !testing.expect(t,parsed,"the catalog is read") {return}
    render.program_catalog_destroy(&r.programs)
    r.programs=catalog
    r.programs.loaded=true
    root:=base.test_folder(t,"playtest-programs")
    if root=="" {return}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    Case :: struct {program:string,domain:render.Program_Domain,missing:bool}
    cases:=[]Case{
        {"Shade",.Surface,false},{"Unbuilt",.Surface,true},{"Streaks",.Surface,false},{"",.Surface,false},
        {"Streaks",.Postprocess,false},{"Shade",.Postprocess,true},{"Unbuilt",.Postprocess,true},
    }
    for c,i in cases {
        info:=asset.MATERIAL_DEFAULTS
        asset.text_set(info.program[:],c.program)
        testing.expect_value(t,asset.material_save(fmt.tprintf("%s/m%d.mat",root,i),&types,{id={9,u64(i)},info=info}),asset.Error.None)
    }
    a:host.Assets
    if !testing.expect(t,host.assets_init(&a,{root=root,capacity=16,renderer=r})) {return}
    defer host.assets_destroy(&a)
    for c,i in cases {
        material:=host.assets_material(&a,{9,u64(i)})
        if !testing.expectf(t,material!=nil,"%d loads",i) {continue}
        testing.expectf(t,audit_program_missing(&a,material,c.domain)==c.missing,"%v: missing %v",c,!c.missing)
    }
}
