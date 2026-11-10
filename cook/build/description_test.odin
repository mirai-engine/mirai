package build

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:project"
import "mirai:std/base"

@(test)
component_descriptions_preserve_quoted_text_in_both_generated_worlds :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"description")
    if folder=="" {return}
    engine:=project.path(folder,"engine",allocator=context.temp_allocator)
    game:=project.path(folder,"project",allocator=context.temp_allocator)
    for path in ([]string{project.path(engine,"core",allocator=context.temp_allocator),project.path(game,"game",allocator=context.temp_allocator)}) {
        if !testing.expect(t,os.make_directory_all(path)==nil) {return}
    }
    source:=`package core
@(component, description="Uses a \"pose\".\nShared rig.")
Described :: struct {value:f32}
@(component)
Unspecified :: struct {value:f32}
@(component,far)
Ground :: struct {value:f32}
@(component)
Commented :: struct {
    reach:f32, // where it "stops"
    plain:f32,
    a,b:f32,   // both
}
`
    testing.expect(t,os.write_entire_file(project.path(engine,"core","data.odin",allocator=context.temp_allocator),source)==nil)
    p:=project.Project{root=game,engine_root=engine}
    output:=world_generate(&p,context.temp_allocator)
    if !testing.expect_value(t,len(output.errors),0) {return}
    description:=fmt.tprintf("%q","Uses a \"pose\".\nShared rig.")
    for text in ([]string{output.game_world,output.editor_world}) {
        testing.expect(t,strings.contains(text,description))
        testing.expect(t,strings.contains(text,`,false,.None,false,nil,"",nil,false,false}`))
        // A component that draws a far form of its own says so.
        testing.expect(t,strings.contains(text,`{"Ground","core",`) && strings.contains(text,`,false,.None,false,nil,"",nil,false,true}`))
        // The comment on the line of a field is its description.
        testing.expectf(t,strings.contains(text,`fields_commented:=[3]p_core.Field_Description{{"reach","where it \"stops\""},{"a","both"},{"b","both"}}`),"%s",text)
        testing.expect(t,strings.contains(text,`,false,.None,false,nil,"",fields_commented[:],false,false}`))
    }
}

// @(storage,setting) is a setting of the project and setting="machine" one of
// the machine; any other kind is an error that says what to write.
// @(storage,scene) is no more: the message says to make it a component.
@(test)
settings_are_of_the_project_or_of_the_machine :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"setting")
    if folder=="" {return}
    engine:=project.path(folder,"engine",allocator=context.temp_allocator)
    game:=project.path(folder,"project",allocator=context.temp_allocator)
    for path in ([]string{project.path(engine,"core",allocator=context.temp_allocator),project.path(game,"game",allocator=context.temp_allocator)}) {
        if !testing.expect(t,os.make_directory_all(path)==nil) {return}
    }
    file:=project.path(engine,"core","data.odin",allocator=context.temp_allocator)
    source:=`package core
@(storage,setting)
Rules :: struct {value:f32}
@(storage,setting="machine")
Quality :: struct {value:f32}
`
    testing.expect(t,os.write_entire_file(file,source)==nil)
    p:=project.Project{root=game,engine_root=engine}
    output:=world_generate(&p,context.temp_allocator)
    if !testing.expect_value(t,len(output.errors),0) {return}
    for text in ([]string{output.game_world,output.editor_world}) {
        testing.expect(t,strings.contains(text,`offset_of(World,rules),.World,.Project,nil,false,nil,false,false,"",false}`),text)
        testing.expect(t,strings.contains(text,`offset_of(World,quality),.World,.Machine,nil,false,nil,false,false,"",false}`),text)
    }
    testing.expect(t,len(output.machine_settings)==1 && output.machine_settings[0]=="Quality")

    // A setting with a value for each GPU gives it to the settings.
    testing.expect(t,os.write_entire_file(file,strings.concatenate({source,"quality_for_device :: proc(device:rhi.Device_Info) -> Quality {return {}}\n"},context.temp_allocator))==nil)
    output=world_generate(&p,context.temp_allocator)
    if !testing.expect_value(t,len(output.errors),0) {return}
    for text in ([]string{output.game_world,output.editor_world}) {
        testing.expect(t,strings.contains(text,`import gen_rhi "mirai:rhi"`),text)
        testing.expect(t,strings.contains(text,`for_device_quality :: proc(dst:rawptr,device:rawptr) {(cast(^p_core.Quality)dst)^=p_core.quality_for_device((cast(^gen_rhi.Device_Info)device)^)}`),text)
        testing.expect(t,strings.contains(text,`.World,.Machine,nil,false,for_device_quality,false,false,"",false}`),text)
    }

    testing.expect(t,os.write_entire_file(file,"package core\n@(storage,setting=\"engine\")\nQuality :: struct {value:f32}\n")==nil)
    output=world_generate(&p,context.temp_allocator)
    if !testing.expect_value(t,len(output.errors),1) {return}
    testing.expect(t,strings.contains(output.errors[0],`setting="engine"`) && strings.contains(output.errors[0],`@(storage,setting="machine")`),output.errors[0])

    testing.expect(t,os.write_entire_file(file,"package core\n@(storage,scene)\nAmbient :: struct {value:f32}\n")==nil)
    output=world_generate(&p,context.temp_allocator)
    if !testing.expect_value(t,len(output.errors),1) {return}
    testing.expect(t,strings.contains(output.errors[0],"Ambient says scene") && strings.contains(output.errors[0],"@(component)"),output.errors[0])
}
