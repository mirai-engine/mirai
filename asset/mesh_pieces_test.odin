package asset

import "core:fmt"
import "core:os"
import "core:testing"
import "mirai:std/base"
import "mirai:std/geom"

// A mesh file that stores no colliders is decomposed into convex pieces once: the cache keeps them by the
// content of the file, and what it keeps is what is given after. One that stores colliders is not
// decomposed, and a cooked one gives the pieces it carries.
@(test)
a_mesh_without_colliders_is_decomposed_once_into_pieces_the_cache_keeps :: proc(t:^testing.T) {
    root:=base.test_folder(t,"asset-pieces")
    if root=="" {return}
    types:Types;types_init(&types);defer types_destroy(&types)
    vertices:=make([dynamic]Vertex,context.temp_allocator)
    order:=make([dynamic]u32,context.temp_allocator)
    for part in 0..<2 {
        box:geom.Mesh_Buffer
        geom.mesh_buffer_init(&box,context.temp_allocator)
        geom.cube_build(&box,part==0?geom.Vec3{3,1,1}:geom.Vec3{1,3,1})
        first:=u32(len(vertices))
        for position in box.positions {append(&vertices,Vertex{position=position+(part==0?geom.Vec3{1,0,0}:geom.Vec3{0,2,0})})}
        for index in box.indices {append(&order,first+index)}
    }
    g:Mesh_Geometry
    if !testing.expect(t,mesh_build({vertices=vertices[:]},order[:],nil,&g,context.temp_allocator)) {return}
    tetra:=[4][3]f32{{0,0,0},{1,0,0},{0,1,0},{0,0,1}}
    one:=[1]u32{4}
    box:=[1]Collider{{kind=.Box,rotation=1,size={1,1,1}}}
    bare,boxed,cooked:=fmt.tprintf("%s/bare.mesh",root),fmt.tprintf("%s/boxed.mesh",root),fmt.tprintf("%s/cooked.mesh",root)
    testing.expect_value(t,mesh_save(bare,&types,{id={0x62617265,1},geometry=g}),Error.None)
    testing.expect_value(t,mesh_save(boxed,&types,{id={0x626f786564,1},geometry=g,colliders=box[:]}),Error.None)
    testing.expect_value(t,mesh_save(cooked,&types,{id={0x636f6f6b6564,1},geometry=g,piece_points=tetra[:],piece_sizes=one[:]}),Error.None)
    folder:=fmt.tprintf("%s/cache",root)
    pieces :: proc(types:^Types,path,folder:string,points:^[dynamic]geom.Vec3,sizes:^[dynamic]u32) -> bool {
        file:Asset
        if asset_load(&file,path,context.temp_allocator)!=.None {return false}
        defer asset_close(&file)
        return mesh_collision_pieces(&file,types,folder,points,sizes)
    }
    points:=make([dynamic]geom.Vec3,context.temp_allocator)
    sizes:=make([dynamic]u32,context.temp_allocator)
    testing.expect(t,!pieces(&types,bare,"",&points,&sizes) && len(sizes)==0,"without a cache, as a shipped game, nothing is decomposed")
    if !testing.expect(t,pieces(&types,bare,folder,&points,&sizes) && len(sizes)>=2,"an L is two convex pieces or more") {return}
    total:=0
    for size in sizes {total+=int(size)}
    testing.expect_value(t,total,len(points))
    kept,_:=os.read_all_directory_by_path(folder,context.temp_allocator)
    if !testing.expect_value(t,len(kept),1) {return}
    // A file put in its place with one piece is what is given next: it is not decomposed again.
    held:Asset
    if !testing.expect_value(t,asset_load(&held,kept[0].fullpath,context.temp_allocator),Error.None) {return}
    header:=held.blob.header
    asset_close(&held)
    doc:Document
    document_init(&doc,COLLISION_PIECES_KIND,header.id,context.temp_allocator)
    doc.kind_version=COLLISION_PIECES_VERSION
    document_put(&doc,&types,"points",tetra[:])
    document_put(&doc,&types,"sizes",one[:])
    testing.expect_value(t,document_save(&doc,kept[0].fullpath),Error.None)
    clear(&points);clear(&sizes)
    testing.expect(t,pieces(&types,bare,folder,&points,&sizes) && len(sizes)==1 && sizes[0]==4 && points[1]==geom.Vec3{1,0,0},"the pieces come from the cache")
    clear(&points);clear(&sizes)
    testing.expect(t,!pieces(&types,boxed,folder,&points,&sizes) && len(points)==0,"a mesh that stores colliders is not decomposed")
    clear(&points);clear(&sizes)
    testing.expect(t,pieces(&types,cooked,"",&points,&sizes) && len(sizes)==1 && points[3]==geom.Vec3{0,0,1},"a cooked mesh gives the pieces it carries")
}
