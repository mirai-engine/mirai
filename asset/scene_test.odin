package asset

import "base:runtime"
import "core:mem"
import "core:os"
import "core:testing"
import "mirai:std/base"
import "mirai:std/serial"

@(private) Test_Transform :: struct {position:[3]f32,rotation:quaternion128,scale:[3]f32}
@(private) Test_Light :: struct {color:[3]f32,intensity:f32,range:f32}
@(private) Test_Follow :: struct {target:base.Entity,anchor:base.Entity_Id,offset:[3]f32}
@(private) Test_Mesh :: struct {mesh:base.Asset_Id,material:base.Asset_Id}
@(private) Test_Tag :: struct {}

@(private="file") LIGHT :: "Light"
@(private="file") light_hash :: proc() -> u64 {return base.name_hash(LIGHT)}

@(private="file")
transform :: proc(x,y,z:f32) -> Test_Transform {return {position={x,y,z},rotation=1,scale={1,1,1}}}

@(test)
scene_builder_names_components_by_type_and_stops_at_the_first_error :: proc(t:^testing.T) {
    content:Content;content_init(&content,"builder_test");defer content_destroy(&content)
    testing.expect(t,content_id("builder_test","mesh","a")!=content_id("other","mesh","a"))

    b:Scene_Builder;builder_init(&b,&content,KIND_PREFAB,{0x61,0x62});defer builder_destroy(&b)
    root:=builder_entity(&b,"Root",{position={1,2,3}})
    child:=builder_entity(&b,"Child",{scale={2,2,2}},root)
    builder_set(&b,child,Test_Light{{1,1,1},3,10})
    testing.expect(t,b.scene.info.root==root && !b.failed && !content.failed)
    placed,found:=scene_get(&b.scene,root,"Transform",Test_Transform)
    testing.expect(t,found && placed==transform(1,2,3))
    scaled,_:=scene_get(&b.scene,child,"Transform",Test_Transform)
    testing.expect(t,scaled.rotation==1 && scaled.scale=={2,2,2})
    light,lit:=scene_get(&b.scene,child,"Test_Light",Test_Light)
    testing.expect(t,lit && light.intensity==3)

    testing.expect_value(t,builder_entity(&b,"Second root"),base.Entity_Id(0))
    testing.expect(t,b.failed && content.failed)
    builder_set(&b,child,Test_Mesh{})
    _,set_after:=scene_get(&b.scene,child,"Test_Mesh",Test_Mesh)
    testing.expect(t,!set_after)

    invalid:Scene_Builder;builder_init(&invalid,&content,KIND_MATERIAL,{1,1});defer builder_destroy(&invalid)
    testing.expect(t,invalid.failed)
    testing.expect_value(t,builder_entity(&invalid,"Nothing"),base.Entity_Id(0))
}

@(test)
scene_builds_saves_and_loads_entities_and_components :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    scene:Scene
    testing.expect_value(t,scene_init(&scene,&types,KIND_SCENE,{0x51,0x52}),Error.None)
    defer scene_destroy(&scene)
    root,child,other:=base.Entity_Id(0x10),base.Entity_Id(0x20),base.Entity_Id(0x30)
    scene_entity_add(&scene,root,0,"Root")
    scene_entity_add(&scene,child,root,"Child")
    scene_entity_add(&scene,other,root,"Other")
    testing.expect_value(t,scene_entity(&scene,2),Entity_Record{other,root,1,"Other"})
    for id,i in ([]base.Entity_Id{root,child,other}) {
        value:=transform(f32(i),0,0)
        testing.expect_value(t,scene_set(&scene,id,"Transform",&value),Error.None)
    }
    light:=Test_Light{{1,0.5,0.25},3,10}
    scene_set(&scene,other,LIGHT,&light)
    follow:=Test_Follow{target=base.Entity(child),anchor=root,offset={0,1,0}}
    scene_set(&scene,child,"Follow",&follow)
    mesh:=Test_Mesh{{7,7},{8,8}}
    scene_set(&scene,child,"Mesh",&mesh)
    scene_set(&scene,root,"Mesh",&mesh)
    tag:Test_Tag
    scene_set(&scene,other,"Tag",&tag)
    scene_set(&scene,root,"Tag",&tag)

    got,found:=scene_get(&scene,other,LIGHT,Test_Light)
    testing.expect(t,found && got==light)
    _,missing:=scene_get(&scene,root,LIGHT,Test_Light)
    testing.expect(t,!missing)
    _,unknown:=scene_get(&scene,root,"Nothing",Test_Light)
    testing.expect(t,!unknown)
    mesh_table,_:=scene_component(&scene,"Mesh")
    testing.expect_value(t,scene.doc.tables[mesh_table].rows,2)
    rows:=mem.slice_data_cast([]u32,scene.doc.tables[mesh_table].columns[0].data)
    testing.expect(t,rows[0]==0 && rows[1]==1) // kept in the order of the entity table
    tags,_:=scene_component(&scene,"Tag")
    testing.expect(t,scene.doc.tables[tags].rows==2 && scene.doc.tables[tags].columns[1].size==0)

    path:=test_path("level.scene")
    defer os.remove(path)
    testing.expect_value(t,scene_save(&scene,path),Error.None)
    loaded:Scene
    testing.expect_value(t,scene_load(&loaded,&types,path),Error.None)
    defer scene_destroy(&loaded)
    testing.expect_value(t,scene_entity_count(&loaded),3)
    for row in 0..<3 {testing.expect_value(t,scene_entity(&loaded,row),scene_entity(&scene,row))}
    back,back_found:=scene_get(&loaded,child,"Follow",Test_Follow)
    testing.expect(t,back_found && back==follow)
    position,_:=scene_get(&loaded,other,"Transform",Test_Transform)
    testing.expect(t,position==transform(2,0,0))
    _,has_tag:=scene_get(&loaded,other,"Tag",Test_Tag)
    _,no_tag:=scene_get(&loaded,child,"Tag",Test_Tag)
    testing.expect(t,has_tag && !no_tag)

    // Saving what was loaded gives the same file.
    first,second:serial.Writer
    serial.writer_init(&first);defer serial.writer_destroy(&first)
    serial.writer_init(&second);defer serial.writer_destroy(&second)
    testing.expect_value(t,scene_write(&scene,&first),Error.None)
    testing.expect_value(t,scene_write(&loaded,&second),Error.None)
    testing.expect(t,mem.compare(serial.writer_bytes(&first),serial.writer_bytes(&second))==0)

    // The same file as the columns a runtime loads.
    a:Asset
    testing.expect_value(t,asset_load(&a,path),Error.None)
    defer asset_close(&a)
    testing.expect(t,len(a.dependencies)==2 && a.dependencies[0]==base.Asset_Id{7,7})
    view,error:=scene_view(&a,&types)
    testing.expect_value(t,error,Error.None)
    testing.expect(t,scene_view_check(view)==.None)
    testing.expect(t,len(view.ids)==3 && view.ids[1]==child && view.parents[1]==root && view.orders[2]==1 && serial.text_field(view.names[2][:])=="Other")
    testing.expect_value(t,len(view.components),5)
    for &component in view.components {
        if component.name!="Transform" {continue}
        testing.expect(t,component.name_hash==base.name_hash("Transform") && len(component.entities)==3 && component.entities[2]==2 && component.size==size_of(Test_Transform))
        index,_:=types_index(&types,Test_Transform)
        testing.expect(t,asset_column_matches(&a,component.table,1,types.hashes[index]))
        values:[3]Test_Transform
        testing.expect_value(t,scene_component_read(&a,&component,&types.schema,index,mem.slice_to_bytes(values[:])),Error.None)
        testing.expect(t,values[1]==transform(1,0,0))
        stored,_:=scene_component_values(&a,&component)
        testing.expect(t,mem.compare(stored,mem.slice_to_bytes(values[:]))==0)
    }
    entities,_:=asset_table(&a,TABLE_ENTITIES)
    testing.expect(t,entities.key==0 && .Text in entities.columns[3].flags)
}

@(test)
scene_refuses_entities_and_hierarchies_that_cannot_be :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    scene:Scene
    testing.expect_value(t,scene_init(&scene,&types,KIND_MESH,{}),Error.Invalid)
    scene_init(&scene,&types,KIND_PREFAB,{1,1})
    defer scene_destroy(&scene)
    _,error:=scene_entity_add(&scene,0,0,"zero")
    testing.expect_value(t,error,Error.Invalid)
    scene_entity_add(&scene,1,0,"a")
    scene_entity_add(&scene,2,1,"b")
    scene_entity_add(&scene,3,2,"c")
    _,error=scene_entity_add(&scene,2,0,"again")
    testing.expect_value(t,error,Error.Invalid)
    _,error=scene_entity_add(&scene,9,77,"orphan")
    testing.expect_value(t,error,Error.Invalid)
    testing.expect_value(t,scene_entity_reparent(&scene,1,3,0),Error.Invalid)
    testing.expect_value(t,scene_entity_reparent(&scene,1,1,0),Error.Invalid)
    testing.expect_value(t,scene_entity_reparent(&scene,5,1,0),Error.Not_Found)
    testing.expect_value(t,scene_entity_reparent(&scene,3,9,0),Error.Not_Found)
    testing.expect_value(t,scene_entity_reparent(&scene,3,1,4),Error.None)
    testing.expect_value(t,scene_entity(&scene,2),Entity_Record{3,1,4,"c"})
    testing.expect_value(t,scene_entity_rename(&scene,3,"a name that is longer than the sixty-three bytes an entity keeps for it"),Error.None)
    testing.expect_value(t,len(scene_entity(&scene,2).name),ENTITY_NAME_BYTES-1)
    testing.expect_value(t,scene_entity_rename(&scene,7,"x"),Error.Not_Found)

    first,second:=scene_new_id(&scene),scene_new_id(&scene)
    testing.expect(t,first!=0 && second!=0 && first!=second && scene.info.id_counter==2)

    light:=Test_Light{}
    testing.expect_value(t,scene_set(&scene,99,LIGHT,&light),Error.Not_Found)
    _,error=scene_component_of(&scene,TABLE_MEMBERS,Test_Light)
    testing.expect_value(t,error,Error.Invalid)
    _,error=scene_component_of(&scene,TABLE_ENTITIES,Test_Light)
    testing.expect_value(t,error,Error.Invalid)
    table,_:=scene_component(&scene,LIGHT)
    lights:=[2]Test_Light{{intensity=1},{intensity=2}}
    testing.expect_value(t,scene_fill(&scene,LIGHT,{2,1},lights[:]),Error.Invalid)
    testing.expect_value(t,scene_fill(&scene,LIGHT,{1,3},lights[:]),Error.Invalid)
    testing.expect_value(t,scene_fill(&scene,LIGHT,{1},lights[:]),Error.Invalid)
    testing.expect_value(t,scene_fill(&scene,LIGHT,{0,2},lights[:]),Error.None)
    got,_:=scene_get(&scene,3,LIGHT,Test_Light)
    testing.expect_value(t,got.intensity,f32(2))
    testing.expect_value(t,scene_component_set(&scene,table,1,{1,2,3}),Error.Invalid)
    testing.expect(t,scene_component_remove(&scene,table,1))
    testing.expect(t,!scene_component_remove(&scene,table,1))
    testing.expect_value(t,scene_component_fill(&scene,table,{0,1},mem.slice_to_bytes(lights[:])),Error.None)
    testing.expect_value(t,scene_component_fill(&scene,0,{0,1},mem.slice_to_bytes(lights[:])),Error.Invalid)
}

@(test)
scene_removes_entities_with_what_hangs_from_them :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    scene:Scene;scene_init(&scene,&types,KIND_SCENE,{2,2});defer scene_destroy(&scene)
    // 1 -> 2 -> 3, 1 -> 4, 5
    parents:=[5]base.Entity_Id{0,1,2,1,0}
    for parent,i in parents {
        id:=base.Entity_Id(i+1)
        scene_entity_add(&scene,id,parent,"e")
        value:=transform(f32(i+1),0,0)
        scene_set(&scene,id,"Transform",&value)
        if i%2==0 {
            light:=Test_Light{intensity=f32(i+1)}
            scene_set(&scene,id,LIGHT,&light)
        }
    }
    removed,remove_error:=scene_entities_remove(&scene,{2})
    testing.expect(t,removed==2 && remove_error==.None)
    testing.expect_value(t,scene_entity_count(&scene),3)
    ids:=scene_ids(&scene)
    testing.expect(t,ids[0]==1 && ids[1]==4 && ids[2]==5)
    for id in ids {
        value,found:=scene_get(&scene,id,"Transform",Test_Transform)
        testing.expect(t,found && value.position.x==f32(id))
    }
    _,gone:=scene_get(&scene,3,LIGHT,Test_Light)
    kept,has:=scene_get(&scene,5,LIGHT,Test_Light)
    testing.expect(t,!gone && has && kept.intensity==5)
    lights,_:=scene_component(&scene,LIGHT)
    testing.expect_value(t,scene.doc.tables[lights].rows,2)
    row,found:=scene_entity_find(&scene,5)
    testing.expect(t,found && row==2)
    _,old:=scene_entity_find(&scene,3)
    testing.expect(t,!old)

    // Without its descendants, what hung from an entity is left without parent.
    removed,remove_error=scene_entities_remove(&scene,{1},false)
    testing.expect(t,removed==1 && remove_error==.None)
    testing.expect_value(t,scene_entity(&scene,0),Entity_Record{4,0,1,"e"})
    removed,remove_error=scene_entities_remove(&scene,{77})
    testing.expect(t,removed==0 && remove_error==.None)
}

@(private="file")
patched_scene_bytes :: proc(t:^testing.T,types:^Types,w:^serial.Writer,patch:proc(doc:^Document)) -> []u8 {
    scene:Scene;scene_init(&scene,types,KIND_SCENE,{3,3})
    for i in 1..=3 {
        scene_entity_add(&scene,base.Entity_Id(i),i>1?base.Entity_Id(i-1):0,"e")
        light:=Test_Light{intensity=f32(i)}
        scene_set(&scene,base.Entity_Id(i),LIGHT,&light)
    }
    serial.writer_reset(w)
    scene_write(&scene,w)
    doc:Document
    document_read(&doc,serial.writer_bytes(w))
    patch(&doc)
    serial.writer_reset(w)
    testing.expect_value(t,document_write(&doc,w),Error.None)
    document_destroy(&doc)
    scene_destroy(&scene)
    return serial.writer_bytes(w)
}

@(test)
scene_refuses_files_whose_tables_contradict_each_other :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    w:serial.Writer;serial.writer_init(&w);defer serial.writer_destroy(&w)
    expect :: proc(t:^testing.T,types:^Types,w:^serial.Writer,expected:Error,view_fails:bool,patch:proc(doc:^Document),loc:=#caller_location) {
        bytes:=patched_scene_bytes(t,types,w,patch)
        scene:Scene
        error:=scene_read(&scene,types,bytes)
        testing.expect_value(t,error,expected,loc)
        if error==.None {scene_destroy(&scene)}
        a:Asset
        if !testing.expect_value(t,asset_open(&a,bytes),Error.None,loc) {return}
        defer asset_close(&a)
        view,view_error:=scene_view(&a,types)
        testing.expect(t,(view_error!=.None || scene_view_check(view)!=.None)==view_fails,"the view agrees with the document",loc=loc)
    }
    ids :: proc(doc:^Document,column:int) -> []base.Entity_Id {return mem.slice_data_cast([]base.Entity_Id,doc.tables[0].columns[column].data)}
    rows :: proc(doc:^Document) -> []u32 {
        table,_:=document_table(doc,LIGHT)
        return mem.slice_data_cast([]u32,doc.tables[table].columns[0].data)
    }
    expect(t,&types,&w,.None,false,proc(doc:^Document) {})
    expect(t,&types,&w,.Corrupt,true,proc(doc:^Document) {ids(doc,0)[2]=1})
    expect(t,&types,&w,.Corrupt,true,proc(doc:^Document) {ids(doc,0)[1]=0})
    expect(t,&types,&w,.Corrupt,true,proc(doc:^Document) {ids(doc,1)[1]=9})
    expect(t,&types,&w,.Corrupt,true,proc(doc:^Document) {ids(doc,1)[0]=3})
    expect(t,&types,&w,.Corrupt,true,proc(doc:^Document) {ids(doc,1)[2]=3})
    expect(t,&types,&w,.Corrupt,true,proc(doc:^Document) {rows(doc)[2]=3})
    expect(t,&types,&w,.Corrupt,true,proc(doc:^Document) {rows(doc)[1]=0})
    expect(t,&types,&w,.Corrupt,true,proc(doc:^Document) {
        table,_:=document_table(doc,TABLE_ENTITIES)
        document_table_remove(doc,table)
    })
    expect(t,&types,&w,.Invalid,true,proc(doc:^Document) {doc.kind=KIND_MESH})
    // Entities need not be the first table of the file.
    expect(t,&types,&w,.None,false,proc(doc:^Document) {
        entities:=doc.tables[0]
        ordered_remove(&doc.tables,0)
        append(&doc.tables,entities)
        for &table in doc.tables {
            for &column in table.columns {
                if column.ref==0 {column.ref=len(doc.tables)-1}
            }
        }
    })
}

@(test)
scene_reads_components_stored_with_another_layout :: proc(t:^testing.T) {
    Old_Light :: struct {intensity:f64,color:[3]f32}
    old_types:Types;types_init(&old_types);defer types_destroy(&old_types)
    types:Types;types_init(&types);defer types_destroy(&types)
    scene:Scene;scene_init(&scene,&old_types,KIND_SCENE,{4,4})
    scene_entity_add(&scene,1,0,"lamp")
    scene_entity_add(&scene,2,0,"other")
    old:=Old_Light{2.5,{1,0,0}}
    scene_set(&scene,1,LIGHT,&old)
    w:serial.Writer;serial.writer_init(&w);defer serial.writer_destroy(&w)
    scene_write(&scene,&w)
    scene_destroy(&scene)

    loaded:Scene
    testing.expect_value(t,scene_read(&loaded,&types,serial.writer_bytes(&w)),Error.None)
    defer scene_destroy(&loaded)
    default:=Test_Light{range=25}
    light,found:=scene_get(&loaded,1,LIGHT,Test_Light,&default)
    testing.expect(t,found && light==Test_Light{{1,0,0},2.5,25})
    // Written through the layout the file has: fields it does not know are not kept.
    brighter:=Test_Light{{0,1,0},4,50}
    testing.expect_value(t,scene_set(&loaded,2,LIGHT,&brighter),Error.None)
    back,_:=scene_get(&loaded,2,LIGHT,Test_Light,&default)
    testing.expect(t,back==Test_Light{{0,1,0},4,25})
    table,_:=scene_component(&loaded,LIGHT)
    testing.expect_value(t,loaded.doc.tables[table].columns[1].size,size_of(Old_Light))
}

@(private="file")
lamp_prefab :: proc(prefab:^Scene,types:^Types,radius:f32,color:[3]f32) {
    scene_init(prefab,types,KIND_PREFAB,{0xa,0xa})
    scene_entity_add(prefab,1,0,"Lamp")
    scene_entity_add(prefab,2,1,"Bulb")
    scene_entity_add(prefab,3,1,"Shade")
    prefab.info.root=1
    for id in ([]base.Entity_Id{1,2,3}) {
        value:=transform(0,f32(id),0)
        scene_set(prefab,id,"Transform",&value)
    }
    light:=Test_Light{color,1,radius}
    scene_set(prefab,2,LIGHT,&light)
    follow:=Test_Follow{target=base.Entity(1),anchor=2,offset={0,0,1}}
    scene_set(prefab,3,"Follow",&follow)
    outside:=Test_Follow{target=base.Entity(99),anchor=1}
    scene_set(prefab,2,"Follow",&outside)
}

@(private="file")
member :: proc(scene:^Scene,instance:u32,source:base.Entity_Id) -> base.Entity_Id {
    for candidate in scene.members {
        if candidate.instance==instance && candidate.source==source {return candidate.entity}
    }
    return 0
}

@(test)
prefab_instances_copy_entities_and_point_references_at_the_copies :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    prefab:Scene;lamp_prefab(&prefab,&types,1,{1,0,0});defer scene_destroy(&prefab)
    scene:Scene;scene_init(&scene,&types,KIND_SCENE,{0xb,0xb});defer scene_destroy(&scene)
    scene_entity_add(&scene,100,0,"Room")
    scene_entity_add(&scene,101,100,"Chair")
    a,root_a,error_a:=scene_instantiate(&scene,&prefab,{0xa,0xa},100)
    b,root_b,error_b:=scene_instantiate(&scene,&prefab,{0xa,0xa},0)
    testing.expect(t,error_a==.None && error_b==.None && a==1 && b==2 && root_a!=root_b)
    testing.expect_value(t,scene_entity_count(&scene),8)
    testing.expect_value(t,scene_entity(&scene,2),Entity_Record{root_a,100,1,"Lamp"})
    bulb,shade:=member(&scene,a,2),member(&scene,a,3)
    testing.expect(t,bulb!=0 && shade!=0 && bulb!=2 && member(&scene,a,1)==root_a && member(&scene,b,1)==root_b)
    row,_:=scene_entity_find(&scene,bulb)
    testing.expect_value(t,scene_entity(&scene,row),Entity_Record{bulb,root_a,0,"Bulb"})
    light,_:=scene_get(&scene,bulb,LIGHT,Test_Light)
    testing.expect(t,light==Test_Light{{1,0,0},1,1})
    follow,_:=scene_get(&scene,shade,"Follow",Test_Follow)
    testing.expect(t,follow==Test_Follow{base.Entity(root_a),bulb,{0,0,1}})
    // A reference to what is not in the prefab comes empty.
    outside,_:=scene_get(&scene,bulb,"Follow",Test_Follow)
    testing.expect(t,outside==Test_Follow{0,root_a,{}})
    testing.expect_value(t,scene_entity_instance(&scene,bulb),a)
    testing.expect_value(t,scene_entity_instance(&scene,101),u32(0))
    testing.expect_value(t,len(scene.members),6)

    _,_,no_parent:=scene_instantiate(&scene,&prefab,{0xa,0xa},555)
    testing.expect_value(t,no_parent,Error.Not_Found)
    _,_,itself:=scene_instantiate(&prefab,&prefab,{0xa,0xa},0)
    testing.expect_value(t,itself,Error.Invalid)

    // Records survive a save, and removing an instance removes what it placed.
    w:serial.Writer;serial.writer_init(&w);defer serial.writer_destroy(&w)
    scene_override_add(&scene,bulb,light_hash(),"intensity")
    testing.expect_value(t,scene_write(&scene,&w),Error.None)
    loaded:Scene
    testing.expect_value(t,scene_read(&loaded,&types,serial.writer_bytes(&w)),Error.None)
    defer scene_destroy(&loaded)
    testing.expect(t,len(loaded.instances)==2 && loaded.instances[0]==Instance{1,{0xa,0xa},root_a,0,0} && len(loaded.members)==6 && len(loaded.overrides)==1)
    testing.expect(t,scene_overridden(&loaded,bulb,light_hash(),"intensity") && loaded.info.last_instance==2)
    asset:Asset
    testing.expect_value(t,asset_open(&asset,serial.writer_bytes(&w)),Error.None)
    defer asset_close(&asset)
    view,_:=scene_view(&asset,&types)
    testing.expect(t,scene_view_check(view)==.None && len(view.instances)==2 && len(view.members)==6 && len(view.overrides)==1 && view.overrides[0].entity==bulb)

    testing.expect_value(t,scene_instance_remove(&loaded,a),Error.None)
    testing.expect(t,scene_entity_count(&loaded)==5 && len(loaded.instances)==1 && len(loaded.members)==3 && len(loaded.overrides)==0)
    testing.expect_value(t,scene_instance_unlink(&loaded,b),Error.None)
    testing.expect(t,scene_entity_count(&loaded)==5 && len(loaded.instances)==0 && len(loaded.members)==0)
    testing.expect_value(t,scene_instance_unlink(&loaded,b),Error.Invalid)
}

@(test)
prefab_update_keeps_what_an_instance_overrides :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    prefab:Scene;lamp_prefab(&prefab,&types,1,{1,0,0});defer scene_destroy(&prefab)
    scene:Scene;scene_init(&scene,&types,KIND_SCENE,{0xb,0xb});defer scene_destroy(&scene)
    a,root_a,_:=scene_instantiate(&scene,&prefab,{0xa,0xa},0)
    b,_,_:=scene_instantiate(&scene,&prefab,{0xa,0xa},0)
    bulb_a,bulb_b,shade_a:=member(&scene,a,2),member(&scene,b,2),member(&scene,a,3)

    // A sets its radius to 2 and places its root; B inherits everything.
    light,_:=scene_get(&scene,bulb_a,LIGHT,Test_Light)
    light.range=2
    scene_set(&scene,bulb_a,LIGHT,&light)
    testing.expect_value(t,scene_override_add(&scene,bulb_a,light_hash(),"range"),Error.None)
    placed:=transform(5,5,5)
    scene_set(&scene,root_a,"Transform",&placed)
    scene_override_add(&scene,root_a,base.name_hash("Transform"),"position")
    scene_entity_rename(&scene,shade_a,"My shade")
    scene_override_add(&scene,shade_a,0,"name")
    mesh:=Test_Mesh{{1,1},{2,2}}
    scene_set(&scene,shade_a,"Mesh",&mesh)
    scene_override_add(&scene,shade_a,base.name_hash("Mesh"),"",.Added)
    follow_table,_:=scene_component(&scene,"Follow")
    scene_component_remove(&scene,follow_table,shade_a)
    scene_override_add(&scene,shade_a,base.name_hash("Follow"),"",.Removed)
    stray:=Test_Mesh{{3,3},{4,4}}
    scene_set(&scene,bulb_a,"Mesh",&stray) // not marked: the prefab does not have it

    // The prefab becomes radius 3 and blue, gains a cable and loses nothing.
    scene_destroy(&prefab)
    lamp_prefab(&prefab,&types,3,{0,0,1})
    scene_entity_add(&prefab,4,2,"Cable")
    cable:=transform(0,-1,0)
    scene_set(&prefab,4,"Transform",&cable)
    scene_entity_rename(&prefab,3,"Shade v2")
    testing.expect_value(t,scene_instance_update(&scene,a,&prefab),Error.None)
    testing.expect_value(t,scene_instance_update(&scene,b,&prefab),Error.None)

    light_a,_:=scene_get(&scene,bulb_a,LIGHT,Test_Light)
    light_b,_:=scene_get(&scene,bulb_b,LIGHT,Test_Light)
    testing.expect(t,light_a==Test_Light{{0,0,1},1,2})
    testing.expect(t,light_b==Test_Light{{0,0,1},1,3})
    root_transform,_:=scene_get(&scene,root_a,"Transform",Test_Transform)
    testing.expect(t,root_transform==placed)
    shade_row,_:=scene_entity_find(&scene,shade_a)
    testing.expect_value(t,scene_entity(&scene,shade_row).name,"My shade")
    shade_b_row,_:=scene_entity_find(&scene,member(&scene,b,3))
    testing.expect_value(t,scene_entity(&scene,shade_b_row).name,"Shade v2")
    kept,has_mesh:=scene_get(&scene,shade_a,"Mesh",Test_Mesh)
    testing.expect(t,has_mesh && kept==mesh)
    _,has_follow:=scene_get(&scene,shade_a,"Follow",Test_Follow)
    _,b_follow:=scene_get(&scene,member(&scene,b,3),"Follow",Test_Follow)
    testing.expect(t,!has_follow && b_follow)
    _,has_stray:=scene_get(&scene,bulb_a,"Mesh",Test_Mesh)
    testing.expect(t,!has_stray)
    cable_a:=member(&scene,a,4)
    cable_row,cable_found:=scene_entity_find(&scene,cable_a)
    testing.expect(t,cable_found && scene_entity(&scene,cable_row).parent==bulb_a && scene_entity(&scene,cable_row).name=="Cable")
    cable_transform,_:=scene_get(&scene,cable_a,"Transform",Test_Transform)
    testing.expect(t,cable_transform==cable)
    testing.expect_value(t,scene_entity_count(&scene),8)

    // Reverting gives the value of the prefab back at the next update.
    testing.expect(t,scene_override_remove(&scene,bulb_a,light_hash(),"range"))
    testing.expect(t,!scene_override_remove(&scene,bulb_a,light_hash(),"range"))
    scene_instance_update(&scene,a,&prefab)
    light_a,_=scene_get(&scene,bulb_a,LIGHT,Test_Light)
    testing.expect_value(t,light_a.range,f32(3))

    // An entity that leaves the prefab leaves its instances.
    scene_entities_remove(&prefab,{2})
    testing.expect_value(t,scene_instance_update(&scene,a,&prefab),Error.None)
    _,bulb_left:=scene_entity_find(&scene,bulb_a)
    _,cable_left:=scene_entity_find(&scene,cable_a)
    testing.expect(t,!bulb_left && !cable_left)
    testing.expect_value(t,scene_entity_count(&scene),6)
    testing.expect_value(t,scene_instance_update(&scene,99,&prefab),Error.Invalid)
}

@(private="file")
plug_prefab :: proc(prefab:^Scene,types:^Types) {
    scene_init(prefab,types,KIND_PREFAB,{0xe,0xe})
    scene_entity_add(prefab,1,0,"Plug")
    scene_entity_add(prefab,2,1,"Pin")
    prefab.info.root=1
}

@(private="file")
gone :: proc(scene:^Scene,ids:..base.Entity_Id) -> bool {
    for id in ids {
        if id==0 || id in scene.index {return false}
    }
    return true
}

@(test)
prefab_node_that_leaves_takes_what_hangs_from_it_and_what_named_it_names_none :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    plug:Scene;plug_prefab(&plug,&types);defer scene_destroy(&plug)
    // The Lamp brings a Plug under its Bulb.
    prefab:Scene;lamp_prefab(&prefab,&types,1,{1,0,0});defer scene_destroy(&prefab)
    _,_,error:=scene_instantiate(&prefab,&plug,{0xe,0xe},2)
    testing.expect_value(t,error,Error.None)
    scene:Scene;scene_init(&scene,&types,KIND_SCENE,{0xb,0xb});defer scene_destroy(&scene)
    room,watcher:=base.Entity_Id(100),base.Entity_Id(101)
    scene_entity_add(&scene,room,0,"Room")
    scene_entity_add(&scene,watcher,0,"Watcher")
    a,root_a,_:=scene_instantiate(&scene,&prefab,{0xa,0xa},0)
    b,root_b,_:=scene_instantiate(&scene,&prefab,{0xa,0xa},0)
    testing.expect_value(t,len(scene.instances),4)
    bulb_a,shade_a,bulb_b:=member(&scene,a,2),member(&scene,a,3),member(&scene,b,2)
    nested_a:=scene.instances[1].id
    testing.expect_value(t,scene.instances[1].outer,a)
    plug_a,pin_a:=member(&scene,nested_a,1),member(&scene,nested_a,2)
    testing.expect(t,plug_a!=0 && pin_a!=0)

    // A overrides the Bulb, adds a Sticker with a child and places a Plug of its own under it.
    light,_:=scene_get(&scene,bulb_a,LIGHT,Test_Light)
    light.range=7
    scene_set(&scene,bulb_a,LIGHT,&light)
    testing.expect_value(t,scene_override_add(&scene,bulb_a,light_hash(),"range"),Error.None)
    sticker,corner:=base.Entity_Id(200),base.Entity_Id(201)
    scene_entity_add(&scene,sticker,bulb_a,"Sticker")
    scene_entity_add(&scene,corner,sticker,"Corner")
    testing.expect_value(t,scene_override_add(&scene,sticker,0,"",.Child),Error.None)
    placed,placed_root,placed_error:=scene_instantiate(&scene,&plug,{0xe,0xe},bulb_a)
    testing.expect_value(t,placed_error,Error.None)
    testing.expect_value(t,scene_override_add(&scene,placed_root,0,"",.Child),Error.None)
    placed_pin:=member(&scene,placed,2)
    // The Shade of A points at the Pin the Lamp brought, as an override.
    follow,_:=scene_get(&scene,shade_a,"Follow",Test_Follow)
    follow.anchor=pin_a
    scene_set(&scene,shade_a,"Follow",&follow)
    testing.expect_value(t,scene_override_add(&scene,shade_a,base.name_hash("Follow"),"anchor"),Error.None)
    // Entities of the scene name the Bulb, what the instance added under it and what came with the Plugs.
    names_bulb:=Test_Follow{target=base.Entity(bulb_a),anchor=pin_a}
    scene_set(&scene,room,"Follow",&names_bulb)
    names_added:=Test_Follow{target=base.Entity(corner),anchor=placed_pin,offset={1,2,3}}
    scene_set(&scene,watcher,"Follow",&names_added)

    // The Bulb leaves the Lamp, with the Plug under it.
    scene_entities_remove(&prefab,{2})
    testing.expect(t,len(prefab.instances)==0 && scene_entity_count(&prefab)==2)
    testing.expect_value(t,scene_instance_update(&scene,a,&prefab),Error.None)
    testing.expect_value(t,scene_instance_update(&scene,b,&prefab),Error.None)

    // The member goes with its overrides, what was added under it and the instances under it.
    testing.expect(t,gone(&scene,bulb_a,bulb_b,sticker,corner,plug_a,pin_a,placed_root,placed_pin))
    testing.expect_value(t,scene_entity_count(&scene),6)
    testing.expect(t,len(scene.instances)==2 && scene.instances[0].id==a && scene.instances[1].id==b)
    testing.expect_value(t,len(scene.members),4)
    for m in scene.members {testing.expect(t,m.entity in scene.index && (m.instance==a || m.instance==b))}
    testing.expect(t,len(scene.overrides)==1 && scene.overrides[0].entity==shade_a)
    // What named any of them names none, also what the Shade overrides; the rest is kept.
    room_follow,_:=scene_get(&scene,room,"Follow",Test_Follow)
    testing.expect_value(t,room_follow,Test_Follow{})
    watcher_follow,_:=scene_get(&scene,watcher,"Follow",Test_Follow)
    testing.expect_value(t,watcher_follow,Test_Follow{offset={1,2,3}})
    shade_follow,_:=scene_get(&scene,shade_a,"Follow",Test_Follow)
    testing.expect_value(t,shade_follow,Test_Follow{target=base.Entity(root_a),offset={0,0,1}})
    shade_b_follow,_:=scene_get(&scene,member(&scene,b,3),"Follow",Test_Follow)
    testing.expect_value(t,shade_b_follow,Test_Follow{target=base.Entity(root_b),offset={0,0,1}})
    for id in scene_ids(&scene) {
        value,has:=scene_get(&scene,id,"Follow",Test_Follow)
        if !has {continue}
        testing.expect(t,value.target==0 || base.Entity_Id(value.target) in scene.index)
        testing.expect(t,value.anchor==0 || value.anchor in scene.index)
    }
    // The scene is still one a file holds.
    w:serial.Writer;serial.writer_init(&w);defer serial.writer_destroy(&w)
    testing.expect_value(t,scene_write(&scene,&w),Error.None)
    loaded:Scene
    testing.expect_value(t,scene_read(&loaded,&types,serial.writer_bytes(&w)),Error.None)
    scene_destroy(&loaded)
    stored:Asset
    testing.expect_value(t,asset_open(&stored,serial.writer_bytes(&w)),Error.None)
    defer asset_close(&stored)
    view,_:=scene_view(&stored,&types)
    testing.expect(t,scene_view_check(view)==.None)
}

@(test)
prefab_overrides_cover_the_parts_inside_them :: proc(t:^testing.T) {
    testing.expect(t,path_covers("","a.b") && path_covers("a","a") && path_covers("a","a.b") && path_covers("a","a[2]") && path_covers("a.b","a.b.c"))
    testing.expect(t,!path_covers("a","ab") && !path_covers("a.b","a") && !path_covers("a.b","a.c"))
    types:Types;types_init(&types);defer types_destroy(&types)
    prefab:Scene;lamp_prefab(&prefab,&types,1,{1,0,0});defer scene_destroy(&prefab)
    scene:Scene;scene_init(&scene,&types,KIND_SCENE,{0xb,0xb});defer scene_destroy(&scene)
    scene_entity_add(&scene,100,0,"loose")
    a,_,_:=scene_instantiate(&scene,&prefab,{0xa,0xa},0)
    bulb:=member(&scene,a,2)
    hash:=light_hash()
    testing.expect_value(t,scene_override_add(&scene,100,hash,"range"),Error.Invalid)
    testing.expect_value(t,scene_override_add(&scene,bulb,hash,"",.Added),Error.None)
    testing.expect_value(t,scene_override_add(&scene,bulb,hash,"x",.Removed),Error.Invalid)
    long:=make([]u8,OVERRIDE_PATH_BYTES,context.temp_allocator)
    for &b in long {b='a'}
    testing.expect_value(t,scene_override_add(&scene,bulb,hash,string(long)),Error.Invalid)
    clear(&scene.overrides)
    scene_override_add(&scene,bulb,hash,"color[0]")
    scene_override_add(&scene,bulb,hash,"color[1]")
    scene_override_add(&scene,bulb,hash,"range")
    scene_override_add(&scene,bulb,hash,"color[1]")
    testing.expect_value(t,len(scene.overrides),3)
    testing.expect(t,scene_overridden(&scene,bulb,hash,"color[1]") && !scene_overridden(&scene,bulb,hash,"color[2]") && !scene_overridden(&scene,bulb,hash,"color"))
    // The whole color takes the place of its channels.
    scene_override_add(&scene,bulb,hash,"color")
    testing.expect_value(t,len(scene.overrides),2)
    testing.expect(t,scene_overridden(&scene,bulb,hash,"color[2]") && scene_overridden(&scene,bulb,hash,"range"))
    scene_override_add(&scene,bulb,hash,"color[0]")
    testing.expect_value(t,len(scene.overrides),2)
    // Removing the component discards what it overrode.
    scene_override_add(&scene,bulb,hash,"",.Removed)
    testing.expect(t,len(scene.overrides)==1 && scene.overrides[0].kind==.Removed && !scene_overridden(&scene,bulb,hash,"range"))
    free_all(context.temp_allocator)
}

@(test)
prefab_inside_a_prefab_keeps_each_level_of_overrides :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    hash:=light_hash()
    lamp:Scene;lamp_prefab(&lamp,&types,1,{1,1,1});defer scene_destroy(&lamp)
    // Room holds a Lamp and sets its intensity to 2.
    room:Scene;scene_init(&room,&types,KIND_PREFAB,{0xc,0xc});defer scene_destroy(&room)
    scene_entity_add(&room,1,0,"Room")
    inner,_,_:=scene_instantiate(&room,&lamp,{0xa,0xa},1)
    room_bulb:=member(&room,inner,2)
    light,_:=scene_get(&room,room_bulb,LIGHT,Test_Light)
    light.intensity=2
    scene_set(&room,room_bulb,LIGHT,&light)
    scene_override_add(&room,room_bulb,hash,"intensity")

    scene:Scene;scene_init(&scene,&types,KIND_SCENE,{0xd,0xd});defer scene_destroy(&scene)
    placed,_,error:=scene_instantiate(&scene,&room,{0xc,0xc},0)
    testing.expect_value(t,error,Error.None)
    testing.expect(t,len(scene.instances)==2 && scene.instances[1].outer==placed && scene.instances[1].prefab==base.Asset_Id{0xa,0xa})
    bulb:=member(&scene,placed,room_bulb)
    testing.expect_value(t,member(&scene,scene.instances[1].id,2),bulb)
    testing.expect_value(t,scene_entity_instance(&scene,bulb),placed)
    testing.expect(t,len(scene.overrides)==1 && scene.overrides[0].instance==scene.instances[1].id && scene.overrides[0].entity==bulb)
    seen,_:=scene_get(&scene,bulb,LIGHT,Test_Light)
    testing.expect_value(t,seen.intensity,f32(2))

    // The scene sets 3 on top; an update of Room keeps it.
    seen.intensity=3
    scene_set(&scene,bulb,LIGHT,&seen)
    scene_override_add(&scene,bulb,hash,"intensity")
    testing.expect_value(t,scene_instance_update(&scene,placed,&room),Error.None)
    seen,_=scene_get(&scene,bulb,LIGHT,Test_Light)
    testing.expect_value(t,seen.intensity,f32(3))
    testing.expect(t,len(scene.instances)==2 && len(scene.overrides)==2)
    // Without the override of the scene, the one of Room shows again.
    testing.expect(t,scene_override_remove(&scene,bulb,hash,"intensity"))
    scene_instance_update(&scene,placed,&room)
    seen,_=scene_get(&scene,bulb,LIGHT,Test_Light)
    testing.expect_value(t,seen.intensity,f32(2))
    // And without the one of Room, updating Room from Lamp gives the value of Lamp.
    testing.expect(t,scene_override_remove(&room,room_bulb,hash,"intensity"))
    testing.expect_value(t,scene_instance_update(&room,inner,&lamp),Error.None)
    scene_instance_update(&scene,placed,&room)
    seen,_=scene_get(&scene,bulb,LIGHT,Test_Light)
    testing.expect_value(t,seen.intensity,f32(1))
    testing.expect_value(t,len(scene.overrides),0)

    // The instance a prefab brought in is not updated or unlinked on its own.
    nested:=scene.instances[1].id
    testing.expect_value(t,scene_instance_update(&scene,nested,&lamp),Error.Invalid)
    testing.expect_value(t,scene_instance_unlink(&scene,placed),Error.None)
    testing.expect(t,len(scene.instances)==1 && scene.instances[0].outer==0 && scene.instances[0].id==nested && len(scene.members)==3)
}

@(test)
components_turned_off_survive_saving_and_go_with_their_component :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    scene:Scene
    testing.expect_value(t,scene_init(&scene,&types,KIND_SCENE,{0x61,0x62}),Error.None)
    defer scene_destroy(&scene)
    a,b:=base.Entity_Id(0x10),base.Entity_Id(0x20)
    scene_entity_add(&scene,a,0,"A");scene_entity_add(&scene,b,0,"B")
    light:=Test_Light{{1,1,1},2,5}
    scene_set(&scene,a,LIGHT,&light);scene_set(&scene,b,LIGHT,&light)
    testing.expect_value(t,scene_component_turn(&scene,a,light_hash(),true),Error.None)
    testing.expect_value(t,scene_component_turn(&scene,a,light_hash(),true),Error.None)
    testing.expect_value(t,len(scene.off),1)
    testing.expect_value(t,scene_component_turn(&scene,0x99,light_hash(),true),Error.Not_Found)

    path:=test_path("off.scene")
    defer os.remove(path)
    testing.expect_value(t,scene_save(&scene,path),Error.None)
    loaded:Scene
    testing.expect_value(t,scene_load(&loaded,&types,path),Error.None)
    defer scene_destroy(&loaded)
    testing.expect(t,scene_component_off(&loaded,a,light_hash()) && !scene_component_off(&loaded,b,light_hash()))
    file:Asset
    testing.expect_value(t,asset_load(&file,path),Error.None)
    view,error:=scene_view(&file,&types)
    testing.expect(t,error==.None && scene_view_check(view)==.None)
    testing.expect(t,len(view.off)==1 && view.off[0]==Component_Off{a,light_hash()})
    testing.expect_value(t,len(view.components),1) // the records are not a component
    asset_close(&file)

    // Without its component, or its entity, nothing is off.
    table,_:=scene_component(&loaded,LIGHT)
    scene_component_remove(&loaded,table,a)
    testing.expect(t,!scene_component_off(&loaded,a,light_hash()))
    scene_component_turn(&loaded,b,light_hash(),true)
    scene_entities_remove(&loaded,{b})
    testing.expect_value(t,len(loaded.off),0)
}

@(test)
prefab_instances_follow_what_their_prefab_turns_off_unless_they_turned_it :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    prefab:Scene;lamp_prefab(&prefab,&types,1,{1,0,0});defer scene_destroy(&prefab)
    scene_component_turn(&prefab,2,light_hash(),true)
    scene:Scene;scene_init(&scene,&types,KIND_SCENE,{0xb,0xb});defer scene_destroy(&scene)
    a,_,_:=scene_instantiate(&scene,&prefab,{0xa,0xa},0)
    b,_,_:=scene_instantiate(&scene,&prefab,{0xa,0xa},0)
    bulb_a,bulb_b:=member(&scene,a,2),member(&scene,b,2)
    testing.expect(t,scene_component_off(&scene,bulb_a,light_hash()) && scene_component_off(&scene,bulb_b,light_hash()))

    // A turns its light on; the prefab turns it on and later off again.
    scene_component_turn(&scene,bulb_a,light_hash(),false)
    testing.expect_value(t,scene_override_add(&scene,bulb_a,light_hash(),"",.Turned),Error.None)
    scene_component_turn(&prefab,2,light_hash(),false)
    scene_instance_update(&scene,a,&prefab);scene_instance_update(&scene,b,&prefab)
    testing.expect(t,!scene_component_off(&scene,bulb_a,light_hash()) && !scene_component_off(&scene,bulb_b,light_hash()))
    scene_component_turn(&prefab,2,light_hash(),true)
    scene_instance_update(&scene,a,&prefab);scene_instance_update(&scene,b,&prefab)
    testing.expect(t,!scene_component_off(&scene,bulb_a,light_hash()),"A keeps its own")
    testing.expect(t,scene_component_off(&scene,bulb_b,light_hash()))
}

@(private="file")
parent_of :: proc(scene:^Scene,id:base.Entity_Id) -> (parent:base.Entity_Id,found:bool) {
    row:=scene_entity_find(scene,id) or_return
    return scene_parents(scene)[row],true
}

@(private="file")
override_kinds :: proc(scene:^Scene) -> (kinds:[Override_Kind]int) {
    for override in scene.overrides {kinds[override.kind]+=1}
    return
}

@(test)
prefab_instances_keep_the_entities_they_add_through_updates :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    prefab:Scene;lamp_prefab(&prefab,&types,1,{1,0,0});defer scene_destroy(&prefab)
    scene:Scene;scene_init(&scene,&types,KIND_SCENE,{0xb,0xb});defer scene_destroy(&scene)
    a,root,_:=scene_instantiate(&scene,&prefab,{0xa,0xa},0)
    bulb,shade:=member(&scene,a,2),member(&scene,a,3)
    // Wire, with a Plug, under Bulb; only the top one is the override.
    scene_entity_add(&scene,500,bulb,"Wire")
    scene_entity_add(&scene,501,500,"Plug")
    testing.expect_value(t,scene_override_add(&scene,500,0,"",.Child),Error.None)
    testing.expect_value(t,scene_override_add(&scene,501,0,"",.Child),Error.Invalid)
    testing.expect_value(t,scene_override_add(&scene,bulb,0,"",.Child),Error.Invalid)
    // A member placed elsewhere without the prefab goes back to the place of the prefab.
    testing.expect_value(t,scene_entity_reparent(&scene,shade,bulb,0),Error.None)

    // The prefab gains a Cable under Bulb and renames Shade.
    scene_entity_add(&prefab,4,2,"Cable")
    scene_entity_rename(&prefab,3,"Shade v2")
    testing.expect_value(t,scene_instance_update(&scene,a,&prefab),Error.None)
    wire_parent,_:=parent_of(&scene,500)
    plug_parent,_:=parent_of(&scene,501)
    shade_parent,_:=parent_of(&scene,shade)
    cable_parent,cable:=parent_of(&scene,member(&scene,a,4))
    testing.expect(t,wire_parent==bulb && plug_parent==500 && shade_parent==root)
    testing.expect(t,cable && cable_parent==bulb)
    shade_row,_:=scene_entity_find(&scene,shade)
    testing.expect_value(t,scene_entity(&scene,shade_row).name,"Shade v2")
    kinds:=override_kinds(&scene)
    testing.expect_value(t,kinds[.Child],1)
    w:serial.Writer;serial.writer_init(&w);defer serial.writer_destroy(&w)
    testing.expect_value(t,scene_write(&scene,&w),Error.None)
    loaded:Scene
    testing.expect_value(t,scene_read(&loaded,&types,serial.writer_bytes(&w)),Error.None)
    defer scene_destroy(&loaded)
    testing.expect(t,len(loaded.overrides)==1 && override_kinds(&loaded)==kinds)

    // What was added under a member that leaves the prefab goes with it.
    scene_entities_remove(&prefab,{2})
    testing.expect_value(t,scene_instance_update(&scene,a,&prefab),Error.None)
    _,bulb_left:=scene_entity_find(&scene,bulb)
    _,wire_left:=scene_entity_find(&scene,500)
    _,plug_left:=scene_entity_find(&scene,501)
    testing.expect(t,!bulb_left && !wire_left && !plug_left)
    shade_parent,_=parent_of(&scene,shade)
    testing.expect_value(t,shade_parent,root)
    testing.expect_value(t,override_kinds(&scene)[.Child],0)
}

@(test)
prefab_entities_an_instance_adds_go_into_the_prefab_and_come_back_out :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    prefab:Scene;lamp_prefab(&prefab,&types,1,{1,0,0});defer scene_destroy(&prefab)
    scene:Scene;scene_init(&scene,&types,KIND_SCENE,{0xb,0xb});defer scene_destroy(&scene)
    a,root,_:=scene_instantiate(&scene,&prefab,{0xa,0xa},0)
    bulb,shade:=member(&scene,a,2),member(&scene,a,3)
    // Wire under Bulb follows Shade.
    scene_entity_add(&scene,500,bulb,"Wire")
    follow:=Test_Follow{target=base.Entity(shade),anchor=root}
    scene_set(&scene,500,"Follow",&follow)
    scene_override_add(&scene,500,0,"",.Child)

    // Reverting the entity added removes it with what is under it.
    w:serial.Writer;serial.writer_init(&w);defer serial.writer_destroy(&w)
    testing.expect_value(t,scene_write(&scene,&w),Error.None)
    copy:Scene
    testing.expect_value(t,scene_read(&copy,&types,serial.writer_bytes(&w)),Error.None)
    defer scene_destroy(&copy)
    scene_entity_add(&copy,501,500,"Plug")
    testing.expect_value(t,scene_child_revert(&copy,a,500),Error.None)
    _,wire_kept:=scene_entity_find(&copy,500)
    _,plug_kept:=scene_entity_find(&copy,501)
    testing.expect(t,!wire_kept && !plug_kept && override_kinds(&copy)[.Child]==0)
    testing.expect_value(t,scene_child_revert(&copy,a,bulb),Error.Invalid)

    // Applying: the prefab gets Wire under Bulb, with its reference to Shade.
    testing.expect_value(t,scene_child_apply(&scene,a,500,&prefab),Error.None)
    wire_source:=base.Entity_Id(0)
    for candidate in scene.members {
        if candidate.instance==a && candidate.entity==500 {wire_source=candidate.source}
    }
    testing.expect(t,wire_source!=0 && wire_source!=500)
    wire_parent,_:=parent_of(&prefab,wire_source)
    testing.expect_value(t,wire_parent,2)
    copied,has:=scene_get(&prefab,wire_source,"Follow",Test_Follow)
    testing.expect(t,has && copied==Test_Follow{target=base.Entity(3),anchor=1})
    // With the override ended, an update keeps every entity where it is, the one added as a member.
    clear(&scene.overrides)
    count:=scene_entity_count(&scene)
    testing.expect_value(t,scene_instance_update(&scene,a,&prefab),Error.None)
    testing.expect_value(t,scene_entity_count(&scene),count)
    wire_parent,_=parent_of(&scene,500)
    testing.expect(t,wire_parent==bulb && member(&scene,a,wire_source)==500)
    kept,_:=scene_get(&scene,500,"Follow",Test_Follow)
    testing.expect_value(t,kept,follow)
    testing.expect_value(t,scene_child_apply(&scene,a,bulb,&prefab),Error.Invalid)
}

// Prefab files held in memory, by id.
@(private="file")
Test_Files :: struct {assets:map[base.Asset_Id]^Asset}

@(private="file")
test_files_open :: proc(data:rawptr,id:base.Asset_Id) -> ^Asset {return (^Test_Files)(data).assets[id] or_else nil}

@(private="file")
test_file_put :: proc(t:^testing.T,files:^Test_Files,scene:^Scene) {
    data,error:=scene_bytes(scene)
    testing.expect_value(t,error,Error.None)
    if old,had:=files.assets[scene.doc.id];had {asset_close(old);free(old)}
    a:=new(Asset)
    testing.expect_value(t,asset_take(a,data),Error.None)
    files.assets[scene.doc.id]=a
}

@(test)
stale_prefab_instances_resolve_against_the_files_of_their_prefabs :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    files:Test_Files
    files.assets=make(map[base.Asset_Id]^Asset)
    defer {
        for _,a in files.assets {asset_close(a);free(a)}
        delete(files.assets)
    }
    lamp:Scene;lamp_prefab(&lamp,&types,1,{1,1,1});defer scene_destroy(&lamp)
    test_file_put(t,&files,&lamp)
    // Room holds a Lamp at intensity 2; the level holds a Room and a Lamp.
    room:Scene;scene_init(&room,&types,KIND_PREFAB,{0xc,0xc});defer scene_destroy(&room)
    scene_entity_add(&room,1,0,"Room")
    room.info.root=1
    inner,_,_:=scene_instantiate(&room,&lamp,{0xa,0xa},1)
    testing.expect_value(t,room.instances[0].stamp,lamp.stamp)
    room_bulb:=member(&room,inner,2)
    light,_:=scene_get(&room,room_bulb,LIGHT,Test_Light)
    light.intensity=2
    scene_set(&room,room_bulb,LIGHT,&light)
    scene_override_add(&room,room_bulb,light_hash(),"intensity")
    test_file_put(t,&files,&room)
    level:Scene;scene_init(&level,&types,KIND_SCENE,{0xd,0xd});defer scene_destroy(&level)
    placed,_,_:=scene_instantiate(&level,&room,{0xc,0xc},0)
    lone,_,_:=scene_instantiate(&level,&lamp,{0xa,0xa},0)
    test_file_put(t,&files,&level)
    {
        r:Prefab_Resolver;resolver_init(&r,&types,{&files,test_files_open});defer resolver_destroy(&r)
        testing.expect(t,!resolver_stale(&r,files.assets[level.doc.id]))
    }

    // Lamp reaches a range of 3: the file of Room is stale through it, and so is the level, by both instances.
    scene_destroy(&lamp)
    lamp_prefab(&lamp,&types,3,{1,1,1})
    test_file_put(t,&files,&lamp)
    r:Prefab_Resolver;resolver_init(&r,&types,{&files,test_files_open});defer resolver_destroy(&r)
    testing.expect_value(t,resolver_check(&r,{0xc,0xc}).state,Resolve_State.Stale)
    testing.expect_value(t,resolver_check(&r,{0xa,0xa}).state,Resolve_State.Current)
    testing.expect(t,resolver_stale(&r,files.assets[level.doc.id]))
    resolved:Scene
    testing.expect_value(t,scene_from_asset(&resolved,&types,files.assets[level.doc.id]),Error.None)
    defer scene_destroy(&resolved)
    changed,error:=scene_resolve(&r,&resolved)
    testing.expect(t,changed && error==.None)
    seen,_:=scene_get(&resolved,member(&resolved,placed,room_bulb),LIGHT,Test_Light)
    testing.expect(t,seen.range==3 && seen.intensity==2)
    seen,_=scene_get(&resolved,member(&resolved,lone,2),LIGHT,Test_Light)
    testing.expect(t,seen.range==3 && seen.intensity==1)
    // The stamps are those of the files: Room as its file is, Lamp as its file is now.
    for instance in resolved.instances {
        if instance.id==placed {testing.expect_value(t,instance.stamp,files.assets[{0xc,0xc}].blob.header.content_hash)}
        if instance.id==lone {testing.expect_value(t,instance.stamp,files.assets[{0xa,0xa}].blob.header.content_hash)}
    }
    // A missing prefab leaves its instances as they are.
    asset_close(files.assets[{0xc,0xc}])
    free(files.assets[{0xc,0xc}])
    delete_key(&files.assets,base.Asset_Id{0xc,0xc})
    other:Prefab_Resolver;resolver_init(&other,&types,{&files,test_files_open});defer resolver_destroy(&other)
    testing.expect_value(t,resolver_check(&other,{0xc,0xc}).state,Resolve_State.Missing)
    testing.expect(t,!resolver_instance_stale(&other,resolved.instances[0]))
}

// Reading the view of an open scene again, as every spawn of a prefab does,
// takes no more of the memory of the asset.
@(test)
a_scene_view_read_again_takes_no_more_memory :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    scene:Scene;scene_init(&scene,&types,KIND_PREFAB,{0x5,0x5})
    scene_entity_add(&scene,1,0,"lamp")
    light:=Test_Light{{1,0,0},2,10}
    scene_set(&scene,1,LIGHT,&light)
    w:serial.Writer;serial.writer_init(&w);defer serial.writer_destroy(&w)
    testing.expect_value(t,scene_write(&scene,&w),Error.None)
    scene_destroy(&scene)

    a:Asset
    if !testing.expect_value(t,asset_open(&a,serial.writer_bytes(&w)),Error.None) {return}
    defer asset_close(&a)
    first,error:=scene_view(&a,&types)
    if !testing.expect_value(t,error,Error.None) {return}
    owned:=len(a.owned)
    for _ in 0..<4 {
        again,again_error:=scene_view(&a,&types)
        testing.expect_value(t,again_error,Error.None)
        testing.expect_value(t,len(again.components),len(first.components))
    }
    testing.expect_value(t,len(a.owned),owned)
}

// What scenes and documents ask their allocator for, with the memory ending
// at each request in turn: the call fails whole with Out_Of_Memory, and with
// memory enough it goes through.
@(test)
scene_calls_without_memory_fail_whole :: proc(t:^testing.T) {
    failure:=Type_Allocation_Failure{owner=context.allocator,remaining=max(int)}
    limited:=runtime.Allocator{type_failure_allocator,&failure}
    types:Types;types_init(&types);defer types_destroy(&types)
    prefab:Scene;lamp_prefab(&prefab,&types,1,{1,0,0});defer scene_destroy(&prefab)
    out:serial.Writer;serial.writer_init(&out);defer serial.writer_destroy(&out)
    if !testing.expect_value(t,scene_write(&prefab,&out),Error.None) {return}
    file:Asset
    if !testing.expect_value(t,asset_open(&file,serial.writer_bytes(&out)),Error.None) {return}
    defer asset_close(&file)
    view,view_error:=scene_view(&file,&types)
    if !testing.expect_value(t,view_error,Error.None) {return}
    Call :: enum {View_Check,Instantiate,Set,Remove,Diff,From_Asset}
    for call in Call {
        scene:Scene
        if !testing.expect_value(t,scene_init(&scene,&types,KIND_SCENE,{0xb,0xb},limited),Error.None) {return}
        defer scene_destroy(&scene)
        _,root,placed:=scene_instantiate(&scene,&prefab,{0xa,0xa},0)
        if !testing.expect_value(t,placed,Error.None) {return}
        before:=scene_entity_count(&scene)
        done,refused:=false,false
        for served in 0..<512 {
            error:Error
            failure.remaining=served
            switch call {
            case .View_Check:
                error=scene_view_check(view,limited)
            case .Instantiate:
                _,_,error=scene_instantiate(&scene,&prefab,{0xa,0xa},0)
            case .Set:
                value:=transform(9,9,9)
                error=scene_set(&scene,root,"Transform",&value)
            case .Remove:
                _,error=scene_entities_remove(&scene,{root})
            case .Diff:
                w:serial.Writer;serial.writer_init(&w)
                _,error=document_diff(&scene.doc,&prefab.doc,&w)
                serial.writer_destroy(&w)
            case .From_Asset:
                doc:Document
                if error=document_from_asset(&doc,&file,limited);error==.None {document_destroy(&doc)}
            }
            failure.remaining=max(int)
            if done=error==.None;done {break}
            refused=true
            if !testing.expectf(t,error==.Out_Of_Memory,"%v with %d requests served: %v",call,served,error) {break}
            if call!=.Remove && call!=.Instantiate {continue}
            testing.expectf(t,scene_entity_count(&scene)==before,"%v with %d requests served: %d entities, %d before",call,served,scene_entity_count(&scene),before)
        }
        // Removing asks the document for nothing: it is what takes back a call that failed.
        testing.expectf(t,done && refused==(call!=.Remove),"%v: refused without memory, and with it it goes through",call)
    }
}

