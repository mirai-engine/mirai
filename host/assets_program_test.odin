package host

import "core:fmt"
import "core:testing"
import "mirai:asset"
import "mirai:render"
import "mirai:render/abi"
import "mirai:rhi"
import "mirai:rhi/shared_device"
import "mirai:std/base"

// A masked material with a Surface program is cut by its mask map: its row
// takes that texture, or its base color map without one, though the program
// reads neither. A program that sets alpha on a masked material is an error
// of that material, which a blended one with it is not.
@(test)
a_masked_material_with_a_program_takes_its_mask_map_and_never_its_alpha :: proc(t:^testing.T) {
    device:=shared_device.take_or_skip(t,hardware_rt=false)
    if device==nil {return}
    r:=new(render.Renderer);defer free(r)
    if !render.renderer_init(r,{device=device,width=64,height=64}) {testing.expect(t,false,r.error);return}
    defer render.renderer_destroy(r)
    text:=fmt.tprintf(`{{"version":%d,"programs":[{{"id":1,"name":"Holes","domain":"Surface","size":0,"parameters":[],"coverage":true}},{{"id":2,"name":"Shade","domain":"Surface","size":0,"parameters":[]}}]}}`,abi.SHADER_CATALOG_VERSION)
    catalog,parsed:=render.program_catalog_parse(transmute([]u8)text)
    if !testing.expect(t,parsed,"the catalog is read") {return}
    render.program_catalog_destroy(&r.programs)
    r.programs=catalog
    r.programs.loaded=true

    root:=base.test_folder(t,"host-masks")
    if root=="" {return}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    pixels:[4*4*4]u8
    mask,color:=base.Asset_Id{7,1},base.Asset_Id{7,2}
    for id,i in ([2]base.Asset_Id{mask,color}) {
        testing.expect_value(t,asset.texture_save(fmt.tprintf("%s/%d.tex",root,i),&types,{id=id,width=4,height=4,layers=1,format=.RGBA8,mips=[][]u8{pixels[:]}}),asset.Error.None)
    }
    Case :: struct {program:string,mode:asset.Alpha_Mode,own:bool,error:bool}
    cases:=[]Case{{"Shade",.Mask,true,false},{"Shade",.Mask,false,false},{"Holes",.Mask,true,true},{"Holes",.Blend,false,false}}
    for c,i in cases {
        info:=asset.MATERIAL_DEFAULTS
        info.alpha_mode=c.mode
        asset.text_set(info.program[:],c.program)
        info.maps.base_color.texture=color
        if c.own {info.maps.mask.texture=mask}
        testing.expect_value(t,asset.material_save(fmt.tprintf("%s/m%d.mat",root,i),&types,{id={8,u64(i)},info=info}),asset.Error.None)
    }
    a:Assets
    if !testing.expect(t,assets_init(&a,{root=root,capacity=16,renderer=r})) {return}
    defer assets_destroy(&a)
    for c,i in cases {
        id:=base.Asset_Id{8,u64(i)}
        material:=assets_material(&a,id)
        if !testing.expectf(t,material!=nil && !material.failed,"%d loads",i) {continue}
        desc:=a.material_descs[material.row-1]
        masked_by:=assets_texture_image(&a,mask if c.own else color)
        testing.expectf(t,c.mode!=.Mask || masked_by!=nil && desc.textures[.Mask if c.own else .Base_Color]==masked_by.handle,"%d: its row takes the texture of its mask",i)
        cut:=false
        for e in a.errors {cut||=e.id==id && e.problem==.Coverage}
        testing.expectf(t,cut==c.error,"%d: %s on a %v material is an error: %v",i,c.program,c.mode,cut)
    }
    testing.expectf(t,rhi.device_validation_errors(device)==0,"validation: %s",rhi.device_validation_message(device))
}
