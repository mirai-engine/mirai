package gltf

import "core:encoding/base64"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:std/base"
import mm "mirai:std/math"
import importer "mirai:cook/import"

// A glTF with one node holding a triangle; extra goes into the JSON of the node, extensions at the top.
@(private="file")
tiny_gltf :: proc(node_extra:string,top_extra:="") -> string {
    positions:=[9]f32{0,0,0,1,0,0,0,1,0}
    encoded,_:=base64.encode(mem.slice_to_bytes(positions[:]),allocator=context.temp_allocator)
    return strings.concatenate({`{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"mesh":0`,node_extra,`}],"meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],"buffers":[{"byteLength":36,"uri":"data:application/octet-stream;base64,`,encoded,`"}],"bufferViews":[{"buffer":0,"byteLength":36}],"accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","min":[0,0,0],"max":[1,1,0]}]`,top_extra,`}`},context.temp_allocator)
}

@(test)
nodes_names_instances_and_hierarchy_of_gltf_and_glb_survive :: proc(t:^testing.T) {
    for filename in ([]string{"hierarchy.gltf","hierarchy.glb"}) {
        model,ok:=import_ok(t,fmt.tprintf("%s%s",FIXTURES,filename))
        if !ok {continue}
        defer importer.model_destroy(&model)
        testing.expect_value(t,len(model.meshes),1)
        testing.expect_value(t,len(model.nodes),3)
        child,instance:=find_node(&model,"Child"),find_node(&model,"Instance")
        testing.expect(t,child>=0 && instance>=0 && find_node(&model,"Unused")<0,"node names survive and the node outside the scene is left out")
        if child<0 || instance<0 {continue}
        testing.expect(t,close_to(world_transform(&model,child).position,{-2,3,0}),"parent and child transforms compose")
        testing.expect(t,model.nodes[child].mesh==0 && model.nodes[instance].mesh==0,"two nodes share one mesh")
        testing.expect(t,close_to(world_transform(&model,instance).position,{-10,0,0}),"the second instance has an independent transform")
        testing.expect_value(t,len(model.materials),1)
        material:=&model.materials[0]
        testing.expect_value(t,material.name,"material 0")
        testing.expect(t,close_to(material.info.base_color,{0.2,0.8,0.4}) && close_to(material.info.emission,{0.1,0.2,0}),"the factors of the material survive")
        testing.expect(t,material.info.metallic==1 && material.info.roughness==1,"factors left out take the defaults of the format")
        mesh:=&model.meshes[0]
        testing.expect_value(t,triangle_count(mesh),1)
        testing.expect(t,close_to(unpacked_normal(mesh.vertices[0]),{0,0,-1},1e-3),"a primitive without normals is flat")
        testing.expect(t,mesh.slots[0].material==0 && mesh.slots[0].id==1)
        testing.expect_value(t,len(model.warnings),0)
    }
}

@(test)
a_single_node_keeps_its_own_transform :: proc(t:^testing.T) {
    model,ok:=import_ok(t,FIXTURES+"single-transform.gltf")
    if !ok {return}
    defer importer.model_destroy(&model)
    testing.expect_value(t,len(model.nodes),1)
    testing.expect(t,model.nodes[0].mesh==0 && model.nodes[0].parent==-1)
    scale:=model.nodes[0].transform.scale
    testing.expect(t,model.nodes[0].transform.position!={0,0,0} && scale.x!=scale.y,"the translation and uneven scale of the node are kept")
}

@(test)
the_plant_of_the_demo_has_slots_per_primitive_and_a_masked_texture :: proc(t:^testing.T) {
    model,ok:=import_ok(t,DEMO+"models/plant.gltf")
    if !ok {return}
    defer importer.model_destroy(&model)
    testing.expect_value(t,len(model.warnings),0)
    testing.expect_value(t,len(model.nodes),1)
    mesh:=&model.meshes[0]
    testing.expect_value(t,len(mesh.slots),3)
    testing.expect_value(t,len(mesh.submeshes),3)
    testing.expect_value(t,len(model.materials),3)
    leaves:=&model.materials[2]
    testing.expect(t,leaves.name=="Leaves" && leaves.info.alpha_mode==.Mask && leaves.info.alpha_cutoff==0.5)
    image:=leaves.images[.Base_Color]
    testing.expect(t,image>=0 && model.images[image].srgb && model.images[image].alpha_cutoff==0.5 && strings.has_suffix(model.images[image].path,"/demo/source/textures/leaves_color.png"),"a masked material asks its image to keep its coverage")
    testing.expect(t,.Has_Colors not_in mesh.flags && .Has_Uv1 not_in mesh.flags && mesh.bounds_max.y>mesh.bounds_min.y)
}

@(test)
a_node_matrix_decomposes_to_the_same_transform_and_shear_is_rejected :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"gltf-matrix")
    if folder=="" {return}
    for rotation in ([]quaternion128{quaternion(x=0.1,y=0.2,z=0.3,w=0.9),quaternion(x=0,y=0.7071068,z=0,w=0.7071068)}) {
        source:=mm.Transform{{2,3,4},linalg.normalize(rotation),{-2,3,4}}
        m:=mm.transform_matrix(source)
        values:strings.Builder
        strings.builder_init(&values,context.temp_allocator)
        for column in 0..<4 {
            for row in 0..<4 {fmt.sbprintf(&values,"%v,",m[row,column])}
        }
        text:=strings.to_string(values)
        path:=write_text(folder,"matrix.gltf",tiny_gltf(fmt.tprintf(`,"matrix":[%s]`,text[:len(text)-1])))
        model,ok:=import_ok(t,path)
        if !ok {continue}
        restored:=mm.transform_matrix(model.nodes[0].transform)
        turn:=[4]f32{-1,1,-1,1}
        for column in 0..<4 {
            for row in 0..<4 {testing.expectf(t,abs(restored[row,column]-turn[row]*turn[column]*m[row,column])<1e-4,"matrix[%d,%d]: %v against %v",row,column,restored[row,column],m[row,column])}
        }
        importer.model_destroy(&model)
    }
    path:=write_text(folder,"shear.gltf",tiny_gltf(`,"matrix":[1,0,0,0, 0.2,1,0,0, 0,0,1,0, 0,0,0,1]`))
    _,error:=importer.import_model(path,FORMATS[:])
    testing.expect_value(t,error.code,importer.Error_Code.Unsupported)
    testing.expect(t,contains(error.message,"shear"),error.message)
    path=write_text(folder,"zero.gltf",tiny_gltf(`,"scale":[0,1,1]`))
    _,error=importer.import_model(path,FORMATS[:])
    testing.expect_value(t,error.code,importer.Error_Code.Unsupported)
    path=write_text(folder,"negative.gltf",tiny_gltf(`,"scale":[-2,3,4],"rotation":[0,0.7071068,0,0.7071068]`))
    model,ok:=import_ok(t,path)
    if ok {
        testing.expect(t,model.nodes[0].transform.scale=={-2,3,4},"a negative scale is kept")
        importer.model_destroy(&model)
    }
}

@(test)
punctual_lights_become_light_descriptions :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"gltf-light")
    if folder=="" {return}
    lights:=`,"extensionsUsed":["KHR_lights_punctual"],"extensions":{"KHR_lights_punctual":{"lights":[{"type":"spot","color":[1,0.5,0.25],"intensity":40,"range":12,"spot":{"innerConeAngle":0.2,"outerConeAngle":0.6}}]}}`
    path:=write_text(folder,"light.gltf",tiny_gltf(`,"extensions":{"KHR_lights_punctual":{"light":0}}`,lights))
    model,ok:=import_ok(t,path)
    if !ok {return}
    defer importer.model_destroy(&model)
    light,has_light:=model.nodes[0].light.?
    testing.expect(t,has_light && light.kind==.Spot && light.color=={1,0.5,0.25} && light.intensity==40 && light.range==12)
    testing.expect(t,abs(light.inner_cone-0.2)<1e-6 && abs(light.outer_cone-0.6)<1e-6)
    shines:=mm.quat_forward(model.nodes[0].transform.rotation)
    testing.expectf(t,close_to(shines,{0,0,1},1e-4),"what shone toward -Z of the file shines where the half turn takes it: %v",shines)
}

@(test)
a_truncated_or_corrupt_glb_and_missing_buffers_fail_cleanly :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"gltf-broken")
    if folder=="" {return}
    bytes,error:=os.read_entire_file(FIXTURES+"hierarchy.glb",context.temp_allocator)
    testing.expect(t,error==nil)
    for length in ([]int{4,12,40,len(bytes)-10}) {
        path:=fmt.tprintf("%s/cut-%d.glb",folder,length)
        _=os.write_entire_file(path,bytes[:length])
        _,failed:=importer.import_model(path,FORMATS[:])
        testing.expectf(t,failed.code==.Malformed || failed.code==.Unsupported,"a glb cut at %d bytes fails: %v %s",length,failed.code,failed.message)
    }
    path:=write_text(folder,"bad.gltf",`{"asset":{"version":"2.0"},"nodes":[`)
    _,failed:=importer.import_model(path,FORMATS[:])
    testing.expect_value(t,failed.code,importer.Error_Code.Malformed)
    path=write_text(folder,"nobuffer.gltf",`{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"mesh":0}],"meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],"buffers":[{"byteLength":36,"uri":"missing.bin"}],"bufferViews":[{"buffer":0,"byteLength":36}],"accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}]}`)
    _,failed=importer.import_model(path,FORMATS[:])
    testing.expect_value(t,failed.code,importer.Error_Code.Read)
    _=os.write_entire_file(fmt.tprintf("%s/missing.bin",folder),[]u8{1,2,3,4})
    _,failed=importer.import_model(path,FORMATS[:])
    testing.expect(t,failed.code==.Malformed,failed.message)
    path=write_text(folder,"nomesh.gltf",`{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"name":"Empty"}]}`)
    _,failed=importer.import_model(path,FORMATS[:])
    testing.expect_value(t,failed.code,importer.Error_Code.Malformed)
}

@(test)
a_primitive_asking_for_a_missing_texture_coordinate_set_is_rejected :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"gltf-uv")
    if folder=="" {return}
    text,_:=strings.replace(tiny_gltf(""),`"meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}]`,`"meshes":[{"primitives":[{"attributes":{"POSITION":0},"material":0}]}],"materials":[{"pbrMetallicRoughness":{"baseColorTexture":{"index":0}}}],"textures":[{"source":0}],"images":[{"uri":"color.png"}]`,1,context.temp_allocator)
    path:=write_text(folder,"uv.gltf",text)
    _,error:=importer.import_model(path,FORMATS[:])
    testing.expect_value(t,error.code,importer.Error_Code.Malformed)
    testing.expect(t,contains(error.message,"TEXCOORD_0"),error.message)
}

@(test)
layered_gltf_extensions_become_the_layers_of_the_material :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"gltf-layers")
    if folder=="" {return}
    primitives:=`"meshes":[{"primitives":[{"attributes":{"POSITION":0},"material":0},{"attributes":{"POSITION":0},"material":1},{"attributes":{"POSITION":0},"material":2},{"attributes":{"POSITION":0},"material":3},{"attributes":{"POSITION":0},"material":4}]}]`
    materials:=`,"materials":[
        {"extensions":{"KHR_materials_clearcoat":{"clearcoatFactor":0.8,"clearcoatRoughnessFactor":0.3}}},
        {"extensions":{"KHR_materials_sheen":{"sheenColorFactor":[0.5,0.25,0],"sheenRoughnessFactor":0.4}}},
        {"pbrMetallicRoughness":{"roughnessFactor":0.5},"extensions":{"KHR_materials_anisotropy":{"anisotropyStrength":0.6,"anisotropyRotation":1}}},
        {"pbrMetallicRoughness":{"baseColorFactor":[0.2,0.4,0.6,0.5]},"extensions":{"KHR_materials_unlit":{},"KHR_materials_clearcoat":{"clearcoatFactor":1}}},
        {"extensions":{"KHR_materials_diffuse_transmission":{"diffuseTransmissionFactor":0.4,"diffuseTransmissionColorFactor":[1,0.75,0.5]}}}]`
    text,_:=strings.replace(tiny_gltf(""),`"meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}]`,strings.concatenate({primitives,materials},context.temp_allocator),1,context.temp_allocator)
    model,ok:=import_ok(t,write_text(folder,"layers.gltf",text))
    if !ok {return}
    defer importer.model_destroy(&model)
    if !testing.expect_value(t,len(model.materials),5) {return}
    testing.expect_value(t,len(model.warnings),0)
    coat:=&model.materials[0].info
    testing.expect_value(t,asset.material_layers(coat),asset.Material_Layers{.Coat})
    testing.expect(t,coat.coat.weight==0.8 && coat.coat.roughness==0.3 && coat.coat.ior==1.5 && coat.coat.color=={1,1,1},"a white coat of index 1.5")
    // c·f + (1 - max(c)·E)·base: the fuzz of weight max(c) and color c/max(c).
    fuzz:=&model.materials[1].info
    testing.expect_value(t,asset.material_layers(fuzz),asset.Material_Layers{.Fuzz})
    testing.expect(t,fuzz.fuzz.weight==0.5 && close_to(fuzz.fuzz.color,{1,0.5,0}) && fuzz.fuzz.roughness==0.4,"the sheen color splits into a weight and a color")
    // The OpenPBR lobe has the alphas of glTF's: mix(r², 1, s²) along the tangent and r² across it.
    turned:=&model.materials[2].info
    testing.expect_value(t,asset.material_layers(turned),asset.Material_Layers{.Anisotropy})
    r,a:=turned.roughness,turned.anisotropy.amount
    along:=r*r*math.sqrt(2/(1+(1-a)*(1-a)))
    testing.expectf(t,abs(along-math.lerp(f32(0.25),f32(1),f32(0.36)))<1e-5 && abs((1-a)*along-0.25)<1e-5,"alphas %v and %v",along,(1-a)*along)
    testing.expect_value(t,turned.anisotropy.rotation,1)
    // Unlit shows its base color as emission and keeps its opacity; it has no other layer.
    unlit:=&model.materials[3].info
    testing.expect_value(t,asset.material_layers(unlit),asset.Material_Layers{.Unlit})
    testing.expect(t,close_to(unlit.emission,{0.2,0.4,0.6}) && unlit.opacity==0.5 && unlit.coat.weight==0,"the base color is emitted")
    // glTF emission has no unit: it is relative to the exposure, as its viewers show it.
    testing.expect(t,unlit.emission_mode==.Relative && coat.emission_mode==.Relative,"glTF emission is relative")
    // A thin surface lets a share of the light it scatters through, filtered by a color.
    leaf:=&model.materials[4].info
    testing.expect_value(t,asset.material_layers(leaf),asset.Material_Layers{.Diffuse_Transmission})
    testing.expect(t,leaf.diffuse_transmission.weight==0.4 && leaf.diffuse_transmission.color==[3]f32{1,0.75,0.5},"the factors of KHR_materials_diffuse_transmission")
}
