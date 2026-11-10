package build

import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:project"
import "mirai:std/base"

@(test)
game_build_rejects_the_cook_and_acp_packages :: proc(t:^testing.T) {
    root:="/project"
    engine:="/engine"
    sources:=[]string{
        "/engine/cook/build/engine.odin",
        "/engine/editor/acp/client.odin",
        "/engine/platform/process.odin",
        "/project/game/main.odin",
    }
    packages:=engine_time_packages(sources,root,engine,allocator=context.temp_allocator)
    testing.expect_value(t,len(packages),2)
    testing.expect_value(t,packages[0],"/engine/cook/build")
    testing.expect_value(t,packages[1],"/engine/editor/acp")
}

// The compiler reads the _test.odin files of every package a game imports,
// and their imports: a test of a runtime package that reaches engine-time code
// makes every game that imports the package fail with Engine_Time_Code.
@(test)
the_tests_of_runtime_packages_import_no_engine_time_package :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    engine:=slashes(project.path_absolute(#directory+"../.."),context.allocator)
    roots:=make([dynamic]string)
    append(&roots,project.path(engine,"core"),project.path(engine,"host"),project.path(engine,"engine"))
    plugins,_:=os.read_all_directory_by_path(project.path(engine,"plugins"),context.allocator)
    for plugin in plugins {
        if runtime:=project.path(engine,"plugins",plugin.name,"runtime");os.is_dir(runtime) {append(&roots,runtime)}
    }
    tests:=0
    for root in roots {
        w:=os.walker_create(root)
        defer os.walker_destroy(&w)
        for info in os.walker_walk(&w) {
            if info.type!=.Regular || !strings.has_suffix(info.name,"_test.odin") {continue}
            text,read_error:=os.read_entire_file(info.fullpath,context.allocator)
            if !testing.expectf(t,read_error==nil,"%s could not be read",info.fullpath) {continue}
            file:=ast.new(ast.File,tokenizer.Pos{},tokenizer.Pos{})
            file.src,file.fullpath=string(text),info.fullpath
            p:=parser.default_parser()
            p.err=proc(pos:tokenizer.Pos,format:string,args:..any) {}
            if !testing.expectf(t,parser.parse_file(&p,file),"%s does not parse",info.fullpath) {continue}
            tests+=1
            for decl in file.imports {
                imported:=strings.trim(decl.fullpath,"\"`")
                folder:string
                switch {
                case strings.has_prefix(imported,"mirai:"):   folder=project.path(engine,imported[len("mirai:"):])
                case strings.has_prefix(imported,"plugins:"): folder=project.path(engine,"plugins",imported[len("plugins:"):])
                case: continue
                }
                reached:=engine_time_packages([]string{project.path(folder,"package.odin")},"",engine)
                testing.expectf(t,len(reached)==0,"%s imports %s, which is engine-time: the game does not ship it",info.fullpath,imported)
            }
        }
    }
    testing.expect(t,tests>0,"the tests of the runtime packages were found")
}

// The player of a shipped game reads input.mirai next to its manifest, as it
// does in the folder of the project: the file travels when the project has it.
@(test)
a_game_ships_the_bindings_of_its_project_when_it_has_them :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"ship")
    if folder=="" {return}
    root:=project.path(folder,"project",allocator=context.temp_allocator)
    bindings:=`{"actions":[{"name":"jump","kind":"Button","bindings":[{"key":"Space"}]}]}`
    m:=project.manifest_default("Bound Game")
    testing.expect(t,os.make_directory_all(project.path(root,"assets",allocator=context.temp_allocator))==nil)
    testing.expect(t,os.write_entire_file(project.path(root,project.PROJECT_FILE,allocator=context.temp_allocator),project.manifest_text(&m,context.temp_allocator))==nil)
    testing.expect(t,os.write_entire_file(project.path(root,project.INPUT_FILE,allocator=context.temp_allocator),bindings)==nil)
    testing.expect(t,os.write_entire_file(project.path(root,"assets","main.scene",allocator=context.temp_allocator),"scene")==nil)
    p,open_error:=project.open(root,#directory+"testdata/engine")
    defer project.close(&p)
    if !testing.expect_value(t,open_error.code,project.Error_Code.None) {return}

    ship:=project.path(folder,"ship",allocator=context.temp_allocator)
    testing.expect(t,copies_run(game_copies(&p,ship,"odin",context.temp_allocator)))
    shipped,read_error:=os.read_entire_file(project.path(ship,project.INPUT_FILE,allocator=context.temp_allocator),context.temp_allocator)
    testing.expect(t,read_error==nil && string(shipped)==bindings)
    for file in ([]string{project.PROJECT_FILE}) {
        testing.expect(t,os.is_file(project.path(ship,file,allocator=context.temp_allocator)),file)
    }

    // Without the file the game ships with the bindings its code declares.
    testing.expect(t,os.remove(project.path(root,project.INPUT_FILE,allocator=context.temp_allocator))==nil)
    bare:=project.path(folder,"bare",allocator=context.temp_allocator)
    copies:=game_copies(&p,bare,"odin",context.temp_allocator)
    for copy in copies {testing.expect(t,copy.from!=project.path(root,project.INPUT_FILE,allocator=context.temp_allocator))}
    testing.expect(t,copies_run(copies))
    testing.expect(t,os.is_file(project.path(bare,project.PROJECT_FILE,allocator=context.temp_allocator)))
    testing.expect(t,!os.exists(project.path(bare,project.INPUT_FILE,allocator=context.temp_allocator)))
}

// A shipped game has no engine: it carries the settings of the machine of
// the file of the engine with those of its project over them, as the editor
// read them.
@(test)
a_game_ships_the_settings_of_the_engine_and_of_its_project_merged :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"ship")
    if folder=="" {return}
    root,engine:=project.path(folder,"project",allocator=context.temp_allocator),project.path(folder,"engine",allocator=context.temp_allocator)
    testing.expect(t,os.make_directory_all(root)==nil && os.make_directory_all(project.path(engine,".mirai",allocator=context.temp_allocator))==nil)
    m:=project.manifest_default("Set Game")
    testing.expect(t,os.write_entire_file(project.path(root,project.PROJECT_FILE,allocator=context.temp_allocator),project.manifest_text(&m,context.temp_allocator))==nil)
    testing.expect(t,os.write_entire_file(project.settings_file(.Project,root,engine,context.temp_allocator),`{"Graphics": {"vsync": false}}`)==nil)
    testing.expect(t,os.write_entire_file(project.settings_file(.Engine,root,engine,context.temp_allocator),`{"version": 3, "Graphics": {"vsync": true, "scale": 2}, "Net": {"port": 9}}`)==nil)
    p,open_error:=project.open(root,engine)
    defer project.close(&p)
    if !testing.expect_value(t,open_error.code,project.Error_Code.None) {return}

    ship:=project.path(folder,"ship",allocator=context.temp_allocator)
    job:=Job{published=project.path(ship,"game.exe",allocator=context.temp_allocator),copies=game_copies(&p,ship,"odin",context.temp_allocator)}
    merge_error:project.Error
    job.settings,merge_error,_=project.settings_merge(p.root,p.engine_root,{"Graphics"},context.temp_allocator)
    testing.expect_value(t,merge_error.code,project.Error_Code.None)
    testing.expect_value(t,job_ship(&job),Failure.None)
    data,read_error:=os.read_entire_file(project.path(ship,project.SETTINGS_FILE,allocator=context.temp_allocator),context.temp_allocator)
    shipped:=string(data)
    testing.expect(t,read_error==nil && strings.contains(shipped,`"vsync": false`) && strings.contains(shipped,`"scale": 2`),shipped)
    testing.expect(t,!strings.contains(shipped,`"vsync": true`) && !strings.contains(shipped,`"Net"`),shipped)
}
