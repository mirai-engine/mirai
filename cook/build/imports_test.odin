package build

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:std/base"
import "mirai:std/subprocess"

// A failed refresh says why: what the import program said on its error
// output, else how it ended and the source it was importing.
@(test)
a_failed_refresh_names_the_source_and_how_the_program_ended :: proc(t:^testing.T) {
    said:="package 1 of 2\nimporting /p/assets/rock.png: its source changed\n  rock: 3 assets, 0.2 s\npackage 2 of 2\nimporting /p/assets/tree.gltf: this engine reads no build of it here\n"
    Case :: struct {state:os.Process_State,said,errors:string,wanted:[]string}
    cases:=[]Case{
        {{exited=true,exit_code=1,success=true},said,"mirai import: package tree: the file is truncated\n",{"package tree: the file is truncated"}},
        {{exited=true,exit_code=9,success=false},said,"",{"crashed or was killed (code 9)","/p/assets/tree.gltf"}},
        {{exited=true,exit_code=3,success=true},said,"",{"exit code 3","/p/assets/tree.gltf"}},
        {{exited=true,exit_code=9,success=false},"","",{"crashed or was killed (code 9)","before importing any source"}},
    }
    for c in cases {
        message:=imports_failure(c.state,c.said,c.errors)
        for wanted in c.wanted {testing.expectf(t,strings.contains(message,wanted),"%q lacks %q",message,wanted)}
        testing.expectf(t,!strings.contains(message,"rock.png"),"only the source it was importing: %q",message)
    }
}

@(test)
a_job_polls_and_can_cancel_a_running_import :: proc(t:^testing.T) {
    Case :: struct {end:Status,exit_code:int,cancel:bool}
    for c in ([]Case{{.Up_To_Date,0,false},{.Failed,7,false},{.Failed,0,true}}) {
        root:=base.test_folder(t,"build-import")
        job:=Job{work=root,prefix="import-test",compiled_status=.Up_To_Date}
        if !testing.expect(t,virtual.arena_init_growing(&job.arena)==nil) {return}
        defer virtual.arena_destroy(&job.arena)
        allocator:=virtual.arena_allocator(&job.arena)
        for &text in job.refresh.output {text=make([dynamic]byte,allocator)}
        command:[]string
        when ODIN_OS==.Windows {
            script:=fmt.tprintf("$null=[Console]::ReadLine(); echo 'importing held.asset'; exit %d",c.exit_code)
            command={"powershell.exe","-NoProfile","-NonInteractive","-Command",script}
        } else {
            script:=fmt.tprintf("read -r line; echo 'importing held.asset'; exit %d",c.exit_code)
            command={"sh","-c",script}
        }
        process,error:=subprocess.start({command=command},pipes=.Separate)
        if !testing.expectf(t,error==nil,"start the held importer: %v",error) {return}
        job.refresh.process=process
        defer subprocess.release(&job.refresh.process)
        if !testing.expect(t,!job_poll(&job) && job_importing(&job)) {return}
        if c.cancel {
            job_cancel(&job)
            testing.expect_value(t,job.result.failure,Failure.Cancelled)
            testing.expect(t,!subprocess.process_alive(process.pid))
        } else {
            subprocess.stdin_close(&job.refresh.process)
            job_wait(&job)
            if c.exit_code!=0 {
                testing.expect_value(t,job.result.failure,Failure.Import_Failed)
                testing.expect(t,strings.contains(job.result.text,"held.asset"))
            }
        }
        testing.expect_value(t,job.result.status,c.end)
        testing.expect(t,!job_importing(&job))
    }
}
