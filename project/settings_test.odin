package project

import "core:os"
import "core:strings"
import "core:testing"
import "mirai:std/serial"

@(private="file")
Inner :: struct {on:bool,level:i32}
@(private="file")
Sample :: struct {count:i32,scale:f32,inner:Inner}
@(private="file")
SAMPLE_DEFAULT :: Sample{count=1,scale=2}
@(private="file")
sample_default :: proc(dst:rawptr) {(^Sample)(dst)^=SAMPLE_DEFAULT}
@(private="file")
Rule :: struct {count:i32}

@(private="file")
file_text :: proc(file:string) -> string {
    data,_:=os.read_entire_file(file,context.temp_allocator)
    return string(data)
}

@(test)
settings_read_what_the_file_has_and_keep_the_rest :: proc(t:^testing.T) {
    sample:=Sample{count=1,scale=2}
    settings:=[]Setting{{name="Sample",info=type_info_of(Sample),value=&sample}}
    error:=settings_parse(`{"Sample": {"count": 3, "gone": [1, {"x": 2}], "inner": {"on": true}}, "Other": {"x": 1}}`,settings)
    testing.expect_value(t,error.code,Error_Code.None)
    testing.expect_value(t,sample,Sample{count=3,scale=2,inner={on=true}})
    error=settings_parse(`{"Sample": {"count": "three"}}`,settings)
    testing.expect_value(t,error.code,Error_Code.Text)
    // The message says the section and the field.
    testing.expect_value(t,error.detail,"Sample.count: expected a number")
    error=settings_parse(`{"Sample": {"inner": {"level": 1, "on": 3}}}`,settings)
    testing.expect_value(t,error.detail,"Sample.inner.on: expected true or false")
}

// The code under the engine under the project: each file holds what differs
// from the layers under it, so a change of the engine reaches the fields the
// project does not set, and the sections no setting names stay. The file of
// the engine holds only the settings of the machine.
@(test)
settings_layers_read_from_the_code_up_and_keep_what_differs :: proc(t:^testing.T) {
    folder,_:=os.make_directory_temp("","mirai-settings",context.temp_allocator)
    defer os.remove_all(folder)
    root,engine:=path(folder,"project",allocator=context.temp_allocator),path(folder,"engine",allocator=context.temp_allocator)
    testing.expect(t,os.make_directory_all(root)==nil)
    project_file,engine_file:=settings_file(.Project,root,engine,context.temp_allocator),settings_file(.Engine,root,engine,context.temp_allocator)
    engine_slashes,_:=strings.replace_all(engine,"\\","/",context.temp_allocator)
    testing.expect_value(t,engine_file,path(engine_slashes,".mirai",SETTINGS_FILE,allocator=context.temp_allocator))
    testing.expect_value(t,settings_under(.Project),Settings_Layers{.Engine})
    testing.expect_value(t,settings_under(.Engine),Settings_Layers{})
    testing.expect_value(t,settings_under(.Player),Settings_Layers{.Project,.Engine})

    sample:=Sample{count=9}
    rule:=Rule{count=4}
    settings:=[]Setting{{name="Sample",info=type_info_of(Sample),value=&sample,default=sample_default,machine=true},{name="Rule",info=type_info_of(Rule),value=&rule}}
    error,_:=settings_load(settings,root,engine)
    testing.expect_value(t,error.code,Error_Code.None)
    testing.expect_value(t,sample,SAMPLE_DEFAULT)
    testing.expect_value(t,rule,Rule{})
    testing.expect_value(t,len(settings_held(settings,.Engine)),1)

    sample.scale,sample.inner.level=5,3
    rule.count=6
    error,_=settings_save(settings,.Engine,root,engine)
    testing.expect_value(t,error.code,Error_Code.None)
    text:=file_text(engine_file)
    testing.expect(t,strings.contains(text,`"scale": 5`) && strings.contains(text,`"level": 3`),text)
    testing.expect(t,!strings.contains(text,`"count"`) && !strings.contains(text,`"on"`) && !strings.contains(text,`"Rule"`),text)

    // A setting of the project in the file of the engine is kept, not read.
    testing.expect(t,os.write_entire_file(engine_file,`{"version": 2, "Sample": {"scale": 5, "inner": {"level": 3}}, "Rule": {"count": 8}}`)==nil)
    settings_load(settings,root,engine)
    testing.expect_value(t,rule,Rule{})
    misplaced:=settings_misplaced(settings,root,engine)
    testing.expect(t,len(misplaced)==1 && misplaced[0]=="Rule")
    sample.scale=5
    settings_save(settings,.Engine,root,engine)
    testing.expect(t,strings.contains(file_text(engine_file),`"Rule": {"count": 8}`))

    testing.expect(t,os.write_entire_file(project_file,`{"Plugin": {"strength": 0.5}, "Sample": {"scale": 1}}`)==nil)
    sample.count=7
    error,_=settings_save(settings,.Project,root,engine)
    testing.expect_value(t,error.code,Error_Code.None)
    text=file_text(project_file)
    testing.expect(t,strings.contains(text,`"count": 7`) && strings.contains(text,`"Plugin": {"strength": 0.5}`),text)
    testing.expect(t,!strings.contains(text,`"scale"`) && !strings.contains(text,`"inner"`),text)

    sample={}
    error,_=settings_load(settings,root,engine)
    testing.expect_value(t,error.code,Error_Code.None)
    testing.expect_value(t,sample,Sample{count=7,scale=5,inner={level=3}})
    error,_=settings_load(settings,root,engine,{.Engine})
    testing.expect_value(t,sample,Sample{count=1,scale=5,inner={level=3}})

    // The engine changes what the project does not set.
    sample.scale=9
    error,_=settings_save(settings,.Engine,root,engine)
    testing.expect_value(t,error.code,Error_Code.None)
    settings_load(settings,root,engine)
    testing.expect_value(t,sample,Sample{count=7,scale=9,inner={level=3}})

    // The project sets it, and keeps it while the engine changes; back to the
    // value of the engine, its file forgets it.
    sample.scale=4
    settings_save(settings,.Project,root,engine)
    testing.expect(t,strings.contains(file_text(project_file),`"scale": 4`))
    settings_load(settings,root,engine,{.Engine})
    sample.scale=6
    settings_save(settings,.Engine,root,engine)
    settings_load(settings,root,engine)
    testing.expect_value(t,sample.scale,f32(4))
    sample.scale=6
    settings_save(settings,.Project,root,engine)
    testing.expect(t,!strings.contains(file_text(project_file),`"scale"`))
    sample.count=1
    settings_save(settings,.Project,root,engine)
    text=file_text(project_file)
    testing.expect(t,!strings.contains(text,`"Sample"`) && strings.contains(text,`"Plugin"`),text)

    testing.expect(t,os.write_entire_file(engine_file,`{"version": 2, "Sample": {"scale": }}`)==nil)
    failed:Settings_Layer
    error,failed=settings_save(settings,.Project,root,engine)
    testing.expect_value(t,error.code,Error_Code.Text)
    testing.expect_value(t,failed,Settings_Layer.Engine)
}

// A file of the machine of another version, or of none, is not read; the next
// save writes the current one and keeps the sections no setting names.
@(test)
settings_files_of_the_machine_of_another_version_are_not_read :: proc(t:^testing.T) {
    folder,_:=os.make_directory_temp("","mirai-settings",context.temp_allocator)
    defer os.remove_all(folder)
    root,engine:=path(folder,"project",allocator=context.temp_allocator),path(folder,"engine",allocator=context.temp_allocator)
    testing.expect(t,os.make_directory_all(path(engine,".mirai",allocator=context.temp_allocator))==nil && os.make_directory_all(root)==nil)
    engine_file:=settings_file(.Engine,root,engine,context.temp_allocator)
    sample:Sample
    settings:=[]Setting{{name="Sample",info=type_info_of(Sample),value=&sample,default=sample_default,machine=true}}
    for text in ([]string{`{"version": 1, "Sample": {"scale": 9}, "Other": {"x": 1}}`,`{"Sample": {"scale": 9}, "Other": {"x": 1}}`}) {
        testing.expect(t,os.write_entire_file(engine_file,text)==nil)
        error,_:=settings_load(settings,root,engine)
        testing.expect_value(t,error.code,Error_Code.None)
        testing.expect_value(t,sample,SAMPLE_DEFAULT)
    }
    sample.scale=5
    error,_:=settings_save(settings,.Engine,root,engine)
    testing.expect_value(t,error.code,Error_Code.None)
    text:=file_text(engine_file)
    testing.expect(t,strings.has_prefix(strings.trim_left_space(text[1:]),`"version": 2`) && strings.contains(text,`"Other": {"x": 1}`) && strings.count(text,`"version"`)==1,text)
    sample={}
    error,_=settings_load(settings,root,engine)
    testing.expect_value(t,error.code,Error_Code.None)
    testing.expect_value(t,sample.scale,f32(5))
}

// The value of the code on this machine is under the files: a field back to
// it leaves the file of the engine, one at the default of the code stays.
@(test)
settings_base_is_the_code_of_this_machine :: proc(t:^testing.T) {
    folder,_:=os.make_directory_temp("","mirai-settings",context.temp_allocator)
    defer os.remove_all(folder)
    root,engine:=path(folder,"project",allocator=context.temp_allocator),path(folder,"engine",allocator=context.temp_allocator)
    testing.expect(t,os.make_directory_all(root)==nil)
    engine_file:=settings_file(.Engine,root,engine,context.temp_allocator)
    base:=Sample{count=1,scale=0.5}
    sample:Sample
    settings:=[]Setting{{name="Sample",info=type_info_of(Sample),value=&sample,default=sample_default,machine=true,base=&base}}
    settings_load(settings,root,engine)
    testing.expect_value(t,sample,base)

    sample.scale=2
    error,_:=settings_save(settings,.Engine,root,engine)
    testing.expect_value(t,error.code,Error_Code.None)
    testing.expect(t,strings.contains(file_text(engine_file),`"scale": 2`))
    clone:=settings_clone(settings,context.temp_allocator)
    testing.expect(t,clone[0].base!=&base && (^Sample)(clone[0].base)^==base)
    settings_load(clone,root,engine)
    testing.expect_value(t,(^Sample)(clone[0].value)^,SAMPLE_DEFAULT)

    sample.scale=0.5
    settings_save(settings,.Engine,root,engine)
    testing.expect(t,!strings.contains(file_text(engine_file),`"Sample"`))
}

// A shipped game reads the merged file as the layers read their two files.
@(test)
settings_merge_gives_what_the_layers_read :: proc(t:^testing.T) {
    folder,_:=os.make_directory_temp("","mirai-settings",context.temp_allocator)
    defer os.remove_all(folder)
    root,engine:=path(folder,"project",allocator=context.temp_allocator),path(folder,"engine",allocator=context.temp_allocator)
    testing.expect(t,os.make_directory_all(root)==nil && os.make_directory_all(path(engine,".mirai",allocator=context.temp_allocator))==nil)
    machine:=[]string{"Sample"}
    merged,error,_:=settings_merge(root,engine,machine,context.temp_allocator)
    testing.expect_value(t,error.code,Error_Code.None)
    testing.expect_value(t,merged,"{}\n")

    project_file,engine_file:=settings_file(.Project,root,engine,context.temp_allocator),settings_file(.Engine,root,engine,context.temp_allocator)
    testing.expect(t,os.write_entire_file(engine_file,`{"version": 2, "Sample": {"count": 2, "scale": 5, "inner": {"level": 3}}, "Engine_Only": {"x": [1, 2]}}`)==nil)
    testing.expect(t,os.write_entire_file(project_file,`{"Sample": {"count": 7, "inner": {"on": true}}, "Plugin": {"y": "z"}}`)==nil)
    merged,error,_=settings_merge(root,engine,machine,context.temp_allocator)
    testing.expect_value(t,error.code,Error_Code.None)
    // Of the engine, only the settings of the machine.
    testing.expect(t,!strings.contains(merged,`"Engine_Only"`) && strings.contains(merged,`"y": "z"`),merged)

    layered,shipped:Sample
    settings:=[]Setting{{name="Sample",info=type_info_of(Sample),value=&layered,default=sample_default,machine=true}}
    settings_load(settings,root,engine)
    testing.expect_value(t,layered,Sample{count=7,scale=5,inner={on=true,level=3}})
    shipped=SAMPLE_DEFAULT
    testing.expect_value(t,settings_parse(merged,{{name="Sample",info=type_info_of(Sample),value=&shipped}}).code,Error_Code.None)
    testing.expect_value(t,shipped,layered)

    testing.expect(t,os.write_entire_file(project_file,`{"Sample": {"count": }}`)==nil)
    layer:Settings_Layer
    _,error,layer=settings_merge(root,engine,machine,context.temp_allocator)
    testing.expect_value(t,error.code,Error_Code.Text)
    testing.expect_value(t,layer,Settings_Layer.Project)
}

// Every worktree of a repository is one engine on the machine: the file of
// the engine layer is that of its main checkout.
@(test)
a_worktree_keeps_the_engine_layer_in_its_main_checkout :: proc(t:^testing.T) {
    folder,_:=os.make_directory_temp("","mirai-checkout",context.temp_allocator)
    defer os.remove_all(folder)
    main,_:=strings.replace_all(path(folder,"main",allocator=context.temp_allocator),"\\","/",context.temp_allocator)
    // Git writes the gitdir of a worktree with forward slashes on every system.
    tree:=path(main,".git","worktrees","side",allocator=context.temp_allocator)
    other:=path(folder,"side",allocator=context.temp_allocator)
    testing.expect(t,os.make_directory_all(tree)==nil && os.make_directory_all(other)==nil)
    testing.expect(t,os.write_entire_file(path(tree,"commondir",allocator=context.temp_allocator),"../..\n")==nil)
    testing.expect(t,os.write_entire_file(path(other,".git",allocator=context.temp_allocator),strings.concatenate({"gitdir: ",tree,"\n"},context.temp_allocator))==nil)
    testing.expect_value(t,shared_root(main,context.temp_allocator),main)
    testing.expect_value(t,shared_root(other,context.temp_allocator),main)
    testing.expect_value(t,machine_folder(other,context.temp_allocator),path(main,".mirai",allocator=context.temp_allocator))
    testing.expect_value(t,settings_file(.Engine,"",other,context.temp_allocator),path(main,".mirai",SETTINGS_FILE,allocator=context.temp_allocator))
    testing.expect_value(t,machine_folder("",context.temp_allocator),"")
}

@(private="file") Layer :: distinct u8
@(private="file") Layer_Mask :: distinct u32
@(private="file") Layered :: struct {layer:Layer,seen:Layer_Mask}

// A setting with the names of the world reads and writes its ids by them.
@(test)
a_setting_reads_and_writes_ids_by_the_names_of_the_world :: proc(t:^testing.T) {
    named:=make(map[typeid]serial.Named,context.temp_allocator)
    named[Layer]={choices={{"floor",1},{"wall",2}}}
    named[Layer_Mask]={choices={{"floor",1},{"wall",2}},bits=true}
    value:Layered
    settings:=[]Setting{{name="Layered",info=type_info_of(Layered),value=&value,named=named}}
    testing.expect_value(t,settings_parse(`{"Layered": {"layer": "wall", "seen": ["floor", "wall"]}}`,settings).code,Error_Code.None)
    testing.expect_value(t,value,Layered{layer=2,seen=0b110})
    text:=settings_text(settings,allocator=context.temp_allocator)
    testing.expectf(t,strings.contains(text,`"layer": "wall"`) && strings.contains(text,`"seen": ["floor", "wall"]`),"%s",text)
}

@(private="file") Entry :: struct {name:[8]u8 `mirai:"text"`,value:i32}
@(private="file") Entries :: struct {scale:f32,entries:[8]Entry}

// A list of entries is written up to the last that differs from the layer below, and read back whole.
@(test)
a_list_of_entries_is_written_up_to_the_last_that_differs :: proc(t:^testing.T) {
    value,under:Entries
    value.scale=2
    value.entries[0]={value=5}
    copy(value.entries[2].name[:],"two")
    settings:=[]Setting{{name="Entries",info=type_info_of(Entries),value=&value}}
    below:=[]Setting{{name="Entries",info=type_info_of(Entries),value=&under}}
    text:=settings_text(settings,below,allocator=context.temp_allocator)
    testing.expectf(t,strings.count(text,"\"value\"")==3,"three entries and no more: %s",text)
    back:Entries
    read:=[]Setting{{name="Entries",info=type_info_of(Entries),value=&back}}
    testing.expect_value(t,settings_parse(text,read).code,Error_Code.None)
    testing.expect_value(t,back,value)
}
