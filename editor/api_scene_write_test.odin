package editor

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:cook/author"
import "mirai:core"
import "mirai:editor/history"
import erender "mirai:engine/render"
import "mirai:editor/api"
import "mirai:std/base"
import "mirai:std/serial"

@(private="file")
write_fixture_init :: proc(t:^testing.T,f:^Prefab_Fixture,state:^Api_State,name:string) -> bool {
    if !prefab_fixture_init(t,f,name) {return false}
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
    result,_,failure,ok=write_scene_made(f,raw)
    return
}

// A write with what its result names as made: "name id" of each, in order.
@(private="file")
write_scene_made :: proc(f:^Prefab_Fixture,raw:string) -> (result:Api_Write_Result,created:[]string,failure:string,ok:bool) {
    method:=api.Method{result_id=Api_Write_Result,writes_result=true}
    out:serial.Writer
    serial.writer_init(&out,0,context.temp_allocator)
    call:=api.Call{method=&method,raw=raw,out=&out,allocator=context.temp_allocator}
    api_scene_write(&f.s,&call)
    if call.failed {return {},nil,call.error.message,false}
    text:=string(serial.writer_bytes(&out))
    if shape:=api.result_mismatch(Api_Write_Result,text);shape!="" {return {},nil,shape,false}
    value,error:=json.parse_string(text,parse_integers=true,allocator=context.temp_allocator)
    if error!=nil {return {},nil,text,false}
    answer:=value.(json.Object)
    id,_:=strconv.parse_u64_maybe_prefixed(answer["id"].(json.String))
    result={id=base.Entity_Id(id),made=int(answer["made"].(json.Integer)),removed=int(answer["removed"].(json.Integer)),disabled=int(answer["disabled"].(json.Integer))}
    names:=make([dynamic]string,context.temp_allocator)
    for made in answer["created"].(json.Array) {
        entry:=made.(json.Object)
        append(&names,fmt.tprintf("%s %s",entry["name"].(json.String),entry["id"].(json.String)))
    }
    return result,names[:],"",true
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
    history.edits_reset(&f.edits,w)
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
    testing.expect(t,history.undo(&f.edits,w,&f.selection))
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
    history.edits_reset(&f.edits,w)
    root_id,a_id,b_id,c_id:=api_entity_id(w,root),api_entity_id(w,a),api_entity_id(w,b),api_entity_id(w,c)
    _,created:=prefab_create(s,root,"members")
    if !testing.expect_value(t,created,Prefab_Error.None) {return}
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
    marked,_:=prefab_overrides_of(s,prefab_instance_for(w,api_entity(w,a_id)))
    for override in marked {
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

// A new entity with prefab is the instance a drop of the prefab places, in the
// step of the write, and what the document says of its members is its own.
@(test)
a_write_places_a_prefab_as_a_linked_instance_with_what_the_document_says_of_it :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    state:Api_State
    if !write_fixture_init(t,f,&state,"write-places") {return}
    defer prefab_fixture_destroy(f)
    defer api_schema_free(&state)
    s:=&f.s
    w:=edited_world(s)
    // A prefab Crate with a Lid that holds a Lamp, and a Level to place it under.
    crate:=write_entity(f,"Crate")
    lid:=write_entity(f,"Lid",crate)
    core.add(&f.world.lamps,write_entity(f,"Lamp",lid),Prefab_Test_Lamp{intensity=2,range=3})
    level:=write_entity(f,"Level")
    core.world_settle(w)
    history.edits_reset(&f.edits,w)
    level_id:=api_entity_id(w,level)
    id,created:=prefab_create(s,crate,"crate")
    if !testing.expect_value(t,created,Prefab_Error.None) {return}
    steps,alive:=len(f.edits.steps),core.world_entities(w).alive
    // The lamp of the instance under the first child of Level.
    placed_lamp :: proc(f:^Prefab_Fixture,level:base.Entity_Id) -> (north,lamp:core.Entity) {
        w:=edited_world(&f.s)
        under:=entity_children(w,api_entity(w,level))
        if len(under)==0 {return}
        north=under[0]
        for part in entity_children(w,north) {
            for inner in entity_children(w,part) {lamp=inner}
        }
        return
    }

    document:=fmt.tprintf(`{{"root":"0x%016x","entities":[{{"name":"Level","children":[{{"name":"North","prefab":"crate.scene","position":[4,0,0],"children":[{{"name":"Lid","children":[{{"name":"Lamp","components":{{"Prefab_Test_Lamp":{{"intensity":9}}}}}}]}}]}}]}}]}}`,u64(level_id))
    result,named,failure,ok:=write_scene_made(f,document)
    if !testing.expect(t,ok,failure) {return}
    testing.expect_value(t,result,Api_Write_Result{id=level_id,made=3})
    testing.expect_value(t,len(f.edits.steps),steps+1)
    testing.expect_value(t,core.world_entities(w).alive,alive+3)
    north,lamp:=placed_lamp(f,level_id)
    north_id,lamp_id:=api_entity_id(w,north),api_entity_id(w,lamp)
    testing.expect(t,len(named)==1 && named[0]==fmt.tprintf("North 0x%016x",u64(north_id)),"The result names the instance it placed, by its root")
    link,linked:=prefab_link_of(w,north)
    testing.expect(t,linked && link.root && link.asset==id && entity_name(w,north)=="North")
    testing.expect_value(t,entity_local(w,north).position,[3]f32{4,0,0})
    member,is_member:=prefab_link_of(w,lamp)
    value,_:=core.get(core.read(&f.world.lamps),lamp)
    testing.expect(t,is_member && !member.root && member.instance==link.instance && value.intensity==9,"What the document says of a member, by its name, the member holds")
    testing.expect(t,prefab_test_has(f,north,lamp,"Prefab_Test_Lamp",.Field,"intensity"),"and the instance holds it on its own")
    held,_:=prefab_overrides_of(s,north)
    for override in held {testing.expect(t,override.kind!=.Child,"Nothing was made beside the members")}

    // The document that placed it, and the one inspect gives of it, written again change nothing.
    result,failure,ok=write_scene(f,document)
    testing.expect(t,ok && result==Api_Write_Result{id=level_id} && len(f.edits.steps)==steps+1,failure)
    tree,entities:=write_tree(t,f,level_id)
    placed:=tree["children"].(json.Array)[0].(json.Object)["prefab"].(json.Object)
    testing.expect(t,placed["root"].(json.Boolean) && len(placed["asset"].(json.String))>0)
    result,failure,ok=write_scene(f,fmt.tprintf(`{{"root":"0x%016x","entities":%s}}`,u64(level_id),entities))
    testing.expect(t,ok && result==Api_Write_Result{id=level_id} && len(f.edits.steps)==steps+1,failure)

    // One step: undone, the instance is gone with its link; done again, it is linked as before.
    testing.expect(t,history.undo(&f.edits,w,&f.selection))
    testing.expect_value(t,core.world_entities(w).alive,alive)
    testing.expect_value(t,core.count(&f.world.instances),1)
    testing.expect(t,history.redo(&f.edits,w,&f.selection))
    north,lamp=placed_lamp(f,level_id)
    link,linked=prefab_link_of(w,north)
    testing.expect(t,linked && link.root && api_entity_id(w,north)==north_id && core.count(&f.world.instances)==2)

    // Revert gives the member back what the prefab has.
    reverted,revert_error:=prefab_revert(s,north,nil,true)
    _,lamp=placed_lamp(f,level_id)
    value,_=core.get(core.read(&f.world.lamps),lamp)
    testing.expect(t,revert_error==.None && reverted>0 && value.intensity==2 && value.range==3,fmt.tprintf("%v %d %v",revert_error,reverted,value))

    // Without root the instance goes at the top of the scene, with what the document says of it.
    result,failure,ok=write_scene(f,`{"merge":true,"entities":[{"name":"Alone","prefab":"crate.scene","enabled":false}]}`)
    alone,placed_alone:=prefab_link_of(w,api_entity(w,result.id))
    testing.expect(t,ok && result.made==3 && placed_alone && alone.root && entity_has(w,api_entity(w,result.id),core.Disabled),fmt.tprintf("%s %v %v %v",failure,result,placed_alone,alone))

    // What a write refuses after placing an instance takes the instance back; and a prefab is not placed in a file it holds.
    yard,nested:=prefab_create(s,api_entity(w,level_id),"yard")
    if !testing.expect_value(t,nested,Prefab_Error.None) {return}
    testing.expect(t,prefab_contains(s,yard,id) && !prefab_contains(s,id,yard))
    steps,alive=len(f.edits.steps),core.world_entities(w).alive
    instances,members:=core.count(&f.world.instances),core.count(&f.world.members)
    open_id:=f.document.id
    cases:=[?]struct{document,says:string,inside:bool}{
        {`{"entities":[{"name":"Top","children":[{"name":"South","prefab":"crate.scene"},{"name":"Bad","components":{"Light":{}}}]}]}`,"entities[0].children[1].components.Light",false},
        {`{"entities":[{"name":"In","prefab":"crate.scene"}]}`,"holds the scene it would be placed in",true},
        {`{"entities":[{"name":"In","prefab":"yard.scene"}]}`,"holds the scene it would be placed in",true},
    }
    for c in cases {
        if c.inside {f.document.id=id}
        _,refused,accepted:=write_scene(f,c.document)
        f.document.id=open_id
        testing.expectf(t,!accepted && strings.contains(refused,c.says),"%s: %s",c.says,refused)
        testing.expect_value(t,core.world_entities(w).alive,alive)
        testing.expect_value(t,len(f.edits.steps),steps)
        testing.expect(t,core.count(&f.world.instances)==instances && core.count(&f.world.members)==members,"The instances are those from before")
    }
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
    history.edits_reset(&f.edits,w)
    root_id,other_id:=api_entity_id(w,root),api_entity_id(w,other)
    alive,steps:=core.world_entities(w).alive,len(f.edits.steps)
    at:=fmt.tprintf(`"root":"0x%016x"`,u64(root_id))
    cases:=[?]struct{document,says:string}{
        {fmt.tprintf(`{{%s,"entities":[{{"children":[{{"name":"made"}},{{}},{{"components":{{"Light":{{}}}}}}]}}]}}`,at),`entities[0].children[2].components.Light: "Light" is not a component; the nearest are`},
        {fmt.tprintf(`{{%s,"entities":[{{"children":[{{"name":"made"}},{{"components":{{"Prefab_Test_Lamp":{{"intensty":1}}}}}}]}}]}}`,at),"entities[0].children[1].components.Prefab_Test_Lamp"},
        {fmt.tprintf(`{{%s,"entities":[{{"children":[{{"components":{{"Prefab_Test_Lamp":null}}}}]}}]}}`,at),"entities[0].children[0].components.Prefab_Test_Lamp: the document declares the components"},
        {fmt.tprintf(`{{%s,"entities":[{{"children":[{{"name":"A","off":["Prefab_Test_Lamp"]}}]}}]}}`,at),"entities[0].children[0].off: Prefab_Test_Lamp is not among the components it declares"},
        {fmt.tprintf(`{{%s,"entities":[{{"children":[{{"name":"x","colour":1}}]}}]}}`,at),"entities[0].children[0] has no 'colour'"},
        {fmt.tprintf(`{{%s,"entities":[{{"children":[{{"position":[1,2]}}]}}]}}`,at),"entities[0].children[0].position must be an array of 3 numbers"},
        {fmt.tprintf(`{{%s,"entities":[{{"children":[{{"id":"0x%016x"}}]}}]}}`,at,u64(other_id)),"entities[0].children[0].id: 0x"},
        {fmt.tprintf(`{{%s,"entities":[{{"children":[{{"name":"made","prefab":"nobody.scene"}}]}}]}}`,at),`entities[0].children[0].prefab: "nobody.scene" is no .scene asset`},
        {fmt.tprintf(`{{%s,"entities":[{{"children":[{{"name":"made","prefab":"level.scene"}}]}}]}}`,at),`entities[0].children[0].prefab: "level.scene" is no .scene asset`},
        {fmt.tprintf(`{{%s,"entities":[{{"children":[{{"name":"made","prefab":{{"asset":"nobody.scene","size":2}}}}]}}]}}`,at),"entities[0].children[0].prefab has no 'size'"},
        {fmt.tprintf(`{{%s,"entities":[{{"children":[{{"name":"made","prefab":7}}]}}]}}`,at),"entities[0].children[0].prefab must be the path or the id of a prefab"},
        {fmt.tprintf(`{{%s,"entities":[{{"children":[{{"name":"A","prefab":{{"root":true}}}}]}}]}}`,at),"entities[0].children[0].prefab: it is not what links the entity to a prefab"},
        {fmt.tprintf(`{{%s,"entities":[{{"children":[{{"name":"A","components":{{"Prefab_Instance":{{}}}}}}]}}]}}`,at),"entities[0].children[0].components.Prefab_Instance: Prefab_Instance is what links an entity to its prefab"},
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
    hostile:=[?]struct{document,says:string}{
        {`{"merge":true,"entities":[{"name":"Root","delete":true,"position":[1,2,3]}]}`,"entities[0]: an entity that goes declares nothing else"},
        {`{"merge":true,"entities":[{"copy":"Nobody"}]}`,`entities[0].copy: "Nobody" names no entity`},
        {`{"merge":true,"entities":[{"copy":"Root","preset":"cube"}]}`,"entities[0].copy: a copy is a new entity made from another"},
        {`{"root":"Root","merge":true,"entities":[{"copy":"Other"}]}`,"entities[0].copy: a copy is a new entity; root is the entity that is there"},
        {`{"merge":"yes","entities":[]}`,"merge must be true or false"},
        {`{"root":"Nobody","entities":[{}]}`,`root: "Nobody" names no entity`},
        {`{"root":"Root","entities":[]}`,"entities declares one entity with root"},
        {`{"entities":"all"}`,"entities must be an array"},
        {`{"merge":true}`,"entities is required"},
        {`{"merge":true,"entities":[{"name":"Root","position":[1,2,1e999]}]}`,"entities[0].position must be an array of 3 finite numbers"},
        {`{"merge":true,"entities":[{"name":"Root","off":["Prefab_Test_Lamp"]}]}`,"entities[0].off: Prefab_Test_Lamp is not among the components it has"},
        {`{"merge":true,"entities":[{"name":"Root","children":[{"name":"A","components":{"Prefab_Test_Lamp":{"intensity":"bright"}}}]}]}`,"entities[0].children[0].components.Prefab_Test_Lamp"},
        {"\xff\x00{[",""},
        {`[1,2,3]`,"document must be an object"},
    }
    for c in hostile {
        _,failure,ok:=write_scene(f,c.document)
        testing.expectf(t,!ok && strings.has_prefix(failure,c.says),"%s: %s",c.says,failure)
        testing.expect_value(t,core.world_entities(w).alive,alive)
        testing.expect_value(t,len(f.edits.steps),steps)
    }
    lamp,_:=core.get(core.read(&f.world.lamps),a)
    testing.expect_value(t,lamp.intensity,f32(2))
}

// With merge a document names only what changes: what it leaves out stays,
// delete takes an entity away, null a component, and copy makes an entity
// from another. Each write is one step.
@(test)
a_merge_changes_what_the_document_names_and_leaves_the_rest :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    state:Api_State
    if !write_fixture_init(t,f,&state,"write-merge") {return}
    defer prefab_fixture_destroy(f)
    defer api_schema_free(&state)
    s:=&f.s
    w:=edited_world(s)
    root:=write_entity(f,"Root")
    a:=write_entity(f,"A",root)
    write_entity(f,"B",root)
    write_entity(f,"C",a)
    other:=write_entity(f,"Other")
    core.add(&f.world.lamps,a,Prefab_Test_Lamp{intensity=2,range=3})
    core.world_settle(w)
    history.edits_reset(&f.edits,w)
    a_id:=api_entity_id(w,a)
    lamps,_:=api_component_named(w,"Prefab_Test_Lamp")
    NONE :: [2]f32{-1,-1}
    cases:=[?]struct{document:string,made,removed:int,children,under_a:string,lamp:[2]f32,off:bool,x:f32}{
        // A field of a component, and the rest of it, of the entity and of its siblings stays.
        {`{"root":"Root","merge":true,"entities":[{"children":[{"name":"A","components":{"Prefab_Test_Lamp":{"intensity":5}}}]}]}`,0,0,"A,B","C",{5,3},false,0},
        // A name no sibling has is a new entity; one without a name is too.
        {`{"root":"Root","merge":true,"entities":[{"children":[{"name":"New","position":[1,2,3]},{}]}]}`,2,0,"A,B,New,Group","C",{5,3},false,0},
        // At the top an id names the entity where it is.
        {fmt.tprintf(`{{"merge":true,"entities":[{{"id":"0x%016x","position":[7,0,0]}}]}}`,u64(a_id)),0,0,"A,B,New,Group","C",{5,3},false,7},
        // off turns a component off, and declared without it in off, on again.
        {`{"root":"Root/A","merge":true,"entities":[{"off":["Prefab_Test_Lamp"]}]}`,0,0,"A,B,New,Group","C",{5,3},true,7},
        {`{"root":"Root/A","merge":true,"entities":[{"components":{"Prefab_Test_Lamp":{"range":4}},"off":[]}]}`,0,0,"A,B,New,Group","C",{5,4},false,7},
        // delete takes entities away, and one that is not there is not an error.
        {`{"root":"Root","merge":true,"entities":[{"children":[{"name":"B","delete":true},{"name":"Group","delete":true},{"name":"Nobody","delete":true}]}]}`,0,2,"A,New","C",{5,4},false,7},
        // A copy stays beside what it copies, with what hangs from it, and takes what the document says.
        {`{"merge":true,"entities":[{"copy":"Root/A","name":"A2","position":[9,0,0],"children":[{"name":"C","enabled":false}]}]}`,2,0,"A,New,A2","C",{5,4},false,7},
        // null takes a component away.
        {`{"root":"Root/A","merge":true,"entities":[{"components":{"Prefab_Test_Lamp":null}}]}`,0,0,"A,New,A2","C",NONE,false,7},
        // Without merge the document declares all there is under root.
        {`{"root":"Root","entities":[{"children":[{"name":"A"}]}]}`,0,4,"A","",NONE,false,0},
    }
    for c in cases {
        steps:=len(f.edits.steps)
        result,failure,ok:=write_scene(f,c.document)
        if !testing.expectf(t,ok,"%s: %s",c.document,failure) {continue}
        testing.expectf(t,result.made==c.made && result.removed==c.removed,"%s: %v",c.document,result)
        testing.expectf(t,len(f.edits.steps)==steps+1,"%s is one step",c.document)
        testing.expect_value(t,write_child_names(f,root),c.children)
        testing.expect_value(t,write_child_names(f,a),c.under_a)
        testing.expect(t,entity_alive(w,other) && entity_parent(w,a)==root,"what the document does not name stays where it is")
        lamp:=cast(^Prefab_Test_Lamp)core.raw_find(core.world_table_at(w,lamps),lamps.info,a)
        _,off,_:=core.raw_state(core.world_table_at(w,lamps),a)
        testing.expectf(t,(lamp!=nil?[2]f32{lamp.intensity,lamp.range}:NONE)==c.lamp && off==c.off,"%s: %v off %v",c.document,lamp,off)
        testing.expect_value(t,entity_local(w,a).position.x,c.x)
    }
    // The copy held the lamp and the child of what it copied, off as the document said.
    testing.expect(t,history.undo(&f.edits,w,&f.selection) && history.undo(&f.edits,w,&f.selection))
    for child in entity_children(w,root) {
        if entity_name(w,child)!="A2" {continue}
        lamp,_:=core.get(core.read(&f.world.lamps),child)
        held:=entity_children(w,child)
        testing.expect(t,lamp.intensity==5 && entity_local(w,child).position.x==9 && len(held)==1 && entity_has(w,held[0],core.Disabled))
    }
}

// The same document written to the file with no editor gives the bytes the
// method and a save give. The entities a document makes take their ids from
// the sequence of whoever makes them, so these documents make none.
@(test)
a_document_written_to_a_file_gives_the_bytes_the_method_and_a_save_give :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    state:Api_State
    if !write_fixture_init(t,f,&state,"write-file") {return}
    defer prefab_fixture_destroy(f)
    defer api_schema_free(&state)
    s:=&f.s
    w:=edited_world(s)
    root:=write_entity(f,"Root")
    a:=write_entity(f,"A",root)
    write_entity(f,"B",root)
    write_entity(f,"C",root)
    core.add(&f.world.lamps,a,Prefab_Test_Lamp{intensity=2,range=3})
    core.world_settle(w)
    if !testing.expect_value(t,scene_save(s,"same.scene"),Document_Error.None) {return}
    file:=fmt.tprintf("%s/same.scene",f.root)
    saved,_:=os.read_entire_file(file,context.temp_allocator)
    p:=author.Project{name="same",assets_root=f.root,info=&f.info}
    asset.registry_init(&p.registry,f.root)
    asset.types_init(&p.types)
    defer {asset.registry_destroy(&p.registry);asset.types_destroy(&p.types);author.scratch_world_free(&p.scratch)}
    p.assets={&p.registry,&p.types}
    documents:=[?]string{
        `{"root":"Root","merge":true,"entities":[{"children":[{"name":"A","position":[1,2,3],"components":{"Prefab_Test_Lamp":{"intensity":5}}},{"name":"B","delete":true}]}]}`,
        `{"root":"Root","entities":[{"name":"Yard","children":[{"name":"C","position":[0,1,0]},{"name":"A","components":{"Prefab_Test_Lamp":{"range":9}},"off":["Prefab_Test_Lamp"]}]}]}`,
        `{"merge":true,"entities":[{"name":"Root","children":[{"name":"C","enabled":false}]}]}`,
    }
    for document in documents {
        if !testing.expect_value(t,os.write_entire_file(file,saved),nil) {return}
        if !testing.expect_value(t,scene_open(s,"same.scene"),Document_Error.None) {return}
        _,failure,ok:=write_scene(f,document)
        if !testing.expect(t,ok,failure) || !testing.expect_value(t,scene_save(s),Document_Error.None) {return}
        live,_:=os.read_entire_file(file,context.temp_allocator)
        if !testing.expect_value(t,os.write_entire_file(file,saved),nil) || !testing.expect_value(t,asset.registry_scan(&p.registry),asset.Error.None) {return}
        _,problem:=author.scene_write(&p,"same.scene",document)
        written,_:=os.read_entire_file(file,context.temp_allocator)
        testing.expect(t,problem=="",problem)
        testing.expectf(t,slice.equal(live,written),"%s: the method and a save gave %d bytes, the file write %d",document,len(live),len(written))
    }
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
    history.edits_reset(&f.edits,w)
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
