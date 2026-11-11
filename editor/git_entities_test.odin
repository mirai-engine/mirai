package editor

import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/history"
import "mirai:std/base"

@(private="file")
git_entities_test_row :: proc(n:^Git_Entities,name:string) -> (row:Git_Entity,found:bool) {
    for entity in n.rows {
        entity:=entity
        if base.text_get(entity.name[:])==name {return entity,true}
    }
    return {},false
}

// The entities of the document against what git keeps of its scene: those
// added, changed and removed, under those they hang from; reverting a node
// puts it back as kept with what hangs from it, as one step undo takes back.
@(test)
the_entities_that_differ_from_what_git_keeps_revert_by_subtree :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    if !testing.expect(t,prefab_fixture_init(t,f,"git-entities")) {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    g:=new(Git)
    s.git=g
    defer {
        git_entities_free(&g.entities)
        free(g)
    }
    castle:=entity_create(s,{name="Castle",named=true})
    core.world_settle(w)
    tower:=entity_create(s,{name="Tower",named=true,parent=castle})
    rock:=entity_create(s,{name="Rock",named=true})
    core.world_settle(w)
    prefab_fixture_step(f)
    castle_id,tower_id,rock_id:=api_entity_id(w,castle),api_entity_id(w,tower),api_entity_id(w,rock)
    if !testing.expect_value(t,test_document_write(s,"level.scene"),Document_Error.None) {return}

    // What the file holds now is what git keeps.
    n:=&g.entities
    base.text_set(g.root[:],f.root)
    base.text_set(n.path[:],"level.scene")
    n.kept=new(asset.Scene)
    if !testing.expect_value(t,asset.scene_load(n.kept,&f.assets.types,document_file(s.document)),asset.Error.None) {return}
    n.read=true
    git_entities_compute(s)
    testing.expect_value(t,len(n.rows),0)

    testing.expect(t,entity_rename(s,tower,"Keep"))
    flag:=entity_create(s,{name="Flag",named=true,parent=castle})
    entities_delete(s,{rock})
    core.world_settle(w)
    prefab_fixture_step(f)
    flag_id:=api_entity_id(w,flag)
    git_entities_update(s)
    Expected :: struct {name:string,change:Git_Entity_Change,depth:int}
    for want in ([]Expected{{"Castle",.Same,0},{"Keep",.Changed,1},{"Flag",.Added,1},{"Rock",.Removed,0}}) {
        row,found:=git_entities_test_row(n,want.name)
        testing.expectf(t,found && row.change==want.change && row.depth==want.depth,"%s is %v at depth %d: %v",want.name,want.change,want.depth,row)
    }
    testing.expect_value(t,len(n.rows),4)

    // The castle goes back with what hangs from it; the rock stays removed.
    steps:=len(f.edits.steps)
    reverted,message:=git_entities_revert(s,{castle_id},true)
    testing.expect_value(t,message,"")
    testing.expect_value(t,reverted,2)
    prefab_fixture_step(f)
    testing.expect_value(t,len(f.edits.steps),steps+1)
    testing.expect_value(t,entity_name(w,api_entity(w,tower_id)),"Tower")
    testing.expect(t,api_entity(w,flag_id)==core.NONE && api_entity(w,rock_id)==core.NONE)
    git_entities_update(s)
    testing.expect(t,len(n.rows)==1 && n.rows[0].id==rock_id)

    // A removed entity comes back with its id, and undo takes that back.
    reverted,message=git_entities_revert(s,{rock_id},true)
    testing.expect(t,message=="" && reverted==1)
    prefab_fixture_step(f)
    back:=api_entity(w,rock_id)
    testing.expect(t,back!=core.NONE && entity_name(w,back)=="Rock")
    git_entities_update(s)
    testing.expect_value(t,len(n.rows),0)
    testing.expect(t,history.undo(&f.edits,w,&f.selection))
    testing.expect(t,api_entity(w,rock_id)==core.NONE)

    _,message=git_entities_revert(s,{castle_id},true)
    testing.expect(t,message!="","an entity that is as kept has nothing to revert")
}
