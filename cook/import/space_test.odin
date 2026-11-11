package importer

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import anim "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

// A format of tests: any file named .test is a node with a child that holds a
// triangle, a bone, a clip and a light, written in the space the format
// declares, or in the one the options of the format state as the space of the file.
@(private="file")
test_read :: proc(r:^Reader,bytes:[]u8) -> bool {
    if r.data!=nil {source_space(r,(^Source_Space)(r.data)^) or_return}
    info:=asset.MATERIAL_DEFAULTS
    material_map(&info,.Base_Color)^={scale={2,1},offset={0.1,0.2},rotation=0.5}
    images:[asset.Material_Map_Kind]int
    for &image in images {image=-1}
    material:=material_add(r,"Paint",0,info,images)
    b:Mesh_Builder
    builder_init(&b,r)
    slot:=builder_slot(&b,1,"Paint",material) or_return
    corners:=[3]Corner{
        {position={100,0,0},normal={0,0,1},uv={0.25,0.25},has_uv=true,color=WHITE},
        {position={0,100,0},normal={0,0,1},uv={0.5,0},uv1={1,1},has_uv=true,has_uv1=true,color=WHITE},
        {position={0,0,100},normal={0,0,1},color=WHITE},
    }
    builder_triangle(&b,slot,corners)
    mesh:=builder_finish(&b,"Triangle")
    joints:=make([]asset.Rig_Joint,1,r.out)
    joints[0]={node=0,inverse_bind=linalg.matrix4_translate_f32({0,0,-100})}
    mesh.joints=joints
    row:=mesh_add(r,mesh)
    turn:=linalg.quaternion_angle_axis_f32(math.PI/2,{0,0,1})
    append(&r.nodes,Imported_Node{name=own(r,"Root"),parent=-1,transform={{100,200,300},turn,{1,2,3}},mesh=-1,visible=true})
    append(&r.nodes,Imported_Node{name=own(r,"Triangle"),parent=0,transform=mm.TRANSFORM_IDENTITY,mesh=row,visible=true,light=Imported_Light{kind=.Point,range=1000}})
    bones:=make([]asset.Skeleton_Bone,1,r.out)
    bones[0]={parent=-1,translation={0,0,100},rotation=turn,scale={1,2,3}}
    append(&r.skeletons,Imported_Skeleton{name=own(r,"Rig"),bones=bones})
    keys:=make([]anim.Keyframe,2,r.out)
    keys[0]={time=0,value={100,0,0,0},tangents=true,in_slope={10,0,0,0},out_slope={0,20,0,0}}
    keys[1]={time=1,value={0,0,100,0}}
    spin:=make([]anim.Keyframe,1,r.out)
    spin[0]={time=0,value={turn.x,turn.y,turn.z,turn.w}}
    tracks:=make([]asset.Animation_Track_Desc,2,r.out)
    tracks[0]={target=own(r,"Root"),property=.Position,keys=keys}
    tracks[1]={target=own(r,"Root"),property=.Rotation,keys=spin}
    append(&r.animations,asset.Animation_Clip_Desc{name=own(r,"Move"),tracks=tracks})
    return true
}

@(private="file")
test_sniff :: proc(head:[]u8) -> Sniff {return .Extension}

// Centimeters, +Z up and +X forward, left-handed, as Unreal; v from the bottom.
@(private="file")
TEST_FORMAT :: Format{name="Test",extensions={0=".test"},version=7,space={meters_per_unit=0.01,axes={.Y,.Z,.Negative_X},v_origin=.Bottom},sniff=test_sniff,read=test_read}

@(private="file")
test_import :: proc(t:^testing.T,format:Format) -> (Imported_Model,Error) {
    folder:=base.test_folder(t,"space")
    if folder=="" {return {},{code=.Not_Found}}
    path:=fmt.tprintf("%s/model.test",folder)
    _=os.write_entire_file(path,"anything")
    formats:=[1]Format{format}
    return import_model(path,formats[:])
}

@(private="file")
test_import_ok :: proc(t:^testing.T,format:Format) -> (model:Imported_Model,ok:bool) {
    error:Error
    model,error=test_import(t,format)
    ok=testing.expectf(t,error.code==.None,"%v %s",error.code,error.message)
    return
}

@(private="file")
near :: proc(a,b:[3]f32) -> bool {return linalg.length(a-b)<1e-5}

// What the file of the facing tests holds, and how many times it was read.
@(private="file")
Facing_File :: struct {
    faces:Front, // where its figure and all it holds stand facing
    rig:bool,    // a skeleton of a body and a triangle skinned to it, under a node, with a clip
    level:bool,  // a triangle without skin under a node of its own
    reads:int,
}

// A point of a file whose content faces +Z, where it is when that content faces front.
@(private="file")
facing_stand :: proc(p:[3]f32,front:Front) -> [3]f32 {
    switch front {
    case .Auto,.Z:
    case .Negative_Z: return {-p.x,p.y,-p.z}
    case .X:          return {p.z,p.y,-p.x}
    case .Negative_X: return {-p.z,p.y,p.x}
    }
    return p
}

// A triangle half a meter before the content, its normal and a morph target toward its front, its tangent to its left.
@(private="file")
facing_triangle :: proc(r:^Reader,file:^Facing_File,name:string,skinned:bool) -> (mesh:Imported_Mesh,ok:bool) {
    b:Mesh_Builder
    builder_init(&b,r,skinned)
    slot:=builder_slot(&b,1,"Paint",-1) or_return
    corners:[3]Corner
    for point,k in ([3][3]f32{{0,1,.5},{.2,1,.5},{0,1.2,.5}}) {
        tangent:=facing_stand({1,0,0},file.faces)
        corners[k]={position=facing_stand(point,file.faces),normal=facing_stand({0,0,1},file.faces),color=WHITE,tangent={tangent.x,tangent.y,tangent.z,1},has_tangent=true,morph=u32(k+1)}
    }
    skin:[3]asset.Skin_Vertex
    for &vertex in skin {vertex.weights[0]=255}
    builder_triangle(&b,slot,corners,skin)
    mesh=builder_finish(&b,name)
    lean:=make([][3]f32,3,context.temp_allocator)
    lean[0]=facing_stand({0,0,.25},file.faces)
    builder_morph(&b,&mesh,{name="Lean",positions=lean}) or_return
    return mesh,true
}

@(private="file")
facing_read :: proc(r:^Reader,bytes:[]u8) -> bool {
    file:=(^Facing_File)(r.data)
    file.reads+=1
    if file.rig {
        // Its left is at +X when it faces +Z.
        FIGURE :: [?]struct {name:string,parent:i32,at:[3]f32}{
            {"Hips",-1,{0,1,0}},{"Spine",0,{0,1.2,0}},{"Neck",1,{0,1.5,0}},{"Head",2,{0,1.6,0}},
            {"LeftUpLeg",0,{.1,.95,0}},{"LeftLeg",4,{.1,.5,0}},{"LeftFoot",5,{.1,.08,0}},{"LeftToeBase",6,{.1,.02,.12}},
            {"RightUpLeg",0,{-.1,.95,0}},{"RightLeg",8,{-.1,.5,0}},{"RightFoot",9,{-.1,.08,0}},{"RightToeBase",10,{-.1,.02,.12}},
        }
        figure:=FIGURE
        bones:=make([]asset.Skeleton_Bone,len(figure),r.out)
        for bone,i in figure {
            bones[i]={parent=bone.parent,rotation=1,scale=1,translation=facing_stand(bone.at-(bone.parent>=0?figure[bone.parent].at:{}),file.faces)}
            base.text_set(bones[i].name[:],bone.name)
            base.text_set(bones[i].path[:],bone.name)
        }
        append(&r.skeletons,Imported_Skeleton{name=own(r,"Rig"),bones=bones})
        mesh:=facing_triangle(r,file,"Body",true) or_return
        joints:=make([]asset.Rig_Joint,1,r.out)
        joints[0]={node=6,inverse_bind=linalg.matrix4_translate_f32(-facing_stand(figure[6].at,file.faces))}
        mesh.joints,mesh.skeleton=joints,0
        mesh.flags+={.Skinned}
        append(&r.nodes,Imported_Node{name=own(r,"Body"),parent=-1,transform={facing_stand({0,0,2},file.faces),1,1},mesh=mesh_add(r,mesh),visible=true})
        keys:=make([]anim.Keyframe,1,r.out)
        step:=facing_stand({0,0,1},file.faces)
        keys[0]={time=0,value={step.x,step.y,step.z,0}}
        tracks:=make([]asset.Animation_Track_Desc,1,r.out)
        tracks[0]={target=own(r,"Hips"),property=.Position,keys=keys}
        append(&r.animations,asset.Animation_Clip_Desc{name=own(r,"Step"),tracks=tracks})
    }
    if file.level || !file.rig {
        mesh:=facing_triangle(r,file,"Floor",false) or_return
        append(&r.nodes,Imported_Node{name=own(r,"Floor"),parent=-1,transform={facing_stand({0,0,2},file.faces),1,1},mesh=mesh_add(r,mesh),visible=true})
    }
    return true
}

@(test)
a_model_is_turned_to_minus_z_in_place_by_its_rig_or_by_the_front_its_settings_state :: proc(t:^testing.T) {
    Case :: struct {
        name:string,
        file:Facing_File,
        front:Front, // of its settings
        faces:Front, // where its content faces once imported
        warns:bool,  // of a body left facing elsewhere
    }
    cases:=[?]Case{
        {name="a rig facing +Z",file={faces=.Z,rig=true},faces=.Negative_Z},
        {name="a rig facing +X",file={faces=.X,rig=true},faces=.Negative_Z},
        {name="a rig facing -X",file={faces=.Negative_X,rig=true},faces=.Negative_Z},
        {name="a rig facing -Z",file={faces=.Negative_Z,rig=true},faces=.Negative_Z},
        {name="a mesh without a rig",file={faces=.Z},faces=.Z},
        {name="a level with a rig",file={faces=.Z,rig=true,level=true},faces=.Z,warns=true},
        {name="a level with a rig whose front is stated",file={faces=.Z,rig=true,level=true},front=.Z,faces=.Negative_Z},
        {name="a mesh whose front is stated",file={faces=.X},front=.X,faces=.Negative_Z},
        {name="a rig stated to face -Z already",file={faces=.Z,rig=true},front=.Negative_Z,faces=.Z},
    }
    folder:=base.test_folder(t,"facing")
    if folder=="" {return}
    path:=fmt.tprintf("%s/model.test",folder)
    _=os.write_entire_file(path,"anything")
    for &c in cases {
        formats:=[1]Format{{name="Facing",extensions={0=".test"},version=1,space=ENGINE_SPACE,sniff=test_sniff,read=facing_read,data=&c.file}}
        model,error:=import_model(path,formats[:],{settings={front=c.front}})
        if !testing.expectf(t,error.code==.None,"%s: %v %s",c.name,error.code,error.message) {continue}
        defer model_destroy(&model)
        testing.expectf(t,c.file.reads==1,"%s: the source was read %d times",c.name,c.file.reads)
        warned:=false
        for warning in model.warnings {warned||=strings.contains(warning,"front")}
        testing.expectf(t,warned==c.warns,"%s: %v",c.name,model.warnings)
        for &mesh in model.meshes {
            corners:=mesh_triangle(&mesh,0)
            testing.expectf(t,near(corners[0].position,facing_stand({0,1,.5},c.faces)) && near(corners[1].position,facing_stand({.2,1,.5},c.faces)),"%s: mesh %s stands at %v",c.name,mesh.name,corners[0].position)
            tangent,sign:=mm.tangent_unpack(corners[0].tangent)
            testing.expectf(t,linalg.length(mm.normal_unpack(corners[0].normal)-facing_stand({0,0,1},c.faces))<1e-3 && linalg.length(tangent-facing_stand({1,0,0},c.faces))<1e-3 && sign==1,"%s: the normal and the tangent of mesh %s turn with it",c.name,mesh.name)
            testing.expectf(t,len(mesh.morph_deltas)==1 && near(mesh.morph_deltas[0].position,facing_stand({0,0,.25},c.faces)),"%s: the morph target of mesh %s turns with it",c.name,mesh.name)
            low,high:=facing_stand({0,1,.5},c.faces),facing_stand({.2,1.2,.5},c.faces)
            testing.expectf(t,near(mesh.bounds_min,linalg.min(low,high)) && near(mesh.bounds_max,linalg.max(low,high)),"%s: the bounds of mesh %s are those of its vertices",c.name,mesh.name)
        }
        for node in model.nodes {testing.expectf(t,near(node.transform.position,facing_stand({0,0,2},c.faces)),"%s: node %s is at %v",c.name,node.name,node.transform.position)}
        if !c.file.rig {continue}
        facing:mm.Vec3
        _,found:=asset.skeleton_body_detect(model.skeletons[0].bones,anim.body_map_empty(),facing=&facing)
        testing.expectf(t,found && facing==facing_stand({0,0,1},c.faces),"%s: its body faces %v",c.name,facing)
        bones:=model.skeletons[0].bones
        testing.expectf(t,near(bones[4].translation,facing_stand({.1,-.05,0},c.faces)) && near(bones[7].translation,facing_stand({0,-.06,.12},c.faces)),"%s: its bones turn with it",c.name)
        bind:=model.meshes[0].joints[0].inverse_bind
        testing.expectf(t,near({bind[0,3],bind[1,3],bind[2,3]},-facing_stand({.1,.08,0},c.faces)),"%s: its inverse binds turn with it",c.name)
        testing.expectf(t,near(model.animations[0].tracks[0].keys[0].value.xyz,facing_stand({0,0,1},c.faces)),"%s: its clips turn with it",c.name)
    }
}

@(test)
the_front_of_a_source_is_a_setting_kept_with_it_that_makes_another_mesh :: proc(t:^testing.T) {
    for front in Front {
        stated:=Import_Settings{front=front}
        parsed,ok:=sidecar_parse(sidecar_text({settings=stated},context.temp_allocator),context.temp_allocator)
        testing.expectf(t,ok && parsed.settings==stated,"%v is read as written",front)
        named,known:=front_from_name(strings.to_lower(fmt.tprint(front),context.temp_allocator))
        testing.expectf(t,known && named==front,"%v is named in lowercase",front)
        for other in Front {
            if other!=front {testing.expectf(t,mesh_settings_hash(stated)!=mesh_settings_hash({front=other}),"%v and %v make the same mesh",front,other)}
        }
    }
    _,ok:=sidecar_parse(`{"version": 3, "settings": {"front": "Up"}, "outputs": []}`,context.temp_allocator)
    testing.expect(t,!ok,"a front the import does not know is not the settings of a source")
}

@(test)
the_space_a_reader_declares_is_baked_once_into_what_the_import_gives :: proc(t:^testing.T) {
    model,ok:=test_import_ok(t,TEST_FORMAT)
    if !ok {return}
    defer model_destroy(&model)
    testing.expect_value(t,model.format,"Test")
    testing.expect_value(t,model.version,u32(IMPORTER_VERSION)|7<<16)

    // engine = 0.01 * (y, z, -x) of the source. No node is added.
    testing.expect_value(t,len(model.nodes),2)
    root:=model.nodes[0].transform
    testing.expect(t,near(root.position,{2,3,-1}) && root.scale==[3]f32{2,3,1},"positions are in meters and scales follow their axes")
    // A quarter turn about the up of the source turns -Z of the engine (its +X) to +X (its +Y).
    testing.expect(t,near(linalg.quaternion_mul_vector3(root.rotation,[3]f32{0,0,-1}),{1,0,0}),"a rotation keeps what it does to the source")
    testing.expect(t,model.nodes[1].parent==0 && near(model.nodes[1].transform.position,{0,0,0}))
    light,has_light:=model.nodes[1].light.?
    testing.expect(t,has_light && abs(light.range-10)<1e-4)

    // The mirror turns the triangle: its normal, from the order of its corners, stays outside.
    mesh:=&model.meshes[0]
    corners:=mesh_triangle(mesh,0)
    testing.expect(t,near(corners[0].position,{0,0,-1}) && near(corners[1].position,{0,1,0}) && near(corners[2].position,{1,0,0}),"the corners are in meters and turned")
    winding:=linalg.normalize(linalg.cross(corners[1].position-corners[0].position,corners[2].position-corners[0].position))
    testing.expect(t,near(winding,linalg.normalize([3]f32{1,1,-1})),"the winding gives the normal of the source")
    testing.expect(t,near(mm.normal_unpack(corners[0].normal),{0,1,0}))
    testing.expect(t,near(mesh.bounds_min,{0,0,-1}) && near(mesh.bounds_max,{1,1,0}))
    bind:=mesh.joints[0].inverse_bind
    testing.expect(t,near({bind[0,3],bind[1,3],bind[2,3]},{0,-1,0}) && bind[0,0]==1 && bind[1,1]==1 && bind[2,2]==1,"an inverse bind is conjugated")

    // V from the bottom: each coordinate the source gives is turned, a missing one is 0 and a missing uv1 is uv.
    testing.expect(t,corners[0].uv=={0.25,0.75} && corners[0].uv1=={0.25,0.75},"uv1 is uv when the source has none")
    testing.expect(t,corners[2].uv=={0.5,1} && corners[2].uv1=={1,0})
    testing.expect(t,corners[1].uv=={0,0} && corners[1].uv1=={0,0},"a missing coordinate is 0")

    // Bones and clips are in the same space.
    bone:=model.skeletons[0].bones[0]
    testing.expect(t,near(bone.translation,{0,1,0}) && bone.scale==[3]f32{2,3,1} && bone.rotation==root.rotation)
    move:=model.animations[0].tracks[0].keys
    testing.expect(t,near(move[0].value.xyz,{0,0,-1}) && near(move[0].in_slope.xyz,{0,0,-0.1}) && near(move[0].out_slope.xyz,{0.2,0,0}) && near(move[1].value.xyz,{0,1,0}))
    spin:=model.animations[0].tracks[1].keys[0].value
    testing.expect(t,spin==[4]f32{root.rotation.x,root.rotation.y,root.rotation.z,root.rotation.w},"a rotation key turns as the node")

    // The mapping of a map, conjugated by the flip of v; the identity stays exact, without a negative zero.
    info:=&model.materials[0].info
    base:=material_map(info,.Base_Color)
    testing.expect_value(t,base.rotation,f32(-0.5))
    testing.expect_value(t,base.scale,[2]f32{2,1})
    testing.expect_value(t,base.offset,[2]f32{0.1-math.sin(f32(0.5)),1-math.cos(f32(0.5))-0.2})
    normal:=material_map(info,.Normal)
    testing.expect(t,normal^==asset.MATERIAL_MAP_DEFAULT && transmute(u32)normal.rotation==0 && transmute(u32)normal.offset.x==0 && transmute(u32)normal.offset.y==0,"the identity mapping keeps its bytes")
}

@(test)
a_source_in_the_space_of_the_engine_is_kept_as_it_is :: proc(t:^testing.T) {
    engine:=TEST_FORMAT
    engine.space=ENGINE_SPACE
    model,ok:=test_import_ok(t,engine)
    if !ok {return}
    corners:=mesh_triangle(&model.meshes[0],0)
    testing.expect(t,len(model.nodes)==2 && model.nodes[0].transform.position==[3]f32{100,200,300})
    testing.expect(t,corners[0].position==[3]f32{100,0,0} && corners[1].position==[3]f32{0,100,0} && corners[0].uv=={0.25,0.25},"nothing is changed")
    testing.expect_value(t,material_map(&model.materials[0].info,.Base_Color).rotation,f32(0.5))
    model_destroy(&model)

    // A file states its space: +Z up, the front toward -Y, as USD or Blender write it.
    stated:=Source_Space{meters_per_unit=1,axes={.Negative_X,.Z,.Y},v_origin=.Top}
    engine.data=&stated
    model,ok=test_import_ok(t,engine)
    if !ok {return}
    testing.expect(t,near(model.nodes[0].transform.position,{-100,300,200}) && near(mesh_triangle(&model.meshes[0],0)[2].position,{0,100,0}),"a rotation of the axes, without a mirror")
    testing.expect(t,near(linalg.quaternion_mul_vector3(model.nodes[0].transform.rotation,[3]f32{1,0,0}),{0,0,-1}))
    model_destroy(&model)

    for broken in ([]Source_Space{{meters_per_unit=0,axes={.X,.Y,.Z}},{meters_per_unit=1,axes={.X,.Negative_X,.Z}}}) {
        stated=broken
        _,refused:=test_import(t,engine)
        testing.expect(t,refused.code==.Malformed && strings.contains(refused.message,"distinct axes"),refused.message)
    }
}
