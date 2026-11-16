package sources

import "core:fmt"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:std/base"
import "mirai:std/geom"
import importer "mirai:cook/import"

@(test)
paths_that_name_devices_are_not_read :: proc(t:^testing.T) {
    when ODIN_OS==.Windows {
        _,folder:=test_project(t,"devices")
        if folder=="" {return}
        path:=write_text(folder,"d.obj","mtllib con\nmtllib nul.mtl\nv 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n")
        model,ok:=import_ok(t,path)
        if ok {
            testing.expect_value(t,len(model.warnings),2)
            importer.model_destroy(&model)
        }
        write_text(folder,"m.mtl","newmtl a\nmap_Kd com1.png\n")
        path=write_text(folder,"i.obj","mtllib m.mtl\nusemtl a\nv 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n")
        model,ok=import_ok(t,path)
        if ok {
            testing.expect(t,len(model.images)==0 && len(model.warnings)==1 && model.materials[0].images[.Base_Color]==-1)
            importer.model_destroy(&model)
        }
        _,error:=importer.import_model(fmt.tprintf("%s/con.obj",folder),FORMATS[:])
        testing.expect_value(t,error.code,importer.Error_Code.Not_Found)
        path=write_text(folder,"b.gltf",`{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"mesh":0}],"meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],"buffers":[{"byteLength":36,"uri":"con"}],"bufferViews":[{"buffer":0,"byteLength":36}],"accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}]}`)
        _,error=importer.import_model(path,FORMATS[:])
        testing.expect(t,error.code==.Malformed && contains(error.message,"device"),error.message)
        _,texture_error:=importer.import_texture(fmt.tprintf("%s/nul.png",folder),{image=.Color})
        testing.expect_value(t,texture_error.code,importer.Error_Code.Not_Found)
    }
}
