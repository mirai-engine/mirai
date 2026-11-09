package editor

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:editor/api"
import "mirai:std/base"
import "mirai:std/serial"

@(private="file")
write_fixture_init :: proc(t:^testing.T,f:^Prefab_Fixture,state:^Api_State,name:string) -> bool {
    if !testing.expect(t,prefab_fixture_init(f,name)) {return false}
    for &storage in f.storages {
        if storage.info==nil {storage.info=type_info_of(storage.type)}
    }
    f.api.state=state
    api_schema_build(&f.s,state)
    return true
}

// An entity made as the editor makes one, after the siblings it has.
@(private="file")
write_entity :: proc(f:^Prefab_Fixture,name:string,parent:=core.NONE) -> core.Entity {
    e:=entity_create(&f.s,{name=name,named=true,parent=parent})
    core.world_settle(edited_world(&f.s))
    return e
}

@(private="file")
write_scene :: proc(f:^Prefab_Fixture,raw:string) -> (result:Api_Write_Result,failure:string,ok:bool) {
    method:=api.Method{result_id=Api_Write_Result}
    call:=api.Call{method=&method,result=&result,raw=raw,allocator=context.temp_allocator}
    api_scene_write(&f.s,&call)
    prefabs_follow(&f.s,&f.prefabs)
    return result,call.error.message,!call.failed
}

// The document scene.inspect gives of root, and the entities in it as text.
@(private="file")
write_tree :: proc(t:^testing.T,f:^Prefab_Fixture,root:base.Entity_Id,components:=true) -> (tree:json.Object,entities:string) {
    params:=Api_Inspect_Params{limit=API_INSPECT_DEFAULT}
    copy(params.root[:],fmt.tprintf("0x%016x",u64(root)))
    method:=api.Method{params_id=Api_Inspect_Params}
    out:serial.Writer
    serial.writer_init(&out,0,context.temp_allocator)
    call:=api.Call{method=&method,raw=components?"{}":`{"components":[]}`,params=&params,out=&out,allocator=context.temp_allocator}
    api_scene_inspect(&f.s,&call)
    if !testing.expect(t,!call.failed,call.error.message) {return}
    text:=string(serial.writer_bytes(&out))
    api_result_shape_expect(t,text,Api_Inspect_Result)
    value,error:=json.parse_string(text,allocator=context.temp_allocator)
    if error!=nil {return}
    start:=strings.index(text,`"entities":`)+len(`"entities":`)
    tree=value.(json.Object)["entities"].(json.Array)[0].(json.Object)
    return tree,text[start:strings.last_index(text,`,"shown":`)]
}

@(private="file")
write_names :: proc(tree:json.Object) -> string {
    names:=make([dynamic]string,context.temp_allocator)
    for child in tree["children"].(json.Array) {append(&names,child.(json.Object)["name"].(json.String))}
    return strings.join(names[:],",",context.temp_allocator)
}

@(private="file")
write_child_names :: proc(f:^Prefab_Fixture,e:core.Entity) -> string {
    w:=edited_world(&f.s)
    names:=make([dynamic]string,context.temp_allocator)
    for child in entity_children(w,e) {append(&names,entity_name(w,child))}
    return strings.join(names[:],",",context.temp_allocator)
}

@(test)
a_write_matches_by_id_name_and_place_and_inspect_gives_back_what_it_wrote :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    state:Api_State
    if !write_fixture_init(t,f,&state,"write-match") {return}
    defer prefab_fixture_destroy(f)
    defer api_schema_free(&state)
    s:=&f.s
    w:=edited_world(s)
    root:=write_entity(f,"Root")
    a:=write_entity(f,"A",root)
    b:=write_entity(f,"B",root)
    c:=write_entity(f,"C",root)
    d:=write_entity(f,"D",root)
    write_entity(f,"E",d)
    core.add(&f.world.lamps,a,Prefab_Test_Lamp{intensity=2,range=3,uses=7})
    core.add(&f.world.lamps,c,Prefab_Test_Lamp{intensity=1})
    core.world_settle(w)
    edits_reset(&f.edits,w)
    ids:=[4]base.Entity_Id{api_entity_id(w,root),api_entity_id(w,a),api_entity_id(w,b),api_entity_id(w,c)}
    d_id:=api_entity_id(w,d)
    steps:=len(f.edits.steps)

    // B by name, A by id with another name, C by place; New and Leaf are made, D and E go.
    document:=fmt.tprintf(`{{"root":"0x%016x","entities":[{{"name":"Root","children":[{{"name":"B","position":[1,0,0]}},{{"id":"0x%016x","name":"A2","components":{{"Prefab_Test_Lamp":{{"intensity":5}}}}}},{{}},{{"name":"New","children":[{{"name":"Leaf"}}]}}]}}]}}`,u64(ids[0]),u64(ids[1]))
    result,failure,ok:=write_scene(f,document)
    if !testing.expect(t,ok,failure) {return}
    testing.expect_value(t,result,Api_Write_Result{id=ids[0],made=2,removed=2})
    testing.expect_value(t,len(f.edits.steps),steps+1)
    for id in ids {testing.expect(t,api_entity(w,id)!=core.NONE)}
    testing.expect(t,api_entity(w,d_id)==core.NONE)
    testing.expect_value(t,write_child_names(f,root),"B,A2,C,New")
    lamp,_:=core.get(core.read(&f.world.lamps),a)
    testing.expect_value(t,lamp,Prefab_Test_Lamp{intensity=5,uses=7})
    testing.expect(t,!core.has(core.read(&f.world.lamps),c))

    tree,entities:=write_tree(t,f,ids[0])
    testing.expect_value(t,write_names(tree),"B,A2,C,New")
    children:=tree["children"].(json.Array)
    testing.expect_value(t,len(children[0].(json.Object)["position"].(json.Array)),3)
    lamp_fields:=children[1].(json.Object)["components"].(json.Object)["Prefab_Test_Lamp"].(json.Object)
    testing.expect(t,len(lamp_fields)==1 && lamp_fields["intensity"].(json.Float)==5,"Only the fields that differ from the value a component starts with")
    testing.expect(t,"components" not_in children[2].(json.Object))
    testing.expect_value(t,write_names(children[3].(json.Object)),"Leaf")
    shape,_:=write_tree(t,f,ids[0],components=false)
    testing.expect(t,write_names(shape)=="B,A2,C,New" && "components" not_in shape["children"].(json.Array)[1].(json.Object),"Without components only the shape of the tree")

    // What inspect gives, written back, changes nothing.
    result,failure,ok=write_scene(f,fmt.tprintf(`{{"root":"0x%016x","entities":%s}}`,u64(ids[0]),entities))
    testing.expect(t,ok,failure)
    testing.expect_value(t,result,Api_Write_Result{id=ids[0]})
    testing.expect_value(t,len(f.edits.steps),steps+1)

    // One step: undone, the subtree is what it was.
    testing.expect(t,undo(&f.edits,w,&f.selection))
    core.world_settle(w)
    testing.expect_value(t,write_child_names(f,root),"A,B,C,D")
    testing.expect(t,core.has(core.read(&f.world.lamps),api_entity(w,ids[3])))

    // Without root the document makes a new root.
    result,failure,ok=write_scene(f,`{"entities":[{"name":"Level","children":[{"name":"Floor","scale":[10,1,10]}]}]}`)
    testing.expect(t,ok,failure)
    testing.expect_value(t,result.made,2)
    level:=api_entity(w,result.id)
    testing.expect(t,level!=core.NONE && entity_parent(w,level)==core.NONE && write_child_names(f,level)=="Floor")
}

@(test)
a_write_turns_off_the_members_of_an_instance_it_leaves_out_and_keeps_their_place :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    state:Api_State
    if !write_fixture_init(t,f,&state,"write-members") {return}
    defer prefab_fixture_destroy(f)
    defer api_schema_free(&state)
    s:=&f.s
    w:=edited_world(s)
    // Root with A (holding C) and B, a prefab and its first instance.
    root:=write_entity(f,"Root")
    a:=write_entity(f,"A",root)
    b:=write_entity(f,"B",root)
    c:=write_entity(f,"C",a)
    core.world_settle(w)
    edits_reset(&f.edits,w)
    prefabs_follow(s,&f.prefabs)
    root_id,a_id,b_id,c_id:=api_entity_id(w,root),api_entity_id(w,a),api_entity_id(w,b),api_entity_id(w,c)
    _,created:=prefab_create(s,root,"members")
    if !testing.expect_value(t,created,Prefab_Error.None) {return}
    prefabs_follow(s,&f.prefabs)
    steps:=len(f.edits.steps)

    _,failure,ok:=write_scene(f,fmt.tprintf(`{{"root":"0x%016x","entities":[{{"name":"Root","children":[{{"id":"0x%016x"}},{{"id":"0x%016x"}},{{"id":"0x%016x"}}]}}]}}`,u64(root_id),u64(a_id),u64(c_id),u64(b_id)))
    testing.expect(t,!ok && strings.has_prefix(failure,"entities[0].children[1]: C is a member of an instance of a prefab and keeps the place"),failure)
    testing.expect_value(t,len(f.edits.steps),steps)
    testing.expect(t,entity_parent(w,api_entity(w,c_id))==api_entity(w,a_id))

    result,write_failure,written:=write_scene(f,fmt.tprintf(`{{"root":"0x%016x","entities":[{{"name":"Root","children":[{{"name":"A","children":[{{"name":"Added"}}]}}]}}]}}`,u64(root_id)))
    if !testing.expect(t,written,write_failure) {return}
    testing.expect_value(t,result,Api_Write_Result{id=root_id,made=1,disabled=2})
    for id in ([]base.Entity_Id{b_id,c_id}) {
        e:=api_entity(w,id)
        testing.expect(t,e!=core.NONE && entity_has(w,e,core.Disabled))
    }
    testing.expect(t,entity_parent(w,api_entity(w,c_id))==api_entity(w,a_id))
    added,child:=0,0
    for override in f.document.previous.overrides {
        if override.kind==.Added {added+=1} else if override.kind==.Child {child+=1}
    }
    testing.expect(t,added==2 && child==1,"The members are off, and what the write made under A is the instance's own")

    // The document of the instance, written back, changes nothing.
    tree,entities:=write_tree(t,f,root_id)
    testing.expect_value(t,write_names(tree),"A,B")
    result,write_failure,written=write_scene(f,fmt.tprintf(`{{"root":"0x%016x","entities":%s}}`,u64(root_id),entities))
    testing.expect(t,written,write_failure)
    testing.expect_value(t,result,Api_Write_Result{id=root_id})
    testing.expect_value(t,len(f.edits.steps),steps+1)
}

@(test)
a_write_that_fails_says_where_in_the_document_and_changes_nothing :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    state:Api_State
    if !write_fixture_init(t,f,&state,"write-fails") {return}
    defer prefab_fixture_destroy(f)
    defer api_schema_free(&state)
    s:=&f.s
    w:=edited_world(s)
    root:=write_entity(f,"Root")
    a:=write_entity(f,"A",root)
    write_entity(f,"B",root)
    other:=write_entity(f,"Other")
    core.add(&f.world.lamps,a,Prefab_Test_Lamp{intensity=2})
    core.world_settle(w)
    edits_reset(&f.edits,w)
    root_id,other_id:=api_entity_id(w,root),api_entity_id(w,other)
    alive,steps:=core.world_entities(w).alive,len(f.edits.steps)
    at:=fmt.tprintf(`"root":"0x%016x"`,u64(root_id))
    cases:=[?]struct{document,says:string}{
        {fmt.tprintf(`{{%s,"entities":[{{"children":[{{"name":"made"}},{{}},{{"components":{{"Light":{{}}}}}}]}}]}}`,at),`entities[0].children[2].components.Light: "Light" is not a component of the world`},
        {fmt.tprintf(`{{%s,"entities":[{{"children":[{{"name":"made"}},{{"components":{{"Prefab_Test_Lamp":{{"intensty":1}}}}}}]}}]}}`,at),"entities[0].children[1].components.Prefab_Test_Lamp"},
        {fmt.tprintf(`{{%s,"entities":[{{"children":[{{"components":{{"Prefab_Test_Lamp":null}}}}]}}]}}`,at),"entities[0].children[0].components.Prefab_Test_Lamp: the document declares the components"},
        {fmt.tprintf(`{{%s,"entities":[{{"children":[{{"name":"A","off":["Prefab_Test_Lamp"]}}]}}]}}`,at),"entities[0].children[0].off: Prefab_Test_Lamp is not among the components it declares"},
        {fmt.tprintf(`{{%s,"entities":[{{"children":[{{"name":"x","colour":1}}]}}]}}`,at),"entities[0].children[0] has no 'colour'"},
        {fmt.tprintf(`{{%s,"entities":[{{"children":[{{"position":[1,2]}}]}}]}}`,at),"entities[0].children[0]: position must be an array of 3 numbers"},
        {fmt.tprintf(`{{%s,"entities":[{{"children":[{{"id":"0x%016x"}}]}}]}}`,at,u64(other_id)),"entities[0].children[0].id: 0x"},
        {fmt.tprintf(`{{%s,"entities":[{{"children":[{{"name":"made","prefab":{{"asset":"0"}}}}]}}]}}`,at),"entities[0].children[0].prefab: scene.write places no prefab"},
        {fmt.tprintf(`{{%s,"entities":[{{"children":[{{"id":"0x%016x"}},{{"id":"0x%016x"}}]}}]}}`,at,u64(root_id)+1,u64(root_id)+1),"entities[0].children[1].id: 0x"},
        {fmt.tprintf(`{{%s,"entities":[{{"name":"Root"}},{{"name":"Two"}}]}}`,at),"entities declares one entity"},
    }
    for c in cases {
        _,failure,ok:=write_scene(f,c.document)
        testing.expectf(t,!ok && strings.has_prefix(failure,c.says),"%s: %s",c.says,failure)
        testing.expect_value(t,core.world_entities(w).alive,alive)
        testing.expect_value(t,len(f.edits.steps),steps)
        testing.expect_value(t,write_child_names(f,root),"A,B")
    }
    lamp,_:=core.get(core.read(&f.world.lamps),a)
    testing.expect_value(t,lamp.intensity,f32(2))
}

@(test)
a_preset_gives_an_entity_of_a_write_the_components_and_place_it_leaves_out :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    state:Api_State
    if !write_fixture_init(t,f,&state,"write-presets") {return}
    defer prefab_fixture_destroy(f)
    defer api_schema_free(&state)
    w:=edited_world(&f.s)
    root:=write_entity(f,"Root")
    edits_reset(&f.edits,w)
    root_id:=api_entity_id(w,root)
    light :: proc(f:^Prefab_Fixture,root:core.Entity,name:string) -> (value:erender.Point_Light,e:core.Entity) {
        w:=edited_world(&f.s)
        for child in entity_children(w,root) {
            if entity_name(w,child)==name {e=child}
        }
        value,_=core.get(core.read(&f.world.point_lights),e)
        return
    }
    document :: proc(root:base.Entity_Id,plain:string) -> string {
        return fmt.tprintf(`{{"root":"0x%016x","entities":[{{"name":"Root","children":[{{"name":"Red","preset":"point_light","position":[0,3,0],"components":{{"Point_Light":{{"color":[1,0,0]}}}}}},{{"name":"Plain","preset":"point_light"%s}},{{"name":"Sun","preset":"sun"}}]}}]}}`,u64(root),plain)
    }
    result,failure,ok:=write_scene(f,document(root_id,""))
    if !testing.expect(t,ok,failure) {return}
    testing.expect_value(t,result.made,3)
    red,_:=light(f,root,"Red")
    plain,_:=light(f,root,"Plain")
    want:=erender.POINT_LIGHT_DEFAULT
    want.color={1,0,0}
    testing.expect_value(t,red,want)
    testing.expect_value(t,plain,erender.POINT_LIGHT_DEFAULT)
    _,sun:=light(f,root,"Sun")
    testing.expect_value(t,entity_local(w,sun).rotation,preset_rotation(.Sun))
    testing.expect_value(t,core.world_entities(w).alive,4)
    steps:=len(f.edits.steps)
    result,failure,ok=write_scene(f,document(root_id,""))
    testing.expect(t,ok && result.made==0 && len(f.edits.steps)==steps,"The same document again changes nothing")

    // A field the document names goes over the preset, and named again the preset gives it back.
    _,failure,ok=write_scene(f,document(root_id,`,"components":{"Point_Light":{"intensity":5}}`))
    plain,_=light(f,root,"Plain")
    testing.expect(t,ok && plain.intensity==5 && plain.color==erender.POINT_LIGHT_DEFAULT.color,failure)
    _,failure,ok=write_scene(f,document(root_id,""))
    plain,_=light(f,root,"Plain")
    testing.expect(t,ok && plain==erender.POINT_LIGHT_DEFAULT,failure)

    _,failure,ok=write_scene(f,fmt.tprintf(`{{"root":"0x%016x","entities":[{{"children":[{{"name":"X","preset":"nope"}}]}}]}}`,u64(root_id)))
    testing.expect(t,!ok && strings.has_prefix(failure,"entities[0].children[0].preset: "),failure)
    testing.expect_value(t,core.world_entities(w).alive,4)
}
