package sources

import "core:fmt"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import importer "mirai:cook/import"
import "mirai:cook/import/gltf"
import "mirai:cook/import/obj"
import "mirai:cook/import/usd"
import "mirai:std/base"
import mm "mirai:std/math"

FIXTURES :: #directory+"/../../../assets/fixtures/"
DEMO :: #directory+"/../../../demo/assets/"

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

// A Library that gives no formats and the types of the game context.user_ptr
// points to: what sync and mirai import write the prefab of a model in.
test_library :: proc(root:string,allocator:mem.Allocator) -> Library_Imports {
    return {world=(^core.World_Info)(context.user_ptr)}
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

// Writes model as the import of a copy of its source in the assets of the
// test project at root, as import_write takes it: a source in no assets
// folder imports nowhere.
write_into :: proc(model:^importer.Imported_Model,root:string,options:importer.Import_Options={}) -> (report:importer.Import_Report,error:importer.Error) {
    assets:=fmt.tprintf("%s/assets",root)
    copied:=fmt.tprintf("%s/%s",assets,filepath.base(model.source))
    if model.source!=copied {
        os.make_directory_all(assets)
        data,_:=os.read_entire_file(model.source,context.temp_allocator)
        _=os.write_entire_file(copied,data)
        model.source=copied
    }
    options:=options
    options.root=root
    return importer.import_write(model,options)
}

// Copies files of a folder (FIXTURES, DEMO), by their paths under it, into
// the assets of the test project at root under the same paths, and gives
// where the first went.
copy_in :: proc(root,from:string,files:..string) -> string {
    first:string
    for file,at in files {
        target:=fmt.tprintf("%s/assets/%s",root,file)
        os.make_directory_all(filepath.dir(target))
        data,_:=os.read_entire_file(fmt.tprintf("%s%s",from,file),context.temp_allocator)
        _=os.write_entire_file(target,data)
        if at==0 {first=target}
    }
    return first
}

// A folder of a test as the root of a project, with its assets folder, where
// the sources of its imports are. "" when there is none.
test_project :: proc(t:^testing.T,name:string) -> (root,assets:string) {
    root=base.test_folder(t,name)
    if root=="" {return}
    assets=fmt.tprintf("%s/assets",root)
    os.make_directory_all(assets)
    return
}
