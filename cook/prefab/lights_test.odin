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
    testing.expectf(t,abs(spot.inner*spot.angle-0.2)<1e-5,"and its inner cone, as a share of the outer one: %v",spot.inner)
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

// Imported lights carry shadowless fill, indirect/scattering multipliers,
// the length of a tube as a field with the scale of its node untouched, so a
// child keeps its own, and Hidden when the source node is invisible.
@(test)
imported_lights_keep_shadows_multipliers_tube_length_and_hidden :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"light-options")
    if folder=="" {return}
    path:=fmt.tprintf("%s/light_options.scene",folder)
    model:=importer.Imported_Model{
        name="light_options",
        nodes={
            {
                name="FillTube",
                path="FillTube",
                parent=-1,
                transform={rotation=1,scale={1,1,1}},
                mesh=-1,
                visible=true,
                light=importer.Imported_Light{
                    kind=.Point,color={0.8,0.9,1},intensity=250,range=10,
                    radius=f32(0.05),length=0.8,
                    shadows=false,indirect=f32(1.4),scattering=f32(0.5),
                },
            },
            {
                name="Cap",
                path="Cap",
                parent=0,
                transform={position={0.4,0,0},rotation=1,scale={0.5,0.5,0.5}},
                mesh=-1,
                visible=true,
            },
            {
                name="OffSpot",
                path="OffSpot",
                parent=-1,
                transform={rotation=1,scale={1,1,1}},
                mesh=-1,
                visible=false,
                light=importer.Imported_Light{
                    kind=.Spot,color={1,1,1},intensity=500,range=15,outer_cone=0.5,
                    shadows=false,indirect=f32(0),scattering=f32(0),
                },
            },
        },
    }
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    assets:=importer.Import_Report{allocator=context.allocator}
    defer importer.report_destroy(&assets)
    _,write_error:=model_prefab(&model,&assets,&types,import_world(t),{2,3},"light_options",path)
    if !testing.expect_value(t,write_error,Error.None) {return}
    scene:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&scene,&types,path),asset.Error.None) {return}
    defer asset.scene_destroy(&scene)
    entity_of :: proc(scene:^asset.Scene,name:string) -> base.Entity_Id {
        for i in 0..<asset.scene_entity_count(scene) {if record:=asset.scene_entity(scene,i);record.name==name {return record.id}}
        return 0
    }
    tube_id:=entity_of(&scene,"FillTube")
    pt,ok_pt:=asset.scene_get(&scene,tube_id,"Point_Light",render.Point_Light)
    tr,ok_tr:=asset.scene_get(&scene,tube_id,"Transform",core.Transform)
    testing.expectf(t,ok_pt && !pt.shadows && abs(pt.indirect-1.4)<1e-5 && abs(pt.scattering-0.5)<1e-5 && abs(pt.radius-0.05)<1e-5,"fill tube light fields preserved: %v",pt)
    testing.expectf(t,ok_tr && abs(pt.length-0.8)<1e-5 && tr.scale=={1,1,1},"a tube of 0.8 m with its entity unscaled: %v %v",pt.length,tr.scale)
    cap,ok_cap:=asset.scene_get(&scene,entity_of(&scene,"Cap"),"Transform",core.Transform)
    testing.expectf(t,ok_cap && cap.scale=={0.5,0.5,0.5},"the child of the tube keeps its own scale: %v",cap.scale)
    testing.expectf(t,len(assets.warnings)==0,"nothing to warn of: %v",assets.warnings)
    _,tube_hidden:=asset.scene_get(&scene,tube_id,"Hidden",render.Hidden)
    testing.expect(t,!tube_hidden,"visible light is not hidden")

    off_id:=entity_of(&scene,"OffSpot")
    sp,ok_sp:=asset.scene_get(&scene,off_id,"Spot_Light",render.Spot_Light)
    _,off_hidden:=asset.scene_get(&scene,off_id,"Hidden",render.Hidden)
    testing.expectf(t,ok_sp && !sp.shadows && sp.indirect==0 && sp.scattering==0,"off spot preserves flags: %v",sp)
    testing.expect(t,off_hidden,"invisible light carries Hidden")

    // Hostile non-finite and negative light values fall back safely with warnings.
    nan:=math.nan_f32()
    inf:=math.inf_f32(1)
    bad:=importer.Imported_Model{
        name="hostile_lights",
        nodes={
            {
                name="BadInf",path="BadInf",parent=-1,transform={rotation=1,scale={1,1,1}},mesh=-1,visible=true,
                light=importer.Imported_Light{kind=.Point,color={1,1,1},intensity=100,range=5,length=inf,radius=nan,indirect=inf,scattering=nan},
            },
            {
                name="BadNeg",path="BadNeg",parent=-1,transform={rotation=1,scale={1,1,1}},mesh=-1,visible=true,
                light=importer.Imported_Light{kind=.Point,color={1,1,1},intensity=100,range=5,length=-2,radius=f32(-1),indirect=f32(-0.5),scattering=f32(-1)},
            },
        },
    }
    bad_path:=fmt.tprintf("%s/hostile_lights.scene",folder)
    bad_assets:=importer.Import_Report{allocator=context.allocator}
    defer importer.report_destroy(&bad_assets)
    _,bad_err:=model_prefab(&bad,&bad_assets,&types,import_world(t),{2,4},"hostile_lights",bad_path)
    if !testing.expect_value(t,bad_err,Error.None) {return}
    bad_scene:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&bad_scene,&types,bad_path),asset.Error.None) {return}
    defer asset.scene_destroy(&bad_scene)
    for node_name in ([]string{"BadInf","BadNeg"}) {
        id:=entity_of(&bad_scene,node_name)
        p,ok_p:=asset.scene_get(&bad_scene,id,"Point_Light",render.Point_Light)
        tr_b,ok_tr_b:=asset.scene_get(&bad_scene,id,"Transform",core.Transform)
        testing.expectf(t,ok_p && p.radius==render.POINT_LIGHT_DEFAULT.radius && p.indirect==1 && p.scattering==1,"%s fell back cleanly: %v",node_name,p)
        testing.expectf(t,ok_tr_b && tr_b.scale=={1,1,1},"%s kept finite unit scale: %v",node_name,tr_b.scale)
    }
    testing.expectf(t,len(bad_assets.warnings)==8,"every invalid field reported a warning: %d",len(bad_assets.warnings))

    // USD CylinderLight + inputs:shadow:enable = false flows through import -> prefab.
    usd_source:=fmt.tprintf("%s/tube.usda",folder)
    usd_path:=fmt.tprintf("%s/tube.scene",folder)
    usd_text:=`#usda 1.0
(
    metersPerUnit = 0.01
    upAxis = "Y"
)
def CylinderLight "NeonTube"
{
    float inputs:intensity = 50
    float inputs:radius = 5
    float inputs:length = 80
    bool inputs:shadow:enable = false
    float3 xformOp:scale = (2, 1, 1)
    uniform token[] xformOpOrder = ["xformOp:scale"]
}
def Mesh "Floor"
{
    point3f[] points = [(0, 0, 0), (100, 0, 0), (0, 100, 0)]
    int[] faceVertexCounts = [3]
    int[] faceVertexIndices = [0, 1, 2]
    uniform token subdivisionScheme = "none"
}
`
    if !testing.expect(t,os.write_entire_file(usd_source,transmute([]u8)usd_text)==nil) {return}
    usd_opts:=usd.Options{no_usdcat=true}
    usd_formats:=[1]importer.Format{usd.format(&usd_opts)}
    usd_model,usd_err:=importer.import_model(usd_source,usd_formats[:])
    if !testing.expectf(t,usd_err.code==.None,"%v: %s",usd_err.code,usd_err.message) {return}
    defer importer.model_destroy(&usd_model)
    usd_assets:=importer.Import_Report{allocator=context.allocator}
    defer importer.report_destroy(&usd_assets)
    _,usd_write_err:=model_prefab(&usd_model,&usd_assets,&types,import_world(t),{2,5},"tube",usd_path)
    if !testing.expect_value(t,usd_write_err,Error.None) {return}
    usd_scene:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&usd_scene,&types,usd_path),asset.Error.None) {return}
    defer asset.scene_destroy(&usd_scene)
    neon_id:=entity_of(&usd_scene,"NeonTube")
    neon_pt,ok_neon:=asset.scene_get(&usd_scene,neon_id,"Point_Light",render.Point_Light)
    neon_tr,ok_neon_tr:=asset.scene_get(&usd_scene,neon_id,"Transform",core.Transform)
    testing.expectf(t,ok_neon && !neon_pt.shadows && abs(neon_pt.radius-0.05)<1e-4,"USD CylinderLight shadow:enable=false and 5cm radius: %v",neon_pt)
    testing.expectf(t,ok_neon_tr && abs(neon_pt.length-1.6)<1e-4 && neon_tr.scale=={2,1,1},"USD CylinderLight 80 cm by its scale of 2, in metres, its scale kept: %v %v",neon_pt.length,neon_tr.scale)
}
