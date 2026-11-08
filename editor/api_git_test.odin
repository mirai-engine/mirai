package editor

import "core:testing"
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
