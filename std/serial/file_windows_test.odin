#+build windows
package serial

import "core:os"
import "core:testing"
import "core:thread"
import "core:time"

@(test)
a_save_replaces_a_file_another_handle_reads :: proc(t:^testing.T) {
    folder,_:=os.make_directory_temp("","serial-held-*",context.temp_allocator)
    defer os.remove_all(folder)
    path:=os.join_path({folder,"held.scene"},context.temp_allocator) or_else ""
    Case :: struct {name:string,scanner:bool}
    for c in ([]Case{{"a reader of the engine",false},{"a scanner that does not share delete, for a moment",true}}) {
        testing.expect_value(t,file_write_atomic(path,transmute([]u8)string("before")),File_Error.None)
        release:^thread.Thread
        reader:Read_File
        if c.scanner {
            held,error:=os.open(path)
            if !testing.expect(t,error==nil,c.name) {return}
            release=thread.create_and_start_with_poly_data(held,proc(held:^os.File) {
                time.sleep(100*time.Millisecond)
                os.close(held)
            })
        } else {
            error:File_Error
            reader,error=file_open_read(path)
            if !testing.expect_value(t,error,File_Error.None) {return}
        }
        testing.expect_value(t,file_write_atomic(path,transmute([]u8)string("after")),File_Error.None)
        if reader!=nil {file_close(reader)}
        if release!=nil {
            thread.join(release)
            thread.destroy(release)
        }
        data,_:=file_read(path,context.temp_allocator)
        testing.expectf(t,string(data)=="after","%s: %q",c.name,string(data))
    }
}
