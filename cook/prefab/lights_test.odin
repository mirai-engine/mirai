package prefab

import "core:encoding/base64"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:cook/import/gltf"
import "mirai:cook/import/usd"
import "mirai:core"
import render "mirai:engine/render"
import "mirai:std/base"

@(rodata,private="file")
FORMATS:=[?]importer.Format{gltf.FORMAT}

// The punctual lights of a glTF reach its prefab in the entity of their node,
// in the same units: a sun, a point without a range given one, and a spot
// whose cone is out of what a Spot_Light takes, cut to it with a warning.
@(test)
imported_lights_are_the_lights_of_their_entities :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"lights")
    if folder=="" {return}
    source:=fmt.tprintf("%s/lights.gltf",folder)
    path:=fmt.tprintf("%s/lights.scene",folder)
    positions:=[9]f32{0,0,0,1,0,0,0,1,0}
    encoded,_:=base64.encode(mem.slice_to_bytes(positions[:]),allocator=context.temp_allocator)
    text:=strings.concatenate({`{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0,1,2,3]}],"meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],"accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","min":[0,0,0],"max":[1,1,0]}],"bufferViews":[{"buffer":0,"byteLength":36}],"buffers":[{"byteLength":36,"uri":"data:application/octet-stream;base64,`,encoded,`"}],
        "nodes":[{"name":"Sun","extensions":{"KHR_lights_punctual":{"light":0}}},{"name":"Bulb","extensions":{"KHR_lights_punctual":{"light":1}}},{"name":"Spot","extensions":{"KHR_lights_punctual":{"light":2}}},{"name":"Floor","mesh":0}],
        "extensionsUsed":["KHR_lights_punctual"],
        "extensions":{"KHR_lights_punctual":{"lights":[
            {"type":"directional","color":[1,0.9,0.8],"intensity":3000},
            {"type":"point","color":[1,1,1],"intensity":50},
            {"type":"spot","color":[0.5,0.5,1],"intensity":40,"range":12,"spot":{"innerConeAngle":0.2,"outerConeAngle":1.565}}]}}}`},context.temp_allocator)
    if !testing.expect(t,os.write_entire_file(source,transmute([]u8)text)==nil) {return}
    model,error:=importer.import_model(source,FORMATS[:])
    if !testing.expectf(t,error.code==.None,"%v: %s",error.code,error.message) {return}
    defer importer.model_destroy(&model)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    assets:=importer.Import_Report{allocator=context.allocator}
    defer importer.report_destroy(&assets)
    _,write_error:=model_prefab(&model,&assets,&types,import_world(t),{1,2},"lights",path)
    if !testing.expect_value(t,write_error,Error.None) {return}
    scene:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&scene,&types,path),asset.Error.None) {return}
    defer asset.scene_destroy(&scene)
    entity_of :: proc(scene:^asset.Scene,name:string) -> base.Entity_Id {
        for i in 0..<asset.scene_entity_count(scene) {if record:=asset.scene_entity(scene,i);record.name==name {return record.id}}
        return 0
    }
    sun,is_sun:=asset.scene_get(&scene,entity_of(&scene,"Sun"),"Sun",render.Sun)
    testing.expectf(t,is_sun && sun.illuminance==3000 && sun.color=={1,0.9,0.8} && sun.disc,"a directional light is a sun in lux: %v",sun)
    point,is_point:=asset.scene_get(&scene,entity_of(&scene,"Bulb"),"Point_Light",render.Point_Light)
    testing.expectf(t,is_point && point.intensity==50 && abs(point.range-10)<1e-4,"a point in candela, as far as it gives 0.5 lux: %v",point)
    spot,is_spot:=asset.scene_get(&scene,entity_of(&scene,"Spot"),"Spot_Light",render.Spot_Light)
    testing.expectf(t,is_spot && spot.intensity==40 && spot.range==12 && spot.angle==render.SPOT_MAX,"a spot keeps its outer cone, cut to 89°: %v",spot)
    testing.expect(t,len(assets.warnings)==1 && strings.contains(assets.warnings[0],"Spot"),"the cut cone is reported")
}

// A rectangle reaches its prefab as a Rect_Light sized by the scale of its
// entity, and a sphere as a point of its radius.
@(test)
imported_rectangles_are_rect_lights_sized_by_their_entity :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"rect-lights")
    if folder=="" {return}
    source:=fmt.tprintf("%s/rect-lights.usda",folder)
    path:=fmt.tprintf("%s/rect-lights.scene",folder)
    text:=`#usda 1.0
(
    metersPerUnit = 1
    upAxis = "Y"
)
def RectLight "Panel"
{
    float inputs:intensity = 300
    float inputs:width = 2
    float inputs:height = 0.5
    float3 xformOp:scale = (1, 3, 1)
    uniform token[] xformOpOrder = ["xformOp:scale"]
}
def SphereLight "Bulb"
{
    float inputs:radius = 0.1
}
def Mesh "Floor"
{
    point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
    int[] faceVertexCounts = [3]
    int[] faceVertexIndices = [0, 1, 2]
    uniform token subdivisionScheme = "none"
}
`
    if !testing.expect(t,os.write_entire_file(source,transmute([]u8)text)==nil) {return}
    options:=usd.Options{no_usdcat=true}
    formats:=[1]importer.Format{usd.format(&options)}
    model,error:=importer.import_model(source,formats[:])
    if !testing.expectf(t,error.code==.None,"%v: %s",error.code,error.message) {return}
    defer importer.model_destroy(&model)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    assets:=importer.Import_Report{allocator=context.allocator}
    defer importer.report_destroy(&assets)
    _,write_error:=model_prefab(&model,&assets,&types,import_world(t),{1,2},"rect-lights",path)
    if !testing.expect_value(t,write_error,Error.None) {return}
    scene:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&scene,&types,path),asset.Error.None) {return}
    defer asset.scene_destroy(&scene)
    entity_of :: proc(scene:^asset.Scene,name:string) -> base.Entity_Id {
        for i in 0..<asset.scene_entity_count(scene) {if record:=asset.scene_entity(scene,i);record.name==name {return record.id}}
        return 0
    }
    panel:=entity_of(&scene,"Panel")
    rect,is_rect:=asset.scene_get(&scene,panel,"Rect_Light",render.Rect_Light)
    testing.expectf(t,is_rect && rect.luminance==300 && abs(rect.range-math.sqrt(f32(300*2*0.5)/0.5))<1e-3,"a rectangle in nits, as far as its candelas give 0.5 lux: %v",rect)
    transform,has_transform:=asset.scene_get(&scene,panel,"Transform",core.Transform)
    testing.expectf(t,has_transform && abs(transform.scale.x-2)<1e-6 && abs(transform.scale.y-1.5)<1e-6 && transform.scale.z==1,"its size scales its entity: %v",transform.scale)
    point,is_point:=asset.scene_get(&scene,entity_of(&scene,"Bulb"),"Point_Light",render.Point_Light)
    testing.expectf(t,is_point && abs(point.radius-0.1)<1e-6,"a point keeps the radius of its sphere: %v",point)
}
