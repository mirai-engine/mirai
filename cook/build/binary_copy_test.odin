package build

import "core:mem/virtual"
import "core:os"
import "core:testing"
import "mirai:project"
import "mirai:std/base"

@(test)
binary_copy_replaces_the_file_and_keeps_the_old_mapping :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"binary-copy")
    if folder=="" {return}
    a:=context.temp_allocator
    published:=project.path(folder,"published.bin",allocator=a)
    source:=project.path(folder,"source.bin",allocator=a)
    if !testing.expect(t,os.write_entire_file(published,"old binary")==nil) {return}
    if !testing.expect(t,os.write_entire_file(source,"new binary")==nil) {return}
    old,stat_error:=binary_copy_info(published)
    if !testing.expect(t,stat_error==nil && old.inode!=0) {return}
    held,map_error:=virtual.map_file(published,{.Read})
    if !testing.expect(t,map_error==nil && raw_data(held)!=nil) {return}
    defer virtual.unmap_file(held)
    if !testing.expect(t,copy_binary(published,source)) {return}
    current,current_error:=binary_copy_info(published)
    if !testing.expect(t,current_error==nil) {return}
    testing.expect(t,current.inode!=old.inode)
    testing.expect_value(t,string(held),"old binary")

    blocked:=project.path(folder,"directory",allocator=a)
    if !testing.expect(t,os.make_directory(blocked)==nil) {return}
    before,before_error:=os.read_all_directory_by_path(folder,a)
    if !testing.expect(t,before_error==nil) {return}
    testing.expect(t,!copy_binary(published,project.path(folder,"missing",allocator=a)))
    testing.expect(t,!copy_binary(blocked,source))
    after,after_error:=os.read_all_directory_by_path(folder,a)
    testing.expect(t,after_error==nil && len(after)==len(before) && os.is_dir(blocked))
    contents,read_error:=os.read_entire_file(published,a)
    testing.expect(t,read_error==nil)
    testing.expect_value(t,string(contents),"new binary")
    remaining,remaining_error:=binary_copy_info(published)
    testing.expect(t,remaining_error==nil && remaining.inode==current.inode)
}

binary_copy_info :: proc(path:string) -> (os.File_Info,os.Error) {
    file,error:=os.open(path)
    if error!=nil {return {},error}
    defer os.close(file)
    return os.fstat(file,context.temp_allocator)
}
