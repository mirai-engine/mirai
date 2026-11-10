package base

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// A folder of its own for a test that writes files, in the temporary folder
// of the system: its absolute path, with forward slashes, which holds until
// the test ends, also past a free of the temp allocator. It goes, with what
// it holds, when the test ends. "" with the test failed when it cannot be
// made.
test_folder :: proc(t:^testing.T,name:string,loc:=#caller_location) -> string {
    made,error:=os.make_directory_temp("",fmt.tprintf("mirai-%s-*",name),context.temp_allocator)
    if !testing.expect(t,error==nil,"the folder of the test could not be made",loc=loc) {return ""}
    if absolute,absolute_error:=os.get_absolute_path(made,context.temp_allocator);absolute_error==nil {made=absolute}
    folder,_:=strings.replace_all(made,"\\","/",context.temp_allocator)
    folder=strings.trim_right(folder,"/")
    heap:=runtime.heap_allocator()
    kept,kept_error:=new(string,heap)
    if !testing.expect(t,kept_error==nil,"the folder of the test could not be kept",loc=loc) {_=remove_all(folder);return ""}
    kept^,kept_error=strings.clone(folder,heap)
    if !testing.expect(t,kept_error==nil,"the folder of the test could not be kept",loc=loc) {_=remove_all(folder);free(kept,heap);return ""}
    testing.cleanup(t,proc(folder:rawptr) {
        kept:=cast(^string)folder
        heap:=runtime.heap_allocator()
        _=remove_all(kept^)
        delete(kept^,heap);free(kept,heap)
    },kept)
    return kept^
}
