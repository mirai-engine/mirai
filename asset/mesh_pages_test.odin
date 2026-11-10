package asset

import "core:math"
import "core:mem"
import "core:fmt"
import "core:testing"
import mm "mirai:std/math"
import "mirai:std/serial"
import "mirai:std/base"

// A welded bumpy sheet of side cells with colors and a uv1 of its own, as a
// static mesh: its DAG has levels enough for pages out of the root.
@(private="file")
page_sheet :: proc(side:int,height:f32=0.3,skinned:=false) -> (g:Mesh_Geometry) {
    vertices:=make([dynamic]Vertex,context.temp_allocator)
    indices:=make([dynamic]u32,context.temp_allocator)
    for z in 0..=side {
        for x in 0..=side {
            y:=height*math.sin(f32(x)*0.4)*math.cos(f32(z)*0.3)
            uv:=[2]f32{f32(x),f32(z)}/f32(side)
            color:=mm.rgba8_pack({uv.x,uv.y,0.5,1})
            append(&vertices,Vertex{position={f32(x),y,f32(z)},normal=mm.normal_pack({0,1,0}),uv=uv,uv1=uv.yx*2,color=color,tangent=mm.tangent_pack({1,0,0},1)})
        }
    }
    row:=u32(side+1)
    for z in 0..<u32(side) {
        for x in 0..<u32(side) {
            a:=z*row+x
            append(&indices,a,a+row,a+1,a+1,a+row,a+row+1)
        }
    }
    skin:[]Skin_Vertex
    if skinned {
        skin=make([]Skin_Vertex,len(vertices),context.temp_allocator)
        for &s in skin {s.weights[0]=255}
    }
    built:=mesh_build_dag({vertices=vertices[:],skin=skin,flags={.Has_Colors,.Has_Uv1}},indices[:],&g,context.temp_allocator)
    assert(built)
    return
}

@(private="file")
Group_Key :: struct {level:u32,parent:[4]f32,parent_error:f32}

// The level of each cluster, the row of levels that holds it.
@(private="file")
cluster_levels :: proc(g:Mesh_Geometry) -> []u32 {
    levels:=make([]u32,len(g.clusters),context.temp_allocator)
    for level,l in g.levels {
        for at in level.first_cluster..<level.first_cluster+level.cluster_count {levels[at]=u32(l)}
    }
    return levels
}

@(test)
pages_hold_whole_groups_of_one_level_in_order :: proc(t:^testing.T) {
    g:=page_sheet(160)
    testing.expect(t,len(g.levels)>3 && len(g.pages)>len(g.levels),"the sheet makes several pages")
    levels:=cluster_levels(g)
    clusters,vertices,words:u32
    for page,at in g.pages {
        testing.expect(t,page.first_cluster==clusters && page.first_vertex==vertices && page.first_triangle==words && page.cluster_count>0)
        testing.expect(t,page.words<=MESH_PAGE_WORDS && page.words==mesh_page_layout(g.flags,page.vertex_count,page.triangle_words).words)
        testing.expect(t,at==0 || page.level>=g.pages[at-1].level)
        held:u32
        for c,k in g.clusters[page.first_cluster:][:page.cluster_count] {
            testing.expect(t,c.page==u32(at) && levels[page.first_cluster+u32(k)]==page.level)
            testing.expect(t,c.vertex_first>=page.first_vertex && c.vertex_first+cluster_vertex_count(c)<=page.first_vertex+page.vertex_count)
            held+=cluster_triangle_words(c)
        }
        testing.expect_value(t,held,page.triangle_words)
        clusters+=page.cluster_count
        vertices+=page.vertex_count
        words+=page.triangle_words
    }
    testing.expect(t,int(clusters)==len(g.clusters) && int(vertices)==len(g.vertices) && int(words)==len(g.triangles))
    // The clusters that share a parent are one group: one page holds it.
    page_of:=make(map[Group_Key]u32,context.temp_allocator)
    for c,at in g.clusters {
        key:=Group_Key{levels[at],c.parent,c.parent_error}
        if page,known:=page_of[key];known {
            if !testing.expectf(t,page==c.page,"a group of level %d spans pages %d and %d",levels[at],page,c.page) {return}
        } else {page_of[key]=c.page}
    }
    // The children of a cluster are the group whose parent is the cluster.
    for c,at in g.clusters {
        if levels[at]==0 {
            testing.expect_value(t,c.child_page,MESH_PAGE_NONE)
            continue
        }
        children,known:=page_of[{levels[at]-1,c.lod,c.error}]
        if !testing.expectf(t,known && c.child_page==children,"cluster %d names page %d for children in page %d",at,c.child_page,children) {return}
    }
}

@(test)
the_root_holds_the_coarsest_levels_and_what_nothing_replaces :: proc(t:^testing.T) {
    g:=page_sheet(160)
    testing.expect(t,g.root_page>0 && int(g.root_page)<len(g.pages),"part of the sheet is out of the root")
    root:=g.pages[g.root_page]
    last:=g.levels[len(g.levels)-1]
    testing.expect(t,root.first_cluster<=last.first_cluster,"the coarsest level is in the root")
    for c in g.clusters {
        if c.parent_error==CLUSTER_ROOT {testing.expect(t,c.page>=g.root_page,"what nothing replaces is in the root")}
    }
    // Past the coarsest level, the root takes whole levels within its words,
    // unless what nothing replaces starts it.
    starts_with_root:=false
    for c in g.clusters[root.first_cluster:][:root.cluster_count] {if c.parent_error==CLUSTER_ROOT {starts_with_root=true}}
    finer:u32
    for page in g.pages[g.root_page:] {if page.level<u32(len(g.levels)-1) {finer+=page.words}}
    testing.expect(t,starts_with_root || finer<=MESH_ROOT_WORDS && (root.level==0 || g.pages[g.root_page-1].level<root.level))

    // Skinned or of whole levels, a mesh is root whole.
    skinned:=page_sheet(160,skinned=true)
    testing.expect(t,len(skinned.pages)>1 && skinned.root_page==0)
    vertices,indices:=test_grid(4000,context.temp_allocator)
    coarse:=make([dynamic]u32,context.temp_allocator)
    for q:=0;q<len(indices)/6;q+=2 {append(&coarse,..indices[q*6:][:6])}
    all:=make([dynamic]u32,context.temp_allocator)
    append(&all,..indices)
    append(&all,..coarse[:])
    whole:=[2]Level_Source{{0,u32(len(indices)),0},{u32(len(indices)),u32(len(coarse)),0.1}}
    levels:Mesh_Geometry
    testing.expect(t,mesh_build({vertices=vertices},all[:],whole[:],&levels,context.temp_allocator))
    testing.expect(t,.Levels in levels.flags && len(levels.pages)>2 && levels.root_page==0)
    for c in levels.clusters {testing.expect_value(t,c.child_page,MESH_PAGE_NONE)}
}

@(test)
the_coarsest_ray_cut_takes_only_root_clusters :: proc(t:^testing.T) {
    for height in ([]f32{0.3,0}) {
        g:=page_sheet(160,height)
        if g.root_page==0 {continue}
        coarsest:f32
        for e in g.ray_errors {if e>0 {coarsest=e}}
        testing.expectf(t,coarsest>0,"a sheet %v high has a ray cut",height)
        triangles:u32
        for c in g.clusters {
            if c.error<=coarsest && coarsest<c.parent_error {
                if !testing.expectf(t,c.page>=g.root_page,"the cut at %v takes cluster of page %d, out of the root",coarsest,c.page) {return}
                triangles+=cluster_triangle_count(c)
            }
        }
        testing.expect(t,triangles>0)
    }
}

@(test)
pages_round_trip_through_a_file_and_decode_one_by_one :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    g:=page_sheet(160)
    path:=fmt.tprintf("%s/pages.mesh",base.test_folder(t,"asset"))
    testing.expect_value(t,mesh_save(path,&types,{id={0x9a,0x6e},geometry=g}),Error.None)
    a:Asset
    testing.expect_value(t,asset_load(&a,path),Error.None)
    defer asset_close(&a)
    view,error:=mesh_view(&a,&types)
    if !testing.expect_value(t,error,Error.None) {return}
    testing.expect(t,mesh_check_indices(view))
    same :: proc(a,b:[]$T) -> bool {return len(a)==len(b) && mem.compare(mem.slice_to_bytes(a),mem.slice_to_bytes(b))==0}
    testing.expect(t,same(view.clusters,g.clusters) && same(view.levels,g.levels) && same(view.vertices,g.vertices) && same(view.triangles,g.triangles))
    testing.expect(t,same(view.uv1s,g.uv1s) && same(view.colors,g.colors) && len(view.uv1s)>0 && len(view.colors)>0)
    testing.expect(t,view.root_page==g.root_page && view.info.root_page==g.root_page && view.ray_errors==g.ray_errors && len(view.pages)==len(g.pages))
    block:=make([]u32,MESH_PAGE_WORDS,context.temp_allocator)
    want:=make([]u32,MESH_PAGE_WORDS,context.temp_allocator)
    decoder:Decoder
    testing.expect_value(t,decoder_init(&decoder),Error.None)
    defer decoder_destroy(&decoder)
    scratch:=make([]u8,MESH_PAGE_SCRATCH_BYTES,context.temp_allocator)
    for page,at in view.pages {
        written:=g.pages[at]
        written.data_offset,written.data_bytes,written.coded_bytes=page.data_offset,page.data_bytes,page.coded_bytes
        testing.expect(t,page==written && page.data_bytes>0)
        testing.expect(t,mesh_page_decode(view.flags,page,view.page_data,scratch,block,&decoder.lz) && mesh_page_gather(g,g.pages[at],want))
        layout:=mesh_page_layout(view.flags,page.vertex_count,page.triangle_words)
        testing.expect(t,same(block[:page.words],want[:page.words]))
        testing.expect(t,same(block[layout.vertices:layout.uv1s],mem.slice_data_cast([]u32,g.vertices[page.first_vertex:][:page.vertex_count])))
        testing.expect(t,same(block[layout.colors:layout.surfaces],g.colors[page.first_vertex:][:page.vertex_count]))
        testing.expect(t,same(block[layout.triangles:layout.words],g.triangles[page.first_triangle:][:page.triangle_words]))
    }
    testing.expect(t,!mesh_page_decode(view.flags,view.pages[0],view.page_data[:view.pages[0].data_bytes-1],scratch,block,&decoder.lz),"a short block is refused")
}

@(test)
pages_out_of_their_ranges_are_refused :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    good:=Mesh_Desc{geometry=page_sheet(160)}
    refuse :: proc(t:^testing.T,types:^Types,desc:Mesh_Desc,loc:=#caller_location) {
        doc:Document
        testing.expect_value(t,mesh_document(&doc,types,desc),Error.Invalid,loc)
    }
    pages :: proc(desc:^Mesh_Desc) -> []Mesh_Page {
        copied:=make([]Mesh_Page,len(desc.geometry.pages),context.temp_allocator)
        copy(copied,desc.geometry.pages)
        desc.geometry.pages=copied
        return copied
    }
    clusters :: proc(desc:^Mesh_Desc) -> []Cluster {
        copied:=make([]Cluster,len(desc.geometry.clusters),context.temp_allocator)
        copy(copied,desc.geometry.clusters)
        desc.geometry.clusters=copied
        return copied
    }
    bad:=good;pages(&bad)[1].first_vertex+=1
    refuse(t,&types,bad)
    bad=good;pages(&bad)[1].words+=1
    refuse(t,&types,bad)
    bad=good;pages(&bad)[0].level=1
    refuse(t,&types,bad)
    bad=good;bad.geometry.pages=good.geometry.pages[1:]
    refuse(t,&types,bad)
    bad=good;bad.geometry.root_page=u32(len(good.geometry.pages))
    refuse(t,&types,bad)
    bad=good;bad.geometry.ray_errors={}
    refuse(t,&types,bad)
    last:=len(good.geometry.clusters)-1
    bad=good;clusters(&bad)[last].child_page=good.geometry.clusters[last].page
    refuse(t,&types,bad)
    bad=good;clusters(&bad)[0].page=1
    refuse(t,&types,bad)

    // In a file, a block out of page_data or shorter than its words.
    for field in ([]string{"data_offset","data_bytes","coded_bytes"}) {
        doc:Document
        testing.expect_value(t,mesh_document(&doc,&types,good),Error.None)
        defer document_destroy(&doc)
        table,_:=document_table(&doc,"pages")
        value:=u64(1<<30) if field=="data_offset" else 1
        testing.expect_value(t,serial.value_set(&doc.schema,doc.tables[table].columns[0].type,document_cell(&doc,table,0,1),field,value),serial.Path_Error.None)
        w:serial.Writer;serial.writer_init(&w);defer serial.writer_destroy(&w)
        testing.expect_value(t,document_write(&doc,&w),Error.None)
        a:Asset
        testing.expect_value(t,asset_open(&a,serial.writer_bytes(&w)),Error.None)
        defer asset_close(&a)
        _,error:=mesh_view(&a,&types)
        testing.expectf(t,error==.Corrupt,"a page with %s changed is %v",field,error)
    }
}
