package mirai_render

import "core:testing"
import "mirai:rhi"

@(test)
gpu_geometry_thumbnail_evaluates_uv1_maps_and_custom_surface :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f,64,64,DEFAULT_SETTINGS) {return}
    defer fixture_destroy(&f)
    renderer,device:=f.renderer,f.device
    state:Thumbnail_GPU;defer thumbnail_destroy(device,&state)
    positions:=[6]Vec3{{-1,0,-1},{1,0,1},{1,0,-1},{-1,0,-1},{-1,0,1},{1,0,1}}
    vertices:[6]Thumbnail_Vertex
    for position,index in positions {vertices[index]={position=position,normal={0,1,0},uv0={0.25,0.5},uv1={0.75,0.5},tint={1,1,1},material=0}}
    image:=[8]u8{255,0,0,255,0,255,0,255}
    texture,loaded:=texture_add(renderer,{pixels=image[:],width=2,height=1,srgb=true,name="thumbnail UV sets"})
    testing.expect(t,loaded,renderer.error);if !loaded {return}
    material:=DEFAULT_MATERIAL
    material.specular_factor=0
    material.textures[.Base_Color]=texture
    material.maps.base_color.uv_set=1
    materials:=[1]Material_Desc{material}
    pixels:=make([]u8,64*64*4);defer delete(pixels)
    ok:=renderer_thumbnail(renderer,&state,vertices[:],materials[:],64,64,pixels)
    testing.expect(t,ok,rhi.device_error(device));if !ok {return}
    golden_check(pixels,.RGBA8_Unorm)
    center:=(32*64+32)*4
    testing.expectf(t,pixels[center+1]>pixels[center]+70,"UV1 texture must be green: %v",pixels[center:center+4])
    testing.expect(t,pixels[3]==0,"thumbnail background is transparent")
    buffers:=[3]rhi.Buffer{state.vertices,state.materials,state.frame}
    targets:=[2]rhi.Texture{state.color,state.depth}
    ocean:=program_find(renderer,"Ocean",.Surface)
    if !testing.expect(t,ocean!=nil) {return}
    material.program_id=ocean.id
    material.ior=1.333
    material.custom_params[0]={0.02,0.03,1,0.7}
    material.custom_params[1]={1,0.8,0,0}
    materials[0]=material
    ok=renderer_thumbnail(renderer,&state,vertices[:],materials[:],64,64,pixels)
    testing.expect(t,ok,rhi.device_error(device));if !ok {return}
    golden_check(pixels,.RGBA8_Unorm)
    testing.expectf(t,pixels[center+2]>pixels[center+1]+70,"custom Surface must replace the green PBR map with blue: %v",pixels[center:center+4])
    testing.expect_value(t,buffers,[3]rhi.Buffer{state.vertices,state.materials,state.frame})
    testing.expect_value(t,targets,[2]rhi.Texture{state.color,state.depth})
    testing.expect_value(t,renderer.frame,u64(0))
    testing.expect(t,!renderer.has_previous,"preview must preserve scene camera histories")
    testing.expectf(t,rhi.device_validation_errors(device)==0,"validation: %s",rhi.device_validation_message(device))
}

@(test)
gpu_material_capture_reads_what_a_material_gives_at_each_pixel :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f,64,64,DEFAULT_SETTINGS,hardware_rt=false) {return}
    defer fixture_destroy(&f)
    renderer,device:=f.renderer,f.device
    state:Thumbnail_Values_GPU;defer thumbnail_values_destroy(device,&state)
    positions:=[6]Vec3{{-1,0,-1},{1,0,1},{1,0,-1},{-1,0,-1},{-1,0,1},{1,0,1}}
    vertices:[6]Thumbnail_Vertex
    for position,index in positions {vertices[index]={position=position,normal={0,1,0},tint={1,1,1},tangent={1,0,0,1}}}
    material:=DEFAULT_MATERIAL
    material.base_color={0.25,0.5,0.75}
    material.roughness,material.metallic=0.3,1
    material.emission={120,0,0}
    materials:=[1]Material_Desc{material}
    SIDE :: 32
    pixels:=make([]u8,SIDE*SIDE*4);defer delete(pixels)
    values:[Thumbnail_Target][][4]f32
    for &target in values {target=make([][4]f32,SIDE*SIDE)}
    defer for target in values {delete(target)}
    ok:=renderer_thumbnail_values(renderer,&state,vertices[:],materials[:],SIDE,SIDE,pixels,values)
    testing.expect(t,ok,rhi.device_error(device));if !ok {return}
    center:=SIDE/2*SIDE+SIDE/2
    near :: proc(a,b:f32) -> bool {return abs(a-b)<=1e-3*max(1,abs(b))}
    testing.expect_value(t,values[.Lit][center].w,f32(1))
    testing.expect_value(t,values[.Lit][0].w,f32(0))
    testing.expectf(t,near(values[.Albedo][center].x,0.25) && near(values[.Albedo][center].y,0.5) && near(values[.Albedo][center].z,0.75),"albedo %v",values[.Albedo][center])
    testing.expectf(t,near(values[.Surface][center].x,0.3) && near(values[.Surface][center].y,1),"roughness and metallic %v",values[.Surface][center])
    testing.expectf(t,near(values[.Normal][center].w,1) && values[.Normal][center].y>0.99,"normal %v",values[.Normal][center])
    testing.expectf(t,near(values[.Emission][center].x,120),"emission in nits %v",values[.Emission][center])
    testing.expect(t,pixels[center*4+3]==255,"the image is drawn with the values")
    // A relative emission adds its own value to what the studio shows.
    material.emission={}
    materials[0]=material
    ok=renderer_thumbnail_values(renderer,&state,vertices[:],materials[:],SIDE,SIDE,pixels,values)
    testing.expect(t,ok,rhi.device_error(device));if !ok {return}
    unlit:=values[.Lit][center].x
    material.emission,material.emission_mode={0.5,0,0},.Relative
    materials[0]=material
    ok=renderer_thumbnail_values(renderer,&state,vertices[:],materials[:],SIDE,SIDE,pixels,values)
    testing.expect(t,ok,rhi.device_error(device));if !ok {return}
    testing.expectf(t,near(values[.Lit][center].x-unlit,0.5),"a relative emission of 0.5 shows %v",values[.Lit][center].x-unlit)
    material.emission={}
    // A program's values are as it writes them.
    ocean:=program_find(renderer,"Ocean",.Surface)
    if !testing.expect(t,ocean!=nil) {return}
    material.program_id=ocean.id
    material.custom_params[0]={0.02,0.03,1,0.7}
    material.custom_params[1]={1,0.8,0,0}
    materials[0]=material
    ok=renderer_thumbnail_values(renderer,&state,vertices[:],materials[:],SIDE,SIDE,pixels,values)
    testing.expect(t,ok,rhi.device_error(device));if !ok {return}
    testing.expectf(t,values[.Albedo][center].z>values[.Albedo][center].x && !near(values[.Albedo][center].x,0.25),"the program gives the base color %v",values[.Albedo][center])
    testing.expectf(t,near(values[.Normal][center].w,1),"Ocean writes a normalized normal %v",values[.Normal][center])
    testing.expectf(t,rhi.device_validation_errors(device)==0,"validation: %s",rhi.device_validation_message(device))
}

@(test)
gpu_thumbnail_frames_a_given_box_and_an_image_of_the_table_takes_new_pixels :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f,64,64,DEFAULT_SETTINGS,hardware_rt=false) {return}
    defer fixture_destroy(&f)
    renderer,device:=f.renderer,f.device
    state:Thumbnail_GPU;defer thumbnail_destroy(device,&state)
    positions:=[6]Vec3{{-1,0,-1},{1,0,1},{1,0,-1},{-1,0,-1},{-1,0,1},{1,0,1}}
    vertices:[6]Thumbnail_Vertex
    for position,index in positions {vertices[index]={position=position,normal={0,1,0},tint={1,1,1}}}
    materials:=[1]Material_Desc{DEFAULT_MATERIAL}
    pixels:=make([]u8,64*64*4);defer delete(pixels)
    covered :: proc(pixels:[]u8) -> (count:int) {
        for i:=3;i<len(pixels);i+=4 {if pixels[i]>0 {count+=1}}
        return
    }
    testing.expect(t,renderer_thumbnail(renderer,&state,vertices[:],materials[:],64,64,pixels),rhi.device_error(device))
    alone:=covered(pixels)
    testing.expect(t,renderer_thumbnail(renderer,&state,vertices[:],materials[:],64,64,pixels,{{-10,-10,-10},{10,10,10}}),rhi.device_error(device))
    framed:=covered(pixels)
    testing.expectf(t,alone>500 && framed>0 && framed*20<alone,"the quad fills the view alone and is small in a box ten times larger: %d %d",alone,framed)
    // A box inside the triangles changes nothing; an inverted one is no box.
    testing.expect(t,renderer_thumbnail(renderer,&state,vertices[:],materials[:],64,64,pixels,{{-0.1,0,-0.1},{0.1,0,0.1}}))
    testing.expect_value(t,covered(pixels),alone)
    testing.expect(t,renderer_thumbnail(renderer,&state,vertices[:],materials[:],64,64,pixels,{{10,10,10},{-10,-10,-10}}))
    testing.expect_value(t,covered(pixels),alone)

    first,second,read:[4*4*4]u8
    for i in 0..<len(first) {first[i]=u8(i);second[i]=u8(255-i)}
    KEY :: u64(0x70726576696577)
    handle,added:=texture_image(renderer,KEY,first[:],4,4,"preview")
    testing.expect(t,added && handle!=0,renderer.error)
    if !added {return}
    count:=texture_count(renderer)
    testing.expect(t,rhi.texture_read(device,renderer.textures.textures[handle-1],read[:]))
    testing.expect(t,read==first)
    again,replaced:=texture_image(renderer,KEY,second[:],4,4,"preview")
    testing.expect(t,replaced && again==handle && texture_count(renderer)==count)
    testing.expect(t,rhi.texture_read(device,renderer.textures.textures[handle-1],read[:]))
    testing.expect(t,read==second)
    _,resized:=texture_image(renderer,KEY,second[:],2,2,"preview")
    testing.expect(t,!resized)
    _,short:=texture_image(renderer,KEY+1,second[:8],4,4,"preview")
    testing.expect(t,!short && texture_count(renderer)==count)
    testing.expectf(t,rhi.device_validation_errors(device)==0,"validation: %s",rhi.device_validation_message(device))
}
