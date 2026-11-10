package build

import "core:os"
import "core:strings"
import "core:testing"
import "mirai:cook/shaders"
import "mirai:project"
import "mirai:std/base"

@(private="file")
shaders_write :: proc(t:^testing.T,parts:..string,text:="") {
    file:=project.path(..parts,allocator=context.temp_allocator)
    directory:=file[:strings.last_index_byte(file,'/')]
    testing.expect(t,os.make_directory_all(directory)==nil || os.is_dir(directory))
    testing.expect(t,os.write_entire_file(file,text)==nil,file)
}

// A project with three plugins that declare shaders: glow (active), fog
// (active, its folder without a Slang source) and dust (not active).
@(private="file")
shaders_fixture :: proc(t:^testing.T,root:string,own:bool) {
    m:=project.manifest_default("Shader Game")
    base.text_set(m.plugins[0][:],"glow")
    base.text_set(m.plugins[1][:],"fog")
    shaders_write(t,root,project.PROJECT_FILE,text=project.manifest_text(&m,context.temp_allocator))
    if own {shaders_write(t,root,"shaders","nested","pulse.slang",text="//! mirai surface Pulse\n")}
    else {shaders_write(t,root,"shaders","notes.txt",text="no programs here")}
    for name in ([]string{"glow","fog","dust"}) {
        plugin:project.Plugin_Manifest
        base.text_set(plugin.name[:],name)
        base.text_set(plugin.version[:],"1.0.0")
        plugin.parts={.Shaders}
        shaders_write(t,root,"plugins",name,project.PLUGIN_FILE,text=project.plugin_text(&plugin,context.temp_allocator))
        shaders_write(t,root,"plugins",name,"shaders",name=="fog"?"readme.txt":"program.slang",text="//! mirai surface X\n")
    }
}

@(test)
shader_sources_are_those_of_the_project_and_of_its_active_plugins :: proc(t:^testing.T) {
    root:=base.test_folder(t,"build-shaders")
    if root=="" {return}
    shaders_fixture(t,root,true)
    p,error:=project.open(root,"")
    defer project.close(&p)
    testing.expect_value(t,error.code,project.Error_Code.None)
    sources,own:=shader_sources(&p,context.temp_allocator)
    testing.expect(t,own,"a Slang source in a subfolder of shaders/ counts")
    testing.expect_value(t,len(sources),1)
    if len(sources)==1 {
        testing.expect_value(t,sources[0].name,"glow")
        testing.expect_value(t,sources[0].folder,project.path(root,"plugins/glow/shaders",allocator=context.temp_allocator))
    }
    testing.expect_value(t,project.shader_generation(root,context.temp_allocator),project.path(root,".mirai/shaders",allocator=context.temp_allocator))
}

@(test)
a_project_without_programs_has_no_generation_and_drops_the_one_it_had :: proc(t:^testing.T) {
    root:=base.test_folder(t,"build-shaders")
    if root=="" {return}
    m:=project.manifest_default("Plain Game")
    shaders_write(t,root,project.PROJECT_FILE,text=project.manifest_text(&m,context.temp_allocator))
    shaders_write(t,root,"shaders","notes.txt",text="no programs here")
    p,error:=project.open(root,"")
    defer project.close(&p)
    testing.expect_value(t,error.code,project.Error_Code.None)
    testing.expect_value(t,project.shader_generation_find(root,context.temp_allocator),"")

    job:=shaders_run(&p)
    testing.expect_value(t,job.result.status,Shaders_Status.None)
    testing.expect(t,shaders_poll(job))
    shaders_destroy(job)
    testing.expect(t,!os.exists(project.shader_generation(root,context.temp_allocator)),"nothing is created for a project without programs")

    shaders_write(t,root,".mirai","shaders","manifest.json",text="{}")
    shaders_write(t,root,".mirai","shaders","blit.frag.spv",text="code")
    testing.expect_value(t,project.shader_generation_find(root,context.temp_allocator),project.shader_generation(root,context.temp_allocator))
    job=shaders_run(&p)
    testing.expect_value(t,job.result.status,Shaders_Status.None)
    shaders_destroy(job)
    testing.expect_value(t,project.shader_generation_find(root,context.temp_allocator),"")
    shaders_destroy(nil)
}

@(test)
shaders_that_cannot_be_generated_say_why_and_leave_what_was_published :: proc(t:^testing.T) {
    root:=base.test_folder(t,"build-shaders")
    if root=="" {return}
    engine:=base.test_folder(t,"build-shaders")
    if engine=="" {return}
    shaders_fixture(t,root,true)
    shaders_write(t,root,".mirai","shaders","manifest.json",text="{}")

    // Without the root of the engine there is nothing to compile with.
    p,error:=project.open(root,"")
    testing.expect_value(t,error.code,project.Error_Code.None)
    job:=shaders_run(&p)
    testing.expect_value(t,job.result.status,Shaders_Status.Failed)
    testing.expect(t,job.result.message!="")
    shaders_destroy(job)
    project.close(&p)

    // An engine folder without shaders or tools: the generation fails on its
    // thread with the message of the generator, and nothing is replaced.
    p,error=project.open(root,engine)
    defer project.close(&p)
    testing.expect_value(t,error.code,project.Error_Code.None)
    job=shaders_start(&p)
    result:=shaders_wait(job)
    testing.expect_value(t,result.status,Shaders_Status.Failed)
    testing.expect(t,result.message!="",result.message)
    // On a machine without Slang the message names the tool and how to get it.
    if _,installed:=shaders.tool_find(engine,.Slangc,context.temp_allocator);!installed {
        testing.expect(t,strings.contains(result.message,"slangc") && strings.contains(result.message,"mirai setup slang"),result.message)
    }
    testing.expect_value(t,result.output,project.shader_generation(root,context.temp_allocator))
    testing.expect(t,shaders_poll(job))
    shaders_destroy(job)
    manifest,_:=os.read_entire_file(project.path(root,".mirai/shaders/manifest.json",allocator=context.temp_allocator),context.temp_allocator)
    testing.expect_value(t,string(manifest),"{}")
}

@(test)
a_game_carries_the_manifest_the_catalog_and_the_code_of_its_system :: proc(t:^testing.T) {
    root:=base.test_folder(t,"build-shaders")
    if root=="" {return}
    copies:=make([dynamic]Copy,context.temp_allocator)
    shaders_copies(&copies,root,"ship",context.temp_allocator)
    testing.expect_value(t,len(copies),0)
    for file in ([]string{"manifest.json","catalog.json","blit.frag.spv","blit.frag.metal","notes.txt","include/surface_programs.slang"}) {
        shaders_write(t,root,".mirai","shaders",file,text=file)
    }
    shaders_copies(&copies,root,"ship",context.temp_allocator)
    testing.expect_value(t,len(copies),3)
    CODE :: "blit.frag.metal" when ODIN_OS==.Darwin else "blit.frag.spv"
    for name in ([]string{"manifest.json","catalog.json",CODE}) {
        found:=false
        for copy in copies {
            found|=copy.from==project.path(root,".mirai/shaders",name,allocator=context.temp_allocator) && copy.to==project.path("ship/shaders",name,allocator=context.temp_allocator) && !copy.folder
        }
        testing.expect(t,found,name)
    }
}
