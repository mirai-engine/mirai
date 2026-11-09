package asset

import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:testing"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"

// A grid of quads: rows*columns*4 vertices and rows*columns*6 indices.
@(private)
test_grid :: proc(cells:int,allocator:=context.allocator) -> (vertices:[]Vertex,indices:[]u32) {
    vertices=make([]Vertex,cells*4,allocator)
    indices=make([]u32,cells*6,allocator)
    for cell in 0..<cells {
        x,z:=f32(cell%64),f32(cell/64)
        for corner in 0..<4 {
            dx,dz:=f32(corner&1),f32(corner>>1)
            vertices[cell*4+corner]={position={x+dx,0,z+dz},normal=mm.normal_pack({0,1,0}),uv={dx,dz},color=0xffffffff,uv1={dx,dz},tangent=mm.tangent_pack({1,0,0},1)}
        }
        base:=u32(cell*4)
        quad:=[6]u32{base,base+1,base+2,base+2,base+1,base+3}
        copy(indices[cell*6:],quad[:])
    }
    return
}

// The geometry of vertices and indices in one level, in the temporary allocator.
@(private)
test_geometry :: proc(vertices:[]Vertex,indices:[]u32,skin:[]Skin_Vertex=nil,flags:=Mesh_Flags{},morphs:[]Morph_Target=nil,deltas:[]Morph_Delta=nil,loc:=#caller_location) -> (g:Mesh_Geometry) {
    built:=mesh_build({vertices=vertices,skin=skin,flags=flags,morphs=morphs,morph_deltas=deltas},indices,nil,&g,context.temp_allocator)
    assert(built,"the test geometry builds",loc)
    return
}

@(private="file")
inside :: proc(a:^Asset,p:rawptr) -> bool {
    return uintptr(p)>=uintptr(raw_data(a.file)) && uintptr(p)<uintptr(raw_data(a.file))+uintptr(len(a.file))
}

@(test)
mesh_round_trips_its_clusters_compressed :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    vertices,indices:=test_grid(8);defer delete(vertices);defer delete(indices)
    for &vertex,i in vertices {vertex.material=u32(i/16)}
    skin:=make([]Skin_Vertex,len(vertices));defer delete(skin)
    for &influence in skin {influence={joints={0,1,0,0,0,0,0,0},weights=skin_weights_quantize({0.75,0.25,0,0,0,0,0,0})}}
    slots:=[2]Material_Slot{{id=1,material={5,5}},{id=7,material={6,6}}}
    text_set(slots[0].label[:],"model.gltf:Soil")
    text_set(slots[1].label[:],"model.gltf:Leaf")
    joints:=[2]Rig_Joint{{0,1},{1,1}}
    points:=[4][3]f32{{0,0,0},{1,0,0},{0,1,0},{0,0,1}}
    hull_indices:=[6]u32{0,1,2,0,2,3}
    colliders:=[2]Collider{{kind=.Box,size={1,2,3},rotation=1},{kind=.Mesh,rotation=1,point_count=4,index_count=6}}
    source:Import_Info
    text_set(source.source[:],"models/model.gltf")
    text_set(source.name[:],"Plant")
    text_set(source.importer[:],"gltf")
    source.index,source.source_size,source.importer_version=2,1234,3
    g:=test_geometry(vertices,indices,skin,{.Has_Uv1})
    desc:=Mesh_Desc{id={0xaaaa,0xbbbb},geometry=g,slots=slots[:],skeleton={7,7},joints=joints[:],colliders=colliders[:],collision_points=points[:],collision_indices=hull_indices[:],source=&source}
    path:=test_path("grid.mesh")
    defer os.remove(path)
    testing.expect_value(t,mesh_save(path,&types,desc),Error.None)

    a:Asset
    testing.expect_value(t,asset_load(&a,path),Error.None)
    defer asset_close(&a)
    testing.expect(t,a.blob.header.kind==KIND_MESH && a.blob.header.kind_version==MESH_VERSION && a.blob.header.id==desc.id && .Cooked in a.blob.header.flags)
    testing.expect(t,len(a.dependencies)==3 && a.dependencies[0]==base.Asset_Id{5,5})
    view,error:=mesh_view(&a,&types)
    testing.expect_value(t,error,Error.None)
    testing.expect(t,mesh_check_indices(view))
    // A slot a cluster: the two slots share no vertex.
    testing.expect(t,view.info.cluster_count==2 && view.info.triangle_count==16 && view.info.vertex_count==32 && view.info.flags==Mesh_Flags{.Has_Uv1,.Skinned,.Levels}-{.Levels})
    testing.expect(t,len(view.levels)==1 && view.levels[0]==Mesh_Level{0,2,16,0,CLUSTER_ROOT})
    testing.expect(t,cluster_slot(view.clusters[0])==0 && cluster_slot(view.clusters[1])==1)
    testing.expect(t,view.info.bounds_min==[3]f32{0,0,0} && view.info.bounds_max==[3]f32{8,0,1})
    testing.expect(t,len(view.skin)==32 && view.skin[5].weights==[8]u8{191,64,0,0,0,0,0,0})
    // The places and uvs of the grid are steps of the grids: they come back exact.
    decoded:=make([dynamic]Vertex,context.temp_allocator)
    decoded_indices:=make([dynamic]u32,context.temp_allocator)
    testing.expect(t,mesh_level_decode(view.geometry,0,&decoded,&decoded_indices) && len(decoded_indices)==len(indices))
    for index,at in decoded_indices {
        want,got:=vertices[indices[at]],decoded[index]
        testing.expect(t,got.position==want.position && got.uv==want.uv && got.uv1==want.uv1 && got.normal==want.normal && got.material==want.material)
    }
    testing.expect(t,len(view.slots)==2 && view.slots[1].id==7 && serial.text_field(view.slots[0].label[:])=="model.gltf:Soil")
    testing.expect(t,view.info.skeleton==base.Asset_Id{7,7} && view.joints[1].node==1)
    testing.expect(t,len(view.colliders)==2 && view.colliders[0].size==[3]f32{1,2,3} && view.collision_points[3]==[3]f32{0,0,1} && view.collision_indices[5]==3)
    testing.expect(t,view.source!=nil && serial.text_field(view.source.source[:])=="models/model.gltf" && view.source.index==2 && view.source.importer_version==3)
    // The bulk columns are LZ: they are memory of the asset, not the file. LZ keeps a
    // chunk of a few hundred bytes as it is, like the clusters here.
    testing.expect(t,inside(&a,view.info) && !inside(&a,raw_data(view.vertices)) && !inside(&a,raw_data(view.triangles)) && !inside(&a,raw_data(view.skin)))
    table,_:=asset_table(&a,"vertices")
    testing.expect(t,.Bulk in table.flags && blob_chunk(&a.blob,table.columns[0].chunk).tag==TAG_BULK)
}

@(test)
mesh_grids_keep_places_uvs_and_tangents_within_half_a_step :: proc(t:^testing.T) {
    vertices,indices:=test_grid(700,context.temp_allocator)
    for &v,i in vertices {
        f:=f32(i)
        v.position=v.position*0.37+{math.sin(f*0.71)*0.013,math.cos(f*1.3)*0.25,math.sin(f*0.29)*0.007}+{1200,-30,4}
        v.uv=v.position.xz*3.1+{0.123,-7.5}
        v.uv1=v.position.zx*0.5
        n:=linalg.normalize([3]f32{math.sin(f),1.5,math.cos(f*0.3)})
        v.normal=mm.normal_pack(n)
        along:=linalg.normalize(linalg.cross(n,[3]f32{math.cos(f*0.2),0.1,math.sin(f*0.2)}))
        v.tangent=mm.tangent_pack(along,-1 if i%3==0 else 1)
    }
    // The index of each vertex rides in its joints: the constructor orders the triangles by place.
    marks:=make([]Skin_Vertex,len(vertices),context.temp_allocator)
    for &mark,i in marks {mark={joints={u16(i),u16(i>>16),0,0,0,0,0,0},weights={255,0,0,0,0,0,0,0}}}
    g:=test_geometry(vertices,indices,marks,flags={.Has_Uv1})
    testing.expect(t,len(g.clusters)>8,"the triangles make several clusters")
    decoded:=make([dynamic]Vertex,context.temp_allocator)
    decoded_indices:=make([dynamic]u32,context.temp_allocator)
    testing.expect(t,mesh_level_decode(g,0,&decoded,&decoded_indices) && len(decoded_indices)==len(indices))
    seen:=make(map[u32][3]f32,context.temp_allocator)
    worst_angle:f32
    for index in decoded_indices {
        origin:=u32(g.skin[index].joints[0])|u32(g.skin[index].joints[1])<<16
        want,got:=vertices[origin],decoded[index]
        for axis in 0..<3 {testing.expect(t,abs(got.position[axis]-want.position[axis])<=g.position_step*0.5001)}
        for axis in 0..<2 {
            testing.expect(t,abs(got.uv[axis]-want.uv[axis])<=g.uv_step*0.5001)
            testing.expect(t,abs(got.uv1[axis]-want.uv1[axis])<=g.uv1_step*0.5001)
        }
        a,sa:=mm.tangent_unpack(want.tangent)
        b,sb:=mm.tangent_unpack(got.tangent)
        worst_angle=max(worst_angle,math.acos(clamp(linalg.dot(linalg.normalize(a),linalg.normalize(b)),-1,1)))
        testing.expect(t,sa==sb)
        // A vertex two clusters share is the same place in both: no cracks.
        if place,known:=seen[origin];known {testing.expect(t,place==got.position)} else {seen[origin]=got.position}
    }
    // tangent_pack itself rounds to 15 bits of an octahedron; the angle adds at most 0.006 degrees.
    testing.expect(t,worst_angle<math.to_radians(f32(0.05)),"tangents keep their direction")
    testing.expect(t,g.position_step<=0.001 && g.uv_step<=0.004,"the grids of strips of 24 m stay under a millimetre")
}

@(test)
mesh_build_makes_clusters_of_one_slot_and_levels_of_one_sphere :: proc(t:^testing.T) {
    vertices,indices:=test_grid(1500,context.temp_allocator)
    for &v,i in vertices {v.material=u32(i/4%3)}
    // Level 1 keeps every other quad.
    coarse:=make([dynamic]u32,context.temp_allocator)
    for q:=0;q<len(indices)/6;q+=2 {append(&coarse,..indices[q*6:][:6])}
    all:=make([dynamic]u32,context.temp_allocator)
    append(&all,..indices)
    append(&all,..coarse[:])
    levels:=[2]Level_Source{{0,u32(len(indices)),0},{u32(len(indices)),u32(len(coarse)),0.1}}
    g:Mesh_Geometry
    testing.expect(t,mesh_build({vertices=vertices},all[:],levels[:],&g,context.temp_allocator))
    testing.expect(t,.Levels in g.flags && len(g.levels)==2)
    testing.expect(t,g.levels[0].triangle_count==u32(len(indices)/3) && g.levels[1].triangle_count==u32(len(coarse)/3))
    testing.expect(t,g.levels[0].error==0 && g.levels[0].parent_error==0.1 && g.levels[1].error==0.1 && g.levels[1].parent_error==CLUSTER_ROOT)
    low,high:=mesh_bounds(vertices)
    sphere:=[4]f32{(low.x+high.x)*0.5,(low.y+high.y)*0.5,(low.z+high.z)*0.5,linalg.length(high-low)*0.5}
    for c,at in g.clusters {
        testing.expect(t,cluster_triangle_count(c)<=CLUSTER_TRIANGLES && cluster_vertex_count(c)<=CLUSTER_VERTICES)
        testing.expect(t,c.lod==sphere && c.parent==sphere)
        level:=0 if u32(at)<g.levels[1].first_cluster else 1
        testing.expect(t,c.error==levels[level].error)
        for local in 0..<cluster_vertex_count(c) {testing.expect(t,cluster_vertex(g,c,local).material==cluster_slot(c))}
    }
    // A grid lies flat: its clusters are seen from both sides, and it is not closed.
    testing.expect(t,.Closed not_in g.flags)
    testing.expect(t,g.clusters[0].counts&CLUSTER_CONE!=0,"a flat cluster has the narrowest cone")
}

@(test)
mesh_refuses_descriptions_and_files_with_ranges_outside_their_tables :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    vertices,indices:=test_grid(2);defer delete(vertices);defer delete(indices)
    good:=Mesh_Desc{geometry=test_geometry(vertices,indices)}
    doc:Document
    testing.expect_value(t,mesh_document(&doc,&types,good),Error.None)
    document_destroy(&doc)
    refuse :: proc(t:^testing.T,types:^Types,desc:Mesh_Desc,loc:=#caller_location) {
        doc:Document
        testing.expect_value(t,mesh_document(&doc,types,desc),Error.Invalid,loc)
    }
    clusters :: proc(desc:^Mesh_Desc) -> ^Cluster {
        copied:=make([]Cluster,len(desc.geometry.clusters),context.temp_allocator)
        copy(copied,desc.geometry.clusters)
        desc.geometry.clusters=copied
        return &copied[0]
    }
    bad:=good
    clusters(&bad).vertex_first=7
    refuse(t,&types,bad)
    bad=good;clusters(&bad).triangle_first=1
    refuse(t,&types,bad)
    bad=good;clusters(&bad).counts|=1<<16
    refuse(t,&types,bad)
    bad=good;clusters(&bad).parent_error=-1
    refuse(t,&types,bad)
    bad=good;bad.geometry.position_step=0.3
    refuse(t,&types,bad)
    bad=good;bad.geometry.uv1s=make([]u32,len(good.geometry.vertices),context.temp_allocator)
    refuse(t,&types,bad)
    bad=good;bad.geometry.levels={{0,1,5,0,CLUSTER_ROOT}}
    refuse(t,&types,bad)
    bad=good;bad.geometry.levels={{0,2,4,0,CLUSTER_ROOT}}
    refuse(t,&types,bad)
    bad=good;bad.geometry.ray_errors={0.2,0.1,0}
    refuse(t,&types,bad)
    bad=good;bad.geometry.ray_errors={0,0.1,0}
    refuse(t,&types,bad)
    bad=good;bad.geometry.skin=make([]Skin_Vertex,3,context.temp_allocator)
    refuse(t,&types,bad)
    bad=good;bad.geometry.triangles=make([]u32,len(good.geometry.triangles),context.temp_allocator)
    bad.geometry.triangles[0]=200
    refuse(t,&types,bad)
    bad=good;bad.slots={{id=1},{id=1}}
    refuse(t,&types,bad)
    bad=good;bad.skeleton={1,1};bad.joints={{0,1}}
    refuse(t,&types,bad)
    bad=good;bad.skeleton={1,1}
    refuse(t,&types,bad)
    bad=good;bad.joints={{1,1}}
    refuse(t,&types,bad)
    bad=good;bad.colliders={{kind=.Hull,point_count=1}}
    refuse(t,&types,bad)
    nan:=transmute(f32)u32(0x7fc00000)
    bad=good;bad.colliders={{kind=.Sphere,size={nan,0,0}}}
    refuse(t,&types,bad)
    skinned:=make([]Skin_Vertex,len(good.geometry.vertices),context.temp_allocator)
    for &influence in skinned {influence.weights[0]=200}
    bad=good;bad.geometry.skin=skinned;bad.skeleton={1,1};bad.joints={{0,1}}
    refuse(t,&types,bad)

    // The same rules hold for a file, whoever wrote it.
    testing.expect_value(t,mesh_document(&doc,&types,good),Error.None)
    defer document_destroy(&doc)
    levels,_:=document_table(&doc,"levels")
    testing.expect_value(t,serial.value_set(&doc.schema,doc.tables[levels].columns[0].type,document_cell(&doc,levels,0,0),"cluster_count",u64(3)),serial.Path_Error.None)
    w:serial.Writer;serial.writer_init(&w);defer serial.writer_destroy(&w)
    testing.expect_value(t,document_write(&doc,&w),Error.None)
    a:Asset
    testing.expect_value(t,asset_open(&a,serial.writer_bytes(&w)),Error.None)
    defer asset_close(&a)
    _,error:=mesh_view(&a,&types)
    testing.expect_value(t,error,Error.Corrupt)

    wrong:Asset
    material:Document
    testing.expect_value(t,material_document(&material,&types,{info=MATERIAL_DEFAULTS}),Error.None)
    defer document_destroy(&material)
    serial.writer_reset(&w)
    document_write(&material,&w)
    testing.expect_value(t,asset_open(&wrong,serial.writer_bytes(&w)),Error.None)
    defer asset_close(&wrong)
    _,kind_error:=mesh_view(&wrong,&types)
    testing.expect_value(t,kind_error,Error.Invalid)
}

@(test)
texture_round_trips_every_format_and_checks_level_sizes :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    testing.expect_value(t,texture_level_size(.RGBA8,5,3),60)
    testing.expect_value(t,texture_level_size(.BC1,5,3),16)
    testing.expect_value(t,texture_level_size(.BC3,8,8),64)
    testing.expect_value(t,texture_level_size(.BC5,1,1),16)
    testing.expect_value(t,texture_level_size(.BC7,5,9),2*3*16)
    testing.expect_value(t,texture_mip_count(8,2),4)
    testing.expect_value(t,texture_mip_count(1,1),1)
    testing.expect_value(t,texture_mip_count(5,3),3)

    path:=test_path("image.tex")
    defer os.remove(path)
    for format in Texture_Format {
        levels:[4][]u8
        state:=u64(1+int(format))
        for &level,i in levels {
            level=make([]u8,texture_level_size(format,max(8>>uint(i),1),max(2>>uint(i),1)),context.temp_allocator)
            for &b in level {b=u8(test_random(&state))}
        }
        desc:=Texture_Desc{id={1,u64(format)},width=8,height=2,format=format,flags={.Srgb},alpha_coverage=0.5,mips=levels[:]}
        testing.expect_value(t,texture_save(path,&types,desc),Error.None)
        a:Asset
        testing.expect_value(t,asset_load(&a,path),Error.None)
        view,error:=texture_view(&a,&types)
        testing.expect_value(t,error,Error.None)
        testing.expect(t,view.info.width==8 && view.info.height==2 && view.info.mip_count==4 && view.info.format==format && view.info.flags=={.Srgb} && view.info.alpha_coverage==0.5)
        for level,i in levels {
            got:=texture_mip(view,i)
            testing.expect(t,mem.compare(got,level)==0)
            testing.expect(t,uintptr(raw_data(got))%TEXTURE_BULK_ALIGNMENT==0 && inside(&a,raw_data(got)))
        }
        testing.expect(t,view.mips[3].width==1 && view.mips[3].height==1 && view.source==nil)
        asset_close(&a)
    }
    refuse :: proc(t:^testing.T,types:^Types,desc:Texture_Desc,loc:=#caller_location) {
        doc:Document
        testing.expect_value(t,texture_document(&doc,types,desc),Error.Invalid,loc)
    }
    pixels:=make([]u8,64,context.temp_allocator)
    refuse(t,&types,{width=4,height=4,format=.RGBA8})
    refuse(t,&types,{width=4,height=4,format=.RGBA8,mips={pixels[:63]}})
    refuse(t,&types,{width=0,height=4,format=.RGBA8,mips={pixels}})
    refuse(t,&types,{width=TEXTURE_MAX_SIZE+1,height=1,format=.RGBA8,mips={pixels}})
    refuse(t,&types,{width=4,height=4,format=.RGBA8,mips={pixels,pixels[:16],pixels[:4],pixels[:4]}})
    refuse(t,&types,{width=4,height=4,format=.RGBA8,mips={pixels,pixels[:8]}})

    // A level that says it lies past the texels.
    doc:Document
    testing.expect_value(t,texture_document(&doc,&types,{width=4,height=4,format=.RGBA8,mips={pixels,pixels[:16]}}),Error.None)
    defer document_destroy(&doc)
    mips,_:=document_table(&doc,"mips")
    serial.value_set(&doc.schema,doc.tables[mips].columns[0].type,document_cell(&doc,mips,0,1),"offset",u64(80))
    w:serial.Writer;serial.writer_init(&w);defer serial.writer_destroy(&w)
    document_write(&doc,&w)
    a:Asset
    testing.expect_value(t,asset_open(&a,serial.writer_bytes(&w)),Error.None)
    defer asset_close(&a)
    _,error:=texture_view(&a,&types)
    testing.expect_value(t,error,Error.Corrupt)
    free_all(context.temp_allocator)
}

@(test)
a_read_of_the_small_levels_decodes_only_the_start_of_the_texels :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    // BC1 whose endpoints change slowly and whose indices are noise: as planes
    // of fields it compresses smaller. Its levels take several blocks of LZ.
    SIDE :: 1024
    count:=texture_mip_count(SIDE,SIDE)
    levels:=make([][]u8,count,context.temp_allocator)
    state:=u64(5)
    for &level,i in levels {
        side:=max(SIDE>>uint(i),1)
        level=make([]u8,texture_level_size(.BC1,side,side),context.temp_allocator)
        for at:=0;at<len(level);at+=8 {
            endpoint:=u16(at/8/256)
            level[at],level[at+1],level[at+2],level[at+3]=u8(endpoint),u8(endpoint>>8),u8(endpoint+1),0x80
            for k in 4..<8 {level[at+k]=u8(test_random(&state))}
        }
    }
    for fast in ([2]bool{false,true}) {
        doc:Document
        flags:=Texture_Flags{.Fast} if fast else {}
        testing.expect_value(t,texture_document(&doc,&types,{id={3,4},width=SIDE,height=SIDE,format=.BC1,flags=flags,mips=levels}),Error.None)
        w:serial.Writer;serial.writer_init(&w);defer serial.writer_destroy(&w)
        testing.expect_value(t,document_write(&doc,&w),Error.None)
        document_destroy(&doc)
        bytes:=serial.writer_bytes(&w)
        a:Asset
        testing.expect_value(t,asset_open(&a,bytes),Error.None)
        view,error:=texture_open(&a,&types)
        testing.expect(t,error==.None && texture_mip(view,count-1)==nil,"open decodes no level")
        testing.expectf(t,(.Fields in view.info.flags)==!fast,"planes of fields when they are smaller, never for fast blocks (fast: %v)",fast)
        testing.expect(t,view.mips[count-1].offset==0 && view.mips[0].offset>view.mips[1].offset,"the smallest level first")
        testing.expect_value(t,texture_decode(&a,&types,&view,0),Error.None)
        for level,i in levels {
            got:=texture_mip(view,i)
            testing.expect(t,mem.compare(got,level)==0 && uintptr(raw_data(got))%TEXTURE_BULK_ALIGNMENT==0)
        }
        table,_:=asset_table(&a,"texels")
        entry:=blob_chunk(&a.blob,table.columns[0].chunk)
        testing.expect(t,entry.compression==.LZ && entry.uncompressed_size>u64(len(levels[0])))
        asset_close(&a)

        // With the end of the stream damaged, the levels at its start still read.
        damaged:=make([]u8,len(bytes),context.temp_allocator)
        copy(damaged,bytes)
        for k in 1..=64 {damaged[entry.offset+entry.size-u64(k)]~=0x5a}
        testing.expect_value(t,asset_open(&a,damaged),Error.None)
        view,error=texture_open(&a,&types)
        testing.expect(t,error==.None && texture_decode(&a,&types,&view,2)==.None)
        testing.expect(t,view.first==2 && texture_mip(view,1)==nil && len(view.texels)<len(levels[0])/2)
        for level in 2..<count {testing.expectf(t,mem.compare(texture_mip(view,level),levels[level])==0,"level %d",level)}
        whole:=texture_decode(&a,&types,&view,0)
        testing.expect(t,whole!=.None || mem.compare(texture_mip(view,0),levels[0])!=0,"a read of every level decodes the damaged end")
        asset_close(&a)
    }
    free_all(context.temp_allocator)
}

@(test)
texture_layers_keep_each_image_of_every_level :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    // A cube of 4x4 faces in BC6H: each level holds its six faces.
    levels:[3][]u8
    for &level,i in levels {
        side:=max(4>>uint(i),1)
        level=make([]u8,texture_level_size(.BC6H,side,side)*6,context.temp_allocator)
        for &b,at in level {b=u8(at*7+i)}
    }
    doc:Document
    testing.expect_value(t,texture_document(&doc,&types,{id={5,6},width=4,height=4,layers=6,format=.BC6H,flags={.Cube},mips=levels[:]}),Error.None)
    w:serial.Writer;serial.writer_init(&w);defer serial.writer_destroy(&w)
    document_write(&doc,&w)
    document_destroy(&doc)
    a:Asset
    testing.expect_value(t,asset_open(&a,serial.writer_bytes(&w)),Error.None)
    view,error:=texture_view(&a,&types)
    testing.expect_value(t,error,Error.None)
    testing.expect(t,view.info.layers==6 && .Cube in view.info.flags && view.mips[0].size==6*16 && view.mips[2].size==6*16)
    testing.expect(t,mem.compare(texture_layer(view,1,4),levels[1][4*16:5*16])==0,"the fifth face of the second level")
    asset_close(&a)

    refuse :: proc(t:^testing.T,types:^Types,desc:Texture_Desc,loc:=#caller_location) {
        doc:Document
        testing.expect_value(t,texture_document(&doc,types,desc),Error.Invalid,loc)
    }
    face:=make([]u8,4*4*4*6,context.temp_allocator)
    refuse(t,&types,{width=4,height=4,layers=5,format=.RGBA8,flags={.Cube},mips={face[:4*4*4*5]}})
    refuse(t,&types,{width=4,height=2,layers=6,format=.RGBA8,flags={.Cube},mips={face[:4*2*4*6]}})
    refuse(t,&types,{width=4,height=4,layers=6,format=.RGBA8,mips={face[:4*4*4*5]}})
    refuse(t,&types,{width=1,height=1,layers=TEXTURE_MAX_LAYERS+1,format=.RGBA8,mips={make([]u8,4*(TEXTURE_MAX_LAYERS+1),context.temp_allocator)}})
    refuse(t,&types,{width=1,height=1,layers=-1,format=.RGBA8,mips={face[:4]}})
    free_all(context.temp_allocator)
}

@(test)
material_keeps_values_parameters_and_overlays :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    info:=MATERIAL_DEFAULTS
    info.base_color,info.roughness,info.alpha_mode,info.transmission,info.ior={0.2,0.4,0.6},0.3,.Blend,0.9,1.333
    info.maps.normal={texture={3,4},scale={2,2},rotation=0.5,uv_set=1}
    info.maps.base_color.texture={1,2}
    text_set(info.program[:],"Ocean")
    parameters:[3]Material_Parameter
    parameters[0]={kind=.Float,components=3,value={0.1,0.3,0.8,0}}
    parameters[1]={kind=.Texture,components=1,texture={9,9}}
    parameters[2]={overlay=4,kind=.Uint,components=1,value={4294967295,0,0,0}}
    text_set(parameters[0].name[:],"color")
    text_set(parameters[1].name[:],"foam_map")
    text_set(parameters[2].name[:],"seed")
    overlays:=[1]Material_Overlay{{id=4,material={7,7},blend=.Multiply,enabled=true}}
    hidden:[2]Material_Name
    text_set(hidden[0].name[:],"pbr")
    text_set(hidden[1].name[:],"foam")
    path:=test_path("ocean.mat")
    defer os.remove(path)
    desc:=Material_Desc{id={8,8},info=info,parameters=parameters[:],overlays=overlays[:],hidden=hidden[:]}
    testing.expect_value(t,material_save(path,&types,desc),Error.None)

    a:Asset
    testing.expect_value(t,asset_load(&a,path),Error.None)
    defer asset_close(&a)
    view,error:=material_view(&a,&types)
    testing.expect_value(t,error,Error.None)
    testing.expect(t,view.info^==info)
    testing.expect(t,len(view.parameters)==3 && view.parameters[2].overlay==4 && view.parameters[2].value[0]==4294967295 && serial.text_field(view.parameters[1].name[:])=="foam_map")
    testing.expect(t,len(view.overlays)==1 && view.overlays[0]==overlays[0] && len(view.hidden)==2 && serial.text_field(view.hidden[0].name[:])=="pbr")
    testing.expect_value(t,len(a.dependencies),4) // two maps, a texture parameter and the material of the overlay
    testing.expect(t,a.dependencies[0]==base.Asset_Id{1,2} && a.dependencies[3]==base.Asset_Id{9,9})

    refuse :: proc(t:^testing.T,types:^Types,desc:Material_Desc,loc:=#caller_location) {
        doc:Document
        testing.expect_value(t,material_document(&doc,types,desc),Error.Invalid,loc)
    }
    bad:=desc
    bad.info.roughness=1.5;refuse(t,&types,bad)
    bad=desc;bad.info.ior=0.5;refuse(t,&types,bad)
    bad=desc;bad.info.emission.g=transmute(f32)u32(0x7f800000);refuse(t,&types,bad)
    bad=desc;bad.info.maps.occlusion.uv_set=2;refuse(t,&types,bad)
    bad=desc;bad.info.alpha_mode=Alpha_Mode(3);refuse(t,&types,bad)
    bad=desc;bad.overlays={{id=0}};refuse(t,&types,bad)
    bad=desc;bad.overlays={{id=4},{id=4}};refuse(t,&types,bad)
    bad=desc;bad.overlays=nil;refuse(t,&types,bad) // a parameter of an overlay that is not there
    twice:=[2]Material_Parameter{parameters[0],parameters[0]}
    bad=desc;bad.parameters=twice[:];refuse(t,&types,bad)
    nameless:=[1]Material_Parameter{{kind=.Float,components=1}}
    bad=desc;bad.parameters=nameless[:];refuse(t,&types,bad)
    wide:=[1]Material_Parameter{parameters[0]}
    wide[0].components=5
    bad=desc;bad.parameters=wide[:];refuse(t,&types,bad)
    bad=desc;bad.info.ior=0
    doc:Document
    testing.expect_value(t,material_document(&doc,&types,bad),Error.None)
    document_destroy(&doc)
}

@(test)
an_imported_material_follows_its_source_except_the_fields_changed_after_the_import :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    given:=MATERIAL_DEFAULTS
    given.roughness,given.metallic=0.5,1
    given.maps.base_color.texture,given.maps.normal.texture={1,1},{2,2}
    changed:=given
    changed.roughness=0.9
    changed.maps.normal.texture={3,3}
    hidden:=[1]Material_Name{}
    text_set(hidden[0].name[:],"pbr")
    data,error:=material_bytes(&types,{id={5,5},info=changed,imported=&given,hidden=hidden[:]},context.temp_allocator)
    if !testing.expect_value(t,error,Error.None) {return}
    a:Asset
    if !testing.expect_value(t,asset_open(&a,data),Error.None) {return}
    defer asset_close(&a)
    view,view_error:=material_view(&a,&types)
    if !testing.expect_value(t,view_error,Error.None) || !testing.expect(t,view.imported!=nil) {return}
    testing.expect(t,view.info^==changed && view.imported^==given)
    overrides:=make([dynamic]string,context.temp_allocator)
    material_overrides(&types,view,&overrides)
    testing.expect(t,len(overrides)==2 && overrides[0]=="roughness" && overrides[1]=="maps.normal.texture","the fields changed after the import, by path")

    // The source changes its roughness, its metal and both textures.
    now:=given
    now.roughness,now.metallic=0.25,0
    now.maps.base_color.texture,now.maps.normal.texture={6,6},{7,7}
    followed:=material_follow(&types,view,now)
    testing.expect(t,followed.roughness==0.9 && followed.maps.normal.texture==base.Asset_Id{3,3},"what was changed stays")
    testing.expect(t,followed.metallic==0 && followed.maps.base_color.texture==base.Asset_Id{6,6},"the rest is what the source gives now")

    reverted,failed,revert_error:=material_revert(&types,view,{"maps.normal","roughness"})
    testing.expect(t,revert_error==.None && failed=="" && reverted==given,"a field or a part goes back to what the source gave")
    every,_,_:=material_revert(&types,view,nil)
    testing.expect(t,every==given)
    _,failed,revert_error=material_revert(&types,view,{"roughness","glossiness"})
    testing.expect(t,revert_error==.Invalid && failed=="glossiness","a path that names no field is refused by name")
    after:=Material_View{info=&reverted,imported=view.imported}
    clear(&overrides)
    material_overrides(&types,after,&overrides)
    testing.expect_value(t,len(overrides),0)

    // A material no import wrote is its own base: nothing to follow or go back to.
    own:=Material_View{info=&changed}
    clear(&overrides)
    material_overrides(&types,own,&overrides)
    testing.expect_value(t,len(overrides),0)
    testing.expect(t,material_follow(&types,own,now)==now)
    _,_,revert_error=material_revert(&types,own,{"roughness"})
    testing.expect_value(t,revert_error,Error.Invalid)
    bad:=given
    bad.roughness=2
    _,error=material_bytes(&types,{id={5,5},info=changed,imported=&bad},context.temp_allocator)
    testing.expect_value(t,error,Error.Invalid)
}

// The parameters a source gives are followed by name: one changed after the
// import stays, one the source no longer gives goes, and one a person added
// or an overlay's stays.
@(test)
material_parameters_follow_their_source_and_keep_what_was_changed :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    row :: proc(name:string,value:f64,overlay:u32=0) -> (p:Material_Parameter) {
        text_set(p.name[:],name)
        p.kind,p.components,p.value.x,p.overlay=.Float,1,value,overlay
        return
    }
    given:=[3]Material_Parameter{row("speed",1),row("gloss",0.5),row("gone",3)}
    current:=[4]Material_Parameter{row("speed",1),row("gloss",0.9),row("gone",3),row("mine",7)}
    info:=MATERIAL_DEFAULTS
    text_set(info.program[:],"Flow")
    data,error:=material_bytes(&types,{id={5,5},info=info,imported=&info,parameters=current[:],imported_parameters=given[:]},context.temp_allocator)
    if !testing.expect_value(t,error,Error.None) {return}
    a:Asset
    if !testing.expect_value(t,asset_open(&a,data),Error.None) {return}
    defer asset_close(&a)
    view,view_error:=material_view(&a,&types)
    if !testing.expect_value(t,view_error,Error.None) || !testing.expect_value(t,len(view.imported_parameters),3) {return}
    now:=[2]Material_Parameter{row("speed",2),row("gloss",0.6)}
    followed:=material_parameters_follow(view,now[:],context.temp_allocator)
    testing.expect_value(t,len(followed),3)
    testing.expect(t,followed[0]==now[0],"the source's new value")
    testing.expect(t,followed[1]==current[1],"the value changed after the import")
    testing.expect(t,followed[2]==current[3],"a parameter a person added")
}

@(test)
material_written_before_a_field_existed_reads_its_default :: proc(t:^testing.T) {
    Old_Map :: struct {texture:base.Asset_Id,scale:[2]f32}
    Old_Maps :: struct {base_color,normal:Old_Map}
    Old_Material :: struct {base_color:[3]f64,roughness:f32,alpha_mode:enum u8 {Opaque,Blend,Mask},maps:Old_Maps,legacy_tint:u32}
    types:Types;types_init(&types);defer types_destroy(&types)
    // The same version: a field added with a default does not change it.
    doc:Document;document_init(&doc,KIND_MATERIAL,{4,4});defer document_destroy(&doc)
    doc.kind_version=MATERIAL_VERSION
    old:=Old_Material{base_color={0.5,0.25,1},roughness=0.2,alpha_mode=.Mask,maps={base_color={{1,1},{3,3}},normal={{2,2},{1,1}}},legacy_tint=7}
    document_put_row(&doc,&types,"material",&old)
    w:serial.Writer;serial.writer_init(&w);defer serial.writer_destroy(&w)
    testing.expect_value(t,document_write(&doc,&w),Error.None)
    a:Asset
    testing.expect_value(t,asset_open(&a,serial.writer_bytes(&w)),Error.None)
    defer asset_close(&a)
    view,error:=material_view(&a,&types)
    testing.expect_value(t,error,Error.None)
    expected:=MATERIAL_DEFAULTS
    expected.base_color,expected.roughness,expected.alpha_mode={0.5,0.25,1},0.2,.Mask
    expected.maps.base_color.texture,expected.maps.base_color.scale={1,1},{3,3}
    expected.maps.normal.texture={2,2}
    testing.expect(t,view.info^==expected)
    testing.expect(t,len(view.parameters)==0 && len(view.overlays)==0 && view.source==nil)
    testing.expect(t,!inside(&a,view.info))
}

@(test)
kinds_are_found_by_extension :: proc(t:^testing.T) {
    kind,found:=kind_of_extension("levels/intro.scene")
    testing.expect(t,found && kind==KIND_SCENE)
    _,unknown:=kind_of_extension("model.gltf")
    testing.expect(t,!unknown)
    info,known:=kind_info(KIND_TEXTURE)
    testing.expect(t,known && info.extension==".tex" && info.name=="texture")
    field:[4]u8
    text_set(field[:],"añil")
    testing.expect_value(t,serial.text_field(field[:]),"añi")
    text_set(field[:],"aññ")
    testing.expect_value(t,serial.text_field(field[:]),"añ")
}
