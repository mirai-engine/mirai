#+build windows
package host

import "core:os"
import "core:testing"
import "mirai:project"
import "mirai:std/base"

@(test)
a_library_loads_again_while_its_first_copy_is_loaded :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"host-library-twice")
    if folder=="" {return}
    path:=project.path(folder,"twice.dll",allocator=context.temp_allocator)
    if !testing.expect_value(t,os.copy_file(path,"C:/Windows/System32/version.dll"),nil) {return}
    first,second:Project_Library
    defer project_library_unload(&first,context.temp_allocator)
    defer project_library_unload(&second,context.temp_allocator)
    error:Library_Error
    first.handle,first.copy,error=library_copy_load(path,context.temp_allocator)
    if !testing.expect_value(t,error,Library_Error.None) {return}
    second.handle,second.copy,error=library_copy_load(path,context.temp_allocator)
    testing.expect_value(t,error,Library_Error.None)
    testing.expect(t,first.copy!=second.copy)
}
