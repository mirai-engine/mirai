package build

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:project"
import "mirai:std/base"

// Each mode has its folder; Keep is the one built last, Release with none.
@(test)
engine_modes_have_folders_of_their_own :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    root:=base.test_folder(t,"engine-modes")
    if root=="" {return}
    dev,release:=engine_paths(root,.Dev),engine_paths(root,.Release)
    testing.expect(t,dev.folder!=release.folder && dev.decl!=release.decl)
    testing.expect_value(t,engine_mode_resolve(root,.Keep),Engine_Mode.Release)
    testing.expect_value(t,engine_mode_resolve(root,.Dev),Engine_Mode.Dev)
    for paths,i in ([2]Engine_Paths{release,dev}) {
        testing.expect(t,os.make_directory_all(paths.folder)==nil)
        testing.expect(t,engine_stamp_write(paths.stamp,{libraries=#partial{.Base={sources=1,tools=2}},programs=3,declares=DECLARE_VERSION})==nil)
        if i==0 {time.sleep(20*time.Millisecond)}
    }
    testing.expect_value(t,engine_mode_resolve(root,.Keep),Engine_Mode.Dev)
    testing.expect_value(t,engine_paths(root,.Keep).folder,dev.folder)
    stamp,read:=engine_stamp_read(dev.stamp)
    testing.expect(t,read)
    testing.expect_value(t,stamp,Engine_Stamp{libraries=#partial{.Base={sources=1,tools=2}},programs=3,declares=DECLARE_VERSION})
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
    testing.expect(t,!engine_current(root,.Keep))
    paths:=engine_paths(root,.Dev)
    testing.expect(t,os.make_directory_all(paths.decl)==nil)
    files:=make([dynamic]string,context.temp_allocator)
    for library,which in paths.libraries {append(&files,library,paths.imports[which])}
    append(&files,paths.editor_program,paths.player_program,paths.import_program,paths.author_program,paths.stamp)
    for file in files {
        testing.expect(t,os.write_entire_file(file,"built")==nil,file)
    }
    result=engine_build({engine_root=root,mode=.Dev})
    testing.expect_value(t,result.status,Status.Up_To_Date)
    testing.expect_value(t,result.mode,ENGINE_MODE_INSTALLED)
    testing.expect(t,engine_current(root,.Dev))
    stamped,current:=engine_state(root,.Keep)
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
    source:=project.path(folder,"engine","thing","thing.odin")
    testing.expect(t,os.make_directory_all(os.dir(source))==nil)
    write :: proc(t:^testing.T,path,text:string) {testing.expect(t,os.write_entire_file(path,text)==nil)}
    write(t,source,"package thing\n\nvalue :: proc(x:int) -> int {return x+1}\n")
    desc:=Declare_Desc{root=project.path(folder,"engine"),packages={"thing"},binary="mirai",library=project.path(folder,"out","thing.lib"),stage=project.path(folder,"out","stage"),decl=project.path(folder,"out","decl")}
    errors,changed:=declare(desc)
    testing.expect_value(t,len(errors),0)
    testing.expect(t,changed.stage && changed.decl,"the first declaration writes both")
    _,changed=declare(desc)
    testing.expect(t,!changed.stage && !changed.decl,"the same sources declare nothing new")
    write(t,source,"package thing\n\nvalue :: proc(x:int) -> int {return x+2}\n")
    _,changed=declare(desc)
    testing.expect(t,changed.stage && !changed.decl,"a body moves the stage and is not declared")
    write(t,source,"package thing\n\nvalue :: proc(x,y:int) -> int {return x+y}\n")
    _,changed=declare(desc)
    testing.expect(t,changed.decl,"another signature is another declaration")
    extra:=project.path(folder,"engine","thing","more.odin")
    write(t,extra,"package thing\n\nmore :: proc() {}\n")
    _,changed=declare(desc)
    testing.expect(t,changed.stage && changed.decl)
    testing.expect(t,os.remove(extra)==nil)
    _,changed=declare(desc)
    testing.expect(t,changed.stage && changed.decl,"a file taken out of the package goes")
    testing.expect(t,!os.exists(project.path(folder,"out","decl","thing","more.odin")))
    testing.expect(t,!os.exists(project.path(folder,"out","stage","thing","more.odin")))
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
    stage_before,declaration_before:=modified(stage),modified(declaration)
    if !testing.expect(t,stage_before>0 && declaration_before>0,"both are written") {return}

    // The file times come from a clock that ticks every few milliseconds: two
    // writes inside one tick would look like one.
    time.sleep(20*time.Millisecond)

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
    nested_before:=modified(nested_decl)

    time.sleep(20*time.Millisecond)
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

    _,stamped:=engine_stamp_read(file)
    testing.expect(t,!stamped,"a stamp that is not there is not read")

    testing.expect(t,os.write_entire_file(file,"not a stamp")==nil)
    _,stamped=engine_stamp_read(file)
    testing.expect(t,!stamped,"a stamp that does not parse is not read")

    testing.expect(t,os.write_entire_file(file,"1 2 3 Modules")==nil)
    _,stamped=engine_stamp_read(file)
    testing.expect(t,!stamped,"a stamp of another shape is not read")

    written:=Engine_Stamp{programs=0x123,declares=DECLARE_VERSION}
    for &library,which in written.libraries {library={sources=0xabc+u64(which),tools=0x456+u64(which)}}
    for &hash,index in written.declared {hash=0xfed+u64(index)}
    testing.expect(t,engine_stamp_write(file,written)==nil)
    read,ok:=engine_stamp_read(file)
    testing.expect(t,ok,"the stamp a build writes is read")
    testing.expect_value(t,read,written)
    testing.expect(t,!strings.contains(engine_stamp_of(root,context.temp_allocator),"\n"),"what a program keeps of the stamp is one line")

    text,_:=os.read_entire_file(file,context.temp_allocator)
    lines:=strings.split_lines(string(text),context.temp_allocator)
    extra,letters,swapped:=slice.clone(lines,context.temp_allocator),slice.clone(lines,context.temp_allocator),slice.clone(lines,context.temp_allocator)
    extra[0]=strings.concatenate({lines[0]," 9"},context.temp_allocator)
    without_library:=slice.clone(lines,context.temp_allocator)
    without_library[0]=lines[0][:strings.last_index_byte(lines[0],' ')]
    without_library[0]=without_library[0][:strings.last_index_byte(without_library[0],' ')]
    letters[0]=strings.concatenate({"zz",lines[0]},context.temp_allocator)
    swapped[1],swapped[2]=lines[2],lines[1]
    cases:=[]struct{what:string,lines:[]string}{
        {"a stamp with an extra field",extra},
        {"a stamp without one of the libraries",without_library},
        {"a stamp whose hashes are not numbers",letters},
        {"a stamp without one of the packages",lines[:len(lines)-1]},
        {"a stamp with its packages in another order",swapped},
    }
    for c in cases {
        testing.expect(t,os.write_entire_file(file,strings.join(c.lines,"\n",context.temp_allocator))==nil)
        _,stamped=engine_stamp_read(file)
        testing.expectf(t,!stamped,"%s is not read",c.what)
    }
}

// What the build decides of a library once declare has run: the library
// follows its stage, so sources that stage the same do not compile again;
// what moved the compiler or the flags compiles it anyway.
@(test)
a_library_of_the_engine_follows_its_stage :: proc(t:^testing.T) {
    testing.expect(t,!engine_library_compile(false,true,false,false),"a stage that did not change is not compiled")
    testing.expect(t,engine_library_compile(false,true,true,false),"the stage that changed is compiled")
    testing.expect(t,engine_library_compile(true,true,false,false),"--force compiles the library")
    testing.expect(t,engine_library_compile(false,true,false,true),"a changed compiler or flags compiles the library")
    testing.expect(t,engine_library_compile(false,false,false,false),"a library that is not there is compiled")
}

// A library compiles against the declarations its sources import from the
// libraries it needs: a declaration that changes builds again the libraries
// that reach its package and no other. A literal that names a package of a
// library above is no import, since nothing above a library is staged for it.
@(test)
a_library_follows_the_declarations_it_reaches_below :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    root:=base.test_folder(t,"declare-reach")
    if root=="" {return}
    source_write(t,root,"core","core.odin","package core\n")
    source_write(t,root,"render","render.odin","package render\n\nimport \"mirai:core\"\n")
    source_write(t,root,"cook/build","build.odin","package build\n\nimport \"mirai:render\"\n\nPROGRAM :: `import \"mirai:editor\"`\n")
    source_write(t,root,"editor","editor.odin","package editor\n\nimport \"mirai:ui\"\n")
    paths:=engine_paths(root,.Dev)
    reaches:[Engine_Library][ENGINE_PACKAGE_COUNT]bool
    for &reached,library in reaches {reached=engine_library_reach(root,paths,library)}
    index :: proc(t:^testing.T,path:string) -> int {
        at,found:=engine_package_index(path)
        testing.expect(t,found,path)
        return at
    }
    core,render,ui,editor:=index(t,"core"),index(t,"render"),index(t,"ui"),index(t,"editor")
    testing.expect(t,reaches[.Engine][core] && reaches[.Cook][render] && reaches[.Editor][ui])
    testing.expect(t,!reaches[.Cook][editor],"a library reaches nothing of a library above it")
    testing.expect(t,reaches[.Base]=={},"the lowest library compiles against no other")

    before:[ENGINE_PACKAGE_COUNT]u64
    for &hash,at in before {hash=0x100+u64(at)}
    cases:=[]struct{what:string,changed:int,built_again:bit_set[Engine_Library]}{
        {"a declaration of the lowest library",core,{.Engine}},
        {"a declaration only the editor imports",ui,{.Editor}},
        {"a declaration of the highest library",editor,{}},
    }
    for c in cases {
        after:=before
        after[c.changed]+=1
        for &reached,library in reaches {
            testing.expectf(t,declared_same(&before,&after,&reached)==(library not_in c.built_again),"%s: %v",c.what,library)
        }
    }
    unknown:=before
    unknown[render]=0
    testing.expect(t,!declared_same(&unknown,&unknown,&reaches[.Cook]),"what reaches a declaration without a hash is built again")
    testing.expect(t,declared_same(&unknown,&unknown,&reaches[.Engine]))
}

// A stage gets the declarations it compiles against as they are, copying
// only what changed.
@(test)
decl_mirror_copies_what_changed_and_drops_what_went :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder:=base.test_folder(t,"mirror")
    if folder=="" {return}
    decl,stage:=project.path(folder,"decl"),project.path(folder,"stage")
    testing.expect(t,os.make_directory_all(project.path(decl,"core"))==nil)
    testing.expect(t,os.write_entire_file(project.path(decl,"core","a.odin"),"package core\na :: 1\n")==nil)
    testing.expect(t,os.write_entire_file(project.path(decl,"core","b.odin"),"package core\nb :: 1\n")==nil)
    testing.expect(t,decl_mirror(stage,decl,{"core"}))
    data,_:=os.read_entire_file(project.path(stage,"core","b.odin"),context.temp_allocator)
    testing.expect_value(t,string(data),"package core\nb :: 1\n")
    testing.expect(t,os.remove(project.path(decl,"core","b.odin"))==nil)
    testing.expect(t,os.write_entire_file(project.path(decl,"core","a.odin"),"package core\na :: 22\n")==nil)
    testing.expect(t,decl_mirror(stage,decl,{"core"}))
    data,_=os.read_entire_file(project.path(stage,"core","a.odin"),context.temp_allocator)
    testing.expect_value(t,string(data),"package core\na :: 22\n")
    testing.expect(t,!os.exists(project.path(stage,"core","b.odin")))
}

// An entry of the shared cache restores into a checkout at another place, once
// the checkout that stored it is gone: the declarations load their files, and
// link against the library, by paths that stand in every checkout. The stages
// there go: the libraries restored were not compiled from them.
@(test)
a_cache_entry_restores_into_another_checkout_without_naming_the_first :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder:=base.test_folder(t,"cache")
    if folder=="" {return}
    source:="package thing\n\nDATA :: #load(\"../assets/data.txt\")\n\nTable :: [1]struct{binary:[]byte}{{binary = #load(\"../assets/data.txt\")}}\n\nvalue_of :: proc(value:int) -> int {return value}\n"
    first,second:=project.path(folder,"first"),project.path(folder,"deeper","second")
    for root in ([2]string{first,second}) {
        source_write(t,root,"thing","thing.odin",source)
        source_write(t,root,"assets","data.txt","data")
    }
    paths:=engine_paths(first,.Dev)
    errors,_:=declaring({root=first,packages={"thing"},binary="mirai",library=paths.imports[.Base],stage=paths.stages[.Base],decl=paths.decl})
    if !declared_ok(t,errors) {return}
    testing.expect(t,os.make_directory_all(paths.folder)==nil)
    for file in ([2]string{paths.libraries[.Base],paths.imports[.Base]}) {testing.expect(t,os.write_entire_file(file,"library")==nil)}
    testing.expect(t,engine_stamp_write(paths.stamp,{libraries=#partial{.Base={sources=1,tools=2}},programs=3,declares=DECLARE_VERSION})==nil)
    entry:=project.path(folder,"cache","entry")
    engine_cache_store(paths,entry)
    testing.expect(t,os.is_file(project.path(entry,CACHE_COMPLETE)),"the build is kept")
    testing.expect(t,os.remove_all(first)==nil)

    restored:=engine_paths(second,.Dev)
    testing.expect(t,os.make_directory_all(restored.stages[.Editor])==nil)
    if !testing.expect(t,engine_cache_restore(entry,restored)) {return}
    testing.expect(t,os.is_file(restored.libraries[.Base]) && os.is_file(restored.imports[.Base]) && os.is_file(restored.stamp))
    testing.expect(t,!os.exists(restored.stages[.Editor]),"a stage of other libraries does not stay")
    text:=declared(restored.decl,"thing","thing.odin")
    testing.expect(t,text!="" && !strings.contains(text,"first"),"the declarations name nothing of the first checkout")
    loaded:=0
    rest:=text
    for {
        at:=strings.index(rest,"#load(\"")
        if at<0 {break}
        rest=rest[at+len("#load(\""):]
        path:=rest[:strings.index_byte(rest,'"')]
        resolved,_:=filepath.join({restored.decl,"thing",path},context.temp_allocator)
        testing.expectf(t,os.is_file(resolved),"%s is loaded from the second checkout",path)
        loaded+=1
    }
    testing.expect_value(t,loaded,2)
    linked:=strings.index(text,"foreign import __mirai \"")
    if testing.expect(t,linked>=0) {
        rest=text[linked+len("foreign import __mirai \""):]
        resolved,_:=filepath.join({restored.decl,"thing",rest[:strings.index_byte(rest,'"')]},context.temp_allocator)
        testing.expect(t,os.is_file(resolved),"the declarations link against the library of the second checkout")
    }
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
