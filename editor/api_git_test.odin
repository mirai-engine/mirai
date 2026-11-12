package editor

import "core:testing"
import "mirai:cook/build"
import "mirai:editor/git"
import "mirai:project"
import "mirai:std/base"

// A merge's conflicts are named by their file, from the project or the root
// of the repository, and their path in it.
@(test)
git_conflicts_go_by_file_and_path :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    g:=new(Git)
    base.text_set(g.prefix[:],"game/")
    a,b:Git_Merge_File
    base.text_set(a.path[:],"game/assets/a.scene")
    base.text_set(b.path[:],"game/assets/b.scene")
    append(&g.merge.files,a,b)
    append(&g.merge.items,Git_Merge_Item{file=0,first=0,count=1},Git_Merge_Item{file=1,first=1,count=2})
    conflicts:[3]Git_Conflict
    base.text_set(conflicts[0].path[:],"Transform[1].position")
    base.text_set(conflicts[1].path[:],"Transform[1].position")
    base.text_set(conflicts[2].path[:],"Material[2].color")
    append(&g.merge.conflicts,..conflicts[:])
    testing.expect(t,api_git_file_merging(g,"assets/a.scene") && api_git_file_merging(g,"game/assets/a.scene"))
    testing.expect(t,!api_git_file_merging(g,"assets/c.scene") && !api_git_file_merging(g,""))
    testing.expect_value(t,api_git_conflict_at(g,"assets/b.scene","Transform[1].position"),1)
    testing.expect_value(t,api_git_conflict_at(g,"assets/b.scene","Material[2].color"),2)
    testing.expect_value(t,api_git_conflict_at(g,"assets/a.scene","Material[2].color"),-1)
    testing.expect_value(t,api_git_item_of(g,"game/assets/b.scene").first,1)
}

// What git merges row by row follows one fact per kind: the table of the
// engine and what the manifest of each plugin declares.
@(test)
git_merges_the_document_kinds_of_the_engine_and_of_the_plugins :: proc(t:^testing.T) {
    plugins:=[]build.Git_Kind{{".particle",true,false},{".grid",false,false}}
    cases:=[]struct {path:string,merged:bool}{
        {"assets/arena/main.scene",true},{"assets/leaf.mat",true},{"assets/rows.records",true},
        {"assets/plant.mesh",false},{"assets/hum.sound",false},{"assets/hum.sound_set",true},
        {"assets/fx/smoke.particle",true},{"assets/fx/smoke.grid",false},{"game/main.odin",false},
    }
    for c in cases {testing.expectf(t,git_merges_entities(plugins,c.path)==c.merged,"%s",c.path)}
}


// A file is pending as git last said of its path from the root of the
// repository, and a project in no repository edits nothing.
@(test)
git_says_what_is_pending_and_a_project_without_repository_edits_nothing :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    g:=new(Git)
    s:=Session{git=g,has_project=true}
    testing.expect_value(t,git_missing(&s),"")
    g.checked,g.available=true,true
    testing.expect(t,git_missing(&s)!="","git answered and the project is in no repository")
    g.repository=true
    testing.expect_value(t,git_missing(&s),"")
    s.has_project=false
    g.repository=false
    testing.expect_value(t,git_missing(&s),"")

    base.text_set(g.root[:],"C:/work/repo")
    pending,kept:git.Change
    base.text_set(pending.path[:],"game/assets/a.scene")
    pending.pending=true
    base.text_set(kept.path[:],"game/assets/b.mat")
    kept.kept=true
    append(&g.changes,pending,kept)
    testing.expect_value(t,git_path(&s,"C:/work/repo/game/assets/a.scene"),"game/assets/a.scene")
    testing.expect_value(t,git_path(&s,"C:/work/other/a.scene"),"")
    testing.expect(t,git_pending(&s,"C:/work/repo/game/assets/a.scene"))
    testing.expect(t,!git_pending(&s,"C:/work/repo/game/assets/b.mat"),"what is kept is not pending")
    testing.expect(t,!git_pending(&s,"") && !git_pending(&s,"C:/work/repo/game/assets/c.scene"))
    testing.expect_value(t,git_pending_count(&s),1)
}
