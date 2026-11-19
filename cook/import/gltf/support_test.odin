package gltf

import "core:fmt"
import "core:math/linalg"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:store"

FIXTURES :: #directory+"/../../../assets/fixtures/"
DEMO :: #directory+"/../../../demo/assets/"

@(rodata)
FORMATS:=[?]importer.Format{FORMAT}

write_text :: proc(folder,name,text:string) -> string {
    path:=fmt.tprintf("%s/%s",folder,name)
    _=os.write_entire_file(path,text)
    return path
}

// Writes a model as the import of a copy of its source in the assets of a
// test project, as import_write takes it: "" for the folder when there is none.
write_model :: proc(t:^testing.T,model:^importer.Imported_Model,name:string) -> (report:importer.Import_Report,error:importer.Error,folder:string) {
    root:=base.test_folder(t,name)
    if root=="" {return}
    folder=fmt.tprintf("%s/assets",root)
    os.make_directory_all(folder)
    copied:=fmt.tprintf("%s/%s",folder,filepath.base(model.source))
    data,_:=os.read_entire_file(model.source,context.temp_allocator)
    _=os.write_entire_file(copied,data)
    model.source=copied
    report,error=write_again(t,model,root)
    return
}

// Writes model again as the import of the project at root, into the store of
// that project, with the documents beside its source; each output of the cache
// gets the file of its object as its path.
write_again :: proc(t:^testing.T,model:^importer.Imported_Model,root:string) -> (report:importer.Import_Report,error:importer.Error) {
    opened,store_error:=store.open(fmt.tprintf("%s/store",root),context.temp_allocator)
    if !testing.expect_value(t,store_error,store.Error.None) {return {},{code=.Write}}
    s:=new(store.Store,context.temp_allocator)
    s^=opened
    report,error=importer.import_write(model,{root=root,store=s,documents=filepath.dir(importer.path_key(model.source))})
    for &written in report.assets {
        if written.path!="" || written.object=={} {continue}
        digits:[64]u8
        path:=fmt.tprintf("%s-objects/%s",s.root,store.hex(written.object,&digits))
        os.make_directory_all(filepath.dir(path))
        if !os.exists(path) {asset.object_file_write(s,written.object,path)}
        written.path=strings.clone(path)
    }
    return
}

import_ok :: proc(t:^testing.T,path:string,options:importer.Import_Options={}) -> (model:importer.Imported_Model,ok:bool) {
    error:importer.Error
    model,error=importer.import_model(path,FORMATS[:],options)
    ok=testing.expectf(t,error.code==.None,"%s: %v %s",path,error.code,error.message)
    return
}

find_node :: proc(model:^importer.Imported_Model,name:string) -> int {
    for node,i in model.nodes {
        if node.name==name {return i}
    }
    return -1
}

world_transform :: proc(model:^importer.Imported_Model,row:int) -> mm.Transform {
    transform:=model.nodes[row].transform
    if model.nodes[row].parent>=0 {transform=mm.transform_compose(world_transform(model,model.nodes[row].parent),transform)}
    return transform
}

close_to :: proc(a,b:[3]f32,tolerance:f32=1e-5) -> bool {return linalg.length(a-b)<tolerance}

triangle_positions :: proc(mesh:^importer.Imported_Mesh,i:int) -> (p:[3][3]f32) {
    corners:=importer.mesh_triangle(mesh,i)
    for k in 0..<3 {p[k]=corners[k].position}
    return
}

triangle_count :: proc(mesh:^importer.Imported_Mesh) -> int {return len(mesh.indices)/3}

unpacked_normal :: proc(vertex:asset.Vertex) -> [3]f32 {return mm.normal_unpack(vertex.normal)}

contains :: proc(text,part:string) -> bool {return strings.contains(text,part)}
