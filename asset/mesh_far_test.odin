package asset

import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:fmt"
import "core:testing"
import "mirai:std/base"
import mm "mirai:std/math"

// A welded bumpy sheet of side cells, one unit a cell, as a static mesh: its
// DAG has levels to cut.
@(private="file")
far_sheet :: proc(side:int) -> (g:Mesh_Geometry) {
    vertices:=make([dynamic]Vertex,context.temp_allocator)
    indices:=make([dynamic]u32,context.temp_allocator)
    for z in 0..=side {
        for x in 0..=side {
            y:=0.3*math.sin(f32(x)*0.4)*math.cos(f32(z)*0.3)
            append(&vertices,Vertex{position={f32(x),y,f32(z)},normal=mm.normal_pack({0,1,0}),uv={f32(x),f32(z)}/f32(side),color=0xffffffff,tangent=mm.tangent_pack({1,0,0},1)})
        }
    }
    row:=u32(side+1)
    for z in 0..<u32(side) {
        for x in 0..<u32(side) {
            a:=z*row+x
            append(&indices,a,a+row,a+1,a+1,a+row,a+row+1)
        }
    }
    built:=mesh_build_dag({vertices=vertices[:]},indices[:],&g,context.temp_allocator)
    assert(built)
    return
}

@(private="file")
far_triangles :: proc(g:Mesh_Geometry,level:int) -> (count:u32) {return g.levels[level].triangle_count}

@(test)
a_far_mesh_joins_its_parts_in_one_slot_with_the_mean_of_their_materials :: proc(t:^testing.T) {
    sheet:=far_sheet(48)
    red:=Far_Material{base_color={1,0,0,1},roughness=0.8}
    glowing:=Far_Material{base_color={0,0,1,1},roughness=0.2,metallic=1,emission={50,100,200}}
    parts:=[2]Far_Part{{geometry=sheet,placement=linalg.MATRIX4F32_IDENTITY},{geometry=sheet,placement=linalg.matrix4_translate_f32({100,0,0})}}
    parts[0].materials[0]=red
    parts[1].materials[0]=glowing
    far:Mesh_Geometry
    testing.expect(t,mesh_build_far(parts[:],0,&far,context.temp_allocator))
    testing.expect(t,far.flags>={.Has_Colors,.Has_Surface} && len(far.surfaces)==len(far.vertices) && len(far.colors)==len(far.vertices))
    // At error 0 both parts are whole, and its own levels go coarser.
    testing.expect_value(t,far_triangles(far,0),2*far_triangles(sheet,0))
    testing.expect(t,len(far.levels)>1 && far.levels[len(far.levels)-1].triangle_count<far_triangles(far,0)/8)
    testing.expect(t,far.ray_errors[0]>0,"rays trace it coarser far away")
    pure:=0
    for c in far.clusters {
        testing.expect_value(t,cluster_slot(c),u32(0))
        // Every vertex of a cluster carries the same.
        first:=c.vertex_first
        for k in 1..<cluster_vertex_count(c) {
            testing.expect(t,far.colors[first+k]==far.colors[first] && far.surfaces[first+k]==far.surfaces[first])
        }
        // The mean of a cluster weighs each part alike in all it keeps: red
        // says how much of it is the first part, blue how much the second.
        color:=mm.rgba8_unpack(far.colors[first])
        surface:=far.surfaces[first]
        roughness,metallic:=f32(surface.material&255)/255,f32(surface.material>>8&255)/255
        emission:=mm.rgb9e5_unpack(surface.emission)
        testing.expectf(t,abs(color.r+color.b-1)<0.01 && color.g==0,"%v",color)
        testing.expectf(t,abs(roughness-(0.8*color.r+0.2*color.b))<0.01 && abs(metallic-color.b)<0.01,"%v %v %v",color,roughness,metallic)
        testing.expectf(t,linalg.length(emission-[3]f32{50,100,200}*color.b)<2+color.b*2,"%v %v",color,emission)
        if color.r==1 || color.b==1 {pure+=1}
    }
    testing.expect(t,pure>len(far.clusters)/2,"most clusters cover one part")
    // It round trips as any mesh.
    types:Types;types_init(&types);defer types_destroy(&types)
    path:=fmt.tprintf("%s/far.mesh",base.test_folder(t,"asset"))
    testing.expect_value(t,mesh_save(path,&types,{id={0xfa,0x12},geometry=far}),Error.None)
    a:Asset
    testing.expect_value(t,asset_load(&a,path),Error.None)
    defer asset_close(&a)
    view,error:=mesh_view(&a,&types)
    testing.expect_value(t,error,Error.None)
    testing.expect(t,.Has_Surface in view.info.flags && len(view.surfaces)==len(far.surfaces) && view.surfaces[0]==far.surfaces[0])
    // Its pages and their blocks are those it was made with, and its streams come back from them whole.
    testing.expect(t,far.root_page>0 && view.root_page==far.root_page && len(view.pages)==len(far.pages))
    testing.expect(t,string(view.page_data)==string(far.page_data),"the file holds the blocks made in memory")
    for s,at in far.surfaces {
        if view.surfaces[at]!=s || view.colors[at]!=far.colors[at] || view.vertices[at]!=far.vertices[at] {
            testing.expectf(t,false,"vertex %d of the far mesh comes back otherwise",at)
            break
        }
    }
}

// A far mesh made in memory whose root is not every page carries the blocks
// of its pages, as a file holds them, so the renderer streams it: each
// decodes to what its clusters own, and the coarsest cut rays trace is of
// the root alone. One small enough for its root to be all of it has none.
@(test)
a_far_mesh_made_in_memory_carries_the_blocks_of_its_pages :: proc(t:^testing.T) {
    sheet:=far_sheet(48)
    parts:=[2]Far_Part{{geometry=sheet,placement=linalg.MATRIX4F32_IDENTITY},{geometry=sheet,placement=linalg.matrix4_translate_f32({100,0,0})}}
    far:Mesh_Geometry
    if !testing.expect(t,mesh_build_far(parts[:],0,&far,context.temp_allocator)) {return}
    if !testing.expect(t,far.root_page>0 && len(far.page_data)>0,"its root is not every page, and it carries their blocks") {return}
    info:=Mesh_Info{vertex_count=u32(len(far.vertices)),cluster_count=u32(len(far.clusters)),bounds_min=far.bounds_min,bounds_max=far.bounds_max,flags=far.flags,position_step=far.position_step,uv_step=far.uv_step,uv1_step=far.uv1_step,ray_errors=far.ray_errors,root_page=far.root_page}
    for c in far.clusters {info.triangle_count+=cluster_triangle_count(c)}
    testing.expect(t,mesh_check({info=&info,geometry=far}),"it holds together as a mesh of a file")
    block:=make([]u32,MESH_PAGE_WORDS,context.temp_allocator)
    want:=make([]u32,MESH_PAGE_WORDS,context.temp_allocator)
    decoder:Decoder
    testing.expect_value(t,decoder_init(&decoder),Error.None)
    defer decoder_destroy(&decoder)
    scratch:=make([]u8,MESH_PAGE_SCRATCH_BYTES,context.temp_allocator)
    for page,at in far.pages {
        if !testing.expectf(t,page.data_bytes>0 && mesh_page_decode(far.flags,page,far.page_data,scratch,block,&decoder.stream),"page %d decodes",at) {return}
        testing.expect(t,mesh_page_gather(far,page,want))
        testing.expectf(t,string(mem.slice_to_bytes(block[:page.words]))==string(mem.slice_to_bytes(want[:page.words])),"page %d decodes to its clusters",at)
    }
    coarsest:f32
    for e in far.ray_errors {if e>0 {coarsest=e}}
    testing.expect(t,coarsest>0)
    for c in far.clusters {
        if c.error<=coarsest && c.parent_error>coarsest {testing.expect(t,c.page>=far.root_page,"the coarsest ray cut is of the root")}
    }
    small:Mesh_Geometry
    tiny:=[1]Far_Part{{geometry=far_sheet(4),placement=linalg.MATRIX4F32_IDENTITY}}
    testing.expect(t,mesh_build_far(tiny[:],0,&small,context.temp_allocator))
    testing.expect(t,small.root_page==0 && len(small.page_data)==0,"a small one is root whole, without blocks")
}

@(test)
a_far_mesh_cuts_its_parts_at_its_error_in_the_space_of_the_section :: proc(t:^testing.T) {
    sheet:=far_sheet(48)
    // The cut at an error a little past that of level 1 of the sheet.
    error:=sheet.levels[1].error*1.01
    parts:=[1]Far_Part{{geometry=sheet,placement=linalg.MATRIX4F32_IDENTITY}}
    far:Mesh_Geometry
    testing.expect(t,mesh_build_far(parts[:],error,&far,context.temp_allocator))
    testing.expect(t,far_triangles(far,0)<far_triangles(sheet,0))
    // Its first level is no finer than the cut it is made of.
    testing.expect_value(t,far.levels[0].error,error)
    for c in far.clusters {testing.expect(t,c.error>=error && c.parent_error>c.error)}
    // Scaled up four times, the same error is a finer cut of it.
    parts[0].placement=linalg.matrix4_scale_f32({4,4,4})
    near:Mesh_Geometry
    testing.expect(t,mesh_build_far(parts[:],error,&near,context.temp_allocator))
    testing.expect(t,far_triangles(near,0)>far_triangles(far,0))
}

@(test)
a_far_mesh_keeps_the_faces_of_a_mirrored_part_facing_out :: proc(t:^testing.T) {
    sheet:=far_sheet(8)
    parts:=[1]Far_Part{{geometry=sheet,placement=linalg.matrix4_scale_f32({-1,1,1})}}
    far:Mesh_Geometry
    testing.expect(t,mesh_build_far(parts[:],0,&far,context.temp_allocator))
    up:=0
    level:=far.levels[0]
    for c in far.clusters[level.first_cluster:][:level.cluster_count] {
        for k in 0..<cluster_triangle_count(c) {
            corners:=cluster_triangle(far.triangles,c,k)
            a,b,d:=cluster_position(far,c,corners[0]),cluster_position(far,c,corners[1]),cluster_position(far,c,corners[2])
            face:=linalg.cross(b-a,d-a)
            normal:=mm.normal_unpack(far.vertices[c.vertex_first+corners[0]].normal)
            if linalg.dot(face,normal)>0 {up+=1}
        }
    }
    testing.expect_value(t,u32(up),level.triangle_count)
}

@(test)
a_far_material_reads_its_maps_where_the_vertex_points :: proc(t:^testing.T) {
    // A 2x1 texture, red left and green right, sRGB: the far mesh keeps it linear.
    pixels:=[8]u8{255,0,0,255,0,255,0,255}
    texels:=[][4]f32{{1,0,0,1},{0,1,0,1}}
    texture:=Far_Texture{2,1,texels}
    info:=Material_Info{base_color={1,1,1},opacity=1,roughness=1,metallic=0,ior=1.5}
    info.maps.base_color={scale={1,1}}
    m:=far_material(info,&texture,nil,nil)
    sheet:=far_sheet(48)
    parts:=[1]Far_Part{{geometry=sheet,placement=linalg.MATRIX4F32_IDENTITY}}
    parts[0].materials[0]=m
    far:Mesh_Geometry
    testing.expect(t,mesh_build_far(parts[:],0,&far,context.temp_allocator))
    level:=far.levels[0]
    left,right:=0,0
    for c in far.clusters[level.first_cluster:][:level.cluster_count] {
        color:=mm.rgba8_unpack(far.colors[c.vertex_first])
        low,high:=cluster_box(far.position_step,c)
        switch {
        case high.x<24: left+=1;testing.expect(t,color.r==1 && color.g==0,"left of u 0.5 is red")
        case low.x>=24 && high.x<48: right+=1;testing.expect(t,color.g==1 && color.r==0,"right of it is green")
        }
    }
    testing.expect(t,left>0 && right>0)
    // A texture level decodes as the far mesh reads it.
    view:=Texture_View{info=&Texture_Info{width=2,height=1,mip_count=1,format=.RGBA8,flags={.Srgb},layers=1},mips=[]Texture_Mip{{2,1,0,8}},texels=pixels[:]}
    decoded,ok:=far_texture(view,context.temp_allocator)
    testing.expect(t,ok && decoded.width==2 && decoded.height==1 && decoded.texels[0]==[4]f32{1,0,0,1} && decoded.texels[1]==[4]f32{0,1,0,1})
}

// A material program keeps its textures in parameters: the one that names a
// base color is the base color of a far mesh; a normal map is not.
@(test)
a_far_mesh_finds_the_base_color_of_a_program_by_its_parameters :: proc(t:^testing.T) {
    parameters:=make([]Material_Parameter,3,context.temp_allocator)
    text_set(parameters[0].name[:],"t2_Norm1");parameters[0].kind,parameters[0].texture=.Texture,{1,1}
    text_set(parameters[1].name[:],"t0_Dif");parameters[1].kind,parameters[1].texture=.Texture,{2,2}
    text_set(parameters[2].name[:],"Tint");parameters[2].kind=.Float
    testing.expect_value(t,far_base_parameter(parameters),base_id(2))
    text_set(parameters[0].name[:],"BaseColor")
    testing.expect_value(t,far_base_parameter(parameters),base_id(1))
    testing.expect_value(t,far_base_parameter(parameters[2:]),base_id(0))
}

@(private="file")
base_id :: proc(n:u64) -> base.Asset_Id {return {n,n}}

// The leaves of a card a masked material covers little are left out of a far mesh.
@(test)
a_far_mesh_leaves_out_what_a_masked_material_does_not_cover :: proc(t:^testing.T) {
    sheet:=far_sheet(16)
    clear_texture:=Far_Texture{1,1,[][4]f32{{1,1,1,0.1}}}
    info:=Material_Info{base_color={1,1,1},opacity=1,alpha_mode=.Mask,alpha_cutoff=0.5,ior=1.5}
    info.maps.base_color={scale={1,1}}
    parts:=[1]Far_Part{{geometry=sheet,placement=linalg.MATRIX4F32_IDENTITY}}
    parts[0].materials[0]=far_material(info,&clear_texture,nil,nil)
    far:Mesh_Geometry
    testing.expect(t,!mesh_build_far(parts[:],0,&far,context.temp_allocator),"nothing is covered: no far mesh")
    covered:=Far_Texture{1,1,[][4]f32{{1,1,1,0.9}}}
    parts[0].materials[0]=far_material(info,&covered,nil,nil)
    testing.expect(t,mesh_build_far(parts[:],0,&far,context.temp_allocator) && far.levels[0].triangle_count==sheet.levels[0].triangle_count)
}
