package asset

import "core:mem"
import "core:testing"
import anim "mirai:std/anim"
import "mirai:std/base"
import "mirai:std/serial"

@(test)
skeleton_round_trips_names_hierarchy_and_rest_pose :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    bones:=[2]Skeleton_Bone{{parent=-1,rotation=1,scale={1,1,1}},{parent=0,rotation=1,scale={1,1,1},translation={0,1,0}}}
    text_set(bones[0].name[:],"root");text_set(bones[0].path[:],"root");bones[0].target=base.name_hash("root")
    text_set(bones[1].name[:],"foot");text_set(bones[1].path[:],"root/foot");bones[1].target=base.name_hash("root/foot")
    doc:Document
    socket:=Skeleton_Socket{bone=bones[1].path,offset={rotation=1,scale={1,1,1}}};text_set(socket.name[:],"boot")
    if !testing.expect_value(t,skeleton_document(&doc,&types,{id={3,5},bones=bones[:],sockets={socket}}),Error.None) {return}
    defer document_destroy(&doc)
    bytes:serial.Writer;serial.writer_init(&bytes);defer serial.writer_destroy(&bytes)
    testing.expect_value(t,document_write(&doc,&bytes),Error.None)
    file:Asset
    if !testing.expect_value(t,asset_open(&file,serial.writer_bytes(&bytes)),Error.None) {return}
    defer asset_close(&file)
    view,error:=skeleton_view(&file,&types)
    testing.expect_value(t,len(view.sockets),1)
    testing.expect_value(t,view.sockets[0],socket)
    duplicate:=view;duplicate.sockets={socket,socket};testing.expect(t,!skeleton_check(duplicate))
    missing:=socket;text_set(missing.bone[:],"missing");duplicate.sockets={missing};testing.expect(t,!skeleton_check(duplicate))
    if !testing.expect_value(t,error,Error.None) {return}
    testing.expect(t,len(view.bones)==2 && view.bones[1].parent==0 && base.text_get(view.bones[1].path[:])=="root/foot")
    testing.expect_value(t,view.bones[1].translation,[3]f32{0,1,0})
    again:serial.Writer;serial.writer_init(&again);defer serial.writer_destroy(&again)
    testing.expect_value(t,document_write(&doc,&again),Error.None)
    testing.expect(t,mem.compare(serial.writer_bytes(&bytes),serial.writer_bytes(&again))==0)
    for cut in 0..<bytes.count {
        truncated:Asset
        if asset_open(&truncated,serial.writer_bytes(&bytes)[:cut])==.None {skeleton_view(&truncated,&types);asset_close(&truncated)}
    }
}

@(test)
skeleton_rejects_ambiguous_paths_cycles_and_invalid_rest :: proc(t:^testing.T) {
    bones:=[2]Skeleton_Bone{{parent=-1,rotation=1,scale={1,1,1}},{parent=0,rotation=1,scale={1,1,1}}}
    for &bone,i in bones {
        path:="root" if i==0 else "root/foot"
        text_set(bone.path[:],path);bone.target=base.name_hash(path)
    }
    info:=Skeleton_Info{2}
    good:=Skeleton_View{info=&info,bones=bones[:]}
    testing.expect(t,skeleton_check(good))
    bones[1].parent=1;testing.expect(t,!skeleton_check(good));bones[1].parent=0
    bones[1].target=bones[0].target;testing.expect(t,!skeleton_check(good));bones[1].target=base.name_hash("root/foot")
    bones[1].scale.y=0;testing.expect(t,!skeleton_check(good));bones[1].scale.y=1
    bones[1].rotation=0;testing.expect(t,!skeleton_check(good));bones[1].rotation=1
    bones[1].translation.x=transmute(f32)u32(0x7fc00000);testing.expect(t,!skeleton_check(good))
}

// A standing figure facing -Z with its left at -X: pelvis, spine, head, arms and legs with toes, in meters.
@(private="file")
skeleton_test_figure :: proc() -> []Skeleton_Bone {
    Row :: struct {name:string,parent:i32,at:[3]f32}
    rows:=[?]Row{
        {"root",-1,{}},{"pelvis",0,{0,1,0}},{"spine_01",1,{0,1.2,0}},{"neck_01",2,{0,1.5,0}},{"head",3,{0,1.6,0}},
        {"upperarm_l",2,{-.2,1.45,0}},{"lowerarm_l",5,{-.45,1.45,0}},{"hand_l",6,{-.7,1.45,0}},
        {"upperarm_r",2,{.2,1.45,0}},{"lowerarm_r",8,{.45,1.45,0}},{"hand_r",9,{.7,1.45,0}},
        {"thigh_l",1,{-.1,.95,0}},{"calf_l",11,{-.1,.5,0}},{"foot_l",12,{-.1,.08,0}},{"ball_l",13,{-.1,.02,-.12}},
        {"thigh_r",1,{.1,.95,0}},{"calf_r",15,{.1,.5,0}},{"foot_r",16,{.1,.08,0}},{"ball_r",17,{.1,.02,-.12}},
    }
    bones:=make([]Skeleton_Bone,len(rows),context.temp_allocator)
    for row,i in rows {
        bone:=&bones[i]
        text_set(bone.name[:],row.name)
        path:=row.name if row.parent<0 else base.text_get(bones[row.parent].path[:])
        if row.parent>=0 {path=string(fmt_join(path,row.name))}
        text_set(bone.path[:],path);bone.target=base.name_hash(path)
        bone.parent=row.parent;bone.rotation=1;bone.scale={1,1,1}
        bone.translation=row.at-(rows[row.parent].at if row.parent>=0 else {})
    }
    return bones
}
@(private="file")
fmt_join :: proc(a,b:string) -> []u8 {
    out:=make([]u8,len(a)+1+len(b),context.temp_allocator)
    copy(out,a);out[len(a)]='/';copy(out[len(a)+1:],b)
    return out
}

@(test)
skeleton_keeps_its_body_by_bone_path_through_a_round_trip :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    bones:=skeleton_test_figure()
    map_,found:=skeleton_body_detect(bones,anim.body_map_empty())
    if !testing.expect(t,found) {return}
    testing.expect(t,map_.bones[.Pelvis]==1 && map_.bones[.Hand_R]==10 && map_.bones[.Toe_L]==14)
    body:Skeleton_Body
    parts:[len(anim.Body_Part)]Skeleton_Body_Part
    count,written:=skeleton_body_rows(bones,map_,&body,&parts)
    testing.expect(t,written && count==17)
    testing.expect_value(t,body.up,[3]f32{0,1,0})
    testing.expect_value(t,body.forward,[3]f32{0,0,-1})
    doc:Document
    if !testing.expect_value(t,skeleton_document(&doc,&types,{id={3,9},bones=bones,body=&body,body_parts=parts[:count]}),Error.None) {return}
    defer document_destroy(&doc)
    bytes:serial.Writer;serial.writer_init(&bytes);defer serial.writer_destroy(&bytes)
    testing.expect_value(t,document_write(&doc,&bytes),Error.None)
    file:Asset
    if !testing.expect_value(t,asset_open(&file,serial.writer_bytes(&bytes)),Error.None) {return}
    defer asset_close(&file)
    view,error:=skeleton_view(&file,&types)
    if !testing.expect_value(t,error,Error.None) {return}
    testing.expect(t,view.body!=nil && view.body^==body && len(view.body_parts)==count)
    testing.expect(t,skeleton_body_map(view.bones,view.body,view.body_parts)==map_)
    for cut in 0..<bytes.count {
        truncated:Asset
        if asset_open(&truncated,serial.writer_bytes(&bytes)[:cut])==.None {skeleton_view(&truncated,&types);asset_close(&truncated)}
    }

    // A part a person set survives detecting again; on other bones it keeps
    // only what still exists.
    map_.bones[.Hand_L]=6;map_.bones[.Elbow_L]=-1;map_.confidence[.Hand_L]=1;map_.manual={.Hand_L}
    count,_=skeleton_body_rows(bones,map_,&body,&parts)
    kept:=skeleton_body_map(bones,&body,parts[:count])
    again,_:=skeleton_body_detect(bones,kept)
    testing.expect(t,again.bones[.Hand_L]==6 && again.manual=={.Hand_L} && again.bones[.Elbow_L]==-1 && again.bones[.Hand_R]==10)
    fewer:=bones[:6]
    testing.expect_value(t,skeleton_body_map(fewer,&body,parts[:count]).bones[.Hand_L],i32(-1))

    // Without a pelvis, legs or arms there is no body to write.
    empty:=anim.body_map_empty()
    _,none:=skeleton_body_rows(bones,empty,&body,&parts);testing.expect(t,!none)
}

@(test)
skeleton_rejects_bodies_that_do_not_fit_its_bones :: proc(t:^testing.T) {
    bones:=skeleton_test_figure()
    map_,_:=skeleton_body_detect(bones,anim.body_map_empty())
    body:Skeleton_Body
    parts:[len(anim.Body_Part)]Skeleton_Body_Part
    count,_:=skeleton_body_rows(bones,map_,&body,&parts)
    info:=Skeleton_Info{u32(len(bones))}
    good:=Skeleton_View{info=&info,bones=bones,body=&body,body_parts=parts[:count]}
    testing.expect(t,skeleton_check(good))
    bad:=good;bad.body=nil;testing.expect(t,!skeleton_check(bad))
    rows:=parts;bad=good;bad.body_parts=rows[:count]
    rows[1].part=rows[0].part;testing.expect(t,!skeleton_check(bad));rows=parts
    rows[1].bone=rows[0].bone;testing.expect(t,!skeleton_check(bad));rows=parts
    text_set(rows[2].bone[:],"missing");testing.expect(t,!skeleton_check(bad));rows=parts
    rows[3].confidence=2;testing.expect(t,!skeleton_check(bad));rows=parts
    rows[4].bone={};testing.expect(t,!skeleton_check(bad));rows[4].manual=true;testing.expect(t,skeleton_check(bad));rows=parts
    testing.expect(t,skeleton_check(bad))
    tilted:=body;tilted.up={0,1,.5};bad=good;bad.body=&tilted;testing.expect(t,!skeleton_check(bad))
    tilted=body;tilted.forward=tilted.up;testing.expect(t,!skeleton_check(bad))
    tilted=body;tilted.confidence=-1;testing.expect(t,!skeleton_check(bad))
}
