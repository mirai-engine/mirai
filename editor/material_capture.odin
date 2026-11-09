package editor

import "core:encoding/base64"
import "core:fmt"
import "core:math"
import "core:os"
import "mirai:asset"
import "mirai:editor/api"
import "mirai:host"
import gpu "mirai:render"
import "mirai:std/base"
import "mirai:std/geom"
import "mirai:std/serial"

// material.preview.capture: a material on the sphere of the studio, the one
// of its previews, as an image and as what it gives at each pixel. Each view
// says {min, max, mean, nan_count, uniform} of its components over the pixels
// the sphere covers; the image puts the views side by side, three per row, in
// the order of the result.

Material_View :: enum u8 {Lit,Albedo,Roughness,Metallic,Normal,Emission}
MATERIAL_VIEW_NAMES :: [Material_View]string{.Lit="Lit",.Albedo="Albedo",.Roughness="Roughness",.Metallic="Metallic",.Normal="Normal",.Emission="Emission"}
MATERIAL_CAPTURE_COLUMNS :: 3

Api_Material_Capture_Params :: struct {
    material:[256]u8 `mirai:"text,label=A material: its path under the assets folder or its id"`,
    views:bit_set[Material_View;u8] `mirai:"optional,label=Views to measure and show (all when empty): Lit is radiance by the exposure of the studio (1: a white surface facing the key light); Albedo the base color; Normal the length of the normal it writes; Emission nits. A program gives them as it writes them before the renderer clamps them"`,
    size:int `mirai:"optional,min=32,max=512,label=Pixels of a side of each view"`,
    path:[API_PATH_BYTES]u8 `mirai:"optional,text,label=PNG file to write (mirai image diff compares two); one under .mirai/captures when empty"`,
    wait:f32 `mirai:"optional,min=0,max=600,label=Seconds to wait for the previews to have the last change of a program: the stages they draw with; published before the rest"`,
}

@(private)
API_MATERIAL_CAPTURE_RESULT :: `{"type":"object","properties":{"content":{"type":"array","description":"The image, with the views three per row and NaN pixels in magenta, and the text of structuredContent"},"structuredContent":{"type":"object","description":"The material and the program it shows, the PNG written and, per view, min, max and mean of its components, nan_count and uniform over the pixels the sphere covers"},"isError":{"const":false}},"required":["content","isError"]}`

@(private)
material_capture_register :: proc(s:^Session,st:^Api_State) {
    defaults:=Api_Material_Capture_Params{size=256,wait=180}
    api_register(s,st,{name="material.preview.capture",summary="Draws a material on the sphere of the studio and returns the image with what it gives at each pixel by views, once the previews have the last change of its program.",params=Api_Material_Capture_Params,result_schema=API_MATERIAL_CAPTURE_RESULT,defaults=&defaults,flags={.Read_Only},mcp_content=true,run=api_material_capture})
}

// The shape previews draw a material on; captures draw it on the sphere.
material_shape_build :: proc(out:^[dynamic]gpu.Thumbnail_Vertex,shape:=Material_Shape.Sphere) {
    built:geom.Mesh_Buffer
    geom.mesh_buffer_init(&built,context.temp_allocator)
    switch shape {
    case .Sphere:   geom.sphere_build(&built,0.5,48,24)
    case .Cube:     geom.cube_build(&built)
    case .Cylinder: geom.cylinder_build(&built,0.5,1,48)
    case .Plane:    geom.plane_build(&built)
    }
    tangents:=make([][4]f32,len(built.indices),context.temp_allocator)
    geom.corner_tangents(built.positions[:],built.normals[:],built.uvs[:],built.indices[:],tangents)
    for index,at in built.indices {
        vertex:=gpu.Thumbnail_Vertex{position=built.positions[index],tint={1,1,1},tangent=tangents[at]}
        if int(index)<len(built.normals) {vertex.normal=built.normals[index]}
        if int(index)<len(built.uvs) {vertex.uv0=built.uvs[index]}
        append(out,vertex)
    }
}

// What a view says of its components over the covered pixels.
@(private)
View_Stats :: struct {
    components:int,
    min,max,sum:[3]f64,
    pixels,nan_count:int,
}

@(private)
view_components :: proc(view:Material_View) -> int {
    #partial switch view {
    case .Roughness,.Metallic,.Normal: return 1
    }
    return 3
}

// The components of a view at a pixel.
@(private)
view_value :: proc(view:Material_View,values:[gpu.Thumbnail_Target][][4]f32,pixel:int) -> (v:[3]f32) {
    switch view {
    case .Lit:       v=values[.Lit][pixel].xyz
    case .Albedo:    v=values[.Albedo][pixel].xyz
    case .Roughness: v.x=values[.Surface][pixel].x
    case .Metallic:  v.x=values[.Surface][pixel].y
    case .Normal:    v.x=values[.Normal][pixel].w
    case .Emission:  v=values[.Emission][pixel].xyz
    }
    return
}

// The color a view shows a pixel with: as the studio displays it, or its values made visible.
@(private)
view_color :: proc(view:Material_View,values:[gpu.Thumbnail_Target][][4]f32,display:[]u8,pixel:int) -> [4]u8 {
    if values[.Lit][pixel].w<0.5 {return {28,28,30,255}}
    encode :: proc(v:f32) -> u8 {
        c:=clamp(v,0,1)
        srgb:=c<=0.0031308?12.92*c:1.055*math.pow(c,1/2.4)-0.055
        return u8(clamp(srgb*255+0.5,0,255))
    }
    v:=view_value(view,values,pixel)
    for c in v {if !rpc_finite(c) {return {255,0,255,255}}}
    switch view {
    case .Lit:
        rgb:=display[pixel*4:][:3]
        return {rgb[0],rgb[1],rgb[2],255}
    case .Albedo:             return {encode(v.x),encode(v.y),encode(v.z),255}
    case .Roughness,.Metallic: g:=encode(v.x);return {g,g,g,255}
    case .Normal:
        n:=values[.Normal][pixel].xyz
        for c in n {if !rpc_finite(c) {return {255,0,255,255}}}
        length:=math.sqrt(n.x*n.x+n.y*n.y+n.z*n.z)
        if length>0 {n/=length}
        return {u8(clamp((n.x*0.5+0.5)*255,0,255)),u8(clamp((n.y*0.5+0.5)*255,0,255)),u8(clamp((n.z*0.5+0.5)*255,0,255)),255}
    case .Emission:
        // Nits over a hundred: a lamp shows white.
        e:=v/100
        return {encode(e.x/(1+e.x)),encode(e.y/(1+e.y)),encode(e.z/(1+e.z)),255}
    }
    return {}
}

@(private)
api_material_capture :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Material_Capture_Params)
    a:=s.app.assets
    if s.app==nil || s.app.renderer==nil || a==nil {api.call_fail(call,api.SERVER_ERROR,"material.preview.capture requires a GPU; start without --no-gpu");return}
    id,found:=asset_named(s,call,base.text_get(p.material[:]),asset.KIND_MATERIAL,".mat","a material")
    if !found {return}
    name:="material"
    if record,known:=asset.registry_find(&a.registry,id);known {name=asset_name(record.path)}
    path,writable:=api_capture_file(s,call,base.text_get(p.path[:]),fmt.tprintf("material-%s.png",name),call.allocator)
    if !writable {return}
    if ok,message:=programs_wait(s,f64(p.wait));!ok {api.call_fail(call,api.SERVER_ERROR,message);return}
    views:=p.views
    if views=={} {views={.Lit,.Albedo,.Roughness,.Metallic,.Normal,.Emission}}
    side:=u32(p.size)
    pixels_count:=int(side*side)
    vertices:=make([dynamic]gpu.Thumbnail_Vertex,context.temp_allocator)
    material_shape_build(&vertices)
    host.assets_material(a,id)
    host.assets_commit(a)
    materials:=[1]gpu.Material_Desc{host.assets_material_values(a,host.assets_material_row(a,id))}
    display:=make([]u8,pixels_count*4,context.temp_allocator)
    values:[gpu.Thumbnail_Target][][4]f32
    for &target in values {target=make([][4]f32,pixels_count,context.temp_allocator)}
    t:=s.thumbnails
    t.capture_renderer=s.app.renderer
    if !gpu.renderer_thumbnail_values(s.app.renderer,&t.capture,vertices[:],materials[:],side,side,display,values) {
        api.call_fail(call,api.SERVER_ERROR,"The material could not be drawn")
        return
    }
    // The stats of each view over the covered pixels.
    shown:=make([dynamic]Material_View,call.allocator)
    stats:[Material_View]View_Stats
    for view in Material_View {
        if view not_in views {continue}
        append(&shown,view)
        st:=&stats[view]
        st.components=view_components(view)
        st.min={math.F64_MAX,math.F64_MAX,math.F64_MAX}
        st.max={-math.F64_MAX,-math.F64_MAX,-math.F64_MAX}
        for pixel in 0..<pixels_count {
            if values[.Lit][pixel].w<0.5 {continue}
            v:=view_value(view,values,pixel)
            bad:=false
            for c in 0..<st.components {bad||=!rpc_finite(v[c])}
            if bad {st.nan_count+=1;continue}
            st.pixels+=1
            for c in 0..<st.components {
                st.min[c]=min(st.min[c],f64(v[c]))
                st.max[c]=max(st.max[c],f64(v[c]))
                st.sum[c]+=f64(v[c])
            }
        }
    }
    // The image: the views in rows of three.
    columns:=min(len(shown),MATERIAL_CAPTURE_COLUMNS)
    rows:=(len(shown)+columns-1)/columns
    width,height:=columns*int(side),rows*int(side)
    image:=make([]u8,width*height*4,s.app.allocator)
    for view,cell in shown {
        x0,y0:=(cell%columns)*int(side),(cell/columns)*int(side)
        for y in 0..<int(side) {
            for x in 0..<int(side) {
                color:=view_color(view,values,display,y*int(side)+x)
                copy(image[((y0+y)*width+x0+x)*4:][:4],color[:])
            }
        }
    }
    if problem:=api_png_write(s,path,image,width,height);problem!="" {api.call_fail(call,api.SERVER_ERROR,problem);return}
    // What it shows, as text for the agent and as structured content.
    info,_:=material_file(s,id)
    program:=base.text_get(info.program[:])
    report:serial.Writer
    serial.writer_init(&report,0,context.temp_allocator)
    names:=MATERIAL_VIEW_NAMES
    asset_named_write(s,&report,"material",id)
    api.write_text(&report,"program",program)
    api.write_text(&report,"image",path)
    api.write_int(&report,"size",i64(side))
    api.write_key(&report,"views");serial.write_u8(&report,'[')
    for view,i in shown {
        st:=&stats[view]
        if i>0 {serial.write_u8(&report,',')}
        serial.write_u8(&report,'{')
        api.write_text(&report,"view",names[view],true)
        api.write_int(&report,"pixels",i64(st.pixels))
        api.write_int(&report,"nan_count",i64(st.nan_count))
        low,high,mean:[3]f32
        uniform:=st.pixels>0
        for c in 0..<st.components {
            if st.pixels>0 {low[c],high[c],mean[c]=f32(st.min[c]),f32(st.max[c]),f32(st.sum[c]/f64(st.pixels))}
            uniform&&=st.max[c]-st.min[c]<=1e-3*max(1,abs(st.max[c]))
        }
        api.write_numbers(&report,"min",low[:st.components])
        api.write_numbers(&report,"max",high[:st.components])
        api.write_numbers(&report,"mean",mean[:st.components])
        api.write_bool(&report,"uniform",uniform)
        serial.write_u8(&report,'}')
    }
    serial.write_u8(&report,']')
    serial.write_u8(&report,'}')
    data,error:=os.read_entire_file(path,context.temp_allocator)
    if error!=nil {api.call_fail(call,api.SERVER_ERROR,"The capture could not be read");return}
    encoded,encode_error:=base64.encode(data,allocator=context.temp_allocator)
    if encode_error!=nil {api.call_fail(call,api.INTERNAL_ERROR,"The capture could not be encoded");return}
    stats_text:=string(serial.writer_bytes(&report))
    if len(encoded)+2*len(stats_text)+256>call.server.max_response {api.call_fail(call,api.SERVER_ERROR,"The capture exceeds the response limit: ask for fewer views or a smaller size");return}
    serial.text_write_raw(call.out,`{"content":[{"type":"image","data":"`)
    serial.text_write_raw(call.out,encoded)
    serial.text_write_raw(call.out,`","mimeType":"image/png"},{"type":"text","text":`)
    serial.text_write_string(call.out,stats_text)
    serial.text_write_raw(call.out,`}],"structuredContent":`)
    serial.text_write_raw(call.out,stats_text)
    serial.text_write_raw(call.out,`,"isError":false}`)
}
