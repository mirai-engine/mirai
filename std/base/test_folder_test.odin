package base

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// A folder of its own for a test that writes files, in the temporary folder
// of the system: its absolute path, with forward slashes, in the temp
// allocator. It goes, with what it holds, when the test ends, also when the
// test freed the temp allocator. "" with the test failed when it cannot be made.
test_folder :: proc(t:^testing.T,name:string,loc:=#caller_location) -> string {
    made,error:=os.make_directory_temp("",fmt.tprintf("mirai-%s-*",name),context.temp_allocator)
    if !testing.expect(t,error==nil,"the folder of the test could not be made",loc=loc) {return ""}
    if absolute,absolute_error:=os.get_absolute_path(made,context.temp_allocator);absolute_error==nil {made=absolute}
    folder,_:=strings.replace_all(made,"\\","/",context.temp_allocator)
    folder=strings.trim_right(folder,"/")
    Kept :: struct {folder:string,allocator:runtime.Allocator}
    kept,kept_error:=new(Kept)
    if !testing.expect(t,kept_error==nil,"no memory for the folder of the test",loc=loc) {
        os.remove_all(folder)
        return ""
    }
    kept.folder,kept.allocator=strings.clone(folder),context.allocator
    testing.cleanup(t,proc(data:rawptr) {
        kept:=cast(^Kept)data
        _=os.remove_all(kept.folder)
        delete(kept.folder,kept.allocator)
        free(kept,kept.allocator)
    },kept)
    return folder
}
