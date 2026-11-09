package fbx

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import anim "mirai:std/anim"
import importer "mirai:cook/import"
import mm "mirai:std/math"

FIXTURES :: #directory+"/../../../assets/fixtures/"

@(rodata)
FORMATS:=[?]importer.Format{FORMAT}

@(private="file")
import_ok :: proc(t:^testing.T,path:string) -> (model:importer.Imported_Model,ok:bool) {
    error:importer.Error
    model,error=importer.import_model(path,FORMATS[:])
    ok=testing.expectf(t,error.code==.None,"%s: %v %s",path,error.code,error.message)
    return
}

@(private="file")
find_node :: proc(model:^importer.Imported_Model,name:string) -> int {
    for node,i in model.nodes {
        if node.name==name {return i}
    }
    return -1
}

@(private="file")
close_to :: proc(a,b:[3]f32,tolerance:f32=1e-5) -> bool {return linalg.length(a-b)<tolerance}

@(private="file")
has_vertex :: proc(mesh:^importer.Imported_Mesh,position:[3]f32) -> bool {
    for vertex in mesh.vertices {
        if close_to(vertex.position,position) {return true}
    }
    return false
}

@(test)
binary_and_ascii_fbx_are_told_by_their_first_bytes :: proc(t:^testing.T) {
    for name in ([]string{"hierarchy.fbx","hierarchy-ascii.fbx"}) {
        bytes,error:=os.read_entire_file_from_path(fmt.tprintf("%s%s",FIXTURES,name),context.temp_allocator)
        if !testing.expectf(t,error==nil,"%s cannot be read",name) {continue}
        testing.expectf(t,sniff(bytes[:min(len(bytes),importer.SNIFF_BYTES)])==.Content,"%s is told an FBX by its bytes",name)
    }
    testing.expect(t,sniff(transmute([]u8)string("o cube\nv 0 0 0\n"))==.Extension,"a text without an FBX header is left to its extension")
}

@(test)
a_binary_and_an_ascii_fbx_of_one_scene_import_alike :: proc(t:^testing.T) {
    binary,binary_ok:=import_ok(t,FIXTURES+"hierarchy.fbx")
    defer importer.model_destroy(&binary)
    ascii,ascii_ok:=import_ok(t,FIXTURES+"hierarchy-ascii.fbx")
    defer importer.model_destroy(&ascii)
    if !binary_ok || !ascii_ok {return}
    if !testing.expect(t,len(binary.nodes)==len(ascii.nodes) && len(binary.meshes)==len(ascii.meshes) && len(binary.materials)==len(ascii.materials),"the same nodes, meshes and materials") {return}
    for node,i in binary.nodes {
        other:=ascii.nodes[i]
        testing.expectf(t,node.path==other.path && node.parent==other.parent && node.mesh==other.mesh && node.transform==other.transform,"node %s is the same",node.path)
    }
    for mesh,i in binary.meshes {
        testing.expectf(t,len(mesh.vertices)==len(ascii.meshes[i].vertices) && len(mesh.indices)==len(ascii.meshes[i].indices),"mesh %s is the same",mesh.name)
        for vertex,v in mesh.vertices {
            if !testing.expectf(t,vertex==ascii.meshes[i].vertices[v],"vertex %d of mesh %s is the same",v,mesh.name) {break}
        }
    }
}

@(test)
an_fbx_of_z_up_in_centimeters_is_imported_in_meters_and_y_up :: proc(t:^testing.T) {
    model,ok:=import_ok(t,FIXTURES+"hierarchy.fbx")
    defer importer.model_destroy(&model)
    if !ok {return}
    parent,quad:=find_node(&model,"Parent"),find_node(&model,"Quad")
    if !testing.expect(t,parent>=0 && quad>=0,"the nodes are imported") {return}
    testing.expect(t,model.nodes[parent].parent==-1 && model.nodes[quad].parent==parent,"the hierarchy is the one of the file")
    testing.expectf(t,close_to(model.nodes[parent].transform.position,{-1,0,0}),"100 cm along X are a meter along -X: %v",model.nodes[parent].transform.position)
    // 90 degrees about Z, which is up, are 90 degrees about the engine's Y.
    turned:=mm.quat_rotate(model.nodes[parent].transform.rotation,[3]f32{1,0,0})
    testing.expectf(t,close_to(turned,{0,0,-1}),"the parent turns about up: X goes to %v",turned)
    testing.expectf(t,close_to(model.nodes[quad].transform.position,{0,0.5,0}),"50 cm up are half a meter along Y: %v",model.nodes[quad].transform.position)
    mesh:=&model.meshes[model.nodes[quad].mesh]
    testing.expectf(t,len(mesh.indices)==9,"a quad and a triangle are three triangles: %d",len(mesh.indices)/3)
    testing.expect(t,has_vertex(mesh,{-0.1,0,0}) && has_vertex(mesh,{0,0,0.1}) && has_vertex(mesh,{-0.2,0,0}),"X turns and Y, the back, is the engine's +Z")
    for vertex in mesh.vertices {
        if !testing.expectf(t,close_to(mm.normal_unpack(vertex.normal),{0,1,0},1e-3),"the normal along Z points up: %v",mm.normal_unpack(vertex.normal)) {break}
    }
    for i:=0;i+2<len(mesh.indices);i+=3 {
        a,b,c:=mesh.vertices[mesh.indices[i]].position,mesh.vertices[mesh.indices[i+1]].position,mesh.vertices[mesh.indices[i+2]].position
        if !testing.expect(t,linalg.cross(b-a,c-a).y>0,"the triangles face where their normals point") {break}
    }
    if testing.expect(t,len(mesh.slots)==2,"one slot per material index") {
        testing.expect(t,mesh.slots[0].id==1 && mesh.slots[1].id==2,"a slot is named by its material index plus one")
        testing.expect(t,model.materials[mesh.slots[0].material].name=="Red" && model.materials[mesh.slots[1].material].name=="Glass","the slots show the materials of the node")
    }
}

@(test)
lambert_and_phong_materials_keep_their_color_texture_and_transparency :: proc(t:^testing.T) {
    model,ok:=import_ok(t,FIXTURES+"hierarchy.fbx")
    defer importer.model_destroy(&model)
    if !ok {return}
    for material in model.materials {
        switch material.name {
        case "Red":
            testing.expectf(t,close_to(material.info.base_color,{1,0,0}),"the diffuse color is the base color: %v",material.info.base_color)
            image:=material.images[.Base_Color]
            if testing.expect(t,image>=0,"the diffuse texture is the base color map") {
                testing.expectf(t,strings.has_suffix(model.images[image].path,"/red.png"),"the texture is the file next to the model: %s",model.images[image].path)
                testing.expect(t,model.images[image].srgb,"a color texture is sRGB")
            }
            testing.expect(t,material.info.alpha_mode==.Opaque && material.info.opacity==1,"without transparency the material is opaque")
        case "Glass":
            testing.expectf(t,close_to(material.info.base_color,{0,0,1}),"the diffuse color is the base color: %v",material.info.base_color)
            testing.expectf(t,abs(material.info.opacity-0.5)<1e-5 && material.info.alpha_mode==.Blend,"half the transparency of white is half the opacity: %v %v",material.info.opacity,material.info.alpha_mode)
        case:
            testing.expectf(t,false,"material %s is not of the file",material.name)
        }
    }
}

@(test)
a_geometry_transform_moves_the_mesh_of_its_node_alone :: proc(t:^testing.T) {
    model,ok:=import_ok(t,FIXTURES+"hierarchy.fbx")
    defer importer.model_destroy(&model)
    if !ok {return}
    quad,offset:=find_node(&model,"Quad"),find_node(&model,"Offset")
    if !testing.expect(t,quad>=0 && offset>=0,"the nodes are imported") {return}
    testing.expect(t,model.nodes[offset].transform==mm.TRANSFORM_IDENTITY,"the node keeps its own transform")
    testing.expect(t,model.nodes[quad].mesh!=model.nodes[offset].mesh,"the geometry moved by a geometry transform is a mesh of its own")
    mesh:=&model.meshes[model.nodes[offset].mesh]
    testing.expect(t,has_vertex(mesh,{0,0.1,0}) && has_vertex(mesh,{-0.1,0.1,0}),"10 cm up move the vertices a tenth of a meter along Y")
}

@(private="file")
find_track :: proc(clip:asset.Animation_Clip_Desc,target:string,property:anim.Property) -> (keys:[]anim.Keyframe,found:bool) {
    for track in clip.tracks {
        if track.target==target && track.property==property {return track.keys,true}
    }
    return
}

@(test)
a_skinned_fbx_imports_its_skeleton_skin_blend_shape_and_stack :: proc(t:^testing.T) {
    model,ok:=import_ok(t,FIXTURES+"skinned.fbx")
    defer importer.model_destroy(&model)
    if !ok {return}
    testing.expectf(t,len(model.warnings)==0,"no warnings: %v",model.warnings)
    if !testing.expect(t,len(model.skeletons)==1,"one skeleton") {return}
    skeleton:=model.skeletons[0]
    testing.expectf(t,skeleton.name=="Armature" && len(skeleton.bones)==3,"the skeleton is the bones under Armature: %s %d",skeleton.name,len(skeleton.bones))
    if len(skeleton.bones)==3 {
        tip_name:=string(skeleton.bones[2].name[:strings.index_byte(string(skeleton.bones[2].name[:]),0)])
        testing.expectf(t,tip_name=="Tip","a bone is named without its namespace: %s",tip_name)
    }
    body:=find_node(&model,"Body")
    if !testing.expect(t,body>=0 && model.nodes[body].mesh>=0,"the skinned mesh has its node") {return}
    mesh:=&model.meshes[model.nodes[body].mesh]
    if !testing.expect(t,len(mesh.joints)==2 && len(mesh.skin)==len(mesh.vertices),"a joint per cluster and an influence per vertex") {return}
    tip:=mesh.joints[1]
    testing.expectf(t,abs(tip.inverse_bind[0,3])<1e-5 && abs(tip.inverse_bind[1,3]+1)<1e-5 && abs(tip.inverse_bind[2,3])<1e-5,"the bind of Tip is a meter up: %v",tip.inverse_bind)
    for vertex,v in mesh.vertices {
        joint:=1 if vertex.position.y>1 else 0
        testing.expectf(t,mesh.skin[v].joints[0]==u16(joint) && mesh.skin[v].weights[0]==255,"vertex %v follows joint %d",vertex.position,joint)
    }
    if testing.expect(t,len(mesh.morphs)==1,"the blend shape is a morph target") {
        name:=string(mesh.morphs[0].name[:strings.index_byte(string(mesh.morphs[0].name[:]),0)])
        testing.expectf(t,name=="Smile" && mesh.morphs[0].count>0,"the morph is named by its channel: %s",name)
    }
    if !testing.expect(t,len(model.animations)==1 && model.animations[0].name=="Wave","the stack is a clip") {return}
    clip:=model.animations[0]
    rotation,turns:=find_track(clip,"Armature/Root/Tip",.Rotation)
    if testing.expect(t,turns && len(rotation)>=2,"Tip turns") {
        last:=rotation[len(rotation)-1]
        half:=f32(math.SQRT_TWO/2)
        testing.expectf(t,abs(last.time-1)<1e-4 && linalg.length(last.value-[4]f32{0,0,-half,half})<1e-4,"90 degrees about Z at a second: %v at %v",last.value,last.time)
    }
    position,moves:=find_track(clip,"Armature/Root/Tip",.Position)
    if testing.expect(t,moves,"Tip moves") {
        stepped:=false
        for key,i in position {
            if abs(key.time-0.5)<1e-4 && key.interpolation==.Step {
                stepped=abs(key.value.x+0.25)<1e-5 && i>0 && abs(position[i-1].value.x)<1e-5
            }
        }
        testing.expectf(t,stepped,"the constant key steps to 0.25 at half a second: %v",position)
    }
    weights,morphs:=find_track(clip,"Armature/Body/@morph/Smile",.Float)
    if testing.expect(t,morphs && len(weights)>=2,"the weight of Smile is animated") {
        testing.expectf(t,abs(weights[len(weights)-1].value.x-1)<1e-5,"100 percent is a weight of one: %v",weights[len(weights)-1].value.x)
    }
    jaw,curved:=find_track(clip,"jawOpen",.Float)
    if testing.expect(t,curved && len(jaw)>=2,"an animated custom attribute is a curve of its name") {
        testing.expectf(t,abs(jaw[0].value.x)<1e-5 && abs(jaw[len(jaw)-1].value.x-.8)<1e-5 && abs(jaw[len(jaw)-1].time-1)<1e-4,"jawOpen goes from 0 to 0.8: %v",jaw)
    }
}

// The world transform of each node at a time of a clip, composed by the engine from the root down.
@(private="file")
pose_at :: proc(model:^importer.Imported_Model,clip:asset.Animation_Clip_Desc,time:f32) -> []mm.Transform {
    worlds:=make([]mm.Transform,len(model.nodes),context.temp_allocator)
    for node,i in model.nodes {
        local:=node.transform
        if keys,found:=find_track(clip,node.path,.Position);found {local.position=anim.track_evaluate(keys,.Position,time).xyz}
        if keys,found:=find_track(clip,node.path,.Rotation);found {local.rotation=anim.vec4_quat(anim.track_evaluate(keys,.Rotation,time))}
        if keys,found:=find_track(clip,node.path,.Scale);found {local.scale=anim.track_evaluate(keys,.Scale,time).xyz}
        worlds[i]=local if node.parent<0 else mm.transform_compose(worlds[node.parent],local)
    }
    return worlds
}

@(test)
a_node_that_does_not_inherit_a_squashed_parent_scale_keeps_its_own_pose :: proc(t:^testing.T) {
    for name in ([]string{"inherit.fbx","inherit-ascii.fbx"}) {
        model,ok:=import_ok(t,fmt.tprintf("%s%s",FIXTURES,name))
        defer importer.model_destroy(&model)
        if !ok {continue}
        testing.expectf(t,len(model.warnings)==0,"%s: no warnings: %v",name,model.warnings)
        segment,leaf,still,blend:=find_node(&model,"Segment"),find_node(&model,"Leaf"),find_node(&model,"Still"),find_node(&model,"Blend")
        if !testing.expectf(t,segment>=0 && leaf>=0 && still>=0 && blend>=0 && len(model.nodes)==6,"%s: the nodes of the file and no others: %d",name,len(model.nodes)) {continue}
        testing.expectf(t,close_to(model.nodes[segment].transform.scale,{1,2,1}),"%s: Segment keeps its scale over the (1, 0.5, 1) of Stretch: %v",name,model.nodes[segment].transform.scale)
        if testing.expectf(t,len(model.skeletons)==1 && len(model.skeletons[0].bones)==2,"%s: Stretch and Segment are the bones",name) {
            bone:=model.skeletons[0].bones[1]
            testing.expectf(t,close_to(bone.scale,{1,2,1}),"%s: the bone of Segment is compensated as its node: %v",name,bone.scale)
        }
        if !testing.expectf(t,len(model.animations)==1 && model.animations[0].name=="Squash","%s: the stack is a clip",name) {continue}
        clip:=model.animations[0]
        _,follows:=find_track(clip,"Stretch/Still",.Scale)
        testing.expectf(t,follows,"%s: Still, without curves, has the scale that undoes the animated one of Stretch",name)
        // What FBX means: Rrs takes the scale of its parent in its position alone, RrSs axis by axis.
        for frame in 0..=30 {
            time:=f32(frame)/30
            stretch:=1+2*time
            depth:=f32(1 if time<0.5 else 2)
            worlds:=pose_at(&model,clip,time)
            expect_pose :: proc(t:^testing.T,name,node:string,world:mm.Transform,position,scale:[3]f32,time:f32) {
                turned:=mm.quat_rotate(world.rotation,[3]f32{1,0,0})
                testing.expectf(t,close_to(world.position,{-position.x,position.y,-position.z},1e-4) && close_to(world.scale,scale,1e-4) && close_to(turned,{0,-1,0},1e-4),"%s: %s at %v is at %v scaled %v, not at %v scaled %v",name,node,time,world.position,world.scale,position,scale)
            }
            expect_pose(t,name,"Segment",worlds[segment],{0.5,0,0},{1,1+time,1},time)
            expect_pose(t,name,"Leaf",worlds[leaf],{0.5-(1+time),0,0},{1,1+time,1},time)
            expect_pose(t,name,"Still",worlds[still],{1,stretch,0},{2,2,2},time)
            expect_pose(t,name,"Blend",worlds[blend],{1,0,depth},{stretch,0.5,depth},time)
        }
        // The step of Stretch is a step of what undoes it, not a ramp from the frame before.
        worlds:=pose_at(&model,clip,0.499)
        testing.expectf(t,abs(worlds[still].scale.z-2)<1e-4 && abs(worlds[segment].scale.z-1)<1e-4,"%s: the depth of Still and Segment does not move before the step: %v %v",name,worlds[still].scale,worlds[segment].scale)
    }
}

@(test)
an_fbx_6_is_refused_saying_why :: proc(t:^testing.T) {
    directory,_:=os.temp_directory(context.temp_allocator)
    path:=fmt.tprintf("%s/mirai-fbx-%d-old.fbx",directory,os.get_pid())
    defer os.remove(path)
    text:="; FBX 6.1.0 project file\nFBXHeaderExtension:  {\n\tFBXHeaderVersion: 1003\n\tFBXVersion: 6100\n}\nObjects:  {\n}\n"
    _=os.write_entire_file(path,text)
    model,error:=importer.import_model(path,FORMATS[:])
    defer importer.model_destroy(&model)
    testing.expectf(t,error.code==.Unsupported && strings.contains(error.message,"FBX 6.1"),"%v %s",error.code,error.message)
}
