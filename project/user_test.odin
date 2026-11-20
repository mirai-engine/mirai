package project

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
user_data_folder_is_made_once_under_its_organization :: proc(t:^testing.T) {
    name:=fmt.tprintf("project-test-%d",os.get_pid())
    data,data_ok:=user_data_folder("Mirai Tests",name,context.temp_allocator)
    testing.expect(t,data_ok && os.is_dir(data),data)
    testing.expect(t,strings.has_suffix(data,name) && strings.contains(data,"Mirai Tests"))
    // Asking again finds the same folder.
    again,again_ok:=user_data_folder("Mirai Tests",name,context.temp_allocator)
    testing.expect(t,again_ok && again==data)
    testing.expect(t,os.remove(data)==nil)
    testing.expect(t,os.remove(filepath.dir(data))==nil || os.is_dir(filepath.dir(data)))
    plain,plain_ok:=user_data_folder("",name,context.temp_allocator)
    testing.expect(t,plain_ok && os.is_dir(plain) && !strings.contains(plain,"Mirai Tests"))
    testing.expect(t,os.remove(plain)==nil)
    _,empty_ok:=user_data_folder("Mirai Tests","",context.temp_allocator)
    testing.expect(t,!empty_ok)
    testing.expect_value(t,user_folder(""),"")
}
