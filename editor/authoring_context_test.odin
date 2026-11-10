package editor

import "core:testing"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import mm "mirai:std/math"

@(private)
Authoring_Context_Component :: struct {value:int}

@(private)
Authoring_Context_Derived :: struct {value:int `mirai:"transient"`}

@(private)
Authoring_Context_World :: struct {
    entities:core.Entities,
    ids:core.Table(core.Id),
    names:core.Table(core.Name),
    transforms:core.Table(core.Transform),
    poses:core.Table(core.World_Transform),
    parents:core.Table(core.Parent),
    meshes:core.Table(erender.Mesh_Renderer),
    authored:core.Table(Authoring_Context_Component),
    derived:core.Table(Authoring_Context_Derived),
    hierarchy:core.Hierarchy,
}

@(private)
authoring_context_settle :: proc(data,shared,editor:rawptr) {
    w:=cast(^Authoring_Context_World)data
    core.table_settle(&w.ids,&w.entities);core.table_settle(&w.names,&w.entities)
    core.table_settle(&w.transforms,&w.entities);core.table_settle(&w.parents,&w.entities)
    core.hierarchy_settle(&w.hierarchy,core.read(&w.parents),&w.entities)
    core.table_settle(&w.poses,&w.entities)
    core.table_settle(&w.meshes,&w.entities);core.table_settle(&w.authored,&w.entities)
    core.table_settle(&w.derived,&w.entities)
    core.entities_settle(&w.entities)
}

@(test)
hierarchy_and_ai_context_keep_authors_with_the_bounds_of_their_derived_geometry :: proc(t:^testing.T) {
    world:Authoring_Context_World
    core.entities_init(&world.entities)
    defer core.entities_destroy(&world.entities)
    core.table_init(&world.ids,"Id");core.table_init(&world.names,"Name")
    core.table_init(&world.transforms,"Transform");core.table_init(&world.parents,"Parent")
    core.table_init(&world.poses,"World_Transform")
    core.table_init(&world.meshes,"Mesh_Renderer");core.table_init(&world.authored,"Authored")
    core.table_init(&world.derived,"Derived")
    defer core.table_destroy(&world.ids);defer core.table_destroy(&world.names)
    defer core.table_destroy(&world.transforms);defer core.table_destroy(&world.parents)
    defer core.table_destroy(&world.poses)
    defer core.table_destroy(&world.meshes);defer core.table_destroy(&world.authored)
    defer core.table_destroy(&world.derived)
    defer core.value_free(&world.hierarchy,type_info_of(core.Hierarchy))
    tables:=[8]core.Table_Info{
        {name="Id",type=core.Id,info=type_info_of(core.Id),offset=offset_of(Authoring_Context_World,ids)},
        {name="Name",type=core.Name,info=type_info_of(core.Name),offset=offset_of(Authoring_Context_World,names)},
        {name="Transform",type=core.Transform,info=type_info_of(core.Transform),offset=offset_of(Authoring_Context_World,transforms)},
        {name="World_Transform",type=core.World_Transform,info=type_info_of(core.World_Transform),offset=offset_of(Authoring_Context_World,poses)},
        {name="Parent",type=core.Parent,info=type_info_of(core.Parent),offset=offset_of(Authoring_Context_World,parents)},
        {name="Mesh_Renderer",type=erender.Mesh_Renderer,info=type_info_of(erender.Mesh_Renderer),offset=offset_of(Authoring_Context_World,meshes)},
        {name="Authored",type=Authoring_Context_Component,info=type_info_of(Authoring_Context_Component),offset=offset_of(Authoring_Context_World,authored)},
        {name="Derived",type=Authoring_Context_Derived,info=type_info_of(Authoring_Context_Derived),offset=offset_of(Authoring_Context_World,derived)},
    }
    storages:=[1]core.Storage_Info{{type=core.Hierarchy,info=type_info_of(core.Hierarchy),offset=offset_of(Authoring_Context_World,hierarchy)}}
    info:=core.World_Info{entities=offset_of(Authoring_Context_World,entities),tables=tables[:],storages=storages[:]}
    ref:=core.world_ref(&world,&info)
    parent,owner:=core.create(&world.entities),core.create(&world.entities)
    left,right,empty,authored_child:=core.create(&world.entities),core.create(&world.entities),core.create(&world.entities),core.create(&world.entities)
    core.add(&world.ids,parent,{value=1});core.add(&world.ids,owner,{value=2});core.add(&world.ids,authored_child,{value=3})
    core.add(&world.names,owner,core.name_make("Terrain author"))
    core.add(&world.names,left,core.name_make("Internal left"));core.add(&world.names,right,core.name_make("Internal right"))
    core.add(&world.transforms,parent,{position={0.25,0,0},rotation=1,scale={1,1,1}})
    core.add(&world.transforms,owner,{position={0.5,0,0},rotation=1,scale={1,1,1}})
    core.add(&world.transforms,left,{position={-2,0,0},rotation=1,scale={1,1,1}})
    core.add(&world.transforms,right,{position={2,0,0},rotation=1,scale={1,1,1}})
    core.add(&world.transforms,empty,core.TRANSFORM_IDENTITY)
    core.add(&world.transforms,authored_child,{position={0,8,0},rotation=1,scale={1,1,1}})
    core.add(&world.parents,owner,{entity=parent})
    for e in ([4]core.Entity{left,right,empty,authored_child}) {core.add(&world.parents,e,{entity=owner})}
    for e in ([2]core.Entity{left,right}) {core.add(&world.meshes,e,{shape=.Cube})}
    core.add(&world.authored,owner,{value=42})
    core.table_settle(&world.ids,&world.entities);core.table_settle(&world.names,&world.entities)
    core.table_settle(&world.transforms,&world.entities);core.table_settle(&world.parents,&world.entities)
    core.hierarchy_settle(&world.hierarchy,core.read(&world.parents),&world.entities)
    core.table_settle(&world.meshes,&world.entities);core.table_settle(&world.authored,&world.entities)
    testing.expect_value(t,len(entity_children(ref,owner)),4)
    children:=hierarchy_children(ref,owner)
    testing.expect(t,len(children)==1 && children[0]==authored_child,"Hierarchy preserves editable children and omits derived nodes")
    viewport:=Viewport{size={800,600},show_indicators=false}
    viewport.view_matrix=mm.look_at({0,0,10},{},{0,1,0})
    viewport.projection=mm.perspective(50*mm.RAD_PER_DEG,800.0/600,0.1,100)
    viewport.view_projection=viewport.projection*viewport.view_matrix
    picker:Picker
    defer picker_clear(&picker);defer delete(picker.meshes)
    app:host.App
    session:=Session{info=&info,edit_world=&world,app=&app,viewport=&viewport,picker=&picker}
    task:=Ai_Task{region={0,0,800,600}}
    entities:=ai_entities_gather(&session,&task)
    if !testing.expect(t,len(entities)==1 && task.entities_total==1,"two visible chunks produce one author") {return}
    entity:=entities[0]
    testing.expect_value(t,entity.id,ai_entity_id_text(ref,owner))
    testing.expect(t,entity.id!="" && entity.name=="Terrain author")
    testing.expect_value(t,entity.parent,ai_entity_id_text(ref,parent))
    testing.expect_value(t,entity.position,[3]f32{0.75,0,0})
    testing.expect(t,!entity.indicator && entity.inside && entity.rect.x<300 && entity.rect.x+entity.rect.z>500)
    testing.expect(t,len(entity.components)==1 && entity.components[0]=="Authored","metadata comes from the author, not its generated chunks")
    task.region={0,0,400,600}
    entities=ai_entities_gather(&session,&task)
    testing.expect(t,len(entities)==1 && !entities[0].inside && task.entities_total==1,"partial regions keep the complete visual bounds of their author")
    edits:Edits
    selection:Selection
    document:Document
    session.edits,session.selection,session.document=&edits,&selection,&document
    defer delete(selection.entities)
    selection_set(&selection,{authored_child})
    entities=ai_entities_gather(&session,&task)
    testing.expect(t,len(entities)==2 && task.entities_total==1,"selected authors are included even without visible geometry")
    testing.expect_value(t,entities[0].id,ai_entity_id_text(ref,authored_child))
    testing.expect(t,!entities[0].inside)
    selection_clear(&selection)
    entities=ai_entities_gather(&session,&task)
    testing.expect(t,len(entities)==1 && entities[0].id==ai_entity_id_text(ref,owner),"deselection removes its automatic AI context")
    defer edits_free(&edits)
    edits_reset(&edits,ref)
    late_chunk:=core.create(&world.entities)
    core.add(&world.parents,late_chunk,{entity=owner})
    core.add(&world.transforms,late_chunk,core.TRANSFORM_IDENTITY)
    core.add(&world.meshes,late_chunk,{shape=.Cube})
    authoring_context_settle(&world,nil,nil)
    edits_cancel(&edits,ref)
    testing.expect(t,core.alive(&world.entities,late_chunk) && core.has(&world.meshes,late_chunk),"cancel without a gesture preserves derived entities added after history reset")
    copies:=entities_duplicate(&session,{owner})
    testing.expect_value(t,len(copies),1)
    testing.expect(t,world.entities.alive==9,"only the author and its authored child are duplicated")
    testing.expect(t,edits_commit(&edits,ref,&selection))
    edits_begin(&edits,&selection,"Terrain source")
    core.get(&world.authored,owner).value=43
    core.get(&world.meshes,left).shape=.Sphere
    edits_end(&edits)
    testing.expect(t,edits_commit(&edits,ref,&selection))
    testing.expect(t,undo(&edits,ref,&selection))
    authored,_:=core.get(core.read(&world.authored),owner)
    derived,_:=core.get(core.read(&world.meshes),left)
    testing.expect_value(t,authored.value,42)
    testing.expect_value(t,derived.shape,erender.Shape.Sphere)
    testing.expect(t,redo(&edits,ref,&selection))
    entities_delete(&session,{authored_child})
    testing.expect(t,edits_commit(&edits,ref,&selection))
    testing.expect(t,undo(&edits,ref,&selection))
    testing.expect(t,core.alive(&world.entities,authored_child) && core.has(&world.ids,authored_child) && core.has(&world.transforms,authored_child),"undo restores deleted authors from the previous Id table")
    entities_delete(&session,{owner})
    testing.expect(t,edits_commit(&edits,ref,&selection))
    testing.expect(t,undo(&edits,ref,&selection))
    testing.expect_value(t,world.entities.alive,5)
    testing.expect(t,core.has(&world.ids,owner) && core.has(&world.ids,authored_child) && !core.alive(&world.entities,left),"structural undo restores authors without leaving empty derived handles alive")
    // A restoration turns entities: what it brought back keeps what holds it.
    transforms:core.Seen
    _=core.changes(&world.transforms,&transforms)
    orphan:=core.create(&world.entities)
    core.add(&world.poses,orphan,{})
    opaque:=core.create(&world.entities)
    core.add(&world.derived,opaque,{value=7})
    authoring_context_settle(&world,nil,nil)
    marks:=make([]u8,len(world.entities.generation),context.temp_allocator)
    marks[core.entity_index(orphan)]=ENTITY_TURNED
    marks[core.entity_index(opaque)]=ENTITY_TURNED
    world_turned_prune(ref,marks,len(marks),transforms)
    testing.expect(t,!core.alive(&world.entities,orphan),"an obsolete world transform does not keep an orphan handle alive after restoration")
    testing.expect(t,core.alive(&world.entities,opaque) && core.has(&world.derived,opaque),"valid transient-only data is retained by its owner")
    testing.expect_value(t,world.entities.alive,6)
    for mark in marks {testing.expect_value(t,mark,u8(0))}
}
