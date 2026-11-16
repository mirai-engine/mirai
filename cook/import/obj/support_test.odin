package obj

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

close_to :: proc(a,b:[3]f32,tolerance:f32=1e-5) -> bool {return linalg.length(a-b)<tolerance}

triangle_count :: proc(mesh:^importer.Imported_Mesh) -> int {return len(mesh.indices)/3}

mesh_area :: proc(mesh:^importer.Imported_Mesh) -> f32 {
    area:f32
    for i in 0..<triangle_count(mesh) {
        p:=importer.mesh_triangle(mesh,i)
        area+=linalg.length(linalg.cross(p[1].position-p[0].position,p[2].position-p[0].position))*0.5
    }
    return area
}

unpacked_normal :: proc(vertex:asset.Vertex) -> [3]f32 {return mm.normal_unpack(vertex.normal)}

contains :: proc(text,part:string) -> bool {return strings.contains(text,part)}
