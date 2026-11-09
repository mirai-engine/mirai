package editor

import "core:strings"
import "core:testing"
import "mirai:cook/build"
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

// What git merges row by row and what Initialize writes of a plugin follow one
// fact per kind: the table of the engine and what each plugin declares.
@(test)
git_merges_the_document_kinds_of_the_engine_and_of_the_plugins :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    s:Session
    s.providers.library=s.library_generation+1
    s.providers.kinds[0]={label="Particle",extension=".particle",merged=true}
    s.providers.kinds[1]={label="Grid state",extension=".grid"}
    s.providers.kind_count=2
    cases:=[]struct {path:string,merged:bool}{
        {"assets/arena/main.scene",true},{"assets/leaf.mat",true},{"assets/rows.records",true},
        {"assets/plant.mesh",false},{"assets/hum.sound",false},{"assets/hum.sound_set",true},
        {"assets/fx/smoke.particle",true},{"assets/fx/smoke.grid",false},{"game/main.odin",false},
    }
    for c in cases {testing.expectf(t,git_merges_entities(&s,c.path)==c.merged,"%s",c.path)}
    text,_:=build.git_attributes(git_plugin_kinds(&s))
    testing.expect(t,strings.contains(text,"*.particle merge="+build.GIT_DRIVER) && strings.contains(text,"*.grid binary"),text)
}
