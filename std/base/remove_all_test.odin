package base

import "core:fmt"
import "core:os"
import "core:testing"

@(test)
remove_all_takes_a_path_with_everything_under_it_and_nothing_a_link_points_to :: proc(t:^testing.T) {
    root:=test_folder(t,"remove-all")
    if root=="" {return}
    at :: proc(root,name:string) -> string {return fmt.tprintf("%s/%s",root,name)}
    outside:=at(root,"outside")
    testing.expect(t,os.make_directory_all(at(outside,"inner"))==nil)
    testing.expect(t,os.write_entire_file(at(outside,"inner/kept.txt"),transmute([]u8)string("kept"))==nil)
    tree:=at(root,"tree")
    testing.expect(t,os.make_directory_all(at(tree,"a/b/c"))==nil)
    for name in ([]string{"top.txt","a/one.txt","a/b/two.txt","a/b/c/three.txt"}) {
        testing.expect(t,os.write_entire_file(at(tree,name),transmute([]u8)string(name))==nil)
    }
    testing.expect(t,os.change_mode(at(tree,"a/b/two.txt"),{.Read_User})==nil,"a read-only file goes too")
    // A link may need a privilege the system does not give; without one the case is left out.
    linked:=os.symlink(outside,at(tree,"a/link"))==nil
    file:=at(root,"file.txt")
    testing.expect(t,os.write_entire_file(file,transmute([]u8)string("file"))==nil)
    cases:=[]struct {path:string,gone:bool} {
        {"",false},
        {at(root,"never-made"),true},
        {at(root,"never-made/below"),true},
        {file,true},
        {tree,true},
    }
    for c in cases {
        testing.expectf(t,remove_all(c.path)==nil,"%q",c.path)
        if c.gone {testing.expectf(t,!os.exists(c.path),"%q is gone",c.path)}
    }
    testing.expect(t,os.is_dir(root),"what is beside it stays")
    if linked {testing.expect(t,os.is_file(at(outside,"inner/kept.txt")),"what a link points to stays")}
}
