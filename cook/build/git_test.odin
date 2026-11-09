package build

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:project"
import "mirai:std/subprocess"

// The attributes the line of a kind gives its files; "" without a line of its own, or with two.
@(private="file")
attributes_of :: proc(text,extension:string) -> string {
    found,count:="",0
    rest:=text
    for line in strings.split_lines_iterator(&rest) {
        if strings.has_prefix(line,strings.concatenate({"*",extension," "},context.temp_allocator)) {found=line[len(extension)+2:];count+=1}
    }
    return count==1?found:""
}

@(test)
git_attributes_follow_the_kinds_and_keep_the_other_lines :: proc(t:^testing.T) {
    plugins:=[]Git_Kind{{".particle",true},{".grid",false},{".mesh",true},{"",true}}
    existing:="* text=auto eol=lf\n*.scene binary\n# kept\n\n*.cmd text eol=crlf\n"
    text,changed:=git_attributes(plugins,false,existing,context.temp_allocator)
    testing.expect(t,changed)
    merges :: proc(attributes:string) -> bool {return strings.contains(attributes,"merge="+GIT_DRIVER) && strings.contains(attributes,"diff="+GIT_DRIVER) && strings.contains(attributes,"-text")}
    for info in asset.KINDS {
        attributes:=attributes_of(text,info.extension)
        testing.expectf(t,info.merged?merges(attributes):attributes=="binary","%s: %q",info.extension,attributes)
    }
    testing.expect(t,merges(attributes_of(text,".particle")),"a document of a plugin merges and diffs")
    testing.expect_value(t,attributes_of(text,".grid"),"binary")
    testing.expect(t,strings.has_prefix(text,"* text=auto eol=lf\n# kept\n\n*.cmd text eol=crlf\n*"),"the lines of other files stay, before those of the kinds")
    again:string
    again,changed=git_attributes(plugins,false,text,context.temp_allocator)
    testing.expect(t,again==text && !changed,"made again from its own text it comes out the same")
    crlf,_:=strings.replace_all(text,"\n","\r\n",context.temp_allocator)
    again,changed=git_attributes(plugins,false,crlf,context.temp_allocator)
    testing.expect(t,again==text && !changed,"line ends are no change")

    large,_:=git_attributes(plugins,true,existing,context.temp_allocator)
    for info in asset.KINDS {
        attributes:=attributes_of(large,info.extension)
        testing.expectf(t,info.merged?merges(attributes):strings.contains(attributes,"filter=lfs"),"%s with LFS: %q",info.extension,attributes)
    }
    testing.expect(t,strings.contains(attributes_of(large,".grid"),"filter=lfs") && strings.contains(attributes_of(large,".png"),"filter=lfs"))
    again,changed=git_attributes(plugins,false,large,context.temp_allocator)
    testing.expect(t,again==large && !changed,"a file that keeps files in LFS keeps them there")
    free_all(context.temp_allocator)
}

@(test)
the_git_attributes_of_the_engine_follow_its_kinds :: proc(t:^testing.T) {
    file:=project.path(project.path_absolute(#directory+"../..",context.temp_allocator),".gitattributes",allocator=context.temp_allocator)
    data,error:=os.read_entire_file(file,context.temp_allocator)
    if !testing.expectf(t,error==nil,"%s does not read",file) {return}
    _,changed:=git_attributes(existing=string(data),allocator=context.temp_allocator)
    testing.expect(t,!changed,"the .gitattributes of the engine does not have the lines of asset.KINDS: `./mirai setup git` writes them")
    free_all(context.temp_allocator)
}

@(private="file")
git :: proc(folder:string,arguments:..string) -> (out:string,ok:bool) {
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,"git","-C",folder)
    append(&command,..arguments)
    state,printed,_,error:=subprocess.exec({command=command[:]},context.temp_allocator)
    return strings.trim_space(string(printed)),error==nil && state.exit_code==0
}

@(test)
git_setup_wires_a_clone_once_and_again_for_another_engine :: proc(t:^testing.T) {
    if _,_,_,missing:=subprocess.exec({command={"git","--version"}},context.temp_allocator);missing!=nil {log.warn("git is not installed: the setup of a clone is not tested");return}
    root,made:=os.make_directory_temp("","mirai-git-*",context.temp_allocator)
    if !testing.expect(t,made==nil) {return}
    defer os.remove_all(root)
    root=project.path_absolute(root,context.temp_allocator)
    join :: proc(parts:..string) -> string {return project.path(..parts,allocator=context.temp_allocator)}
    engine,other,clone:=join(root,"engine"),join(root,"other engine"),join(root,"clone")
    testing.expect(t,os.make_directory_all(join(clone,"game"))==nil)

    _,error:=git_setup(engine,clone,context.temp_allocator)
    testing.expect_value(t,error,Git_Setup_Error.No_Repository)
    _,initialized:=git(clone,"init","-q")
    if !testing.expect(t,initialized) {return}
    state,_:=git_wiring(engine,clone,context.temp_allocator)
    testing.expect_value(t,state,Git_Wiring.None)

    // From a folder inside it, as from its top.
    done:Git_Setup
    done,error=git_setup(engine,join(clone,"game"),context.temp_allocator)
    testing.expect_value(t,error,Git_Setup_Error.None)
    testing.expect_value(t,done.settings,GIT_SETTINGS)
    testing.expect(t,done.attributes!="" && os.is_file(join(clone,".gitattributes")),"the .gitattributes goes to the top of the clone")
    driver,_:=git(clone,"config","--local","merge."+GIT_DRIVER+".driver")
    testing.expectf(t,strings.contains(driver,engine) && strings.has_suffix(driver,"asset merge %O %A %B"),"%q",driver)
    textconv,_:=git(clone,"config","--local","diff."+GIT_DRIVER+".textconv")
    testing.expectf(t,strings.contains(textconv,engine) && strings.has_suffix(textconv,"asset dump --textconv"),"%q",textconv)
    state,_=git_wiring(engine,clone,context.temp_allocator)
    testing.expect_value(t,state,Git_Wiring.Wired)

    done,error=git_setup(engine,clone,context.temp_allocator)
    testing.expect_value(t,error,Git_Setup_Error.None)
    testing.expect(t,done.settings==0 && done.attributes=="","a second run writes nothing")

    state,_=git_wiring(other,clone,context.temp_allocator)
    testing.expect_value(t,state,Git_Wiring.Other)
    done,error=git_setup(other,clone,context.temp_allocator)
    testing.expect(t,error==.None && done.settings>0 && done.settings<GIT_SETTINGS,"an engine that moved writes the settings that name it")
    state,_=git_wiring(other,clone,context.temp_allocator)
    testing.expect_value(t,state,Git_Wiring.Wired)

    // A clone that brings the .gitattributes and has no drivers yet.
    _,unset:=git(clone,"config","--local","--remove-section","merge."+GIT_DRIVER)
    testing.expect(t,unset)
    state,_=git_wiring(other,clone,context.temp_allocator)
    testing.expect_value(t,state,Git_Wiring.Unset)

    // A checkout of the engine names its own launcher, wherever it is.
    testing.expect(t,os.make_directory_all(join(clone,"tools/mirai"))==nil)
    for file in ([]string{"AGENTS.md","mirai"}) {testing.expect(t,os.write_entire_file(join(clone,file),"")==nil)}
    for setting in git_settings(other,clone,context.temp_allocator) {
        testing.expectf(t,!strings.contains(setting.value,root),"%s = %s names a folder of this machine",setting.key,setting.value)
    }
    free_all(context.temp_allocator)
}
