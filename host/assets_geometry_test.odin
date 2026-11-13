package host

import "base:runtime"
import "core:fmt"
import "core:math/linalg"
import "core:os"
import "core:testing"
import "mirai:asset"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"

@(test)
geometry_primitives_append_complete_white_attributes_and_relative_indices :: proc(t:^testing.T) {
    buffer:geom.Mesh_Buffer;geom.mesh_buffer_init(&buffer);defer geom.mesh_buffer_destroy(&buffer)
    for shape in ([8]Shape{.Cube,.Sphere,.Cylinder,.Cone,.Capsule,.Plane,.Prism,.Pyramid}) {
        first,indices:=len(buffer.positions),len(buffer.indices)
        testing.expect(t,assets_geometry(nil,{},shape,&buffer,true))
        testing.expect(t,geom.mesh_is_valid(geom.mesh_buffer_view(&buffer)))
        testing.expect(t,len(buffer.positions)>first && len(buffer.indices)>indices)
        for index in buffer.indices[indices:] {testing.expect(t,index>=u32(first) && int(index)<len(buffer.positions))}
        for color in buffer.colors[first:] {testing.expect_value(t,color,geom.Vec4{1,1,1,1})}
    }
}

@(test)
geometry_generated_colors_are_owned_and_missing_colors_are_white :: proc(t:^testing.T) {
    assets:Assets
    if !testing.expect(t,assets_init(&assets,{root="assets",capacity=4})) {return}
    defer assets_destroy(&assets)
    colors:=[3]geom.Vec4{{0.1,0.2,0.3,0.4},{0.2,0.4,0.6,0.8},{1,0,0.5,1}}
    original:=colors
    source:=geom.Mesh{positions={{0,0,0},{1,0,0},{0,0,1}},indices={0,2,1},colors=colors[:]}
    id,created:=assets_mesh_generate(&assets,source,options={collision=true})
    if !testing.expect(t,created) {return}
    colors[0]={9,9,9,9}
    buffer:geom.Mesh_Buffer;geom.mesh_buffer_init(&buffer);defer geom.mesh_buffer_destroy(&buffer)
    testing.expect(t,assets_geometry(&assets,id,.None,&buffer,true))
    testing.expect(t,geom.mesh_is_valid(geom.mesh_buffer_view(&buffer)))
    for color,i in buffer.colors {testing.expect_value(t,color,original[i])}
    testing.expect(t,assets_mesh_release(&assets,id))
    source.colors=nil
    id,created=assets_mesh_generate(&assets,source,options={collision=true})
    testing.expect(t,created && assets_geometry(&assets,id,.None,&buffer,true))
    for color in buffer.colors[3:] {testing.expect_value(t,color,geom.Vec4{1,1,1,1})}
    source.colors=colors[:2]
    _,created=assets_mesh_generate(&assets,source,options={collision=true})
    testing.expect(t,!created)
}

@(test)
geometry_file_preserves_packed_colors_normals_uvs_materials_and_slots :: proc(t:^testing.T) {
    root:=base.test_folder(t,"host-geometry")
    if root=="" {return}
    path:=fmt.tprintf("%s/colored.mesh",root)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    vertices:=[3]asset.Vertex{
        {position={0,0,0},normal=mm.normal_pack({0,1,0}),uv={0.1,0.2},uv1={0.7,0.8},color=0x80604020},
        {position={1,0,0},normal=mm.normal_pack({0,1,0}),uv={0.3,0.4},uv1={0.2,0.3},color=0xffffffff},
        {position={0,0,1},normal=mm.normal_pack({0,1,0}),uv={0.5,0.6},uv1={0.4,0.5},color=0xff0000ff},
    }
    id:=base.Asset_Id{0x63706f6c6f7273,1}
    slot:=[1]asset.Material_Slot{{id=1,material={5,5}}}
    order:=[3]u32{0,2,1}
    testing.expect_value(t,mesh_save_test(path,&types,id,vertices[:],order[:],slot[:],{.Has_Colors,.Has_Uv1}),asset.Error.None)
    assets:Assets
    if !testing.expect(t,assets_init(&assets,{root=root,capacity=4})) {return}
    defer assets_destroy(&assets)
    buffer:geom.Mesh_Buffer;geom.mesh_buffer_init(&buffer);defer geom.mesh_buffer_destroy(&buffer)
    slots:Assets_Slots
    testing.expect(t,assets_geometry(&assets,id,.None,&buffer,true,&slots))
    testing.expect(t,geom.mesh_is_valid(geom.mesh_buffer_view(&buffer)))
    testing.expect_value(t,len(buffer.positions),3)
    // The slots come from the file, which is not loaded for them.
    testing.expect(t,slots.count==1 && slots.materials[0]==base.Asset_Id{5,5})
    testing.expect(t,!(id in assets.index))
    // The corners of the triangle name the vertices it was given with, on the grids of the mesh.
    for source,corner in order {
        vertex,at:=vertices[source],buffer.indices[corner]
        testing.expect_value(t,buffer.positions[at],vertex.position)
        testing.expect_value(t,buffer.normals[at],mm.normal_unpack(vertex.normal))
        testing.expect(t,linalg.length(buffer.uvs[at]-vertex.uv)<1e-4)
        testing.expect_value(t,buffer.colors[at],mm.rgba8_unpack(vertex.color))
    }
    testing.expect_value(t,buffer.materials[0],u32(0))
}

@(test)
geometry_reservation_failure_preserves_existing_values_and_lengths :: proc(t:^testing.T) {
    buffer:geom.Mesh_Buffer;geom.mesh_buffer_init(&buffer);defer geom.mesh_buffer_destroy(&buffer)
    append(&buffer.positions,geom.Vec3{9,8,7});append(&buffer.normals,geom.Vec3{1,0,0});append(&buffer.uvs,geom.Vec2{0.4,0.6})
    saved_allocator:=buffer.colors.allocator
    buffer.colors.allocator=runtime.nil_allocator()
    testing.expect(t,!assets_geometry(nil,{},.Cube,&buffer,true))
    buffer.colors.allocator=saved_allocator
    testing.expect_value(t,len(buffer.positions),1);testing.expect_value(t,len(buffer.normals),1)
    testing.expect_value(t,len(buffer.uvs),1);testing.expect_value(t,len(buffer.colors),0)
    testing.expect_value(t,len(buffer.indices),0);testing.expect_value(t,len(buffer.materials),0)
    testing.expect_value(t,buffer.positions[0],geom.Vec3{9,8,7});testing.expect_value(t,buffer.uvs[0],geom.Vec2{0.4,0.6})
    testing.expect(t,assets_geometry(nil,{},.Cube,&buffer,true))
    testing.expect_value(t,buffer.colors[0],geom.Vec4{1,1,1,1})
    testing.expect(t,geom.mesh_is_valid(geom.mesh_buffer_view(&buffer)))
    testing.expect(t,!assets_geometry(nil,{},.None,&buffer,true))
    testing.expect(t,!assets_geometry(nil,{},.Cube,nil,true))
    geom.mesh_buffer_clear(&buffer)
    buffer.positions.allocator=runtime.nil_allocator()
    buffer.indices.allocator=runtime.nil_allocator()
    // Previously reserved geometry remains usable with a refusing allocator.
    testing.expect(t,assets_geometry(nil,{},.Cube,&buffer))
    buffer.positions.allocator=saved_allocator;buffer.indices.allocator=saved_allocator
    empty:geom.Mesh_Buffer;geom.mesh_buffer_init(&empty,runtime.nil_allocator());defer geom.mesh_buffer_destroy(&empty)
    testing.expect(t,!assets_geometry(nil,{},.Cube,&empty))
    testing.expect_value(t,len(empty.positions),0);testing.expect_value(t,len(empty.indices),0)
}

// The boxes, spheres and capsules a mesh stores are each a convex piece of a Hull collider of the mesh,
// where they lie, and hulls of triangles for a Mesh collider.
@(test)
stored_boxes_spheres_and_capsules_are_the_convex_pieces_of_a_collider_of_their_mesh :: proc(t:^testing.T) {
    root:=base.test_folder(t,"host-shapes")
    if root=="" {return}
    path:=fmt.tprintf("%s/shapes.mesh",root)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    vertices:=[3]asset.Vertex{{position={0,0,0}},{position={1,0,0}},{position={0,0,1}}}
    order:=[3]u32{0,2,1}
    g:asset.Mesh_Geometry
    if !testing.expect(t,asset.mesh_build({vertices=vertices[:]},order[:],nil,&g,context.temp_allocator)) {return}
    colliders:=[3]asset.Collider{
        {kind=.Box,center={10,0,0},rotation=1,size={1,2,3}},
        {kind=.Sphere,center={0,10,0},rotation=1,size={0.5,0,0}},
        {kind=.Capsule,center={0,0,10},rotation=1,size={0.25,1,0}},
    }
    id:=base.Asset_Id{0x7368617065,2}
    testing.expect_value(t,asset.mesh_save(path,&types,{id=id,geometry=g,colliders=colliders[:]}),asset.Error.None)
    assets:Assets
    if !testing.expect(t,assets_init(&assets,{root=root,capacity=4})) {return}
    defer assets_destroy(&assets)
    points:=make([dynamic]geom.Vec3,context.temp_allocator)
    sizes:=make([dynamic]u32,context.temp_allocator)
    if !testing.expect(t,assets_collision_hulls(&assets,id,.None,&points,&sizes),"the stored shapes are pieces of a hull") {return}
    if !testing.expect_value(t,len(sizes),3) {return}
    testing.expect_value(t,sizes[0],u32(8))
    reach:=[3][2]geom.Vec3{{{9,-2,-3},{11,2,3}},{{-0.5,9.5,-0.5},{0.5,10.5,0.5}},{{-0.25,-1.25,9.75},{0.25,1.25,10.25}}}
    from:=0
    for size,piece in sizes {
        low,high:=geom.Vec3{max(f32),max(f32),max(f32)},geom.Vec3{min(f32),min(f32),min(f32)}
        for p in points[from:][:size] {low,high=linalg.min(low,p),linalg.max(high,p)}
        from+=int(size)
        testing.expectf(t,linalg.length(low-reach[piece][0])<1e-4 && linalg.length(high-reach[piece][1])<1e-4,"piece %v reaches %v to %v",piece,low,high)
    }
    testing.expect_value(t,from,len(points))
    // A primitive or an unknown mesh has no pieces and leaves both as they were.
    testing.expect(t,!assets_collision_hulls(&assets,{},.Cube,&points,&sizes) && !assets_collision_hulls(&assets,{1,2},.None,&points,&sizes))
    testing.expect(t,len(sizes)==3 && len(points)==from)
    surface:geom.Mesh_Buffer;geom.mesh_buffer_init(&surface);defer geom.mesh_buffer_destroy(&surface)
    stored,ok:=assets_collision(&assets,id,.None,.Mesh,&surface)
    testing.expect(t,stored && ok && len(surface.indices)>=3*3*4,"each shape is a hull of triangles")
}

// A mesh file that stores no colliders is decomposed into convex pieces once: the cache keeps them by the
// content of the file, and what it keeps is what is given after. One that stores colliders is not
// decomposed, and is what a placed mesh collides with.
@(test)
a_mesh_without_colliders_is_decomposed_once_into_pieces_the_cache_keeps :: proc(t:^testing.T) {
    root:=base.test_folder(t,"host-pieces")
    if root=="" {return}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    vertices:=make([dynamic]asset.Vertex,context.temp_allocator)
    order:=make([dynamic]u32,context.temp_allocator)
    for part in 0..<2 {
        box:geom.Mesh_Buffer
        geom.mesh_buffer_init(&box,context.temp_allocator)
        geom.cube_build(&box,part==0?geom.Vec3{3,1,1}:geom.Vec3{1,3,1})
        first:=u32(len(vertices))
        for position in box.positions {append(&vertices,asset.Vertex{position=position+(part==0?geom.Vec3{1,0,0}:geom.Vec3{0,2,0})})}
        for index in box.indices {append(&order,first+index)}
    }
    g:asset.Mesh_Geometry
    if !testing.expect(t,asset.mesh_build({vertices=vertices[:]},order[:],nil,&g,context.temp_allocator)) {return}
    bare,boxed:=base.Asset_Id{0x62617265,1},base.Asset_Id{0x626f786564,1}
    box:=[1]asset.Collider{{kind=.Box,rotation=1,size={1,1,1}}}
    testing.expect_value(t,asset.mesh_save(fmt.tprintf("%s/bare.mesh",root),&types,{id=bare,geometry=g}),asset.Error.None)
    testing.expect_value(t,asset.mesh_save(fmt.tprintf("%s/boxed.mesh",root),&types,{id=boxed,geometry=g,colliders=box[:]}),asset.Error.None)
    assets:Assets
    if !testing.expect(t,assets_init(&assets,{root=root,capacity=4})) {return}
    defer assets_destroy(&assets)
    testing.expect(t,!assets_mesh_collides(&assets,bare) && assets_mesh_collides(&assets,boxed) && !assets_mesh_collides(&assets,{}),"only the mesh that stores colliders collides as placed")
    folder:=fmt.tprintf("%s/cache",root)
    pieces :: proc(assets:^Assets,id:base.Asset_Id,folder:string,points:^[dynamic]geom.Vec3,sizes:^[dynamic]u32) -> bool {
        file:asset.Asset
        if _,_,opened:=assets_open(assets,id,.Mesh,&file);!opened {return false}
        defer asset.asset_close(&file)
        return assets_collision_pieces_file(&file,&assets.types,folder,points,sizes)
    }
    points:=make([dynamic]geom.Vec3,context.temp_allocator)
    sizes:=make([dynamic]u32,context.temp_allocator)
    if !testing.expect(t,pieces(&assets,bare,folder,&points,&sizes) && len(sizes)>=2,"an L is two convex pieces or more") {return}
    total:=0
    for size in sizes {total+=int(size)}
    testing.expect_value(t,total,len(points))
    kept,_:=os.read_all_directory_by_path(folder,context.temp_allocator)
    if !testing.expect_value(t,len(kept),1) {return}
    // A file put in its place with one piece is what is given next: it is not decomposed again.
    held:asset.Asset
    if !testing.expect_value(t,asset.asset_load(&held,kept[0].fullpath,context.temp_allocator),asset.Error.None) {return}
    header:=held.blob.header
    asset.asset_close(&held)
    tetra:=[4][3]f32{{0,0,0},{1,0,0},{0,1,0},{0,0,1}}
    one:=[1]u32{4}
    doc:asset.Document
    asset.document_init(&doc,COLLISION_PIECES_KIND,header.id,context.temp_allocator)
    doc.kind_version=COLLISION_PIECES_VERSION
    asset.document_put(&doc,&types,"points",tetra[:])
    asset.document_put(&doc,&types,"sizes",one[:])
    testing.expect_value(t,asset.document_save(&doc,kept[0].fullpath),asset.Error.None)
    clear(&points);clear(&sizes)
    testing.expect(t,pieces(&assets,bare,folder,&points,&sizes) && len(sizes)==1 && sizes[0]==4 && points[1]==geom.Vec3{1,0,0},"the pieces come from the cache")
    clear(&points);clear(&sizes)
    testing.expect(t,!pieces(&assets,boxed,folder,&points,&sizes) && len(points)==0,"a mesh that stores colliders is not decomposed")
}

// The convex pieces of a generated mesh are checked and copied when it is made, and go with it.
@(test)
generated_hull_pieces_are_checked_copied_and_released_with_their_mesh :: proc(t:^testing.T) {
    assets:Assets
    if !testing.expect(t,assets_init(&assets,{root="assets",capacity=8})) {return}
    defer assets_destroy(&assets)
    triangle:=[3]geom.Vec3{{0,0,0},{1,0,0},{0,0,1}}
    order:=[3]u32{0,2,1}
    source:=geom.Mesh{positions=triangle[:],indices=order[:]}
    corners:[8]geom.Vec3
    for &p,i in corners {p={f32(i&1),f32(i>>1&1),f32(i>>2&1)}}
    nan:=corners
    nan[3].y=transmute(f32)u32(0x7fc00000)
    Case :: struct {points:[]geom.Vec3,sizes:[]u32}
    refused:=[?]Case{
        {corners[:],[]u32{4}},       // fewer points named than given
        {corners[:],[]u32{4,8}},     // more named than given
        {corners[:],[]u32{5,3}},     // a piece of three points has no volume
        {corners[:],[]u32{8,0}},
        {corners[:],[]u32{max(u32)}},
        {corners[:],nil},            // points of no piece
        {nil,[]u32{4}},
        {nan[:],[]u32{4,4}},
    }
    for c,at in refused {
        _,made:=assets_mesh_generate(&assets,source,options={hull_points=c.points,hull_sizes=c.sizes})
        testing.expectf(t,!made,"case %v is refused",at)
    }
    plain,plain_made:=assets_mesh_generate(&assets,source)
    points:=make([dynamic]geom.Vec3,context.temp_allocator)
    sizes:=make([dynamic]u32,context.temp_allocator)
    append(&points,geom.Vec3{7,7,7})
    testing.expect(t,plain_made && !assets_collision_hulls(&assets,plain,.None,&points,&sizes))
    halves:=[2]u32{4,4}
    id,made:=assets_mesh_generate(&assets,source,options={hull_points=corners[:],hull_sizes=halves[:]})
    if !testing.expect(t,made) {return}
    corners[0]={9,9,9}
    testing.expect(t,assets_collision_hulls(&assets,id,.None,&points,&sizes))
    testing.expect(t,len(points)==9 && points[0]==geom.Vec3{7,7,7} && points[1]==geom.Vec3{0,0,0} && len(sizes)==2 && sizes[1]==4)
    testing.expect(t,assets_mesh_release(&assets,id))
    testing.expect(t,!assets_collision_hulls(&assets,id,.None,&points,&sizes) && len(points)==9 && len(sizes)==2)
}
