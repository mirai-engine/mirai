package build

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:project"
import "mirai:std/base"

// Each mode has its folder and its libraries: release one per layer, dev one
// per package or per few packages that change together. Every package is in
// one library of each, beside the others of it, so a library imports only
// from the ones before it.
@(test)
engine_modes_have_folders_and_libraries_of_their_own :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    root:=base.test_folder(t,"engine-modes")
    if root=="" {return}
    dev,release:=engine_paths(root,.Dev),engine_paths(root,.Release)
    testing.expect(t,dev.folder!=release.folder && dev.decl!=release.decl)
    testing.expect_value(t,engine_mode_resolve(root,.Dev),Engine_Mode.Dev)
    testing.expect_value(t,len(engine_libraries(.Release)),len(Engine_Layer))
    for mode in Engine_Mode {
        libraries:=engine_libraries(mode)
        next:=0
        files:=make(map[string]bool)
        for library in libraries {
            testing.expectf(t,library.first==next && len(library.packages)>0,"%v: %s starts where the one before it ends",mode,library.name)
            testing.expectf(t,library.file not_in files,"%v: two libraries are %s",mode,library.file)
            files[library.file]=true
            for path,at in library.packages {testing.expect_value(t,path,engine_package(library.first+at))}
            next+=len(library.packages)
        }
        testing.expect_value(t,next,ENGINE_PACKAGE_COUNT)
    }
    core_library:^Engine_Library
    packages:=ENGINE_PACKAGES
    units:=make(map[string]int)
    for &library in engine_libraries(.Dev) {
        if slice.contains(library.packages,"core") {core_library=&library}
        if unit:=packages[library.first].unit;unit!="" {
            testing.expectf(t,unit not_in units,"the packages of the unit %s stand together",unit)
            units[unit]=library.first
            testing.expect_value(t,library.name,unit)
        }
    }
    testing.expect(t,core_library!=nil && len(core_library.packages)==1 && core_library.file=="mirai-core","in dev a package that is edited often is a library")
    // Release carries the debug information of what ships; dev does not write it again with every library.
    testing.expect(t,slice.contains(engine_flags(root,false)[:],"-debug") && !slice.contains(engine_flags(root,true)[:],"-debug"))
}

// The packages of the engine are listed each after the ones it imports: what
// a library links against is built before it.
@(test)
a_package_of_the_engine_imports_only_the_ones_before_it :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    root:=slashes(project.path_absolute(#directory+"../..",context.temp_allocator),context.temp_allocator)
    for index in 0..<ENGINE_PACKAGE_COUNT {
        for file in engine_sources(root,{engine_package(index)}) {
            data,error:=os.read_entire_file(file,context.temp_allocator)
            if !testing.expect(t,error==nil,file) {continue}
            rest:=string(data)
            quoted:=false
            for line in strings.split_lines_iterator(&rest) {
                // The source of a program inside a raw string is no import of this file.
                inside:=quoted
                if strings.count(line,"`")%2==1 {quoted=!quoted}
                if inside || !strings.has_prefix(line,"import ") {continue}
                at:=strings.index(line,"\"mirai:")
                if at<0 {continue}
                path:=line[at+len("\"mirai:"):]
                path=path[:max(strings.index_byte(path,'"'),0)]
                imported,found:=engine_package_index(path)
                testing.expectf(t,found && imported<index,"%s imports %s, which ENGINE_PACKAGES does not list before %s",file,path,engine_package(index))
            }
        }
    }
}

// An installed engine has the binaries of one mode and builds none: it is
// current when they are all there, and says it lacks them otherwise.
@(test)
an_installed_engine_builds_nothing_and_says_what_it_lacks :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    root:=base.test_folder(t,"engine-installed")
    if root=="" {return}
    m:project.Engine_Manifest
    if !testing.expect_value(t,project.engine_manifest_write(root,&m).code,project.Error_Code.None) {return}
    testing.expect_value(t,engine_mode_resolve(root,.Dev),ENGINE_MODE_INSTALLED)
    result:=engine_build({engine_root=root,mode=.Dev})
    testing.expect_value(t,result.status,Status.Failed)
    testing.expect_value(t,result.failure,Failure.Engine_Incomplete)
    testing.expect(t,!engine_current(root,.Release))
    paths:=engine_paths(root,.Dev)
    testing.expect(t,os.make_directory_all(paths.decl)==nil)
    files:=make([dynamic]string,context.temp_allocator)
    for library in engine_libraries(ENGINE_MODE_INSTALLED) {
        file,linked:=engine_library_files(paths,library)
        append(&files,file,linked)
    }
    append(&files,paths.editor_program,paths.player_program,paths.import_program,paths.author_program,paths.stamp)
    for file in files {
        testing.expect(t,os.write_entire_file(file,"built")==nil,file)
    }
    result=engine_build({engine_root=root,mode=.Dev})
    testing.expect_value(t,result.status,Status.Up_To_Date)
    testing.expect_value(t,result.mode,ENGINE_MODE_INSTALLED)
    testing.expect(t,engine_current(root,.Dev))
    stamped,current:=engine_state(root,.Release)
    testing.expect(t,stamped && current)
}

// What the build of the engine keeps between runs is what declare writes and
// the stamp it leaves.
@(private="file")
source_write :: proc(t:^testing.T,root,package_path,file,text:string) {
    folder:=project.path(root,package_path,allocator=context.temp_allocator)
    // Making a folder that is already there is .Exist on POSIX and no error on
    // Windows: what counts is that the folder is there.
    if error:=os.make_directory_all(folder);error!=nil && !os.is_dir(folder) {testing.expect(t,false,package_path);return}
    testing.expect(t,os.write_entire_file(project.path(folder,file,allocator=context.temp_allocator),text)==nil,file)
}

@(private="file")
describe :: proc(root:string,packages:[]string) -> Declare_Desc {
    return {
        root=root,
        packages=packages,
        binary="mirai",
        library=project.path(root,"mirai-engine.lib",allocator=context.temp_allocator),
        stage=project.path(root,"stage",allocator=context.temp_allocator),
        decl=project.path(root,"decl",allocator=context.temp_allocator),
    }
}

@(private="file")
of_folder :: proc(folder,package_path,file:string) -> string {
    return project.path(folder,package_path,file,allocator=context.temp_allocator)
}

// What a source became in one of the two folders declare writes.
@(private="file")
declared :: proc(folder,package_path,file:string) -> string {
    data,error:=os.read_entire_file(of_folder(folder,package_path,file),context.temp_allocator)
    if error!=nil {return ""}
    return string(data)
}

// The date a test gives a file to tell whether it is written again, without waiting for the clock of the file system to tick.
@(private="file")
PAST :: time.Time{_nsec=1_500_000_000*1_000_000_000}

// What a project's fingerprint reads of the declarations of the engine.
@(private="file")
modified :: proc(path:string) -> i64 {
    info,error:=os.stat(path,context.temp_allocator)
    if error!=nil {return 0}
    return time.to_unix_nanoseconds(info.modification_time)
}

@(private="file")
declared_ok :: proc(t:^testing.T,errors:[]string) -> bool {
    if len(errors)==0 {return true}
    testing.expect(t,false,strings.join(errors,"\n"))
    return false
}

// The parser the declaration reads with builds a tree that has no destructor:
// the process that builds calls it once and exits, so it does not free it. The
// test lends it the temporary allocator, as a generated world does, so that
// what it does not free is not reported as a leak of the test.
@(private="file")
declaring :: proc(desc:Declare_Desc) -> (errors:[]string,changed:Declare_Changed) {
    previous:=context.allocator
    context.allocator=context.temp_allocator
    errors,changed=declare(desc)
    context.allocator=previous
    return
}

// A declaration that comes out the same writes nothing and says so: what
// compiles against it stands. A change of a body alone declares the same.
@(test)
declare_says_whether_a_declaration_changed :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder:=base.test_folder(t,"declare")
    if folder=="" {return}
    source:=project.path(folder,"engine","core","thing.odin")
    testing.expect(t,os.make_directory_all(os.dir(source))==nil)
    write :: proc(t:^testing.T,path,text:string) {testing.expect(t,os.write_entire_file(path,text)==nil)}
    write(t,source,"package core\n\nvalue :: proc(x:int) -> int {return x+1}\n")
    desc:=Declare_Desc{root=project.path(folder,"engine"),packages={"core"},binary="mirai",library=project.path(folder,"out","thing.lib"),stage=project.path(folder,"out","stage"),decl=project.path(folder,"out","decl")}
    errors,changed:=declare(desc)
    testing.expect_value(t,len(errors),0)
    testing.expect(t,changed.stage && changed.decl,"the first declaration writes both")
    _,changed=declare(desc)
    testing.expect(t,!changed.stage && !changed.decl,"the same sources declare nothing new")
    write(t,source,"package core\n\nvalue :: proc(x:int) -> int {return x+2}\n")
    _,changed=declare(desc)
    testing.expect(t,changed.stage && !changed.decl,"a body moves the stage and is not declared")
    write(t,source,"package core\n\nvalue :: proc(x,y:int) -> int {return x+y}\n")
    _,changed=declare(desc)
    testing.expect(t,changed.decl,"another signature is another declaration")

    // A private procedure the declarations do not name is not declared.
    private :: "package core\n\nvalue :: proc(x,y:int) -> int {{return helper(x)+y}}\n\ntwice :: #force_inline proc(x:int) -> int {{return named(x)}}\n\n@(private)\nhelper :: proc(%s) -> int {{return x}}\n\n@(private)\nnamed :: proc(%s) -> int {{return x*2}}\n"
    write(t,source,fmt.tprintf(private,"x:int","x:int"))
    errors,_=declare(desc)
    testing.expect_value(t,len(errors),0)
    write(t,source,fmt.tprintf(private,"x:int,y:=0","x:int"))
    errors,changed=declare(desc)
    testing.expect(t,len(errors)==0 && changed.stage && !changed.decl,"a private procedure no declaration names is not declared")
    write(t,source,fmt.tprintf(private,"x:int,y:=0","x:int,y:=0"))
    errors,changed=declare(desc)
    testing.expect(t,len(errors)==0 && changed.decl,"the one an inline body calls is")

    extra:=project.path(folder,"engine","core","more.odin")
    write(t,extra,"package core\n\nmore :: proc() {}\n")
    _,changed=declare(desc)
    testing.expect(t,changed.stage && changed.decl)
    testing.expect(t,os.remove(extra)==nil)
    _,changed=declare(desc)
    testing.expect(t,changed.stage && changed.decl,"a file taken out of the package goes")
    testing.expect(t,!os.exists(project.path(folder,"out","decl","core","more.odin")))
    testing.expect(t,!os.exists(project.path(folder,"out","stage","core","more.odin")))

    // Built to be taken in place: a body declares the same, another signature names its
    // declaration, and a package variable keeps the package from being taken.
    desc.names,desc.slots=true,true
    write(t,source,"package core\n\nvalue :: proc(x:int) -> int {return x+1}\n")
    _,first:=declare(desc)
    testing.expect(t,os.exists(project.path(folder,"out","stage","core","mirai__slots.odin")),"a package that exports has its table")
    write(t,source,"package core\n\nvalue :: proc(x:int) -> int {return x+2}\n")
    _,changed=declare(desc)
    testing.expect(t,changed.declared==first.declared && changed.moved=="" && changed.pinned=="","a body declares the same")
    write(t,source,"package core\n\nvalue :: proc(x,y:int) -> int {return x+y}\n")
    _,changed=declare(desc)
    testing.expectf(t,changed.declared!=first.declared && changed.moved=="core.value","another signature is named: %q",changed.moved)
    write(t,source,"package core\n\nvalue :: proc(x,y:int) -> int {return x+y}\n\n@(private)\ncounter:int\n")
    _,changed=declare(desc)
    testing.expect_value(t,changed.pinned,"variable:core.counter")
}

// A private procedure is declared, and exported, only when the declarations
// name it: no other package can call it, so only what is copied into them
// and the default values of what they declare can. One private to a file is
// looked up in the declarations of its file alone.
@(test)
declarations_carry_only_the_private_procedures_they_name :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    cases:=[]struct{what:string,a,b:string,declared,left:[]string}{
        {
            what="an inline body calls it",
            a="@(private)\nhelper :: proc(x:int) -> int {return x}\n\n@(private)\nalone :: proc(x:int) -> int {return helper(x)}\n\nrun :: #force_inline proc(x:int) -> int {return helper(x)}\n",
            declared={"mirai.thing.helper"},left={"mirai.thing.alone"},
        },
        {
            what="only a private body copied with the one that calls it does",
            a="@(private)\ninner :: proc() {}\n\n@(private)\nmiddle :: #force_inline proc() {inner()}\n\nrun :: #force_inline proc() {middle()}\n",
            declared={"mirai.thing.inner"},
        },
        {
            what="a constant and a table take it as a value",
            a="@(private)\non_event :: proc() {}\n\n@(private)\non_frame :: proc() {}\n\n@(private)\non_nothing :: proc() {}\n\nHANDLER :: on_event\n\n@(rodata)\nHANDLERS := [1]proc(){on_frame}\n",
            declared={"mirai.thing.on_event","mirai.thing.on_frame"},left={"mirai.thing.on_nothing"},
        },
        {
            what="a default value names it, and its own names another",
            a="@(private)\nfallback :: proc(then:=last) {}\n\n@(private)\nlast :: proc() {}\n\nrun :: proc(then:=fallback) {then()}\n",
            declared={"mirai.thing.fallback","mirai.thing.last"},
        },
        {
            what="a group of procedures names it",
            a="@(private)\nof_int :: proc(x:int) {}\n\n@(private=\"file\")\nof_f32 :: proc(x:f32) {}\n\n@(private)\nof_none :: proc() {}\n\nof :: proc{of_int,of_f32}\n",
            declared={"mirai.thing.of_int","mirai.thing.a.of_f32"},left={"mirai.thing.of_none"},
        },
        {
            what="a deferred procedure",
            a="@(private)\nleave :: proc() {}\n\n@(deferred_none=leave)\nenter :: proc() {}\n",
            declared={"mirai.thing.leave"},
        },
        {
            what="each branch of a when declares its own",
            a="when ODIN_OS==.Windows {\n    @(private)\n    wait :: proc() {}\n    @(private)\n    idle :: proc() {}\n} else {\n    @(private)\n    wait :: proc(ms:=0) {}\n}\n\nrun :: #force_inline proc() {\n    when ODIN_DEBUG {wait()}\n}\n",
            declared={"mirai.thing.wait","wait :: proc(ms:=0)"},left={"mirai.thing.idle"},
        },
        {
            what="another file has one of the same name that nothing copied calls",
            a="@(private=\"file\")\nhelper :: proc() {}\n\nrun :: #force_inline proc() {helper()}\n",
            b="@(private=\"file\")\nhelper :: proc() {}\n\nother :: proc() {helper()}\n",
            declared={"mirai.thing.a.helper"},left={"mirai.thing.b.helper"},
        },
        {
            what="a field and a private file have its name",
            a="Thing :: struct {reset:int}\n\n@(private)\nreset :: proc() {}\n\nread :: #force_inline proc(thing:Thing) -> int {return thing.reset}\n",
            b="#+private\npackage thing\n\nquiet :: proc() {}\n\nloud :: proc() {}\n\nTABLE :: [1]proc(){loud}\n",
            declared={"mirai.thing.loud"},left={"mirai.thing.reset","mirai.thing.quiet"},
        },
    }
    root:=base.test_folder(t,"declare-private")
    if root=="" {return}
    for c,index in cases {
        folder:=project.path(root,fmt.tprint(index))
        source_write(t,folder,"thing","a.odin",strings.concatenate({"package thing\n\n",c.a}))
        if c.b!="" {source_write(t,folder,"thing","b.odin",strings.has_prefix(c.b,"#+")?c.b:strings.concatenate({"package thing\n\n",c.b}))}
        desc:=describe(folder,[]string{"thing"})
        errors,_:=declaring(desc)
        if !declared_ok(t,errors) {continue}
        decl:=strings.concatenate({declared(desc.decl,"thing","a.odin"),declared(desc.decl,"thing","b.odin")})
        stage:=strings.concatenate({declared(desc.stage,"thing","a.odin"),declared(desc.stage,"thing","b.odin")})
        for name in c.declared {
            testing.expectf(t,strings.contains(decl,name),"%s: %s is declared:\n%s",c.what,name,decl)
            if strings.has_prefix(name,"mirai.") {testing.expectf(t,strings.contains(stage,fmt.tprintf("@(export,link_name=%q",name)),"%s: %s is exported:\n%s",c.what,name,stage)}
        }
        for name in c.left {
            testing.expectf(t,!strings.contains(decl,name) && !strings.contains(stage,name),"%s: %s stays in the binary alone:\n%s",c.what,name,decl)
        }
    }
}

// An inline procedure copied into the declarations can call one private to its
// file, an LLVM intrinsic of its file and read a table of its file: each file
// declares its own procedure under a link name of its file, carries its table
// and the intrinsic as it is, which has nothing to export.
@(test)
declarations_keep_the_procedures_and_tables_private_to_a_file_that_inline_ones_use :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder:=base.test_folder(t,"declare")
    if folder=="" {return}
    for name in ([]string{"a","b"}) {
        source:=project.path(folder,"engine","thing",strings.concatenate({name,".odin"}))
        testing.expect(t,os.make_directory_all(os.dir(source))==nil)
        text:=fmt.tprintf("package thing\n\n@(private=\"file\")\nhelper :: proc(x:int) -> int {{return x*2}}\n\n@(private=\"file\",rodata)\nTABLE := [2]int{{3,4}}\n\n@(private=\"file\",default_calling_convention=\"none\")\nforeign _ {{\n    @(link_name=\"llvm.ctpop.i64\")\n    popcount :: proc(x:i64) -> i64 ---\n}}\n\n%s :: #force_inline proc(x:int) -> int {{return helper(x)+TABLE[x&1]+int(popcount(i64(x)))}}\n",name)
        testing.expect(t,os.write_entire_file(source,text)==nil)
    }
    desc:=Declare_Desc{root=project.path(folder,"engine"),packages={"thing"},binary="mirai",library=project.path(folder,"out","thing.lib"),stage=project.path(folder,"out","stage"),decl=project.path(folder,"out","decl")}
    errors,_:=declaring(desc)
    if !declared_ok(t,errors) {return}
    for name in ([]string{"a","b"}) {
        link:=fmt.tprintf("link_name=\"mirai.thing.%s.helper\"",name)
        decl:=declared(project.path(folder,"out","decl"),"thing",strings.concatenate({name,".odin"}))
        stage:=declared(project.path(folder,"out","stage"),"thing",strings.concatenate({name,".odin"}))
        testing.expectf(t,strings.contains(decl,link) && strings.contains(decl,"helper :: proc") && strings.contains(decl,"TABLE := [2]int"),"%s declares its helper and its table:\n%s",name,decl)
        testing.expectf(t,strings.contains(stage,fmt.tprintf("@(export,%s,private=\"file\")",link)),"%s exports its helper:\n%s",name,stage)
        testing.expectf(t,strings.contains(decl,"@(link_name=\"llvm.ctpop.i64\")") && !strings.contains(stage,"__mirai_export_popcount"),"%s declares its intrinsic and exports none:\n%s",name,decl)
    }
}

// The declarations load their files by paths relative to their own folder:
// the shared cache copies them into checkouts at other places.
@(test)
declarations_load_their_files_relative_to_their_folder :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder:=base.test_folder(t,"declare")
    if folder=="" {return}
    source:=project.path(folder,"engine","thing","thing.odin")
    testing.expect(t,os.make_directory_all(os.dir(source))==nil)
    testing.expect(t,os.make_directory_all(project.path(folder,"engine","assets"))==nil)
    testing.expect(t,os.write_entire_file(project.path(folder,"engine","assets","data.txt"),"data")==nil)
    testing.expect(t,os.write_entire_file(source,"package thing\n\nDATA :: #load(\"../assets/data.txt\")\n")==nil)
    desc:=Declare_Desc{root=project.path(folder,"engine"),packages={"thing"},binary="mirai",library=project.path(folder,"out","thing.lib"),stage=project.path(folder,"out","stage"),decl=project.path(folder,"out","decl")}
    errors,_:=declaring(desc)
    if !declared_ok(t,errors) {return}
    text:=declared(desc.decl,"thing","thing.odin")
    testing.expectf(t,strings.contains(text,`#load("../../../engine/assets/data.txt")`),"the declaration loads its file from its own folder: %s",text)
    testing.expect(t,!strings.contains(text,folder),"no path of the checkout that declared")
}

// A procedure a project calls through the library is declared foreign and its
// body travels only in the stage: changing the body moves the stage and leaves
// the declarations as they were, which is what keeps the libraries above
// it and the projects from being built again.
@(test)
a_body_only_the_library_carries_changes_the_stage_and_leaves_the_declarations :: proc(t:^testing.T) {
    root:=base.test_folder(t,"declare-body")
    if root=="" {return}
    source_write(t,root,"thing","thing.odin","package thing\n\nvalue_of :: proc(value:int) -> int {return value}\n")
    desc:=describe(root,[]string{"thing"})

    errors,first:=declaring(desc)
    if !declared_ok(t,errors) {return}
    testing.expect(t,first.stage && first.decl,"the first declaration writes both")
    declaration:=declared(desc.decl,"thing","thing.odin")
    testing.expect(t,strings.contains(declaration,"foreign __mirai"),declaration)

    source_write(t,root,"thing","thing.odin","package thing\n\nvalue_of :: proc(value:int) -> int {return value+0}\n")
    second_errors,second:=declaring(desc)
    if !declared_ok(t,second_errors) {return}
    testing.expect_value(t,second.stage,true)
    testing.expect_value(t,second.decl,false)
    testing.expect_value(t,declared(desc.decl,"thing","thing.odin"),declaration)
    testing.expect(t,strings.contains(declared(desc.stage,"thing","thing.odin"),"value+0"),"the stage carries the body")
}

// The library of a half is compiled again only when the text of its stage
// changed, and a project is built again by the times of the declarations: a
// declaration with nothing to write must move neither.
@(test)
a_declaration_with_nothing_to_write_leaves_the_times_of_its_files :: proc(t:^testing.T) {
    root:=base.test_folder(t,"declare-quiet")
    if root=="" {return}
    source_write(t,root,"thing","thing.odin","package thing\n\nvalue_of :: proc(value:int) -> int {return value}\n")
    desc:=describe(root,[]string{"thing"})

    errors,_:=declaring(desc)
    if !declared_ok(t,errors) {return}
    stage,declaration:=of_folder(desc.stage,"thing","thing.odin"),of_folder(desc.decl,"thing","thing.odin")
    // A time of long ago: a file written again would take the one of now.
    for file in ([2]string{stage,declaration}) {testing.expect(t,os.change_times(file,PAST,PAST)==nil,file)}
    stage_before,declaration_before:=modified(stage),modified(declaration)
    if !testing.expect(t,stage_before>0 && declaration_before>0,"both are written") {return}

    quiet_errors,changed:=declaring(desc)
    if !declared_ok(t,quiet_errors) {return}
    testing.expect(t,!changed.stage && !changed.decl,"the second declaration writes nothing")
    testing.expect_value(t,modified(stage),stage_before)
    testing.expect_value(t,modified(declaration),declaration_before)
}

// What a source no longer declares does not stay declared.
@(test)
a_declaration_whose_source_is_gone_is_removed :: proc(t:^testing.T) {
    root:=base.test_folder(t,"declare-gone")
    if root=="" {return}
    source_write(t,root,"thing","kept.odin","package thing\n\nkept :: proc(value:int) -> int {return value}\n")
    source_write(t,root,"thing","gone.odin","package thing\n\ngone :: proc(value:int) -> int {return value}\n")
    desc:=describe(root,[]string{"thing"})

    errors,_:=declaring(desc)
    if !declared_ok(t,errors) {return}
    for folder in ([]string{desc.stage,desc.decl}) {
        testing.expect(t,os.is_file(of_folder(folder,"thing","gone.odin")),folder)
    }

    testing.expect(t,os.remove(project.path(root,"thing","gone.odin",allocator=context.temp_allocator))==nil)
    swept_errors,changed:=declaring(desc)
    if !declared_ok(t,swept_errors) {return}
    testing.expect(t,changed.stage && changed.decl,"removing a source writes both")
    for folder in ([]string{desc.stage,desc.decl}) {
        testing.expect(t,!os.is_file(of_folder(folder,"thing","gone.odin")),"the source that is gone is not declared")
        testing.expect(t,os.is_file(of_folder(folder,"thing","kept.odin")),"the source that stays is")
    }
}

// The folder of a package can hold the folder of another package: only the
// files of the one being declared go.
@(test)
a_declaration_leaves_the_files_of_the_package_below_it :: proc(t:^testing.T) {
    root:=base.test_folder(t,"declare-below")
    if root=="" {return}
    source_write(t,root,"thing","thing.odin","package thing\n\nvalue_of :: proc(value:int) -> int {return value}\n")
    source_write(t,root,"thing/nested","nested.odin","package thing_nested\n\nnested_of :: proc(value:int) -> int {return value}\n")
    desc:=describe(root,[]string{"thing","thing/nested"})

    errors,_:=declaring(desc)
    if !declared_ok(t,errors) {return}
    nested_decl,nested_stage:=of_folder(desc.decl,"thing/nested","nested.odin"),of_folder(desc.stage,"thing/nested","nested.odin")
    testing.expect(t,os.is_file(nested_decl) && os.is_file(nested_stage),"the package below is declared")
    testing.expect(t,os.change_times(nested_decl,PAST,PAST)==nil)
    nested_before:=modified(nested_decl)

    alone_errors,changed:=declaring(describe(root,[]string{"thing"}))
    if !declared_ok(t,alone_errors) {return}
    testing.expect(t,!changed.stage && !changed.decl,"nothing of the package above changed")
    testing.expect(t,os.is_file(nested_decl) && os.is_file(nested_stage),"the package below is still declared")
    testing.expect_value(t,modified(nested_decl),nested_before)
}

// What links against a library of the engine is a file of its own on Windows:
// a build that finds the library and not that file compiles it again, which is
// what the build asks of every library before it keeps what is there.
@(test)
a_library_of_the_engine_is_not_there_without_what_links_against_it :: proc(t:^testing.T) {
    root:=base.test_folder(t,"declare-library")
    if root=="" {return}
    library:=project.path(root,project.library_file("mirai-engine",context.temp_allocator),allocator=context.temp_allocator)
    linked_against:=project.path(root,library_import_file("mirai-engine",context.temp_allocator),allocator=context.temp_allocator)

    testing.expect(t,!library_present(library,linked_against),"neither is there")
    testing.expect(t,os.write_entire_file(library,"library")==nil)
    when ODIN_OS==.Windows {
        testing.expect(t,!library_present(library,linked_against),"the library alone is not the library")
    }
    testing.expect(t,os.write_entire_file(linked_against,"import library")==nil)
    testing.expect(t,library_present(library,linked_against),"both are there")
}

// A stamp that is not there, cannot be read, or is of another shape is none,
// and the build of the engine is done whole.
@(test)
a_stamp_that_is_not_the_one_of_a_build_is_not_read :: proc(t:^testing.T) {
    root:=base.test_folder(t,"declare-stamp")
    if root=="" {return}
    file:=project.path(root,"engine.stamp",allocator=context.temp_allocator)

    _,stamped:=engine_stamp_read(file,engine_libraries(.Dev,context.temp_allocator))
    testing.expect(t,!stamped,"a stamp that is not there is not read")

    testing.expect(t,os.write_entire_file(file,"not a stamp")==nil)
    _,stamped=engine_stamp_read(file,engine_libraries(.Dev,context.temp_allocator))
    testing.expect(t,!stamped,"a stamp that does not parse is not read")

    testing.expect(t,os.write_entire_file(file,"1 2 3 Modules")==nil)
    _,stamped=engine_stamp_read(file,engine_libraries(.Dev,context.temp_allocator))
    testing.expect(t,!stamped,"a stamp of another shape is not read")

    libraries:=engine_libraries(.Dev,context.temp_allocator)
    written:=stamp_fixture(libraries)
    testing.expect(t,engine_stamp_write(file,written,libraries)==nil)
    read,ok:=engine_stamp_read(file,libraries)
    testing.expect(t,ok,"the stamp a build writes is read")
    testing.expect(t,read.programs==written.programs && read.programs_against==written.programs_against && read.declares==written.declares && slice.equal(read.libraries,written.libraries) && slice.equal(read.declared,written.declared),"as it was written")
    kept:=engine_stamp_of(root,context.temp_allocator)
    // A library built again moves what a program keeps of the stamp, whichever it is.
    written.libraries[len(libraries)-1].against+=1
    testing.expect(t,engine_stamp_write(file,written,libraries)==nil)
    testing.expect(t,engine_stamp_of(root,context.temp_allocator)!=kept,"it follows every library")
    _,stamped=engine_stamp_read(file,engine_libraries(.Release,context.temp_allocator))
    testing.expect(t,!stamped,"the stamp of other libraries is not read")

    text,_:=os.read_entire_file(file,context.temp_allocator)
    lines:=strings.split_lines(string(text),context.temp_allocator)
    extra,letters,swapped:=slice.clone(lines,context.temp_allocator),slice.clone(lines,context.temp_allocator),slice.clone(lines,context.temp_allocator)
    extra[0]=strings.concatenate({lines[0]," 9"},context.temp_allocator)
    without_library:=slice.clone(lines,context.temp_allocator)
    without_library[0]=lines[0][:strings.last_index_byte(lines[0],' ')]
    letters[0]=strings.concatenate({"zz",lines[0]},context.temp_allocator)
    swapped[1],swapped[2]=lines[2],lines[1]
    cases:=[]struct{what:string,lines:[]string}{
        {"a stamp with an extra field",extra},
        {"a stamp without one of its fields",without_library},
        {"a stamp whose hashes are not numbers",letters},
        {"a stamp without one of the libraries",lines[:len(lines)-1]},
        {"a stamp with its libraries in another order",swapped},
    }
    for c in cases {
        testing.expect(t,os.write_entire_file(file,strings.join(c.lines,"\n",context.temp_allocator))==nil)
        _,stamped=engine_stamp_read(file,libraries)
        testing.expectf(t,!stamped,"%s is not read",c.what)
    }
}

@(private="file")
stamp_fixture :: proc(libraries:[]Engine_Library) -> Engine_Stamp {
    stamp:=Engine_Stamp{programs=0x123,programs_against=0x321,declares=DECLARE_VERSION,libraries=make([]Library_Stamp,len(libraries),context.temp_allocator),declared=make([]Library_Declared,len(libraries),context.temp_allocator)}
    for &library,which in stamp.libraries {library={sources=0xabc+u64(which),tools=0x456+u64(which),against=0xfed+u64(which)}}
    for &declared,which in stamp.declared {declared.hash=0x777+u64(which)}
    return stamp
}

// A program takes in place the dev libraries built again that declare what
// they did, and none other: what another library compiled in of them, what a
// second copy would not share, other programs or a release build restart it,
// saying why.
@(test)
a_library_built_again_is_taken_in_place_while_what_it_declares_stands :: proc(t:^testing.T) {
    libraries:=engine_libraries(.Dev,context.temp_allocator)
    root:=base.test_folder(t,"engine-swap")
    if root=="" {return}
    text :: proc(t:^testing.T,root:string,stamp:Engine_Stamp,libraries:[]Engine_Library) -> string {
        testing.expect(t,engine_stamp_write(project.path(root,ENGINE_STAMP,allocator=context.temp_allocator),stamp,libraries)==nil)
        return engine_stamp_of(root,context.temp_allocator)
    }
    copy_of :: proc(stamp:Engine_Stamp) -> Engine_Stamp {
        next:=stamp
        next.libraries=slice.clone(stamp.libraries,context.temp_allocator)
        next.declared=slice.clone(stamp.declared,context.temp_allocator)
        return next
    }
    running:=stamp_fixture(libraries)
    last:=len(libraries)-1
    body:=copy_of(running)
    body.libraries[0].sources+=1
    body.libraries[last].sources+=1
    declared:=copy_of(body)
    declared.declared[last]={hash=1,moved="editor.Session"}
    pinned:=copy_of(body)
    pinned.declared[0].pinned="variable:std.base.counter"
    programs:=copy_of(body)
    programs.programs+=1
    unbuilt:=copy_of(body)
    unbuilt.libraries[last].sources=0
    cases:=[]struct{what:string,now:Engine_Stamp,swapped:int,restart:string}{
        {"the same build",running,0,""},
        {"bodies of two libraries",body,2,""},
        {"a declaration",declared,0,"the declaration editor.Session changed"},
        {"a package variable",pinned,0,"keeps what a newer one would not have (variable:std.base.counter)"},
        {"other programs",programs,0,"the compiler or the flags of the build changed"},
        {"a library that did not build",unbuilt,0,"did not build"},
    }
    was:=text(t,root,running,libraries)
    for c in cases {
        swapped,restart:=engine_swap(.Dev,was,text(t,root,c.now,libraries),context.temp_allocator)
        testing.expectf(t,len(swapped)==c.swapped && strings.contains(restart,c.restart) && (c.restart=="")==(restart==""),"%s: %d libraries, %q",c.what,len(swapped),restart)
    }
    _,restart:=engine_swap(.Release,was,text(t,root,body,libraries),context.temp_allocator)
    testing.expect(t,restart!="","a release build is never taken in place")
    _,restart=engine_swap(.Dev,"not a stamp",was,context.temp_allocator)
    testing.expect(t,restart!="","nor what no stamp says")
}

// A library links against the libraries its imports reach before it, directly
// or through another, and names the declarations of those its sources write
// after the name of an import: what it is built again by. A literal that
// names a package outside an import, or a package after its own, imports nothing.
@(test)
a_library_needs_the_libraries_it_reaches_and_names_what_it_writes :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    root:=base.test_folder(t,"declare-reach")
    if root=="" {return}
    source_write(t,root,"core","core.odin","package core\n")
    source_write(t,root,"render","render.odin","package render\n\nimport \"mirai:core\"\n\nframes :: proc() -> int {return core.count()+core .\n  more(..core.rest())}\n")
    source_write(t,root,"cook/build","build.odin","package build\n\nimport draw \"mirai:render\"\n\nPROGRAM :: `import \"mirai:editor\"`\n\nPLAYER :: \"import \\\"mirai:host\\\"\"\n\nNAMED :: \"mirai:asset\"\n\nrun :: proc() {draw.frames()}\n")
    source_write(t,root,"editor","editor.odin","package editor\n\nimport \"mirai:ui\"\nimport _ \"mirai:cook/build\"\n")
    for mode in Engine_Mode {
        libraries:=engine_libraries(mode)
        reach:=engine_reach(root,libraries)
        of :: proc(t:^testing.T,libraries:[]Engine_Library,path:string) -> int {
            for library,which in libraries {
                if slice.contains(library.packages,path) {return which}
            }
            testing.expect(t,false,path)
            return 0
        }
        core,render,ui,asset,host:=of(t,libraries,"core"),of(t,libraries,"render"),of(t,libraries,"ui"),of(t,libraries,"asset"),of(t,libraries,"host")
        cook,editor:=of(t,libraries,"cook/build"),of(t,libraries,"editor")
        testing.expectf(t,reach.needs[cook][render] && reach.needs[cook][core],"%v: what it imports and what that imports",mode)
        testing.expectf(t,reach.needs[editor][cook] && reach.needs[editor][ui] && reach.needs[editor][core],"%v: the editor reaches them all",mode)
        testing.expectf(t,!reach.needs[cook][editor] && !slice.contains(reach.needs[core],true),"%v: a library needs nothing after it",mode)
        if mode==.Dev {
            testing.expect(t,reach.needs[render][core] && !reach.needs[cook][host] && !reach.needs[cook][asset],"a package is a library, and a literal outside an import imports nothing")
            names:=reach.names[render]
            testing.expect(t,"mirai:core.count" in names && "mirai:core.more" in names && "mirai:core.rest" in names,"what follows the name of the import")
            testing.expect(t,"mirai:render.frames" in reach.names[cook],"under the name it is imported with")
            for name in reach.names[cook] {testing.expectf(t,!strings.has_prefix(name,"mirai:editor.") && !strings.has_prefix(name,"mirai:host.") && !strings.has_prefix(name,"mirai:asset."),"%s is of no import",name)}
            // With no declaration moved only the libraries whose sources changed are read, and they link in order.
            only:=make([]bool,len(libraries))
            only[core],only[cook]=true,true
            read:=engine_reach(root,libraries,only)
            testing.expect(t,"mirai:render.frames" in read.names[cook] && len(read.names[render])==0 && len(read.names[editor])==0,"the others name what they named")
            testing.expect(t,read.needs[cook][core] && !read.needs[cook][render] && !slice.contains(read.needs[editor],true))
        } else {
            // In release render and core are one library: the first compiles the second from the stage.
            testing.expect(t,core!=render || len(reach.names[core])==0)
        }
    }
}

// What names a declaration is built again when that declaration, or one it
// reaches, changes: a type with those of its fields, also through a pointer, a
// procedure with those of its signature, an inline body with what it calls.
// The body of a procedure the library carries, and a declaration nothing
// names, build nothing again.
@(test)
what_names_a_declaration_follows_it_and_what_it_reaches :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    root:=base.test_folder(t,"declare-names")
    if root=="" {return}
    CORE :: "package core\n\nEntity :: struct {{id:u32%s}}\n\nTable :: struct {{rows:[]Entity}}\n\nConfig :: struct {{size:int%s}}\n\ncount :: proc(t:^Table) -> int {{return len(t.rows)%s}}\n\nlimit :: proc(%s) -> int {{return 4}}\n\ntwice :: #force_inline proc(x:int) -> int {{return helper(x)%s}}\n\n@(private)\nhelper :: proc(x:int%s) -> int {{return x*2%s}}\n%s\nwhen ODIN_DEBUG%s {{\n    checked :: proc() {{}}\n}}\n"
    RENDER :: "package render\n\nimport data \"mirai:core\"\n\nView :: struct {{config:^data.Config}}\n\ndraw :: proc(v:^View%s) {{}}\n"
    Consumer :: enum {Counts,Limits,Twices,Draws,Checks,Imports}
    consumers:=[Consumer]string{
        .Counts="package game\n\nimport \"mirai:core\"\n\nrun :: proc() {_=core.count(nil)}\n",
        .Limits="package game\n\nimport c \"mirai:core\"\n\nrun :: proc() {_=c.limit()}\n",
        .Twices="package game\n\nimport \"mirai:core\"\n\nrun :: proc() {_=core.twice(1)}\n",
        .Draws="package game\n\nimport \"mirai:render\"\n\nrun :: proc() {render.draw(nil)}\n",
        .Checks="package game\n\nimport \"mirai:core\"\n\nrun :: proc() {core.checked()}\n",
        .Imports="package game\n\nimport _ \"mirai:core\"\n",
    }
    desc:=describe(root,[]string{"core","render"})
    desc.names=true
    index:=project.path(root,"engine.declared")
    keys :: proc(t:^testing.T,root:string,desc:Declare_Desc,index:string,consumers:[Consumer]string,core:[9]string,render:string) -> (keys:[Consumer]u64) {
        source_write(t,root,"core","core.odin",fmt.tprintf(CORE,core[0],core[1],core[2],core[3],core[4],core[5],core[6],core[7],core[8]))
        source_write(t,root,"render","render.odin",fmt.tprintf(RENDER,render))
        errors,_:=declaring(desc)
        if !declared_ok(t,errors) {return}
        testing.expect(t,declared_write(desc.decl,index))
        declared:=declared_read(index,context.temp_allocator)
        testing.expect(t,"mirai:core.Entity" in declared && "mirai:render.draw" in declared)
        for source,consumer in consumers {keys[consumer]=declared_key(declared,named_of(source))}
        return
    }
    before:=keys(t,root,desc,index,consumers,{},"")
    cases:=[]struct{what:string,core:[9]string,render:string,built_again:bit_set[Consumer]}{
        {what="the body of a procedure the library carries",core={2="+0"}},
        {what="a field of a type a signature reaches through another",core={0=",generation:u32"},built_again={.Counts}},
        {what="a field of a type reached through a pointer of another package",core={1=",scale:f32"},built_again={.Draws}},
        {what="the signature of a procedure",core={3="floor:=0"},built_again={.Limits}},
        {what="the body of an inline procedure",core={4="+0"},built_again={.Twices}},
        {what="the body of a private procedure an inline one calls",core={6="+0"}},
        {what="the signature of a private procedure an inline one calls",core={5=",y:=0"},built_again={.Twices}},
        {what="a declaration nothing names",core={7="\nextra :: proc() {}\n"}},
        {what="the condition of the when around a declaration",core={8=" && ODIN_OS==.Windows"},built_again={.Checks}},
        {what="the signature of a procedure of another package",render=",layer:=0",built_again={.Draws}},
    }
    for c in cases {
        after:=keys(t,root,desc,index,consumers,c.core,c.render)
        for consumer in Consumer {
            testing.expectf(t,(after[consumer]!=before[consumer])==(consumer in c.built_again),"%s: %v built again %v",c.what,consumer,after[consumer]!=before[consumer])
        }
    }
    // Without the index nothing is known, and what is not declared yet moves a key once it is.
    missing:=declared_read(project.path(root,"none"),context.temp_allocator)
    testing.expect_value(t,len(missing),0)
    names:=named_of("package game\n\nimport \"mirai:core\"\n\nrun :: proc() {core.extra()}\n")
    declared:=declared_read(index,context.temp_allocator)
    without:=declared_key(declared,names)
    _=keys(t,root,desc,index,consumers,{7="\nextra :: proc() {}\n"},"")
    declared=declared_read(index,context.temp_allocator)
    testing.expect(t,declared_key(declared,names)!=without,"a declaration that appears moves what already named it")
}

// The packages of a library are compiled together from the stage, as the
// collection it is compiled as, and every other package is its declarations:
// in the stage they import each other through that collection, and nothing
// else changes.
@(test)
the_packages_of_a_library_import_each_other_from_the_stage :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    root:=base.test_folder(t,"declare-staged")
    if root=="" {return}
    source_write(t,root,"thing","thing.odin","package thing\n\nimport \"core:fmt\"\nimport below \"mirai:thing/nested\"\nimport \"mirai:other\"\n\nvalue_of :: proc() -> int {return below.nested_of(other.ONE)}\n")
    source_write(t,root,"thing/nested","nested.odin","package thing_nested\n\nnested_of :: proc(value:int) -> int {return value}\n")
    desc:=describe(root,[]string{"thing","thing/nested"})
    desc.staged="staged"
    errors,_:=declaring(desc)
    if !declared_ok(t,errors) {return}
    staged,declaration:=declared(desc.stage,"thing","thing.odin"),declared(desc.decl,"thing","thing.odin")
    testing.expect(t,strings.contains(staged,"import below \"staged:thing/nested\"") && strings.contains(staged,"import \"mirai:other\"") && strings.contains(staged,"import \"core:fmt\""),staged)
    testing.expect(t,strings.contains(declaration,"import below \"mirai:thing/nested\""),declaration)
    testing.expect_value(t,strings.count(staged[:strings.index(staged,"value_of")],"\n"),6)
}

// A library of the engine is kept in the shared cache by what it is built
// from, and another checkout that builds it from the same takes it: the
// library, what links against it and its debug information, and nothing else.
// A library built from other sources, against other declarations or in
// another mode is another entry.
@(test)
a_library_of_the_engine_is_shared_by_what_it_is_built_from :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder:=base.test_folder(t,"cache")
    if folder=="" {return}
    first,second:=project.path(folder,"first"),project.path(folder,"deeper","second")
    libraries:=engine_libraries(.Dev)
    library:=libraries[0]
    built:=Library_Stamp{sources=1,tools=2}
    paths:=engine_paths(first,.Dev)
    testing.expect(t,os.make_directory_all(paths.folder)==nil)
    for name in engine_cache_files(library) {
        if name!="" {testing.expect(t,os.write_entire_file(project.path(paths.folder,name),name)==nil)}
    }
    testing.expect(t,os.write_entire_file(project.path(paths.folder,"mirai-other.txt"),"other")==nil)
    entry:=project.path(folder,"cache","entry")
    engine_cache_store(entry,paths,library)
    testing.expect(t,os.is_file(project.path(entry,CACHE_COMPLETE)),"the library is kept")
    testing.expect(t,!os.exists(project.path(entry,"mirai-other.txt")),"with nothing of another")
    testing.expect(t,base.remove_all(first)==nil)

    restored:=engine_paths(second,.Dev)
    testing.expect(t,os.make_directory_all(restored.folder)==nil)
    testing.expect(t,!engine_cache_take(project.path(folder,"cache","none"),restored,library),"an entry the cache does not have is not taken")
    if !testing.expect(t,engine_cache_take(entry,restored,library)) {return}
    // What links against it is made from its declarations, not kept.
    file,_:=engine_library_files(restored,library)
    testing.expect(t,os.is_file(file),"the library")

    keys:=make(map[string]bool)
    keys[engine_cache_entry(first,library,.Dev,built,3)]=true
    keys[engine_cache_entry(first,library,.Dev,{sources=9,tools=2},3)]=true
    keys[engine_cache_entry(first,library,.Dev,{sources=1,tools=9},3)]=true
    keys[engine_cache_entry(first,library,.Dev,built,9)]=true
    keys[engine_cache_entry(first,library,.Release,built,3)]=true
    keys[engine_cache_entry(first,libraries[1],.Dev,built,3)]=true
    testing.expect_value(t,len(keys),6)
    here,there:=engine_cache_entry(first,library,.Dev,built,3),engine_cache_entry(second,library,.Dev,built,3)
    testing.expect_value(t,here[strings.last_index_byte(here,'/'):],there[strings.last_index_byte(there,'/'):])

}

// A source without a package clause, a comment alone, is an error that names the file for the
// world generator and for declare, not a crash of the tool.
@(test)
a_source_without_a_package_clause_names_its_file :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder:=base.test_folder(t,"no-package")
    if folder=="" {return}
    engine,game:=project.path(folder,"engine"),project.path(folder,"project")
    write :: proc(t:^testing.T,path,text:string) {
        testing.expect(t,os.make_directory_all(os.dir(path))==nil)
        testing.expect(t,os.write_entire_file(path,text)==nil)
    }
    write(t,project.path(engine,"core","core.odin"),"package core\n\nvalue :: proc() -> int {return 1}\n")
    write(t,project.path(engine,"core","probe.odin"),"// probe\n")
    write(t,project.path(game,"game","game.odin"),"package game\n")
    p:=project.Project{root=game,engine_root=engine}
    generated:=world_generate(&p,context.temp_allocator).errors
    declared,_:=declare({root=engine,packages={"core"},binary="mirai",library=project.path(folder,"out","core.lib"),stage=project.path(folder,"out","stage"),decl=project.path(folder,"out","decl")})
    for errors,who in ([][]string{generated,declared}) {
        text:=strings.join(errors,"\n")
        testing.expectf(t,strings.contains(text,"probe.odin(") && strings.contains(text,"Expected a package declaration"),"%s: %s",who==0?"generator":"declare",text)
    }
}

// The keys of the declarations a source names (declared_named), from its parse.
@(private="file")
named_of :: proc(source:string) -> map[string]bool {
    file:=new(ast.File,context.temp_allocator)
    file^={src=source,fullpath="game.odin"}
    p:=parser.default_parser()
    names:=make(map[string]bool,context.temp_allocator)
    if !parser.parse_file(&p,file) {return names}
    declared_named({file},nil,&names)
    return names
}
