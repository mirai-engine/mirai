package sources

import "base:runtime"
import "core:c"
import "core:encoding/base64"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"
import stbi "vendor:stb/image"
import "mirai:asset"
import anim "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"
import importer "mirai:cook/import"

Png_Sink :: struct {bytes:[dynamic]u8,allocator:runtime.Allocator}

png_sink :: proc "c" (user:rawptr,data:rawptr,size:c.int) {
    sink:=(^Png_Sink)(user)
    context=runtime.default_context()
    context.allocator=sink.allocator
    append(&sink.bytes,..([^]u8)(data)[:size])
}

// A PNG of one color, with a gradient in alpha when masked is set.
png_bytes :: proc(width,height:int,rgb:[3]u8,masked:=false) -> []u8 {
    pixels:=make([]u8,width*height*4,context.temp_allocator)
    for y in 0..<height {
        for x in 0..<width {
            at:=(y*width+x)*4
            pixels[at],pixels[at+1],pixels[at+2]=rgb[0],rgb[1],rgb[2]
            pixels[at+3]=u8(x*255/max(width-1,1)) if masked else 255
        }
    }
    sink:=Png_Sink{allocator=context.temp_allocator}
    stbi.write_png_to_func(png_sink,&sink,c.int(width),c.int(height),4,raw_data(pixels),c.int(width*4))
    return sink.bytes[:]
}

read_asset :: proc(t:^testing.T,written:importer.Written,types:^asset.Types) -> (a:asset.Asset,ok:bool) {
    error:=asset.asset_load(&a,written.path)
    ok=testing.expectf(t,error==.None,"%s: %v",written.path,error)
    if ok {
        testing.expectf(t,asset.blob_verify_hash(&a.blob),"%s: the hash matches",written.path)
        testing.expect(t,a.blob.header.id==written.id && .Cooked in a.blob.header.flags,"the asset has the id of the report and is cooked")
    } else {asset.asset_close(&a)}
    return
}

written_of :: proc(report:^importer.Import_Report,kind:asset.Fourcc,name:string) -> (written:importer.Written,found:bool) {
    for item in report.assets {
        if item.kind==kind && item.name==name {return item,true}
    }
    return {},false
}

@(test)
a_written_obj_is_read_back_with_its_material_and_its_dependencies :: proc(t:^testing.T) {
    folder:=temp_folder("write-obj")
    defer os.remove_all(folder)
    model,ok:=import_ok(t,FIXTURES+"concave.obj")
    if !ok {return}
    defer importer.model_destroy(&model)
    report,error:=importer.import_write(&model,fmt.tprintf("%s/out",folder))
    defer importer.report_destroy(&report)
    testing.expect_value(t,error.code,importer.Error_Code.None)
    testing.expect_value(t,len(report.assets),2)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    mesh_written,has_mesh:=written_of(&report,asset.KIND_MESH,"ConcaveL")
    material_written,has_material:=written_of(&report,asset.KIND_MATERIAL,"red")
    testing.expect(t,has_mesh && has_material && strings.has_suffix(mesh_written.path,"/ConcaveL.mesh") && mesh_written.bytes>0)
    if !has_mesh || !has_material {return}

    a,loaded:=read_asset(t,mesh_written,&types)
    if !loaded {return}
    defer asset.asset_close(&a)
    view,view_error:=asset.mesh_view(&a,&types)
    testing.expect_value(t,view_error,asset.Error.None)
    testing.expect(t,asset.mesh_check_indices(view))
    testing.expect_value(t,len(view.vertices),6)
    testing.expect_value(t,view.info.triangle_count,4)
    testing.expect(t,close_to(view.info.bounds_max,{2,2,0}))
    testing.expect_value(t,len(view.slots),1)
    testing.expect_value(t,view.slots[0].material,material_written.id)
    testing.expect(t,slice.contains(a.dependencies,material_written.id),"the mesh depends on its material")
    testing.expect(t,view.source!=nil && string_of(view.source.importer[:])==importer.IMPORTER_NAME && string_of(view.source.name[:])=="ConcaveL" && view.source.source_hash==model.source_hash && view.source.source_size==model.source_size)

    m,m_loaded:=read_asset(t,material_written,&types)
    if !m_loaded {return}
    defer asset.asset_close(&m)
    material,material_error:=asset.material_view(&m,&types)
    testing.expect_value(t,material_error,asset.Error.None)
    testing.expect(t,close_to(material.info.base_color,{0.5,1,0.5}) && close_to(material.info.emission,{0.1,0,0}))
}

@(test)
a_written_model_with_textures_links_materials_to_them :: proc(t:^testing.T) {
    folder:=temp_folder("write-plant")
    defer os.remove_all(folder)
    model,ok:=import_ok(t,DEMO+"models/plant.gltf")
    if !ok {return}
    defer importer.model_destroy(&model)
    report,error:=importer.import_write(&model,folder)
    defer importer.report_destroy(&report)
    testing.expect_value(t,error.code,importer.Error_Code.None)
    testing.expect_value(t,len(report.warnings),0)
    testing.expect_value(t,len(report.assets),5)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    texture_written,has_texture:=written_of(&report,asset.KIND_TEXTURE,"leaves_color")
    leaves_written,has_leaves:=written_of(&report,asset.KIND_MATERIAL,"Leaves")
    testing.expect(t,has_texture && has_leaves)
    if !has_texture || !has_leaves {return}

    a,loaded:=read_asset(t,texture_written,&types)
    if !loaded {return}
    defer asset.asset_close(&a)
    texture,texture_error:=asset.texture_view(&a,&types)
    testing.expect_value(t,texture_error,asset.Error.None)
    testing.expect(t,.Srgb in texture.info.flags && .Normal_Map not_in texture.info.flags && texture.info.alpha_coverage==0.5 && texture.info.format==.BC7,"a masked color texture is sRGB, keeps its coverage and is stored in blocks with alpha")
    testing.expect_value(t,int(texture.info.mip_count),asset.texture_mip_count(int(texture.info.width),int(texture.info.height)))

    plain_folder:=temp_folder("write-plant-rgba8")
    defer os.remove_all(plain_folder)
    plain_report,plain_error:=importer.import_write(&model,plain_folder,{textures=.Uncompressed,ignore_stored=true})
    defer importer.report_destroy(&plain_report)
    testing.expect_value(t,plain_error.code,importer.Error_Code.None)
    if plain_written,found:=written_of(&plain_report,asset.KIND_TEXTURE,"leaves_color");testing.expect(t,found) {
        p,p_loaded:=read_asset(t,plain_written,&types)
        if !p_loaded {return}
        defer asset.asset_close(&p)
        plain,_:=asset.texture_view(&p,&types)
        testing.expect(t,plain.info.format==.RGBA8 && plain_written.bytes>texture_written.bytes*3,"the same image, uncompressed when the import asks")
        testing.expect(t,plain.source!=nil && texture.source!=nil && plain.source.settings_hash!=texture.source.settings_hash,"the encoding is a setting of the import")
    }

    m,m_loaded:=read_asset(t,leaves_written,&types)
    if !m_loaded {return}
    defer asset.asset_close(&m)
    material,material_error:=asset.material_view(&m,&types)
    testing.expect_value(t,material_error,asset.Error.None)
    testing.expect_value(t,material.info.maps.base_color.texture,texture_written.id)
    testing.expect(t,material.info.alpha_mode==.Mask && slice.contains(m.dependencies,texture_written.id))
}

@(test)
a_skinned_mesh_is_written_with_its_rig :: proc(t:^testing.T) {
    folder:=temp_folder("write-skin")
    defer os.remove_all(folder)
    model,ok:=import_ok(t,FIXTURES+"skeletal-analytic.glb")
    if !ok {return}
    defer importer.model_destroy(&model)
    // A clip that bends a bone of the rig, which the file does not bring.
    keys:=[2]anim.Keyframe{{value={0,0,0,1}},{time=1,value={0,0,.38,.92}}}
    tracks:=[1]asset.Animation_Track_Desc{{target=base.text_get(model.skeletons[0].bones[len(model.skeletons[0].bones)-1].path[:]),property=.Rotation,keys=keys[:]}}
    bend:=[1]asset.Animation_Clip_Desc{{name="bend",tracks=tracks[:]}}
    brought:=model.animations;model.animations=bend[:]
    report,error:=importer.import_write(&model,folder)
    model.animations=brought
    defer importer.report_destroy(&report)
    testing.expect_value(t,error.code,importer.Error_Code.None)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    written,found:=written_of(&report,asset.KIND_MESH,"analytic skin")
    testing.expect(t,found)
    if !found {return}
    a,loaded:=read_asset(t,written,&types)
    if !loaded {return}
    defer asset.asset_close(&a)
    view,view_error:=asset.mesh_view(&a,&types)
    testing.expect_value(t,view_error,asset.Error.None)
    testing.expect(t,asset.mesh_check_indices(view) && .Skinned in view.info.flags)
    testing.expect_value(t,len(view.skin),len(view.vertices))
    testing.expect_value(t,len(view.joints),2)
    testing.expect_value(t,view.info.skeleton,report.skeleton_ids[model.meshes[0].skeleton])
    skeleton_written,has_skeleton:=written_of(&report,asset.KIND_SKELETON,model.skeletons[0].name)
    if !testing.expect(t,has_skeleton) {return}
    skeleton_file,skeleton_loaded:=read_asset(t,skeleton_written,&types)
    if !skeleton_loaded {return}
    defer asset.asset_close(&skeleton_file)
    skeleton,skeleton_error:=asset.skeleton_view(&skeleton_file,&types)
    testing.expect_value(t,skeleton_error,asset.Error.None)
    testing.expect(t,len(skeleton.bones)>=2 && int(view.joints[1].node)<len(skeleton.bones))
    // Its clips play on that rig.
    animation_written:importer.Written
    for item in report.assets {if item.kind==asset.KIND_ANIMATION {animation_written=item}}
    if !testing.expect(t,animation_written.id!={}) {return}
    animation_file,has_animation:=read_asset(t,animation_written,&types)
    if !has_animation {return}
    defer asset.asset_close(&animation_file)
    clips,clips_error:=asset.animation_view(&animation_file,&types)
    testing.expect_value(t,clips_error,asset.Error.None)
    testing.expect(t,len(clips.clips)==1 && clips.clips[0].skeleton==report.skeleton_ids[0])
}

// With Import_Settings.skeleton the import writes only the clips, as an .anim bound to that
// skeleton of the project: the motion of another file onto a character imported before.
@(test)
clips_onto_a_skeleton_write_only_the_anim :: proc(t:^testing.T) {
    folder:=temp_folder("write-clips-onto")
    defer os.remove_all(folder)
    model,ok:=import_ok(t,FIXTURES+"skeletal-analytic.glb")
    if !ok {return}
    defer importer.model_destroy(&model)
    keys:=[2]anim.Keyframe{{value={0,0,0,1}},{time=1,value={0,0,.38,.92}}}
    tracks:=[1]asset.Animation_Track_Desc{{target=base.text_get(model.skeletons[0].bones[len(model.skeletons[0].bones)-1].path[:]),property=.Rotation,keys=keys[:]}}
    // A clip of markers alone (its motion was on bones this skeleton lacks) goes on it as well.
    cue:=[1]asset.Animation_Marker_Desc{{time=0.5,name="sndnt#reload"}}
    bend:=[2]asset.Animation_Clip_Desc{{name="bend",tracks=tracks[:]},{name="cue",markers=cue[:]}}
    brought:=model.animations;model.animations=bend[:]
    player:=base.Asset_Id{0x1234,0x5678}
    report,error:=importer.import_write(&model,folder,{settings={skeleton=player}})
    model.animations=brought
    defer importer.report_destroy(&report)
    testing.expect_value(t,error.code,importer.Error_Code.None)
    testing.expect_value(t,len(report.assets),1)
    if len(report.assets)!=1 {return}
    testing.expect_value(t,report.assets[0].kind,asset.KIND_ANIMATION)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    file,loaded:=read_asset(t,report.assets[0],&types)
    if !loaded {return}
    defer asset.asset_close(&file)
    clips,clips_error:=asset.animation_view(&file,&types)
    testing.expect_value(t,clips_error,asset.Error.None)
    testing.expect(t,len(clips.clips)==2 && clips.clips[0].skeleton==player && clips.clips[1].skeleton==player,"bound to the skeleton given")
    testing.expect(t,len(clips.clips)==2 && clips.clips[1].marker_count==1)
}

@(test)
a_humanoid_skeleton_is_written_with_its_body_and_keeps_what_a_person_set :: proc(t:^testing.T) {
    folder:=temp_folder("write-body")
    defer os.remove_all(folder)
    options:=importer.Import_Options{ignore_stored=true,no_save=true}
    options.max_texture_size=4
    body_of :: proc(t:^testing.T,folder:string,options:importer.Import_Options,types:^asset.Types) -> (map_:anim.Body_Map,bones:[]asset.Skeleton_Bone,path:string,sockets:[]asset.Skeleton_Socket) {
        model,ok:=import_ok(t,DEMO+"models/mirai/mirai.glb",options)
        if !ok {return}
        defer importer.model_destroy(&model)
        report,error:=importer.import_write(&model,folder,options)
        defer importer.report_destroy(&report)
        testing.expect_value(t,error.code,importer.Error_Code.None)
        written,found:=written_of(&report,asset.KIND_SKELETON,model.skeletons[0].name)
        if !testing.expect(t,found) {return}
        file,loaded:=read_asset(t,written,types)
        if !loaded {return}
        defer asset.asset_close(&file)
        view,view_error:=asset.skeleton_view(&file,types)
        if !testing.expect_value(t,view_error,asset.Error.None) || !testing.expect(t,view.body!=nil) {return}
        bones=slice.clone(view.bones,context.temp_allocator)
        return asset.skeleton_body_map(bones,view.body,view.body_parts),bones,strings.clone(written.path,context.temp_allocator),slice.clone(view.sockets,context.temp_allocator)
    }
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    map_,bones,path,_:=body_of(t,folder,options,&types)
    if bones==nil {return}
    name :: proc(bones:[]asset.Skeleton_Bone,map_:anim.Body_Map,part:anim.Body_Part) -> string {
        bone:=map_.bones[part]
        return base.text_get(bones[bone].name[:]) if bone>=0 else ""
    }
    testing.expect(t,name(bones,map_,.Pelvis)=="Hips" && name(bones,map_,.Neck)=="neck" && name(bones,map_,.Head)=="Head")
    testing.expect(t,name(bones,map_,.Hand_L)=="LeftHand" && name(bones,map_,.Elbow_R)=="RightForeArm" && name(bones,map_,.Toe_R)=="RightToeBase")
    testing.expect_value(t,map_.up,[3]f32{0,1,0})

    // A person points the left hand at another bone; importing again keeps it.
    index:=-1
    for &bone,i in bones {if base.text_get(bone.name[:])=="head_end" {index=i}}
    if !testing.expect(t,index>=0) {return}
    map_.bones[.Hand_L],map_.confidence[.Hand_L],map_.manual=i32(index),1,{.Hand_L}
    body:asset.Skeleton_Body
    parts:[len(anim.Body_Part)]asset.Skeleton_Body_Part
    count,_:=asset.skeleton_body_rows(bones,map_,&body,&parts)
    file:asset.Asset
    if !testing.expect_value(t,asset.asset_load(&file,path),asset.Error.None) {return}
    view,_:=asset.skeleton_view(&file,&types)
    id:=file.blob.header.id
    // And hangs a weapon from the right hand by a socket of its own: importing again keeps it.
    sockets:=make([dynamic]asset.Skeleton_Socket,context.temp_allocator)
    append(&sockets,..view.sockets)
    held:=asset.Skeleton_Socket{offset=mm.TRANSFORM_IDENTITY}
    held.offset.position={.1,.2,.3}
    for &bone in bones {if base.text_get(bone.name[:])=="RightHand" {held.bone=bone.path}}
    base.text_set(held.name[:],"weapon")
    append(&sockets,held)
    rewritten:=asset.skeleton_save(path,&types,{id=id,bones=view.bones,sockets=sockets[:],body=&body,body_parts=parts[:count],source=view.source})
    asset.asset_close(&file)
    testing.expect_value(t,rewritten,asset.Error.None)
    options.rebuild=true
    again,_,_,kept:=body_of(t,folder,options,&types)
    testing.expect(t,name(bones,again,.Hand_L)=="head_end" && again.manual=={.Hand_L} && name(bones,again,.Hand_R)=="RightHand")
    weapon:=0
    for &socket in kept {if base.text_get(socket.name[:])=="weapon" && socket.bone==held.bone && socket.offset==held.offset {weapon+=1}}
    testing.expectf(t,weapon==1,"a socket of its own stays once, on its bone and offset: %d",weapon)
}

// The bone above the pelvis carries the motion of the body (the root of an Unreal skeleton): a
// clip that moves or turns it gets it as its root, which a character whose capsule moves it keeps
// in place, and one that leaves it still gets none. A root a person set stays on importing again.
@(test)
imported_clips_that_move_the_bone_above_the_pelvis_carry_it_as_their_root :: proc(t:^testing.T) {
    folder:=temp_folder("write-root")
    defer os.remove_all(folder)
    options:=importer.Import_Options{ignore_stored=true,no_save=true}
    options.max_texture_size=4
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    roots_of :: proc(t:^testing.T,folder:string,options:importer.Import_Options,types:^asset.Types) -> (roots:map[string]asset.Animation_Root,path:string,armature:string) {
        model,ok:=import_ok(t,DEMO+"models/mirai/mirai.glb",options)
        if !ok {return}
        defer importer.model_destroy(&model)
        bones:=model.skeletons[0].bones
        if !testing.expect(t,len(bones)>1 && base.text_get(bones[0].name[:])=="Armature" && base.text_get(bones[1].name[:])=="Hips" && bones[1].parent==0) {return}
        armature=strings.clone(base.text_get(bones[0].path[:]),context.temp_allocator)
        hips:=base.text_get(bones[1].path[:])
        rise:=[2]anim.Keyframe{{value={0,0,0,0}},{time=1,value={0,1.5,1.2,0}}}
        turn:=[2]anim.Keyframe{{value={0,0,0,1}},{time=1,value={0,.38,0,.92}}}
        still:=[2]anim.Keyframe{{value={0,0,0,0}},{time=1,value={0,0,0,0}}}
        bob:=[2]anim.Keyframe{{value={0,1,0,0}},{time=1,value={0,1.1,.5,0}}}
        clips:=[4]asset.Animation_Clip_Desc{
            {name="climb",tracks={{target=armature,property=.Position,keys=rise[:]}}},
            {name="pivot",tracks={{target=armature,property=.Rotation,keys=turn[:]}}},
            {name="stand",tracks={{target=armature,property=.Position,keys=still[:]},{target=hips,property=.Position,keys=bob[:]}}},
            {name="mixamo",tracks={{target=hips,property=.Position,keys=bob[:]}}},
        }
        brought:=model.animations;model.animations=clips[:]
        report,error:=importer.import_write(&model,folder,options)
        model.animations=brought
        defer importer.report_destroy(&report)
        testing.expect_value(t,error.code,importer.Error_Code.None)
        written:importer.Written
        for item in report.assets {if item.kind==asset.KIND_ANIMATION {written=item}}
        if !testing.expect(t,written.id!={}) {return}
        file,loaded:=read_asset(t,written,types)
        if !loaded {return}
        defer asset.asset_close(&file)
        view,view_error:=asset.animation_view(&file,types)
        if !testing.expect_value(t,view_error,asset.Error.None) {return}
        roots=make(map[string]asset.Animation_Root,context.temp_allocator)
        for &clip in view.clips {roots[strings.clone(base.text_get(clip.name[:]),context.temp_allocator)]=clip.root}
        return roots,strings.clone(written.path,context.temp_allocator),armature
    }
    roots,path,armature:=roots_of(t,folder,options,&types)
    if path=="" {return}
    for name in ([2]string{"climb","pivot"}) {
        root:=roots[name]
        testing.expectf(t,base.text_get(root.bone[:])==armature && root.translation && root.rotation,"%s carries the root it moves: %v",name,root)
    }
    testing.expect(t,roots["stand"]==asset.Animation_Root{} && roots["mixamo"]==asset.Animation_Root{},"a clip that leaves the root still, or moves only the pelvis, carries none")

    // A person keeps only the translation of the climb: importing again keeps it.
    file:asset.Asset
    if !testing.expect_value(t,asset.asset_load(&file,path),asset.Error.None) {return}
    view,_:=asset.animation_view(&file,&types)
    descs,ok:=asset.animation_descs(view,context.temp_allocator)
    if !testing.expect(t,ok) {asset.asset_close(&file);return}
    for &clip in descs {if clip.name=="climb" {clip.root.rotation=false}}
    id:=file.blob.header.id
    rewritten:=asset.animation_save(path,&types,{id=id,clips=descs,source=view.source})
    asset.asset_close(&file)
    testing.expect_value(t,rewritten,asset.Error.None)
    options.rebuild=true
    again,_,_:=roots_of(t,folder,options,&types)
    climb:=again["climb"]
    testing.expectf(t,base.text_get(climb.bone[:])==armature && climb.translation && !climb.rotation,"the root a person set stays: %v",climb)
    testing.expect(t,again["pivot"].rotation)
}

@(test)
importing_again_keeps_what_was_changed_in_a_material_and_takes_the_rest_from_the_source :: proc(t:^testing.T) {
    folder:=temp_folder("write-material-layers");defer os.remove_all(folder)
    source:=fmt.tprintf("%s/plant.gltf",folder)
    text,error:=os.read_entire_file(DEMO+"models/plant.gltf",context.temp_allocator)
    if !testing.expect(t,error==nil) {return}
    texture,_:=filepath.abs(DEMO+"textures/leaves_color.png",context.temp_allocator)
    texture,_=strings.replace_all(texture,"\\","/",context.temp_allocator)
    gltf,_:=strings.replace_all(string(text),"../textures/leaves_color.png",texture,context.temp_allocator)
    if !testing.expect(t,os.write_entire_file(source,transmute([]u8)gltf)==nil) {return}
    options:=importer.Import_Options{ignore_stored=true,no_save=true,max_texture_size=4}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    import_once :: proc(t:^testing.T,source,folder:string,options:importer.Import_Options,types:^asset.Types) -> string {
        model,ok:=import_ok(t,source,options);if !ok {return ""}
        defer importer.model_destroy(&model)
        report,error:=importer.import_write(&model,folder,options);defer importer.report_destroy(&report)
        if !testing.expect_value(t,error.code,importer.Error_Code.None) {return ""}
        written,found:=written_of(&report,asset.KIND_MATERIAL,"Terracotta")
        if !testing.expect(t,found) {return ""}
        return strings.clone(written.path,context.temp_allocator)
    }
    out:=fmt.tprintf("%s/out",folder)
    path:=import_once(t,source,out,options,&types);if path=="" {return}
    file:asset.Asset
    if !testing.expect_value(t,asset.asset_load(&file,path),asset.Error.None) {return}
    view,view_error:=asset.material_view(&file,&types)
    if !testing.expect(t,view_error==.None && view.imported!=nil) {asset.asset_close(&file);return}
    original:=view.imported^;edited:=view.info^;edited.roughness=.123
    saved:=asset.material_save(path,&types,{id=file.blob.header.id,owner=file.blob.header.owner,info=edited,imported=view.imported,parameters=view.parameters,overlays=view.overlays,hidden=view.hidden,source=view.source})
    asset.asset_close(&file);testing.expect_value(t,saved,asset.Error.None)
    gltf,_=strings.replace(gltf,"0.62,","0.42,",1,context.temp_allocator)
    if !testing.expect(t,os.write_entire_file(source,transmute([]u8)gltf)==nil) {return}
    again:=import_once(t,source,out,options,&types)
    if !testing.expect(t,again==path) || !testing.expect_value(t,asset.asset_load(&file,path),asset.Error.None) {return}
    defer asset.asset_close(&file)
    view,view_error=asset.material_view(&file,&types)
    if !testing.expect(t,view_error==.None && view.imported!=nil) {return}
    testing.expect(t,view.info.roughness==.123 && view.imported.roughness==original.roughness)
    testing.expect(t,abs(view.info.base_color.x-.42)<.001 && view.imported.base_color==view.info.base_color && view.info.base_color!=original.base_color)
    overrides:=make([dynamic]string,context.temp_allocator);asset.material_overrides(&types,view,&overrides)
    testing.expect(t,len(overrides)==1 && overrides[0]=="roughness")
    reverted,failed,revert_error:=asset.material_revert(&types,view,{"roughness"})
    testing.expect(t,revert_error==.None && failed=="" && reverted.roughness==original.roughness)
}

@(test)
importing_again_keeps_the_identity_of_every_asset :: proc(t:^testing.T) {
    folder:=temp_folder("write-identity")
    defer os.remove_all(folder)
    model,ok:=import_ok(t,DEMO+"models/plant.gltf")
    if !ok {return}
    defer importer.model_destroy(&model)
    first,first_error:=importer.import_write(&model,fmt.tprintf("%s/one",folder))
    defer importer.report_destroy(&first)
    testing.expect_value(t,first_error.code,importer.Error_Code.None)

    again,again_ok:=import_ok(t,DEMO+"models/plant.gltf")
    if !again_ok {return}
    defer importer.model_destroy(&again)
    second,second_error:=importer.import_write(&again,fmt.tprintf("%s/one",folder))
    defer importer.report_destroy(&second)
    testing.expect_value(t,second_error.code,importer.Error_Code.None)
    testing.expect_value(t,len(first.assets),len(second.assets))
    for item,i in first.assets {
        testing.expectf(t,item.id==second.assets[i].id && item.path==second.assets[i].path,"%s keeps its id and its file",item.name)
        testing.expect(t,item.id!=base.Asset_Id{})
    }
    ids:=make(map[base.Asset_Id]bool,context.temp_allocator)
    for item in first.assets {
        testing.expect(t,!ids[item.id],"ids are distinct")
        ids[item.id]=true
    }
    names,_:=os.read_all_directory_by_path(fmt.tprintf("%s/one",folder),context.temp_allocator)
    testing.expect_value(t,len(names),len(first.assets))

    // A copy of a project, its sources with its assets, imports again with the ids of its assets.
    for root in ([]string{"a","b"}) {
        source:=fmt.tprintf("%s/%s/models",folder,root)
        os.make_directory_all(source)
        data,_:=os.read_entire_file(DEMO+"models/vase.mtl",context.temp_allocator)
        _=os.write_entire_file(fmt.tprintf("%s/vase.mtl",source),data)
        data,_=os.read_entire_file(DEMO+"models/vase.obj",context.temp_allocator)
        _=os.write_entire_file(fmt.tprintf("%s/vase.obj",source),data)
    }
    ids_by_root:[2][dynamic]base.Asset_Id
    for root,i in ([]string{"a","b"}) {
        if i==1 {
            os.make_directory_all(fmt.tprintf("%s/b/out",folder))
            copied,_:=os.read_all_directory_by_path(fmt.tprintf("%s/a/out",folder),context.temp_allocator)
            for entry in copied {
                data,_:=os.read_entire_file(entry.fullpath,context.temp_allocator)
                _=os.write_entire_file(fmt.tprintf("%s/b/out/%s",folder,entry.name),data)
            }
        }
        options:=importer.Import_Options{root=fmt.tprintf("%s/%s",folder,root)}
        vase,vase_ok:=import_ok(t,fmt.tprintf("%s/%s/models/vase.obj",folder,root),options)
        if !vase_ok {continue}
        report,vase_error:=importer.import_write(&vase,fmt.tprintf("%s/%s/out",folder,root),options)
        testing.expect_value(t,vase_error.code,importer.Error_Code.None)
        ids_by_root[i].allocator=context.temp_allocator
        for item in report.assets {append(&ids_by_root[i],item.id)}
        importer.report_destroy(&report)
        importer.model_destroy(&vase)
    }
    testing.expect(t,len(ids_by_root[0])>0 && slice.equal(ids_by_root[0][:],ids_by_root[1][:]),"the copy of a project keeps the ids of its assets")
}

@(test)
images_that_are_missing_or_not_images_leave_a_warning_and_no_reference :: proc(t:^testing.T) {
    folder:=temp_folder("write-images")
    defer os.remove_all(folder)
    write_text(folder,"m.mtl","newmtl paint\nKd 1 0 0\nmap_Kd gone.png\nmap_Ke garbage.png\nmap_Bump good.png\n")
    _=os.write_entire_file(fmt.tprintf("%s/garbage.png",folder),[]u8{1,2,3,4,5,6,7,8})
    _=os.write_entire_file(fmt.tprintf("%s/good.png",folder),png_bytes(8,8,{128,128,255}))
    path:=write_text(folder,"m.obj","mtllib m.mtl\nv 0 0 0\nv 1 0 0\nv 0 1 0\nusemtl paint\nf 1 2 3\n")
    model,ok:=import_ok(t,path)
    if !ok {return}
    defer importer.model_destroy(&model)
    testing.expect_value(t,len(model.warnings),0)
    report,error:=importer.import_write(&model,fmt.tprintf("%s/out",folder))
    defer importer.report_destroy(&report)
    testing.expect_value(t,error.code,importer.Error_Code.None)
    testing.expect_value(t,len(report.warnings),2)
    joined:=strings.join(report.warnings[:],"\n",context.temp_allocator)
    testing.expect(t,contains(joined,"gone") && contains(joined,"does not exist") && contains(joined,"garbage"),joined)
    testing.expect_value(t,len(report.assets),3)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    paint,_:=written_of(&report,asset.KIND_MATERIAL,"paint")
    good,_:=written_of(&report,asset.KIND_TEXTURE,"good")
    a,loaded:=read_asset(t,paint,&types)
    if !loaded {return}
    defer asset.asset_close(&a)
    material,_:=asset.material_view(&a,&types)
    testing.expect(t,material.info.maps.base_color.texture=={} && material.info.maps.emission.texture=={},"a map whose image is not written has no texture")
    testing.expect_value(t,material.info.maps.normal.texture,good.id)
}

@(test)
embedded_images_and_the_maximum_texture_size_are_honored :: proc(t:^testing.T) {
    folder:=temp_folder("write-embedded")
    defer os.remove_all(folder)
    encoded,_:=base64.encode(png_bytes(64,32,{200,100,50}),allocator=context.temp_allocator)
    positions:=[9]f32{0,0,0,1,0,0,0,1,0}
    uvs:=[6]f32{0,0,1,0,0,1}
    all:[15]f32
    copy(all[:9],positions[:]);copy(all[9:],uvs[:])
    buffer,_:=base64.encode(slice.to_bytes(all[:]),allocator=context.temp_allocator)
    gltf:=strings.concatenate({`{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"mesh":0}],"meshes":[{"primitives":[{"attributes":{"POSITION":0,"TEXCOORD_0":1},"material":0}]}],`,
        `"materials":[{"name":"Tinted","pbrMetallicRoughness":{"baseColorTexture":{"index":0}}}],"textures":[{"source":0}],"images":[{"name":"wood","uri":"data:image/png;base64,`,encoded,`"}],`,
        `"buffers":[{"byteLength":60,"uri":"data:application/octet-stream;base64,`,buffer,`"}],"bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36},{"buffer":0,"byteOffset":36,"byteLength":24}],`,
        `"accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","min":[0,0,0],"max":[1,1,0]},{"bufferView":1,"componentType":5126,"count":3,"type":"VEC2"}]}`},context.temp_allocator)
    path:=write_text(folder,"embedded.gltf",gltf)
    model,ok:=import_ok(t,path)
    if !ok {return}
    defer importer.model_destroy(&model)
    testing.expect_value(t,len(model.images),1)
    testing.expect(t,model.images[0].path=="" && len(model.images[0].data)>0 && model.images[0].name=="wood")
    report,error:=importer.import_write(&model,fmt.tprintf("%s/out",folder),{max_texture_size=16})
    defer importer.report_destroy(&report)
    testing.expect_value(t,error.code,importer.Error_Code.None)
    testing.expect_value(t,len(report.warnings),0)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    written,found:=written_of(&report,asset.KIND_TEXTURE,"wood")
    testing.expect(t,found)
    if !found {return}
    a,loaded:=read_asset(t,written,&types)
    if !loaded {return}
    defer asset.asset_close(&a)
    texture,_:=asset.texture_view(&a,&types)
    testing.expect(t,texture.info.width==16 && texture.info.height==8 && texture.info.mip_count==5,"the largest size is capped and the chain is rebuilt")
}

@(test)
gltf_and_glb_write_pbr_maps_with_color_spaces_channels_and_independent_uvs :: proc(t:^testing.T) {
    folder:=temp_folder("pbr-gltf-glb")
    defer os.remove_all(folder)
    images:=[3][]u8{png_bytes(8,8,{180,70,25}),png_bytes(8,8,{32,96,224}),png_bytes(8,8,{128,128,255})}
    names:=[3]string{"paint color","orm","normal"}
    geometry:=[21]f32{0,0,0,1,0,0,0,1,0, 0,0,1,0,0,1, 0.25,0.75,0.75,0.75,0.25,0.25}
    for binary in ([]bool{false,true}) {
        payload:serial.Writer;serial.writer_init(&payload);defer serial.writer_destroy(&payload)
        serial.write_bytes(&payload,slice.to_bytes(geometry[:]))
        image_json,views:strings.Builder
        strings.builder_init(&image_json,context.temp_allocator)
        strings.builder_init(&views,context.temp_allocator)
        for bytes,i in images {
            if i!=0 {strings.write_string(&image_json,",")}
            if binary {
                serial.write_align(&payload,4)
                strings.write_string(&views,fmt.tprintf(",{{\"buffer\":0,\"byteOffset\":%d,\"byteLength\":%d}}",payload.count,len(bytes)))
                strings.write_string(&image_json,fmt.tprintf("{{\"name\":\"%s\",\"bufferView\":%d,\"mimeType\":\"image/png\"}}",names[i],3+i))
                serial.write_bytes(&payload,bytes)
            } else {
                _=os.write_entire_file(fmt.tprintf("%s/%s.png",folder,names[i]),bytes)
                uri:=names[i] if i!=0 else "paint%20color"
                strings.write_string(&image_json,fmt.tprintf("{{\"name\":\"%s\",\"uri\":\"%s.png\"}}",names[i],uri))
            }
        }
        serial.write_align(&payload,4)
        uri:="" if binary else `,"uri":"pbr.bin"`
        json:=strings.concatenate({`{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"mesh":0}],
            "meshes":[{"name":"Surface","primitives":[{"attributes":{"POSITION":0,"TEXCOORD_0":1,"TEXCOORD_1":2},"material":0},{"attributes":{"POSITION":0,"TEXCOORD_0":1,"TEXCOORD_1":2},"material":1}]}],
            "materials":[{"name":"PBR","pbrMetallicRoughness":{"baseColorFactor":[0.8,0.7,0.6,1],"baseColorTexture":{"index":0},"metallicFactor":0.75,"roughnessFactor":0.6,"metallicRoughnessTexture":{"index":1,"texCoord":1}},
                "normalTexture":{"index":2,"scale":0.7,"extensions":{"KHR_texture_transform":{"offset":[0.2,0.3],"scale":[2,3],"rotation":0.5,"texCoord":1}}},
                "occlusionTexture":{"index":1,"strength":0.4},"emissiveTexture":{"index":0,"texCoord":1},"emissiveFactor":[0.1,0.2,0.3],
                "extensions":{"KHR_materials_specular":{"specularFactor":0.5,"specularTexture":{"index":0},"specularColorFactor":[0.9,0.8,0.7],"specularColorTexture":{"index":0,"texCoord":1}}}},
                {"name":"Shared","pbrMetallicRoughness":{"baseColorTexture":{"index":0,"texCoord":1},"metallicRoughnessTexture":{"index":1}},"normalTexture":{"index":2}}],
            "textures":[{"source":0},{"source":1},{"source":2}],"images":[`,strings.to_string(image_json),`],"extensionsUsed":["KHR_texture_transform","KHR_materials_specular"],
            "buffers":[{"byteLength":`,fmt.tprint(payload.count),uri,`}],"bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36},{"buffer":0,"byteOffset":36,"byteLength":24},{"buffer":0,"byteOffset":60,"byteLength":24}`,strings.to_string(views),`],
            "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","min":[0,0,0],"max":[1,1,0]},{"bufferView":1,"componentType":5126,"count":3,"type":"VEC2"},{"bufferView":2,"componentType":5126,"count":3,"type":"VEC2"}]}`},context.temp_allocator)
        path:=fmt.tprintf("%s/pbr.%s",folder,"glb" if binary else "gltf")
        if binary {
            file:serial.Writer;serial.writer_init(&file);defer serial.writer_destroy(&file)
            padded:=(len(json)+3)&~3
            serial.write_u32(&file,0x46546c67);serial.write_u32(&file,2);serial.write_u32(&file,u32(12+8+padded+8+payload.count))
            serial.write_u32(&file,u32(padded));serial.write_u32(&file,0x4e4f534a)
            serial.write_bytes(&file,transmute([]u8)json)
            for _ in len(json)..<padded {serial.write_u8(&file,32)}
            serial.write_u32(&file,u32(payload.count));serial.write_u32(&file,0x004e4942)
            serial.write_bytes(&file,serial.writer_bytes(&payload))
            _=os.write_entire_file(path,serial.writer_bytes(&file))
        } else {
            _=os.write_entire_file(path,json)
            _=os.write_entire_file(fmt.tprintf("%s/pbr.bin",folder),serial.writer_bytes(&payload))
        }
        model,ok:=import_ok(t,path)
        if !ok {continue}
        defer importer.model_destroy(&model)
        testing.expect_value(t,len(model.materials),2)
        testing.expect(t,len(model.images)==4,"the same color image used as linear data needs its own texture")
        // The fixture binds the maps of the base; the layers have none.
        for slot in ([?]asset.Material_Map_Kind{.Base_Color,.Metallic_Roughness,.Normal,.Emission,.Occlusion,.Specular,.Specular_Color}) {
            index:=model.materials[0].images[slot]
            if !testing.expect(t,index>=0) {continue}
            image:=model.images[index]
            color:=slot==.Base_Color || slot==.Emission || slot==.Specular_Color
            testing.expect(t,image.srgb==color && image.normal_map==(slot==.Normal))
            testing.expect(t,(image.path=="")==binary && (len(image.data)>0)==binary)
        }
        options:=importer.Import_Options{root=folder,textures=.Uncompressed}
        report,error:=importer.import_write(&model,fmt.tprintf("%s/%s",folder,"glb-out" if binary else "gltf-out"),options)
        if !testing.expect_value(t,error.code,importer.Error_Code.None) {continue}
        defer importer.report_destroy(&report)
        testing.expect_value(t,len(report.warnings),0)
        testing.expect_value(t,len(report.assets),7)
        surface,has_surface:=written_of(&report,asset.KIND_MESH,"Surface")
        pbr,has_pbr:=written_of(&report,asset.KIND_MATERIAL,"PBR")
        testing.expect(t,has_surface && has_pbr && report.mesh_ids[0]==surface.id && report.material_ids[0]==pbr.id && surface.id!={} && pbr.id!={})
        types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
        for written in report.assets {
            a,loaded:=read_asset(t,written,&types)
            if !loaded {continue}
            defer asset.asset_close(&a)
            switch written.kind {
            case asset.KIND_MATERIAL:
                material,view_error:=asset.material_view(&a,&types)
                if !testing.expect_value(t,view_error,asset.Error.None) {continue}
                row:=0 if written.name=="PBR" else 1
                for slot in asset.Material_Map_Kind {
                    index:=model.materials[row].images[slot]
                    map_:=importer.material_map(material.info,slot)
                    if index<0 {testing.expect_value(t,map_.texture,base.Asset_Id{});continue}
                    testing.expect_value(t,map_.texture,report.image_ids[index])
                    testing.expect(t,slice.contains(a.dependencies,map_.texture))
                }
                if row==0 {
                    info:=material.info
                    testing.expect_value(t,info.base_color,[3]f32{0.8,0.7,0.6})
                    testing.expect(t,info.metallic==0.75 && info.roughness==0.6 && info.normal_scale==0.7 && info.occlusion_strength==0.4)
                    testing.expect(t,info.maps.metallic_roughness.texture==info.maps.occlusion.texture && info.maps.specular.texture!=info.maps.base_color.texture)
                    testing.expect(t,info.maps.base_color.uv_set==0 && info.maps.metallic_roughness.uv_set==1 && info.maps.occlusion.uv_set==0)
                    testing.expect(t,info.maps.normal.uv_set==1 && info.maps.normal.offset=={0.2,0.3} && info.maps.normal.scale=={2,3} && info.maps.normal.rotation==0.5)
                    testing.expect_value(t,info.maps.emission.texture,info.maps.base_color.texture)
                    testing.expect_value(t,info.maps.specular_color.texture,info.maps.base_color.texture)
                }
            case asset.KIND_TEXTURE:
                texture,view_error:=asset.texture_view(&a,&types)
                if !testing.expect_value(t,view_error,asset.Error.None) {continue}
                index:=-1
                for id,i in report.image_ids {if id==written.id {index=i;break}}
                if !testing.expect(t,index>=0) {continue}
                image:=model.images[index]
                testing.expect(t,(.Srgb in texture.info.flags)==image.srgb && (.Normal_Map in texture.info.flags)==image.normal_map)
                testing.expect(t,texture.info.width==8 && texture.info.height==8 && texture.info.mip_count==4)
                testing.expect_value(t,texture.info.format,asset.Texture_Format.RGBA8)
                if index==model.materials[0].images[.Metallic_Roughness] {
                    pixels:=asset.texture_mip(texture,0)
                    testing.expect(t,len(pixels)>=4 && pixels[0]==32 && pixels[1]==96 && pixels[2]==224,"occlusion R, roughness G, metallic B remain linear and keep their channels")
                }
            case asset.KIND_MESH:
                mesh,view_error:=asset.mesh_view(&a,&types)
                if !testing.expect_value(t,view_error,asset.Error.None) {continue}
                testing.expect(t,len(mesh.slots)==2 && mesh.slots[0].material==report.material_ids[0] && mesh.slots[1].material==report.material_ids[1])
                vertices:=make([dynamic]asset.Vertex,context.temp_allocator)
                indices:=make([dynamic]u32,context.temp_allocator)
                if testing.expect(t,asset.mesh_level_decode(mesh.geometry,0,&vertices,&indices)) {testing.expect_value(t,vertices[0].uv1,[2]f32{0.25,0.75})}
            }
        }
        blocks,blocks_error:=importer.import_write(&model,fmt.tprintf("%s/%s-blocks",folder,"glb" if binary else "gltf"),{root=folder,textures=.Blocks})
        if !testing.expect_value(t,blocks_error.code,importer.Error_Code.None) {continue}
        defer importer.report_destroy(&blocks)
        testing.expect_value(t,len(blocks.warnings),0)
        for id,i in blocks.image_ids {testing.expect_value(t,id,report.image_ids[i])}
        for written in blocks.assets {
            if written.kind!=asset.KIND_TEXTURE {continue}
            a,loaded:=read_asset(t,written,&types)
            if !loaded {continue}
            defer asset.asset_close(&a)
            texture,view_error:=asset.texture_view(&a,&types)
            if !testing.expect_value(t,view_error,asset.Error.None) {continue}
            expected:=asset.Texture_Format.BC5 if .Normal_Map in texture.info.flags else .BC7 if .Srgb in texture.info.flags else .BC1
            testing.expect_value(t,texture.info.format,expected)
        }
    }
}

@(test)
a_standalone_image_becomes_a_texture :: proc(t:^testing.T) {
    folder:=temp_folder("write-texture")
    defer os.remove_all(folder)
    path:=fmt.tprintf("%s/Bricks Color.png",folder)
    _=os.write_entire_file(path,png_bytes(16,16,{150,60,40}))
    report,error:=importer.import_texture(path,fmt.tprintf("%s/out",folder),{image=.Color})
    defer importer.report_destroy(&report)
    testing.expect_value(t,error.code,importer.Error_Code.None)
    testing.expect_value(t,len(report.assets),1)
    testing.expect(t,report.assets[0].id!={} && strings.has_suffix(report.assets[0].path,"/Bricks Color.tex"))
    again,again_error:=importer.import_texture(path,fmt.tprintf("%s/out",folder),{image=.Normal})
    defer importer.report_destroy(&again)
    testing.expect_value(t,again_error.code,importer.Error_Code.None)
    testing.expect(t,again.assets[0].id==report.assets[0].id && again.assets[0].path==report.assets[0].path,"imported again as a normal map, the image is the same texture")

    _=os.write_entire_file(path,[]u8{1,2,3})
    _,bad:=importer.import_texture(path,fmt.tprintf("%s/other",folder),{image=.Color})
    testing.expect_value(t,bad.code,importer.Error_Code.Unsupported)
    testing.expect(t,!os.exists(fmt.tprintf("%s/other/Bricks Color.tex",folder)),"a failed import leaves no file")
    _,missing:=importer.import_texture(fmt.tprintf("%s/none.png",folder),fmt.tprintf("%s/other",folder),{image=.Color})
    testing.expect_value(t,missing.code,importer.Error_Code.Not_Found)
}

// A Radiance image is an image whose light above 1 the texture keeps, in BC6H.
@(test)
a_radiance_image_becomes_an_hdr_texture :: proc(t:^testing.T) {
    folder:=temp_folder("write-hdr")
    defer os.remove_all(folder)
    path:=fmt.tprintf("%s/sky.hdr",folder)
    hdr:=make([dynamic]u8,context.temp_allocator)
    append(&hdr,"#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 2 +X 4\n")
    for _ in 0..<8 {append(&hdr,200,200,200,135)} // 100
    _=os.write_entire_file(path,hdr[:])
    testing.expect_value(t,source_kind(path),Source_Kind.Image)
    report,error:=import_source(path,fmt.tprintf("%s/out",folder),{no_save=true})
    defer importer.report_destroy(&report)
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    a:asset.Asset
    if !testing.expect_value(t,asset.asset_load(&a,report.assets[0].path),asset.Error.None) {return}
    defer asset.asset_close(&a)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    texture,view_error:=asset.texture_view(&a,&types)
    if !testing.expect_value(t,view_error,asset.Error.None) {return}
    testing.expect_value(t,texture.info.format,asset.Texture_Format.BC6H)
    light:[16][4]f32
    testing.expect(t,asset.texture_level_linear(texture.info.format,texture.info.flags,asset.texture_layer(texture,0,0),4,2,light[:8]))
    testing.expectf(t,abs(light[0].r-100)<3,"the light of the image is not clipped: %v",light[0])
}

@(test)
embedded_images_with_the_same_name_keep_distinct_texture_ids :: proc(t:^testing.T) {
    folder:=temp_folder("duplicate-image-names");defer os.remove_all(folder)
    red,_:=base64.encode(png_bytes(4,4,{255,0,0}),allocator=context.temp_allocator)
    blue,_:=base64.encode(png_bytes(4,4,{0,0,255}),allocator=context.temp_allocator)
    vertices:=[15]f32{0,0,0,1,0,0,0,1,0,0,0,1,0,0,1}
    encoded,_:=base64.encode(slice.to_bytes(vertices[:]),allocator=context.temp_allocator)
    source:=strings.concatenate({`{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"mesh":0}],
        "meshes":[{"primitives":[{"attributes":{"POSITION":0,"TEXCOORD_0":1},"material":0},{"attributes":{"POSITION":0,"TEXCOORD_0":1},"material":1}]}],
        "materials":[{"name":"Red","pbrMetallicRoughness":{"baseColorTexture":{"index":0}}},{"name":"Blue","pbrMetallicRoughness":{"baseColorTexture":{"index":1}}}],
        "textures":[{"source":0},{"source":1}],"images":[{"name":"paint","uri":"data:image/png;base64,`,red,`"},{"name":"paint","uri":"data:image/png;base64,`,blue,`"}],
        "buffers":[{"byteLength":60,"uri":"data:application/octet-stream;base64,`,encoded,`"}],"bufferViews":[{"buffer":0,"byteLength":36},{"buffer":0,"byteOffset":36,"byteLength":24}],
        "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","min":[0,0,0],"max":[1,1,0]},{"bufferView":1,"componentType":5126,"count":3,"type":"VEC2"}]}`},context.temp_allocator)
    path:=write_text(folder,"names.gltf",source)
    model,ok:=import_ok(t,path);if !ok {return};defer importer.model_destroy(&model)
    report,error:=importer.import_write(&model,fmt.tprintf("%s/out",folder),{textures=.Uncompressed})
    if !testing.expect_value(t,error.code,importer.Error_Code.None) {return};defer importer.report_destroy(&report)
    testing.expect(t,len(report.image_ids)==2 && report.image_ids[0]!=report.image_ids[1])
    testing.expect_value(t,len(report.warnings),0)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    for written in report.assets {
        a,loaded:=read_asset(t,written,&types);if !loaded {continue};defer asset.asset_close(&a)
        switch written.kind {
        case asset.KIND_TEXTURE:
            texture,view_error:=asset.texture_view(&a,&types)
            if !testing.expect_value(t,view_error,asset.Error.None) {continue}
            color:=asset.texture_mip(texture,0)
            red:=written.id==report.image_ids[0]
            testing.expect(t,color[0]==(255 if red else 0) && color[2]==(0 if red else 255))
        case asset.KIND_MATERIAL:
            material,view_error:=asset.material_view(&a,&types)
            if !testing.expect_value(t,view_error,asset.Error.None) {continue}
            testing.expect_value(t,material.info.maps.base_color.texture,report.image_ids[0 if written.name=="Red" else 1])
        }
    }
}

@(test)
names_are_made_safe_and_unique_as_file_names :: proc(t:^testing.T) {
    folder:=temp_folder("write-names")
    defer os.remove_all(folder)
    path:=write_text(folder,"n.obj","o a/b:c\nv 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\no a_b_c\nv 0 0 1\nv 1 0 1\nv 0 1 1\nf 4 5 6\no a/b:c\nv 0 0 2\nv 1 0 2\nv 0 1 2\nf 7 8 9\n")
    model,ok:=import_ok(t,path)
    if !ok {return}
    defer importer.model_destroy(&model)
    testing.expect_value(t,len(model.meshes),3)
    testing.expect(t,model.meshes[0].name!=model.meshes[2].name,"a repeated name is made unique in the model")
    report,error:=importer.import_write(&model,fmt.tprintf("%s/out",folder))
    defer importer.report_destroy(&report)
    testing.expect_value(t,error.code,importer.Error_Code.None)
    seen:=make(map[string]bool,context.temp_allocator)
    for item in report.assets {
        testing.expect(t,!seen[strings.to_lower(item.path,context.temp_allocator)] && os.exists(item.path),"every asset has a file of its own")
        seen[strings.to_lower(item.path,context.temp_allocator)]=true
        testing.expect(t,!contains(item.path[len(folder)+4:],":") && !contains(item.path[len(folder)+4:],"\\"))
    }
}

@(test)
a_destination_that_cannot_be_a_folder_fails_without_leaving_files :: proc(t:^testing.T) {
    folder:=temp_folder("write-fail")
    defer os.remove_all(folder)
    model,ok:=import_ok(t,FIXTURES+"concave.obj")
    if !ok {return}
    defer importer.model_destroy(&model)
    blocker:=write_text(folder,"blocker","this is a file")
    _,error:=importer.import_write(&model,blocker)
    testing.expect_value(t,error.code,importer.Error_Code.Write)
    _,error=importer.import_write(&model,fmt.tprintf("%s/inside",blocker))
    testing.expect_value(t,error.code,importer.Error_Code.Write)
}

@(test)
every_fixture_imports_writes_and_reads_back_with_its_dependencies_resolved :: proc(t:^testing.T) {
    folder:=temp_folder("write-fixtures")
    defer os.remove_all(folder)
    sources:=[]string{
        FIXTURES+"concave.obj",FIXTURES+"multiple.obj",FIXTURES+"hierarchy.gltf",FIXTURES+"hierarchy.glb",FIXTURES+"single-transform.gltf",
        FIXTURES+"skeletal-analytic.gltf",FIXTURES+"skeletal-analytic.glb",FIXTURES+"khronos-simple-skin/SimpleSkin.gltf",FIXTURES+"hierarchy.usda",
        DEMO+"models/vase.obj",DEMO+"models/plant.gltf",DEMO+"models/skeletal-character/robot.glb",DEMO+"models/skeletal-character/robot.gltf",
    }
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    for source,i in sources {
        out:=fmt.tprintf("%s/%d",folder,i)
        text:=text_formats()
        model,ok:=import_ok(t,source,formats=text[:])
        if !ok {continue}
        defer importer.model_destroy(&model)
        report,error:=importer.import_write(&model,out)
        defer importer.report_destroy(&report)
        testing.expectf(t,error.code==.None && len(report.warnings)==0,"%s: %v %s",source,error.code,error.message)
        counts:[3]int
        for written in report.assets {
            a,loaded:=read_asset(t,written,&types)
            if !loaded {continue}
            defer asset.asset_close(&a)
            switch written.kind {
            case asset.KIND_MESH:
                counts[0]+=1
                view,view_error:=asset.mesh_view(&a,&types)
                testing.expectf(t,view_error==.None && asset.mesh_check_indices(view),"%s: %s reads back",source,written.name)
            case asset.KIND_MATERIAL:
                counts[1]+=1
                _,view_error:=asset.material_view(&a,&types)
                testing.expect_value(t,view_error,asset.Error.None)
            case asset.KIND_TEXTURE:
                counts[2]+=1
                _,view_error:=asset.texture_view(&a,&types)
                testing.expect_value(t,view_error,asset.Error.None)
            }
        }
        testing.expectf(t,counts[0]==len(model.meshes) && counts[1]==len(model.materials),"%s: every mesh and material is an asset",source)
        registry:asset.Registry
        asset.registry_init(&registry,out)
        testing.expect_value(t,asset.registry_scan(&registry),asset.Error.None)
        missing:[dynamic]asset.Registry_Missing
        missing.allocator=context.temp_allocator
        asset.registry_missing(&registry,&missing)
        testing.expectf(t,len(missing)==0 && len(registry.duplicates)==0,"%s: every dependency of what was written is written",source)
        asset.registry_destroy(&registry)
    }
}

@(test)
the_report_names_the_asset_of_every_row_of_the_model :: proc(t:^testing.T) {
    folder:=temp_folder("write-rows")
    defer os.remove_all(folder)
    model,ok:=import_ok(t,DEMO+"models/plant.gltf")
    if !ok {return}
    defer importer.model_destroy(&model)
    report,error:=importer.import_write(&model,folder)
    defer importer.report_destroy(&report)
    testing.expect_value(t,error.code,importer.Error_Code.None)
    testing.expect_value(t,len(report.mesh_ids),1)
    plant,has_plant:=written_of(&report,asset.KIND_MESH,"Plant")
    testing.expect(t,has_plant && report.mesh_ids[0]==plant.id)
    testing.expect_value(t,len(report.material_ids),3)
    for material,i in model.materials {
        written,has:=written_of(&report,asset.KIND_MATERIAL,material.name)
        testing.expect(t,has && report.material_ids[i]==written.id)
    }
    testing.expect_value(t,len(report.image_ids),1)
    texture,found:=written_of(&report,asset.KIND_TEXTURE,"leaves_color")
    testing.expect(t,found && report.image_ids[0]==texture.id)
}

// glTF's anisotropy (mix(r², 1, s²) along the tangent, r² across it) takes an
// OpenPBR roughness and amount that depend on the roughness of each texel: a
// roughness texture becomes a converted one, with an anisotropy image of the
// amounts, and the factors become 1.
@(test)
gltf_anisotropy_with_a_roughness_texture_is_converted_texel_by_texel :: proc(t:^testing.T) {
    folder:=temp_folder("write-anisotropy")
    defer os.remove_all(folder)
    encoded,_:=base64.encode(png_bytes(8,8,{255,128,64}),allocator=context.temp_allocator)
    positions:=[9]f32{0,0,0,1,0,0,0,1,0}
    uvs:=[6]f32{0,0,1,0,0,1}
    all:[15]f32
    copy(all[:9],positions[:]);copy(all[9:],uvs[:])
    buffer,_:=base64.encode(slice.to_bytes(all[:]),allocator=context.temp_allocator)
    gltf :: proc(material,encoded,buffer:string) -> string {
        return strings.concatenate({`{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"mesh":0}],"meshes":[{"primitives":[{"attributes":{"POSITION":0,"TEXCOORD_0":1},"material":0}]}],`,
            `"materials":[`,material,`],"textures":[{"source":0}],"images":[{"name":"orm","uri":"data:image/png;base64,`,encoded,`"}],`,
            `"buffers":[{"byteLength":60,"uri":"data:application/octet-stream;base64,`,buffer,`"}],"bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36},{"buffer":0,"byteOffset":36,"byteLength":24}],`,
            `"accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","min":[0,0,0],"max":[1,1,0]},{"bufferView":1,"componentType":5126,"count":3,"type":"VEC2"}]}`},context.temp_allocator)
    }
    path:=write_text(folder,"brushed.gltf",gltf(`{"name":"Brushed","pbrMetallicRoughness":{"metallicRoughnessTexture":{"index":0}},"extensions":{"KHR_materials_anisotropy":{"anisotropyStrength":0.6,"anisotropyRotation":0.5}}}`,encoded,buffer))
    model,ok:=import_ok(t,path)
    if !ok {return}
    defer importer.model_destroy(&model)
    testing.expect_value(t,len(model.warnings),0)
    testing.expect_value(t,len(model.images),2)
    info:=&model.materials[0].info
    testing.expect(t,info.roughness==1 && info.anisotropy.amount==1 && info.anisotropy.rotation==0.5 && info.metallic==1,"the textures hold the values")
    rough,turned:=model.materials[0].images[.Metallic_Roughness],model.materials[0].images[.Anisotropy]
    if !testing.expect(t,rough>=0 && turned>=0) {return}
    testing.expect(t,model.images[rough].made.width==8 && len(model.images[rough].made.texels)==8*8*4,"the converted image has the size of the source")
    // Roughness 128/255 and strength 0.6: the alphas of the converted lobe are glTF's.
    r,a:=f32(model.images[rough].made.texels[1])/255,f32(model.images[turned].made.texels[2])/255
    along,across:=r*r*f32(math.sqrt(2/(1+(1-a)*(1-a)))),(1-a)*r*r*f32(math.sqrt(2/(1+(1-a)*(1-a))))
    base:=f32(128)/255
    testing.expectf(t,abs(along-(base*base+(1-base*base)*0.36))<0.01 && abs(across-base*base)<0.01,"alphas %v and %v",along,across)
    testing.expect(t,model.images[rough].made.texels[0]==255 && model.images[rough].made.texels[2]==64,"occlusion and metallic stay")
    report,error:=importer.import_write(&model,fmt.tprintf("%s/out",folder),{})
    defer importer.report_destroy(&report)
    testing.expect_value(t,error.code,importer.Error_Code.None)
    testing.expect_value(t,len(report.warnings),0)
    // Textures that read different coordinates cannot be converted together: the factors are, and a warning says so.
    other:=write_text(folder,"apart.gltf",gltf(`{"name":"Apart","pbrMetallicRoughness":{"metallicRoughnessTexture":{"index":0}},"extensions":{"KHR_materials_anisotropy":{"anisotropyStrength":0.6,"anisotropyTexture":{"index":0,"extensions":{"KHR_texture_transform":{"scale":[2,2]}}}}}}`,encoded,buffer))
    apart,read:=import_ok(t,other)
    if !read {return}
    defer importer.model_destroy(&apart)
    testing.expect(t,len(apart.warnings)==1 && strings.contains(apart.warnings[0],"differ in texture coordinates"),"a warning names why")
    testing.expect_value(t,len(apart.images),1)
}
