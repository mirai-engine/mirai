package gltf

import "core:fmt"
import "core:math/linalg"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import importer "mirai:cook/import"
import mm "mirai:std/math"

FIXTURES :: #directory+"/../../../assets/fixtures/"
DEMO :: #directory+"/../../../demo/assets/"

@(rodata)
FORMATS:=[?]importer.Format{FORMAT}

write_text :: proc(folder,name,text:string) -> string {
    path:=fmt.tprintf("%s/%s",folder,name)
    _=os.write_entire_file(path,text)
    return path
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
