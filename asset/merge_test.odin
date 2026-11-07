package asset

import "core:testing"
import "mirai:std/base"

@(private="file") A :: base.Entity_Id(0x10)
@(private="file") B :: base.Entity_Id(0x20)
@(private="file") C :: base.Entity_Id(0x30)

@(private="file")
transform :: proc(x,y,z:f32) -> Test_Transform {return {position={x,y,z},rotation=1,scale={1,1,1}}}

// The scene every side starts from: A with a light, B and C under it.
@(private="file")
origin_scene :: proc(t:^testing.T,types:^Types,scene:^Scene) {
    testing.expect_value(t,scene_init(scene,types,KIND_SCENE,{0x61,0x62}),Error.None)
    scene_entity_add(scene,A,0,"A")
    scene_entity_add(scene,B,A,"B")
    scene_entity_add(scene,C,A,"C")
    for id,i in ([]base.Entity_Id{A,B,C}) {
        value:=transform(f32(i),0,0)
        scene_set(scene,id,"Transform",&value)
    }
    light:=Test_Light{{1,1,1},3,10}
    scene_set(scene,A,"Light",&light)
    scene_set(scene,C,"Light",&light)
}

// A copy of a scene, as a file read again would give it.
@(private="file")
scene_copy :: proc(t:^testing.T,types:^Types,from:^Scene,to:^Scene) {
    data,error:=scene_bytes(from)
    testing.expect_value(t,error,Error.None)
    defer delete(data)
    testing.expect_value(t,scene_read(to,types,data),Error.None)
}

@(private="file")
scene_document :: proc(t:^testing.T,scene:^Scene) -> (doc:Document) {
    data,error:=scene_bytes(scene)
    testing.expect_value(t,error,Error.None)
    defer delete(data)
    testing.expect_value(t,document_read(&doc,data),Error.None)
    return
}

// Merges ours and theirs against base and reads the result as a scene.
@(private="file")
merged_scene :: proc(t:^testing.T,types:^Types,origin,ours,theirs:^Scene,merged:^Scene,m:^Merge) {
    a,b,c:=scene_document(t,ours),scene_document(t,origin),scene_document(t,theirs)
    defer {document_destroy(&b);document_destroy(&c)}
    testing.expect_value(t,scene_merge(m,types,&a,&b,&c),Error.None)
    testing.expect_value(t,scene_from_document(merged,types,&a),Error.None)
}

@(test)
merge_keeps_what_each_side_changed_in_other_fields :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    origin,ours,theirs,merged:Scene
    origin_scene(t,&types,&origin);defer scene_destroy(&origin)
    scene_copy(t,&types,&origin,&ours);defer scene_destroy(&ours)
    scene_copy(t,&types,&origin,&theirs);defer scene_destroy(&theirs)
    moved:=transform(5,0,0)
    scene_set(&ours,A,"Transform",&moved)
    scaled:=transform(0,0,0);scaled.scale={2,2,2}
    scene_set(&theirs,A,"Transform",&scaled)
    brighter:=Test_Light{{1,1,1},7,10}
    scene_set(&theirs,A,"Light",&brighter)
    scene_entity_rename(&theirs,B,"Bee")

    m:Merge;defer merge_destroy(&m)
    merged_scene(t,&types,&origin,&ours,&theirs,&merged,&m);defer scene_destroy(&merged)
    testing.expect_value(t,len(m.conflicts),0)
    got,_:=scene_get(&merged,A,"Transform",Test_Transform)
    testing.expect(t,got.position==[3]f32{5,0,0} && got.scale==[3]f32{2,2,2})
    light,_:=scene_get(&merged,A,"Light",Test_Light)
    testing.expect_value(t,light.intensity,7)
    row,_:=scene_entity_find(&merged,B)
    testing.expect_value(t,scene_entity(&merged,row).name,"Bee")
}

@(test)
merge_lists_a_value_both_sides_changed_and_keeps_ours :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    origin,ours,theirs,merged:Scene
    origin_scene(t,&types,&origin);defer scene_destroy(&origin)
    scene_copy(t,&types,&origin,&ours);defer scene_destroy(&ours)
    scene_copy(t,&types,&origin,&theirs);defer scene_destroy(&theirs)
    mine,yours:=transform(1,0,0),transform(2,0,0)
    scene_set(&ours,A,"Transform",&mine)
    scene_set(&theirs,A,"Transform",&yours)

    m:Merge;defer merge_destroy(&m)
    merged_scene(t,&types,&origin,&ours,&theirs,&merged,&m);defer scene_destroy(&merged)
    testing.expect_value(t,len(m.conflicts),1)
    conflict:=m.conflicts[0]
    testing.expect_value(t,conflict.kind,Merge_Kind.Value)
    testing.expect_value(t,conflict.path,"Transform[@0x0000000000000010].value.position")
    testing.expect_value(t,conflict.table,"Transform")
    testing.expect_value(t,conflict.key,u64(A))
    got,_:=scene_get(&merged,A,"Transform",Test_Transform)
    testing.expect(t,got.position==[3]f32{1,0,0})
}

@(test)
merge_removes_what_one_side_removed_unless_the_other_changed_it :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    origin,ours,theirs,merged:Scene
    origin_scene(t,&types,&origin);defer scene_destroy(&origin)
    scene_copy(t,&types,&origin,&ours);defer scene_destroy(&ours)
    scene_copy(t,&types,&origin,&theirs);defer scene_destroy(&theirs)
    scene_entities_remove(&theirs,{B,C})
    dimmer:=Test_Light{{1,1,1},1,10}
    scene_set(&ours,C,"Light",&dimmer)

    m:Merge;defer merge_destroy(&m)
    merged_scene(t,&types,&origin,&ours,&theirs,&merged,&m);defer scene_destroy(&merged)
    _,has_b:=scene_entity_find(&merged,B)
    _,has_c:=scene_entity_find(&merged,C)
    testing.expect(t,!has_b && has_c)
    light,_:=scene_get(&merged,C,"Light",Test_Light)
    testing.expect_value(t,light.intensity,1)
    // C comes back whole: its transform too, which ours did not change.
    _,has_transform:=scene_get(&merged,C,"Transform",Test_Transform)
    testing.expect(t,has_transform)
    removed:=0
    for conflict in m.conflicts {
        if conflict.kind==.Removed && conflict.key==u64(C) && conflict.ours && !conflict.theirs {removed+=1}
    }
    testing.expect(t,removed>0)
}

@(test)
merge_keeps_entities_both_sides_added_and_drops_what_hung_from_a_removed_one :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    origin,ours,theirs,merged:Scene
    origin_scene(t,&types,&origin);defer scene_destroy(&origin)
    scene_copy(t,&types,&origin,&ours);defer scene_destroy(&ours)
    scene_copy(t,&types,&origin,&theirs);defer scene_destroy(&theirs)
    D,E,F:=base.Entity_Id(0x40),base.Entity_Id(0x50),base.Entity_Id(0x60)
    scene_entity_add(&ours,D,0,"D")
    placed:=transform(9,9,9)
    scene_set(&ours,D,"Transform",&placed)
    scene_entity_add(&theirs,E,A,"E")
    scene_set(&theirs,E,"Transform",&placed)
    // Ours removes B; theirs gives B a light and a child.
    scene_entities_remove(&ours,{B})
    light:=Test_Light{{0,1,0},2,5}
    scene_set(&theirs,B,"Light",&light)
    scene_entity_add(&theirs,F,B,"F")

    m:Merge;defer merge_destroy(&m)
    merged_scene(t,&types,&origin,&ours,&theirs,&merged,&m);defer scene_destroy(&merged)
    _,has_d:=scene_entity_find(&merged,D)
    _,has_e:=scene_entity_find(&merged,E)
    _,has_b:=scene_entity_find(&merged,B)
    row_f,has_f:=scene_entity_find(&merged,F)
    testing.expect(t,has_d && has_e && !has_b && has_f)
    testing.expect_value(t,scene_entity(&merged,row_f).parent,base.Entity_Id(0))
    e,_:=scene_get(&merged,E,"Transform",Test_Transform)
    testing.expect(t,e==placed)
    for conflict in m.conflicts {testing.expect(t,conflict.kind==.Removed)}
    testing.expect(t,len(m.conflicts)>=2)
}

@(test)
merge_gives_instances_both_sides_placed_their_own_ids :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    origin,ours,theirs,merged:Scene
    origin_scene(t,&types,&origin);defer scene_destroy(&origin)
    scene_copy(t,&types,&origin,&ours);defer scene_destroy(&ours)
    scene_copy(t,&types,&origin,&theirs);defer scene_destroy(&theirs)
    R1,R2:=base.Entity_Id(0x71),base.Entity_Id(0x72)
    scene_entity_add(&ours,R1,0,"Lamp")
    append(&ours.instances,Instance{id=1,prefab={1,1},root=R1})
    append(&ours.members,Member{instance=1,source=0x1,entity=R1})
    scene_entity_add(&theirs,R2,0,"Tree")
    append(&theirs.instances,Instance{id=1,prefab={2,2},root=R2})
    append(&theirs.members,Member{instance=1,source=0x1,entity=R2})

    m:Merge;defer merge_destroy(&m)
    merged_scene(t,&types,&origin,&ours,&theirs,&merged,&m);defer scene_destroy(&merged)
    testing.expect_value(t,len(m.conflicts),0)
    testing.expect_value(t,len(merged.instances),2)
    ids:[2]u32
    for instance in merged.instances {
        if instance.root==R1 {ids[0]=instance.id} else {ids[1]=instance.id}
    }
    testing.expect(t,ids[0]==1 && ids[1]==2)
    for member in merged.members {
        if member.entity==R2 {testing.expect_value(t,member.instance,u32(2))}
        if member.entity==R1 {testing.expect_value(t,member.instance,u32(1))}
    }
}

@(private="file") Test_Shade :: struct {roughness:f32,metallic:f32,tint:[3]f32}

@(test)
merge_of_a_document_of_one_row_takes_fields_from_each_side :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    build :: proc(t:^testing.T,types:^Types,value:Test_Shade,texels:[]u32) -> (doc:Document) {
        document_init(&doc,KIND_MATERIAL,{0x81,0x82})
        shade:=value
        _,error:=document_put_row(&doc,types,"shade",&shade)
        testing.expect_value(t,error,Error.None)
        _,error=document_put(&doc,types,"texels",texels,{.Bulk})
        testing.expect_value(t,error,Error.None)
        return
    }
    first:=[]u32{1,2,3}
    origin:=build(t,&types,{0.8,0,{1,1,1}},first);defer document_destroy(&origin)
    ours:=build(t,&types,{0.5,0,{1,1,1}},[]u32{1,2,4});defer document_destroy(&ours)
    theirs:=build(t,&types,{0.8,1,{1,1,1}},[]u32{1,2,5});defer document_destroy(&theirs)
    m:Merge;defer merge_destroy(&m)
    testing.expect_value(t,document_merge(&m,&ours,&origin,&theirs),Error.None)
    rows:=make([dynamic]Test_Shade);defer delete(rows)
    testing.expect_value(t,document_rows(&ours,&types,"shade",&rows),Error.None)
    testing.expect(t,len(rows)==1 && rows[0].roughness==0.5 && rows[0].metallic==1)
    testing.expect_value(t,len(m.conflicts),1)
    testing.expect_value(t,m.conflicts[0].kind,Merge_Kind.Table)
    testing.expect_value(t,m.conflicts[0].path,"texels")
}

@(private="file") Test_Shade_Glow :: struct {roughness:f32,metallic:f32,tint:[3]f32,glow:f32}

// A field only theirs added (its type grew since base) is kept with what theirs gave it, and what
// ours changed in the other fields stays.
@(test)
merge_keeps_a_field_only_theirs_added :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    build :: proc(t:^testing.T,types:^Types,value:$T) -> (doc:Document) {
        document_init(&doc,KIND_MATERIAL,{0x81,0x82})
        row:=value
        _,error:=document_put_row(&doc,types,"shade",&row)
        testing.expect_value(t,error,Error.None)
        return
    }
    origin:=build(t,&types,Test_Shade{0.8,0,{1,1,1}});defer document_destroy(&origin)
    ours:=build(t,&types,Test_Shade{0.5,0,{1,1,1}});defer document_destroy(&ours)
    theirs:=build(t,&types,Test_Shade_Glow{0.8,0,{1,1,1},2});defer document_destroy(&theirs)
    m:Merge;defer merge_destroy(&m)
    testing.expect_value(t,document_merge(&m,&ours,&origin,&theirs),Error.None)
    rows:=make([dynamic]Test_Shade_Glow);defer delete(rows)
    testing.expect_value(t,document_rows(&ours,&types,"shade",&rows),Error.None)
    testing.expectf(t,len(rows)==1 && rows[0].roughness==0.5 && rows[0].glow==2,"ours' change and theirs' field: %v",rows)
    testing.expect_value(t,len(m.conflicts),0)
}
