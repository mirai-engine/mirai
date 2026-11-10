package sources

import "core:fmt"
import "core:math/linalg"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:cook/import/gltf"
import "mirai:cook/import/obj"
import "mirai:cook/import/usd"
import mm "mirai:std/math"

FIXTURES :: #directory+"/../../../assets/fixtures/"
DEMO :: #directory+"/../../../demo/source/"

@(rodata)
USD_TEXT:=usd.Options{no_usdcat=true}

// FORMATS with USD read as text, without usdcat, as every machine can.
text_formats :: proc() -> [3]importer.Format {
    return {gltf.FORMAT,usd.format(&USD_TEXT),obj.FORMAT}
}

write_text :: proc(folder,name,text:string) -> string {
    path:=fmt.tprintf("%s/%s",folder,name)
    _=os.write_entire_file(path,text)
    return path
}

// formats: FORMATS when nil.
import_ok :: proc(t:^testing.T,path:string,options:importer.Import_Options={},formats:[]importer.Format=nil) -> (model:importer.Imported_Model,ok:bool) {
    error:importer.Error
    model,error=importer.import_model(path,formats if formats!=nil else FORMATS[:],options)
    ok=testing.expectf(t,error.code==.None,"%s: %v %s",path,error.code,error.message)
    return
}

find_node :: proc(model:^importer.Imported_Model,name:string) -> int {
    for node,i in model.nodes {
        if node.name==name {return i}
    }
    return -1
}

close_to :: proc(a,b:[3]f32,tolerance:f32=1e-5) -> bool {return linalg.length(a-b)<tolerance}

unpacked_normal :: proc(vertex:asset.Vertex) -> [3]f32 {return mm.normal_unpack(vertex.normal)}

contains :: proc(text,part:string) -> bool {return strings.contains(text,part)}

string_of :: proc(field:[]u8) -> string {
    for b,i in field {
        if b==0 {return string(field[:i])}
    }
    return string(field)
}
