package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:testing"
import "mirai:cook/workspace"
import "mirai:project"

// A headless session, of a copy or not, opens its API on a free port, never the default one of
// the user's editor, unless the arguments name a port or no API.
@(test)
a_session_leaves_the_default_api_port_to_the_users_editor :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    testing.expect(t,slice.equal(session_api_args({"--frames","5"}),[]string{"--frames","5","--api-port","0"}))
    testing.expect(t,slice.equal(session_api_args({}),[]string{"--api-port","0"}))
    testing.expect(t,slice.equal(session_api_args({"--api-port","7957"}),[]string{"--api-port","7957"}))
    testing.expect(t,slice.equal(session_api_args({"--no-api"}),[]string{"--no-api"}))
}

// start and restart take the mode, the flags of their own and, for the
// editor, everything else in order.
@(test)
session_options_take_their_flags_and_leave_the_rest_to_the_editor :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    options,problem:=session_options({"--dev","--discard","--copy","--timeout","30","--frames","5","--dev"})
    testing.expect_value(t,problem,"")
    testing.expect_value(t,options.mode,Build_Mode.Dev)
    testing.expect(t,options.discard && options.copy && !options.no_build && !options.orphans)
    testing.expect_value(t,options.timeout,30)
    testing.expect(t,slice.equal(options.editor_args,[]string{"--frames","5"}))
    options,problem=session_options({})
    testing.expect_value(t,problem,"")
    testing.expect_value(t,options.mode,Build_Mode.Keep)
    testing.expect_value(t,options.timeout,180)
    testing.expect_value(t,len(options.editor_args),0)
}

@(test)
session_options_refuse_both_modes_and_a_timeout_that_is_no_number :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    for args in ([][]string{{"--dev","--release"},{"--timeout"},{"--timeout","0"},{"--timeout","x"}}) {
        _,problem:=session_options(args)
        testing.expectf(t,problem!="","%v is refused",args)
    }
}

// Unsaved changes go alone only when every one is of a copy under
// .mirai/tmp/ of the project: a scene outside the assets folder is named by
// its file, and the rest relative to the assets folder or to the project.
@(test)
only_unsaved_copies_under_mirai_tmp_go_without_discard :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder:="C:/proyectos/demo" when ODIN_OS==.Windows else "/proyectos/demo"
    copy:=fmt.tprintf("%s/.mirai/tmp/prueba.scene",folder)
    testing.expect(t,session_discardable(folder,{}))
    testing.expect(t,session_discardable(folder,{copy,".mirai/tmp/shaders/x.slang"}))
    testing.expect(t,!session_discardable(folder,{copy,"scenes/main.scene"}),"a scene of the assets")
    testing.expect(t,!session_discardable(folder,{copy,"materials/rock.mat"}),"an asset")
    testing.expect(t,!session_discardable(folder,{""}),"a scene never saved")
    testing.expect(t,!session_discardable(folder,{fmt.tprintf("%s/.mirai/tmp/../../assets/x.scene",folder)}),"out of tmp by ..")
    testing.expect(t,!session_discardable(folder,{fmt.tprintf("%s/.mirai/tmpx/a.scene",folder)}),"a folder that starts like tmp")
    testing.expect(t,!session_discardable(folder,{"C:/otro/.mirai/tmp/a.scene" when ODIN_OS==.Windows else "/otro/.mirai/tmp/a.scene"}),"tmp of another project")
    when ODIN_OS==.Windows {
        testing.expect(t,session_discardable(folder,{`c:\PROYECTOS\demo\.mirai\tmp\b.scene`}),"backslashes and another case")
    }
}

@(test)
the_unsaved_paths_are_the_dirty_scenes_and_the_unsaved_assets :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    documents:=`{"active":0,"documents":[{"index":0,"path":"C:/p/.mirai/tmp/a.scene","dirty":true,"preview_sun":false},{"index":1,"path":"scenes/main.scene","dirty":false,"preview_sun":false},{"index":2,"path":"","dirty":true,"preview_sun":false}],"asset":-1,"assets":[{"index":0,"path":"materials/rock.mat","kind":"material","dirty":true,"undo":1,"redo":0}]}`
    assets:=`{"assets":[{"path":"materials/rock.mat","removed":false,"asset":"00112233445566778899aabbccddeeff","kind":"material"},{"path":"shaders/water.slang","removed":false,"kind":"program"}],"scene":["materials/rock.mat"]}`
    paths,ok:=session_unsaved_parse(documents,assets)
    testing.expect(t,ok)
    testing.expect(t,slice.equal(paths,[]string{"C:/p/.mirai/tmp/a.scene","","materials/rock.mat","shaders/water.slang"}),"dirty scenes, then assets once")
    paths,ok=session_unsaved_parse(`{"documents":[]}`,`{"assets":[]}`)
    testing.expect(t,ok && len(paths)==0)
    _,ok=session_unsaved_parse("not json",assets)
    testing.expect(t,!ok)
}

// The project comes from --project, relative to where the program runs when
// it is not absolute; --headless says it has no window. The first argument
// may be the program or not, as each system gives them.
@(test)
an_engine_program_names_its_project_and_whether_it_has_a_window :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    root:="C:/m" when ODIN_OS==.Windows else "/m"
    folder,headless:=engine_arguments({"mirai-editor","--project",fmt.tprintf("%s/demo/",root),"--headless","--frames","3"},"")
    testing.expect_value(t,folder,fmt.tprintf("%s/demo",root))
    testing.expect(t,headless)
    folder,headless=engine_arguments({"--project","demo"},root)
    testing.expect_value(t,folder,fmt.tprintf("%s/demo",root))
    testing.expect(t,!headless)
    folder,headless=engine_arguments({"mirai-editor","--launcher","--project"},root)
    testing.expect_value(t,folder,"")
    testing.expect(t,!headless)
}

// A session is a headless editor that the port file and the record of its
// project name; one the port file names otherwise is reachable, and an
// editor it does not name is an orphan, with a window or without.
@(test)
an_engine_program_is_told_by_the_files_of_its_project :: proc(t:^testing.T) {
    editor:="C:/m/.mirai/engine/dev/mirai-editor.exe" when ODIN_OS==.Windows else "/m/.mirai/engine/dev/mirai-editor"
    player:="C:/m/.mirai/engine/dev/mirai-player.exe" when ODIN_OS==.Windows else "/m/.mirai/engine/dev/mirai-player"
    headless:=Engine_Process{pid=10,program=editor,project="/p",headless=true,read=true}
    window:=Engine_Process{pid=20,program=editor,project="/p",read=true}
    testing.expect_value(t,engine_role(headless,10,10),Engine_Role.Session)
    testing.expect_value(t,engine_role(headless,10,0),Engine_Role.Reachable)
    testing.expect_value(t,engine_role(headless,10,99),Engine_Role.Reachable)
    testing.expect_value(t,engine_role(window,20,20),Engine_Role.Reachable)
    testing.expect_value(t,engine_role(headless,11,10),Engine_Role.Orphan)
    testing.expect_value(t,engine_role(window,0,0),Engine_Role.Orphan)
    testing.expect_value(t,engine_role({pid=30,program=player,project="/p",read=true},0,0),Engine_Role.Program)
    testing.expect_value(t,engine_role({pid=40,program=editor},40,40),Engine_Role.Unknown)
}

// The role reads <project>/.mirai/api.json and session.json; the record
// keeps the mode and the arguments restart repeats.
@(test)
the_role_and_the_record_come_from_the_files_of_the_project :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder,error:=os.make_directory_temp("","mirai-session-*",context.temp_allocator)
    if !testing.expect(t,error==nil) {return}
    defer os.remove_all(folder)
    folder=project.path_absolute(folder)
    testing.expect(t,os.make_directory_all(project.path(folder,".mirai"))==nil)
    pid:=os.get_pid()
    testing.expect(t,os.write_entire_file(project.path(folder,".mirai","api.json"),fmt.tprintf(`{{"port":7999,"pid":%d,"manual":true}}`,pid))==nil)
    editor:=Engine_Process{pid=pid,program="mirai-editor",project=folder,headless=true,read=true}
    testing.expect_value(t,engine_process_role(editor),Engine_Role.Reachable)
    testing.expect(t,os.write_entire_file(project.path(folder,".mirai",SESSION_FILE),fmt.tprintf(`{{"pid":%d,"mode":"dev","args":["--frames","2"]}}`,pid))==nil)
    testing.expect_value(t,engine_process_role(editor),Engine_Role.Session)
    other:=editor
    other.pid=pid+1
    testing.expect_value(t,engine_process_role(other),Engine_Role.Orphan)
    record,found:=session_record(folder)
    testing.expect(t,found)
    testing.expect_value(t,session_record_mode(record),Build_Mode.Dev)
    testing.expect(t,slice.equal(record.args,[]string{"--frames","2"}))
    file,alive:=session_find(folder)
    testing.expect(t,alive && file.port==7999 && file.manual,"this process is the one the port file names")
}

@(test)
a_path_is_inside_a_folder_only_past_a_separator :: proc(t:^testing.T) {
    testing.expect(t,path_inside("/a/b/c","/a/b"))
    testing.expect(t,path_inside("/a/b/c","/a/b/"))
    testing.expect(t,!path_inside("/a/b","/a/b"))
    testing.expect(t,!path_inside("/a/bc","/a/b"))
    testing.expect(t,!path_inside("/a/b/c",""))
    when ODIN_OS==.Windows {
        testing.expect(t,path_inside(`C:\M\.mirai\engine\dev\mirai-editor.exe`,"c:/m/.mirai/engine"))
    }
}

// A copy for a session takes the sources, the assets and the caches, never
// the files of the editor that holds the project; stop knows it by its place.
@(test)
a_session_copy_takes_the_project_and_its_caches_without_the_files_of_its_editor :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder,error:=os.make_directory_temp("","mirai-copy-*",context.temp_allocator)
    if !testing.expect(t,error==nil) {return}
    defer os.remove_all(folder)
    folder=project.path_absolute(folder)
    kept:=[]string{project.PROJECT_FILE,"assets/scenes/main.scene","game/game.odin","source/art.fbx",
        ".mirai/cache/registry/index",".mirai/thumbs/main.png"}
    left:=[]string{".git/HEAD",".mirai/api.json",".mirai/session.json",".mirai/session.lock",
        ".mirai/session.log",".mirai/editor.dll",".mirai/editor-live-12-0.dll",".mirai/gen/world.odin",
        ".mirai/tmp/probe.scene",".mirai/cache/textures.lock"}
    for files in ([][]string{kept,left}) {
        for file in files {
            path:=project.path(folder,file)
            testing.expect(t,os.make_directory_all(os.dir(path))==nil)
            testing.expect(t,os.write_entire_file(path,file)==nil)
        }
    }
    copy,lock,problem:=session_copy(folder)
    if !testing.expect_value(t,problem,"") {return}
    workspace.lock_release(&lock)
    testing.expect(t,path_inside(copy,project.path(folder,".mirai","tmp")),"under .mirai/tmp/ of the project")
    for file in kept {
        data,read:=os.read_entire_file(project.path(copy,file),context.temp_allocator)
        testing.expectf(t,read==nil && string(data)==file,"%s is copied",file)
    }
    for file in left {testing.expectf(t,!os.exists(project.path(copy,file)),"%s stays out",file)}
    testing.expect(t,session_copied(copy) && !session_copied(folder))
    testing.expect(t,!session_copied(project.path(folder,".mirai","tmp","other")),"only what session_copy names")
    testing.expect(t,session_copy_remove(copy,"test") && !os.exists(copy))
    testing.expect(t,os.is_file(project.path(folder,".mirai","api.json")),"the project keeps its own files")
}

// A sweep deletes the copies a killed run left behind: those whose editor ended. A copy that a
// session start is still making or opening stays, and so does one whose port file or record names
// a process that runs and opens it; a pid that another process took again does not keep it.
@(test)
a_sweep_deletes_only_the_copies_whose_editor_ended :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder,error:=os.make_directory_temp("","mirai-sweep-*",context.temp_allocator)
    if !testing.expect(t,error==nil) {return}
    defer os.remove_all(folder)
    folder=project.path_absolute(folder)
    testing.expect(t,os.write_entire_file(project.path(folder,project.PROJECT_FILE),"")==nil)
    opening,opening_lock,opening_problem:=session_copy(folder)
    killed,killed_lock,killed_problem:=session_copy(folder)
    reused,reused_lock,reused_problem:=session_copy(folder)
    if !testing.expect(t,opening_problem=="" && killed_problem=="" && reused_problem=="") {return}
    workspace.lock_release(&killed_lock)
    workspace.lock_release(&reused_lock)
    record :: proc(copy:string,pid:int) -> bool {
        path:=project.path(copy,".mirai",SESSION_FILE)
        return os.write_entire_file(path,fmt.tprintf(`{{"pid": %d, "mode": "dev", "args": []}}`,pid))==nil
    }
    // No process opens a copy as its project: this test's own pid stands for a pid taken again.
    testing.expect(t,record(killed,1<<30) && record(reused,os.get_pid()))
    swept,kept:=session_copies_sweep(folder)
    testing.expect_value(t,swept,2)
    testing.expect_value(t,kept,0)
    testing.expect(t,os.is_dir(opening),"a copy still being opened stays")
    testing.expect(t,!os.exists(killed) && !os.exists(reused))
    workspace.lock_release(&opening_lock)
    swept,kept=session_copies_sweep(folder)
    testing.expect(t,swept==1 && !os.exists(opening),"once its start ends without an editor, it goes")
    testing.expect(t,os.is_file(project.path(folder,project.PROJECT_FILE)),"the project stays")
}

// A sync brings into a copy only the files named: one another session is
// editing in the project stays out. A file gone from the project leaves the
// copy; a path outside the project or of what a copy never takes is refused;
// code asks for a restart and assets only for a reload, relative to assets/.
@(test)
a_sync_brings_only_the_files_named_into_a_copy :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder,error:=os.make_directory_temp("","mirai-sync-*",context.temp_allocator)
    if !testing.expect(t,error==nil) {return}
    defer os.remove_all(folder)
    folder=project.path_absolute(folder)
    write :: proc(t:^testing.T,root,file,text:string) {
        path:=project.path(root,file)
        testing.expect(t,os.make_directory_all(os.dir(path))==nil || os.is_dir(os.dir(path)))
        testing.expect(t,os.write_entire_file(path,text)==nil)
    }
    read :: proc(root,file:string) -> string {
        data,_:=os.read_entire_file(project.path(root,file),context.temp_allocator)
        return string(data)
    }
    for file in ([]string{project.PROJECT_FILE,"game/blade.odin","game/game.odin","assets/items/Blade.prefab","assets/old.tex"}) {write(t,folder,file,"before")}
    copy,lock,problem:=session_copy(folder)
    if !testing.expect_value(t,problem,"") {return}
    workspace.lock_release(&lock)
    defer session_copy_remove(copy,"test")
    // Another session half-edits game.odin; this one changes blade.odin and the prefab and deletes old.tex.
    write(t,folder,"game/game.odin","half edited")
    write(t,folder,"game/blade.odin","after")
    write(t,folder,"assets/items/Blade.prefab","after")
    testing.expect(t,os.remove(project.path(folder,"assets/old.tex"))==nil)

    plan,refused:=session_sync_plan(folder,copy,{"assets/items/Blade.prefab",`assets\old.tex`})
    if !testing.expect_value(t,refused,"") {return}
    testing.expect(t,!plan.rebuild,"assets alone are read again")
    plan,refused=session_sync_plan(folder,copy,{"game/blade.odin","assets/items/Blade.prefab","assets/old.tex"})
    if !testing.expect_value(t,refused,"") {return}
    testing.expect(t,plan.rebuild,"code asks for a restart")
    testing.expect_value(t,session_sync_apply(folder,copy,plan),"")
    testing.expect_value(t,read(copy,"game/blade.odin"),"after")
    testing.expect_value(t,read(copy,"assets/items/Blade.prefab"),"after")
    testing.expect_value(t,read(copy,"game/game.odin"),"before")
    testing.expect(t,!os.exists(project.path(copy,"assets/old.tex")),"what the project deleted leaves the copy")

    for wrong in ([]string{"../outside.odin","C:/abs.odin","/abs.odin",".mirai/api.json","game","game/missing.odin"}) {
        _,refused=session_sync_plan(folder,copy,{wrong})
        testing.expectf(t,refused!="","%s is refused",wrong)
    }
    _,refused=session_sync_plan(folder,copy,{})
    testing.expect(t,refused!="","a sync names its files")
}
