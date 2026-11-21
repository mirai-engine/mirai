package build

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:std/base"
import "mirai:std/subprocess"

@(test)
only_a_release_game_refresh_requires_final_textures :: proc(t:^testing.T) {
    Case :: struct {target:Target,quick,final:bool}
    for c in ([]Case{{.Game,true,false},{.Game,false,true},{.Editor,false,false}}) {
        job:=Job{target=c.target,imports={"project"},import_program="mirai-import"}
        if c.target==.Game {job.cook={assets="project/assets",quick=c.quick}}
        args:=job_imports_command(&job)
        testing.expect_value(t,slice.contains(args,"--final"),c.final)
        testing.expect(t,slice.equal(args[len(args)-2:],[]string{"--refresh","project"}))
    }
}

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

// A published build keeps its debug files and sweeps stale work files even
// while its package refresh is still running or if that refresh fails.
@(test)
a_published_build_keeps_debug_files_across_async_import :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"build-import-files")
    if folder=="" {return}
    job:=Job{work=folder,target=.Editor,prefix=fmt.tprintf("editor-2-%d",os.get_pid()),started=time.now(),compiled_status=.Built}
    if !testing.expect(t,virtual.arena_init_growing(&job.arena)==nil) {return}
    defer virtual.arena_destroy(&job.arena)
    own_pdb:=fmt.tprintf("%s/%s.pdb",folder,job.prefix)
    own_err:=fmt.tprintf("%s/%s.err",folder,job.prefix)
    stale:=fmt.tprintf("%s/editor-1-999999999.err",folder)
    old:=time.time_add(job.started,-2*STALE_AFTER)
    for path in ([]string{own_pdb,own_err,stale}) {
        if !testing.expect(t,os.write_entire_file(path,"x")==nil) {return}
    }
    if !testing.expect(t,os.change_times(stale,old,old)==nil) {return}
    // While job.result.status is still .Running (right after publish, before import ends).
    job_files_remove(&job)
    testing.expect(t,os.exists(own_pdb),"debug file of the published target stays while importing")
    testing.expect(t,!os.exists(own_err),"non-debug work files go")
    testing.expect(t,!os.exists(stale),"stale files of dead jobs go once a build published")
    // And if the import subsequently fails or is cancelled, the published target's debug file stands.
    job_fail(&job,.Import_Failed)
    testing.expect(t,os.exists(own_pdb),"debug file of the published target still stands after import failure")
}

// Large output from the import program drains in a bounded loop per poll without stalling.
@(test)
imports_poll_drains_multi_chunk_output :: proc(t:^testing.T) {
    refresh:Import_Refresh
    command:[]string
    when ODIN_OS==.Windows {
        command={"powershell.exe","-NoProfile","-NonInteractive","-Command","1..200 | ForEach-Object { Write-Output ('line ' + $_ + ' ' + ('x' * 80)) }; Write-Output 'importing final.glb'; exit 5"}
    } else {
        command={"sh","-c","i=0; while [ $i -lt 200 ]; do printf 'line %d xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\\n' $i; i=$((i+1)); done; echo 'importing final.glb'; exit 5"}
    }
    if !testing.expect(t,imports_start(&refresh,command,context.temp_allocator)==nil) {return}
    defer subprocess.release(&refresh.process)
    done,ok:=false,false
    message:=""
    for !done {done,ok,message=imports_poll(&refresh,true)}
    testing.expect(t,!ok)
    testing.expect(t,len(refresh.output[.Stdout])>16000,"all chunks were read")
    testing.expectf(t,strings.contains(message,"final.glb"),"tail importing line kept: %q",message)
}
