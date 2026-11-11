package shaders

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:std/base"
import "mirai:project"

// A package like the official ones, made with the tar of the system: bin/slangc and a library.
@(private="file")
archive_make :: proc(t:^testing.T,root,compiler_text:string,with_compiler:=true) -> (archive,sha256:string,ok:bool) {
    content:=path_join(root,"content",allocator=context.temp_allocator)
    os.remove_all(content)
    if with_compiler {fixture_write(t,content,strings.concatenate({"bin/slangc",project.EXECUTABLE_SUFFIX},context.temp_allocator),compiler_text)}
    fixture_write(t,content,"lib/slang.txt","library")
    archive=path_join(root,"slang-test.tar.gz",allocator=context.temp_allocator)
    runner:Runner
    output,made:=tool_run(&runner,{system_tool("tar"),"-czf",archive,"-C",content,"."},context.temp_allocator)
    if !made {log.warnf("tar is not available: the installation of Slang is not tested (%s)",strings.trim_space(output));return "","",false}
    data,_:=os.read_entire_file(archive,context.temp_allocator)
    return archive,sha_of(data,context.temp_allocator),true
}

@(private="file")
slang_test_package :: proc(sha256:string) -> Prebuilt {
    return {name="Slang",version=SLANG_VERSION,folder="slang",asset="slang-test.tar.gz",sha256=sha256,required=strings.concatenate({"bin/slangc",project.EXECUTABLE_SUFFIX},context.temp_allocator)}
}

// A package whose files are under one folder of the archive, like the releases of ripgrep.
@(test)
prebuilt_package_takes_its_files_from_the_top_folder :: proc(t:^testing.T) {
    root:=base.test_folder(t,"shaders")
    if root=="" {return}
    content:=path_join(root,"content",allocator=context.temp_allocator)
    fixture_write(t,content,"tool-1.0/tool.txt","the tool")
    archive:=path_join(root,"tool-1.0.tar.gz",allocator=context.temp_allocator)
    runner:Runner
    output,made:=tool_run(&runner,{system_tool("tar"),"-czf",archive,"-C",content,"."},context.temp_allocator)
    if !made {log.warnf("tar is not available: the installation of a package is not tested (%s)",strings.trim_space(output));return}
    data,_:=os.read_entire_file(archive,context.temp_allocator)
    p:=Prebuilt{name="Tool",version="1.0",folder="tool",asset="tool-1.0.tar.gz",sha256=sha_of(data,context.temp_allocator),top="tool-1.0",required="tool.txt"}
    target:=path_join(root,".deps/tool",allocator=context.temp_allocator)
    message,ok:=prebuilt_install_archive(target,archive,p,context.temp_allocator)
    testing.expect(t,ok,message)
    text,_:=os.read_entire_file(path_join(target,"tool.txt",allocator=context.temp_allocator),context.temp_allocator)
    testing.expect_value(t,string(text),"the tool")
    testing.expect(t,prebuilt_installed(target,p.sha256))
    p.required="missing.txt"
    message,ok=prebuilt_install_archive(path_join(root,".deps/other",allocator=context.temp_allocator),archive,p,context.temp_allocator)
    testing.expect(t,!ok && strings.contains(message,"missing.txt"),message)
}

@(test)
slang_package_is_checked_unpacked_and_marked :: proc(t:^testing.T) {
    root:=base.test_folder(t,"shaders")
    if root=="" {return}
    archive,sha256,made:=archive_make(t,root,"first compiler")
    if !made {return}
    target:=path_join(root,".deps/slang",allocator=context.temp_allocator)
    testing.expect(t,!prebuilt_installed(target,sha256))
    message,ok:=prebuilt_install_archive(target,archive,slang_test_package(sha256),context.temp_allocator)
    testing.expect(t,ok,message)
    compiler,_:=os.read_entire_file(path_join(target,"bin",strings.concatenate({"slangc",project.EXECUTABLE_SUFFIX},context.temp_allocator),allocator=context.temp_allocator),context.temp_allocator)
    testing.expect_value(t,string(compiler),"first compiler")
    testing.expect(t,os.is_file(path_join(target,"lib/slang.txt",allocator=context.temp_allocator)))
    testing.expect(t,prebuilt_installed(target,sha256),"the marker names the package that was installed")
    testing.expect(t,!prebuilt_installed(target,"another hash"))
    marker,_:=os.read_entire_file(path_join(target,"mirai-package.json",allocator=context.temp_allocator),context.temp_allocator)
    testing.expect_value(t,string(marker),strings.concatenate({"{\n  \"version\": \"",SLANG_VERSION,"\",\n  \"asset\": \"slang-test.tar.gz\",\n  \"sha256\": \"",sha256,"\"\n}\n"},context.temp_allocator))
    found,located:=tool_find(root,.Slangc,context.temp_allocator)
    if _,configured:=os.lookup_env("MIRAI_SLANGC",context.temp_allocator);!configured {
        if _,also:=os.lookup_env("MIRAI_SLANG",context.temp_allocator);!also {testing.expect(t,located && path_inside(found,target),"the generator finds the installed compiler")}
    }
    // Another package replaces the installation whole.
    archive,sha256,_=archive_make(t,root,"second compiler")
    message,ok=prebuilt_install_archive(target,archive,slang_test_package(sha256),context.temp_allocator)
    testing.expect(t,ok,message)
    compiler,_=os.read_entire_file(path_join(target,"bin",strings.concatenate({"slangc",project.EXECUTABLE_SUFFIX},context.temp_allocator),allocator=context.temp_allocator),context.temp_allocator)
    testing.expect_value(t,string(compiler),"second compiler")
    siblings,_:=os.read_all_directory_by_path(path_join(root,".deps",allocator=context.temp_allocator),context.temp_allocator)
    testing.expectf(t,len(siblings)==1,"nothing but the installation is left in .deps: %d entries",len(siblings))
}

@(test)
slang_package_with_another_hash_or_without_compiler_changes_nothing :: proc(t:^testing.T) {
    root:=base.test_folder(t,"shaders")
    if root=="" {return}
    archive,sha256,made:=archive_make(t,root,"good compiler")
    if !made {return}
    target:=path_join(root,".deps/slang",allocator=context.temp_allocator)
    message,ok:=prebuilt_install_archive(target,archive,slang_test_package(sha256),context.temp_allocator)
    testing.expect(t,ok,message)
    message,ok=prebuilt_install_archive(target,archive,slang_test_package("0000"),context.temp_allocator)
    testing.expect(t,!ok && strings.contains(message,"Wrong SHA-256"),message)
    empty,empty_sha,_:=archive_make(t,root,"",with_compiler=false)
    message,ok=prebuilt_install_archive(target,empty,slang_test_package(empty_sha),context.temp_allocator)
    testing.expect(t,!ok && strings.contains(message,"bin/slangc"),message)
    message,ok=prebuilt_install_archive(target,path_join(root,"missing.tar.gz",allocator=context.temp_allocator),slang_test_package(sha256),context.temp_allocator)
    testing.expect(t,!ok)
    compiler,_:=os.read_entire_file(path_join(target,"bin",strings.concatenate({"slangc",project.EXECUTABLE_SUFFIX},context.temp_allocator),allocator=context.temp_allocator),context.temp_allocator)
    testing.expect_value(t,string(compiler),"good compiler")
    testing.expect(t,prebuilt_installed(target,sha256),"the previous installation is intact")
}

@(test)
archive_entry_must_stay_inside_its_destination :: proc(t:^testing.T) {
    for entry in ([]string{"bin/slangc","./bin/slangc.exe","lib/","a..b/c","share/doc/..hidden"}) {testing.expectf(t,archive_entry_confined(entry),"%s is inside",entry)}
    for entry in ([]string{"../outside","bin/../../outside","/etc/passwd","C:/Windows/x","bin\\..\\..\\outside","\\\\server\\share"}) {testing.expectf(t,!archive_entry_confined(entry),"%s is outside",entry)}
}

@(test)
slang_package_of_this_platform_is_pinned :: proc(t:^testing.T) {
    package_info,supported:=slang_package()
    if !supported {return}
    testing.expect_value(t,len(package_info.sha256),64)
    testing.expect(t,strings.has_suffix(package_info.suffix,".zip") || strings.has_suffix(package_info.suffix,".tar.gz"))
    // The engine's own checkout is installed already when its marker names this package.
    target:=path_join(path_clean(ENGINE_ROOT,context.temp_allocator),".deps/slang",allocator=context.temp_allocator)
    if !prebuilt_installed(target,package_info.sha256) {return}
    message,ok:=slang_install(ENGINE_ROOT,"",context.temp_allocator)
    testing.expect(t,ok && strings.contains(message,"already installed"),message)
}

// A compiler the engine accepts is the pinned one or a later one; anything it
// cannot compare, and anything older, is not.
@(test)
a_slang_version_is_the_pinned_one_or_a_later_one :: proc(t:^testing.T) {
    cases := [?]struct {
        version:  string,
        accepted: bool,
    }{
        {SLANG_VERSION, true},
        {"2026.20", true},
        {"2026.20.1", true},
        {"2026.21", true},
        {"2027.1", true},
        {"v2026.20", true},
        {"2026.20.0-1-g84792eb15", true},
        {"2026.19.9", false},
        {"2026.13.1-1-g84792eb15", false},
        {"2025.99", false},
        {"", false},
        {"unknown", false},
    }
    for c in cases {
        testing.expectf(t,slang_version_at_least(c.version,SLANG_VERSION)==c.accepted,
            "%q should compare as %v against %s",c.version,c.accepted,SLANG_VERSION)
    }
}
