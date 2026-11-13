package build

import "core:os"
import "core:strings"
import "core:testing"
import "mirai:project"
import "mirai:std/base"

@(test)
a_new_project_gets_what_the_templates_share :: proc(t:^testing.T) {
    engine:=base.test_folder(t,"create")
    if engine=="" {return}
    write :: proc(t:^testing.T,file,text:string,loc:=#caller_location) {
        testing.expect(t,os.make_directory_all(file[:len(file)-len("/x")])==nil || os.is_dir(file[:len(file)-len("/x")]),loc=loc)
        testing.expect(t,os.write_entire_file(file,text)==nil,loc=loc)
    }
    join :: proc(parts:..string) -> string {return project.path(..parts,allocator=context.temp_allocator)}
    write(t,join(engine,"templates/common/.claude/x"),"shared")
    write(t,join(engine,"templates/common/x"),"shared")
    write(t,join(engine,"templates/small/x2"),"own")
    write(t,join(engine,"templates/small",project.PROJECT_FILE),`{"name": "Small", "plugins": ["fx"], "build": {"compression": "open"}}`)
    testing.expect(t,os.make_directory_all(join(engine,"plugins/fx"))==nil)
    write(t,join(engine,"plugins/fx",project.PLUGIN_FILE),`{"name": "fx", "version": "1.0.0", "asset_kinds": [{"extension": ".spark", "kind": "SPAR", "version": 1, "merged": true}]}`)

    listed:=templates_list(engine,context.temp_allocator)
    testing.expect_value(t,len(listed),1)
    testing.expect_value(t,listed[0].name,"small")

    folder:=join(engine,"made")
    testing.expect_value(t,project_create(template_folder(engine,"small",context.temp_allocator),folder,"Made",engine),Create_Error.None)
    for file in ([]string{"x","x2",".claude/x"}) {testing.expectf(t,os.is_file(join(folder,file)),"%s is missing",file)}
    m,read_error:=project.manifest_read(join(folder,project.PROJECT_FILE))
    testing.expect_value(t,read_error.code,project.Error_Code.None)
    testing.expect_value(t,string(m.name[:4]),"Made")
    testing.expect(t,base.text_get(m.build.compression[:])=="","a new project does not keep the compression of the template")
    attributes,_:=os.read_entire_file(join(folder,".gitattributes"),context.temp_allocator)
    testing.expect(t,strings.contains(string(attributes),"*.scene merge="+GIT_DRIVER) && strings.contains(string(attributes),"*.spark merge="+GIT_DRIVER),"a new project says which of its files git merges through mirai, those of its plugins too")
}
