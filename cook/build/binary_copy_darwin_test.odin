#+build darwin
package build

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/subprocess"

@(test)
a_replaced_binary_launches_while_the_previous_one_runs :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"binary-launch")
    if folder=="" {return}
    a:=context.temp_allocator
    compiler,found:=compiler_find(".",a)
    if !testing.expect(t,found) {return}
    source:=project.path(folder,"fixture.odin",allocator=a)
    code:=`package fixture
import "core:time"
main :: proc() {when #config(HOLD,false) {time.sleep(30*time.Second)}}
`
    if !testing.expect(t,os.write_entire_file(source,code)==nil) {return}
    old:=project.path(folder,"old",allocator=a)
    new:=project.path(folder,"new",allocator=a)
    for output,i in ([?]string{old,new}) {
        command:=[]string{compiler,"build",source,"-file",fmt.tprintf("-out:%s",output),
            i==0?"-define:HOLD=true":"-define:HOLD=false"}
        state,_,stderr,error:=subprocess.exec({command=command},a)
        if !testing.expectf(t,error==nil && state.exit_code==0,"%v: %s",error,stderr) {return}
    }
    published:=project.path(folder,"program",allocator=a)
    if !testing.expect(t,copy_binary(published,old)) {return}
    first,start_error:=subprocess.start({command={published}})
    if !testing.expectf(t,start_error==nil,"first launch: %v",start_error) {return}
    defer subprocess.release(&first)
    first_state,first_wait:=subprocess.wait(&first,0)
    if !testing.expectf(t,first_wait==os.General_Error.Timeout,
        "first process: %v, %v",first_state,first_wait) {return}

    if !testing.expect(t,copy_binary(published,new)) {return}
    second,restart_error:=subprocess.start({command={published}})
    if !testing.expectf(t,restart_error==nil,"second launch: %v",restart_error) {return}
    defer subprocess.release(&second)
    state,wait_error:=subprocess.wait(&second,5*time.Second)
    testing.expectf(t,wait_error==nil && state.exited && state.exit_code==0,
        "second process: %v, %v",state,wait_error)
    _,still_running:=subprocess.wait(&first,0)
    testing.expect(t,still_running==os.General_Error.Timeout)
}
