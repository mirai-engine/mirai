package main

import "core:os"
import "core:testing"
import "mirai:std/base"

@(test)
a_new_checkout_gets_the_ignored_folders_the_main_one_lists :: proc(t:^testing.T) {
    root:=base.test_folder(t,"worktree-files")
    if root=="" {return}
    shared,folder:=join(root,"shared"),join(root,"new")
    for path in ([]string{join(shared,".mirai"),join(shared,"private/pkg"),join(shared,"tracked"),folder}) {
        if !testing.expect(t,os.make_directory_all(path)==nil) {return}
    }
    files:=[?][2]string{
        {join(shared,".mirai/worktree-files"),"private/pkg\n\ntracked\n"},
        {join(shared,"private/pkg/a.odin"),"package pkg\n"},
        {join(shared,"tracked/b.odin"),"package tracked\n"},
        {join(folder,".gitignore"),"/private/*\n"},
    }
    for file in files {
        if !testing.expect(t,os.write_entire_file(file[0],file[1])==nil) {return}
    }
    if _,made:=render_git(folder,"init","--quiet");!testing.expect(t,made) {return}
    worktree_files_copy(shared,folder)
    testing.expect(t,os.is_file(join(folder,"private/pkg/a.odin")),"what git ignores comes from the main checkout")
    testing.expect(t,!os.exists(join(folder,"tracked")),"what git keeps is that of its commit")
}
