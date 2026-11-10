package gltf

import "core:fmt"
import "core:mem"
import "core:os"
import "core:testing"
import importer "mirai:cook/import"
import "mirai:std/base"

// A node moved by one clip whose glTF animation carries markers in its extras.
@(private="file")
markers_fixture :: proc(folder,markers:string) -> string {
    values:=[8]f32{0,1, 0,0,0, 1,0,0}
    if os.write_entire_file(fmt.tprintf("%s/markers.bin",folder),mem.slice_data_cast([]u8,values[:]))!=nil {return ""}
    return write_text(folder,"markers.gltf",fmt.tprintf(`{{"asset":{{"version":"2.0"}},"buffers":[{{"uri":"markers.bin","byteLength":32}}],"bufferViews":[{{"buffer":0,"byteOffset":0,"byteLength":8}},{{"buffer":0,"byteOffset":8,"byteLength":24}}],"accessors":[{{"bufferView":0,"componentType":5126,"count":2,"type":"SCALAR","min":[0],"max":[1]}},{{"bufferView":1,"componentType":5126,"count":2,"type":"VEC3"}}],"nodes":[{{"name":"Mover"}}],"scenes":[{{"nodes":[0]}}],"scene":0,"animations":[{{"name":"Step","samplers":[{{"input":0,"output":1,"interpolation":"LINEAR"}}],"channels":[{{"sampler":0,"target":{{"node":0,"path":"translation"}}}}],"extras":{{"markers":%s}}}}]}}`,markers))
}

// The events a source keeps on a clip's timeline (footsteps, notifies) come in as its markers,
// sorted by time; a marker at a time that is not finite and nonnegative fails the import.
@(test)
gltf_animation_extras_give_the_markers_of_the_clip :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"markers-import")
    if folder=="" {return}
    model,ok:=import_ok(t,markers_fixture(folder,`[{"name":"foot_r","time":0.6},{"name":"foot_l","time":0.25}]`));defer importer.model_destroy(&model)
    if !ok {return}
    testing.expect_value(t,len(model.animations),1)
    markers:=model.animations[0].markers
    testing.expect_value(t,len(markers),2)
    if len(markers)==2 {
        testing.expect(t,markers[0].name=="foot_l" && markers[0].time==0.25 && markers[1].name=="foot_r" && markers[1].time==0.6,"sorted by time")
    }
    _,error:=importer.import_model(markers_fixture(folder,`[{"name":"foot_l","time":-1}]`),FORMATS[:],{})
    testing.expect_value(t,error.code,importer.Error_Code.Malformed)
}
