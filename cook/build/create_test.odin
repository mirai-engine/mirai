package build

import "core:os"
import "core:testing"
import "mirai:project"

@(test)
a_new_project_gets_what_the_templates_share :: proc(t:^testing.T) {
    engine,error:=os.make_directory_temp("","mirai-create-*",context.temp_allocator)
    if !testing.expect(t,error==nil) {return}
    defer os.remove_all(engine)
    engine=project.path_absolute(engine,context.temp_allocator)
    write :: proc(t:^testing.T,file,text:string,loc:=#caller_location) {
        testing.expect(t,os.make_directory_all(file[:len(file)-len("/x")])==nil || os.is_dir(file[:len(file)-len("/x")]),loc=loc)
        testing.expect(t,os.write_entire_file(file,text)==nil,loc=loc)
    }
    join :: proc(parts:..string) -> string {return project.path(..parts,allocator=context.temp_allocator)}
    write(t,join(engine,"templates/common/.claude/x"),"shared")
    write(t,join(engine,"templates/common/x"),"shared")
    write(t,join(engine,"templates/small/x2"),"own")
    write(t,join(engine,"templates/small",project.PROJECT_FILE),`{"name": "Small"}`)

    listed:=templates_list(engine,context.temp_allocator)
    testing.expect_value(t,len(listed),1)
    testing.expect_value(t,listed[0].name,"small")

    folder:=join(engine,"made")
    testing.expect_value(t,project_create(template_folder(engine,"small",context.temp_allocator),folder,"Made"),Create_Error.None)
    for file in ([]string{"x","x2",".claude/x"}) {testing.expectf(t,os.is_file(join(folder,file)),"%s is missing",file)}
    m,read_error:=project.manifest_read(join(folder,project.PROJECT_FILE))
    testing.expect_value(t,read_error.code,project.Error_Code.None)
    testing.expect_value(t,string(m.name[:4]),"Made")
}
