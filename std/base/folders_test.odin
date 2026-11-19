package base

import "core:fmt"
import "core:os"
import "core:testing"

@(test)
a_folder_is_made_and_filled_by_a_copy_also_when_it_is_already_there :: proc(t:^testing.T) {
    root:=test_folder(t,"folders")
    if root=="" {return}
    at :: proc(root,name:string) -> string {return fmt.tprintf("%s/%s",root,name)}
    source:=at(root,"source")
    for path in ([]string{at(source,"inner"),at(source,"inner"),source,root}) {
        testing.expectf(t,make_directory_all(path)==nil,"%q",path)
    }
    for name in ([]string{"top.txt","inner/below.txt"}) {
        testing.expect(t,os.write_entire_file(at(source,name),transmute([]u8)string(name))==nil)
    }
    testing.expect(t,make_directory_all(at(source,"top.txt"))!=nil,"a file is not a folder")
    testing.expect(t,make_directory_all(at(source,"top.txt/below"))!=nil,"nor is what is below a file")
    there:=at(root,"there")
    testing.expect(t,os.make_directory(there)==nil)
    for target in ([]string{at(root,"new/deep"),there}) {
        testing.expectf(t,copy_directory_all(target,source)==nil,"%q",target)
        for name in ([]string{"top.txt","inner/below.txt"}) {
            data,_:=os.read_entire_file(at(target,name),context.temp_allocator)
            testing.expectf(t,string(data)==name,"%s holds %s",target,name)
        }
        testing.expectf(t,!os.exists(at(target,"source")),"%s holds what is in the source, not the source",target)
    }
}
