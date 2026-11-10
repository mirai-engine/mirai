package editor

import "core:testing"
import "mirai:core"
import "mirai:editor/history"
import erender "mirai:engine/render"
import "mirai:host"
import mm "mirai:std/math"

@(private)
Authoring_Context_Component :: struct {value:int}

@(private)
Authoring_Context_Derived :: struct {value:int `mirai:"transient"`}

@(private)
Authoring_Context_World :: struct {
    using world:core.Test_World,
    using scene_tables:Test_Scene,
    poses:core.Table(core.World_Transform),
    meshes:core.Table(erender.Mesh_Renderer),
    authored:core.Table(Authoring_Context_Component) `mirai:"name=Authored"`,
    derived:core.Table(Authoring_Context_Derived) `mirai:"name=Derived"`,
}

@(test)
hierarchy_and_ai_context_keep_authors_with_the_bounds_of_their_derived_geometry :: proc(t:^testing.T) {
    world:Authoring_Context_World
    if !core.test_world_init(t,&world,test_types) {return}
    defer core.test_world_destroy(&world)
    info:=core.test_world_info(&world)
    ref:=core.test_world_ref(&world)
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
    core.test_world_settle(&world)
    testing.expect_value(t,len(entity_children(ref,owner)),4)
    children:=hierarchy_children(ref,owner)
    testing.expect(t,len(children)==1 && children[0]==authored_child,"Hierarchy preserves editable children and omits derived nodes")
    viewport:=Viewport{size={800,600},show_indicators=false}
    viewport.view_matrix=mm.look_at({0,0,10},{},{0,1,0})
    viewport.projection=mm.perspective(50*mm.RAD_PER_DEG,800.0/600,0.1,100)
    viewport.view_projection=viewport.projection*viewport.view_matrix
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root="assets",capacity=4})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets}
    session:=Session{info=info,edit_world=&world,app=&app,viewport=&viewport}
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
    edits:history.Edits
    selection:history.Selection
    document:Document
    session.edits,session.selection,session.document=&edits,&selection,&document
    defer delete(selection.entities)
    history.selection_set(&selection,{authored_child})
    entities=ai_entities_gather(&session,&task)
    testing.expect(t,len(entities)==2 && task.entities_total==1,"selected authors are included even without visible geometry")
    testing.expect_value(t,entities[0].id,ai_entity_id_text(ref,authored_child))
    testing.expect(t,!entities[0].inside)
    history.selection_clear(&selection)
    entities=ai_entities_gather(&session,&task)
    testing.expect(t,len(entities)==1 && entities[0].id==ai_entity_id_text(ref,owner),"deselection removes its automatic AI context")
    defer history.edits_free(&edits)
    history.edits_reset(&edits,ref)
    late_chunk:=core.create(&world.entities)
    core.add(&world.parents,late_chunk,{entity=owner})
    core.add(&world.transforms,late_chunk,core.TRANSFORM_IDENTITY)
    core.add(&world.meshes,late_chunk,{shape=.Cube})
    core.test_world_settle(&world)
    history.edits_cancel(&edits,ref)
    testing.expect(t,core.alive(&world.entities,late_chunk) && core.has(&world.meshes,late_chunk),"cancel without a gesture preserves derived entities added after history reset")
    copies:=entities_duplicate(&session,{owner})
    testing.expect_value(t,len(copies),1)
    testing.expect(t,world.entities.alive==9,"only the author and its authored child are duplicated")
    testing.expect(t,history.edits_commit(&edits,ref,&selection))
    history.edits_begin(&edits,&selection,"Terrain source")
    core.get(&world.authored,owner).value=43
    core.get(&world.meshes,left).shape=.Sphere
    history.edits_end(&edits)
    testing.expect(t,history.edits_commit(&edits,ref,&selection))
    testing.expect(t,history.undo(&edits,ref,&selection))
    authored,_:=core.get(core.read(&world.authored),owner)
    derived,_:=core.get(core.read(&world.meshes),left)
    testing.expect_value(t,authored.value,42)
    testing.expect_value(t,derived.shape,erender.Shape.Sphere)
    testing.expect(t,history.redo(&edits,ref,&selection))
    entities_delete(&session,{authored_child})
    testing.expect(t,history.edits_commit(&edits,ref,&selection))
    testing.expect(t,history.undo(&edits,ref,&selection))
    testing.expect(t,core.alive(&world.entities,authored_child) && core.has(&world.ids,authored_child) && core.has(&world.transforms,authored_child),"undo restores deleted authors from the previous Id table")
    entities_delete(&session,{owner})
    testing.expect(t,history.edits_commit(&edits,ref,&selection))
    testing.expect(t,history.undo(&edits,ref,&selection))
    testing.expect_value(t,world.entities.alive,5)
    testing.expect(t,core.has(&world.ids,owner) && core.has(&world.ids,authored_child) && !core.alive(&world.entities,left),"structural undo restores authors without leaving empty derived handles alive")
    // A restoration turns entities: what it brought back keeps what holds it.
    transforms:core.Seen
    _=core.changes(&world.transforms,&transforms)
    orphan:=core.create(&world.entities)
    core.add(&world.poses,orphan,{})
    opaque:=core.create(&world.entities)
    core.add(&world.derived,opaque,{value=7})
    core.test_world_settle(&world)
    marks:=make([]u8,len(world.entities.generation),context.temp_allocator)
    marks[core.entity_index(orphan)]=history.ENTITY_TURNED
    marks[core.entity_index(opaque)]=history.ENTITY_TURNED
    history.world_turned_prune(ref,marks,len(marks),transforms)
    testing.expect(t,!core.alive(&world.entities,orphan),"an obsolete world transform does not keep an orphan handle alive after restoration")
    testing.expect(t,core.alive(&world.entities,opaque) && core.has(&world.derived,opaque),"valid transient-only data is retained by its owner")
    testing.expect_value(t,world.entities.alive,6)
    for mark in marks {testing.expect_value(t,mark,u8(0))}
}
