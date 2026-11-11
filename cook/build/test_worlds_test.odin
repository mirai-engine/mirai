package build

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:project"
import "mirai:std/base"

// The World_Info of a @(test_world) says of each table and storage what the
// attributes of its type say, as that of a game does: the generator reads
// them from the package that declares the type, with its defaults and the
// procedures it names. A struct no World could be is refused saying what to
// write instead.
@(test)
a_test_world_gets_the_world_info_the_declarations_of_its_types_give_a_game :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder:=base.test_folder(t,"test-worlds")
    if folder=="" {return}
    engine:=project.path(folder,"engine")
    toy:=project.path(engine,"engine","toy")
    for path in ([]string{project.path(engine,"core"),toy}) {
        if !testing.expect(t,os.make_directory_all(path)==nil) {return}
    }
    testing.expect_value(t,os.write_entire_file(project.path(engine,"core","core.odin"),`package core
// Where it is.
@(component,shared,replicated="owner",description="Where an entity is.") Transform :: struct {
    position:[3]f32, // In meters.
}
TRANSFORM_DEFAULT :: Transform{}
@(component,locks="Transform") Body :: struct {mass:f32}
@(storage,reset="clock_reset") Clock :: struct {scale:f32}
clock_default :: proc() -> Clock {return {scale=1}}
clock_reset :: proc(c:^Clock) {}
@(storage,host,by_world,free="problems_free") Problems :: struct {count:int}
problems_free :: proc(p:^Problems) {}
@(storage,host,setting="machine") Quality :: struct {level:int}
quality_for_device :: proc(device:int) -> Quality {return {}}
`),nil)
    world:=project.path(toy,"toy_test.odin")
    valid:=`package toy
import "mirai:core"
Toy_Score :: struct {points:int}
TOY_SCORE_DEFAULT :: Toy_Score{points=3}
Toy_Group :: struct {bodies:core.Table(core.Body),clock:core.Clock}
Toy_Shared :: struct {problems:core.By_World(core.Problems),quality:core.Quality}
@(test_world,host="Toy_Shared")
Toy_World :: struct {
    using world:Test_World,
    transforms:core.Table(core.Transform),
    using group:Toy_Group,
    pair:[2]core.Table(Toy_Score) ` + "`mirai:\"game\"`" + `,
    score:Toy_Score ` + "`mirai:\"name=Score\"`" + `,
    plain:[dynamic]u32,
}
`
    testing.expect_value(t,os.write_entire_file(world,valid),nil)
    file:=project.path(toy,TEST_WORLDS_FILE)
    errors:=test_worlds_write(engine,"",{toy},true)
    data,_:=os.read_entire_file(file,context.temp_allocator)
    text:=string(data)
    if !testing.expectf(t,len(errors)==0 && text!="","%v",errors) {return}
    for wanted in ([]string{
        "storage_revisions:[5]u64,",
        `tables[0]={"Transform","core",typeid_of(p_core.Transform),type_info_of(p_core.Transform),offset_of(Toy_World,transforms),.World,true,.Owner,false,default_test_world_p_core_transform,"Where an entity is.",fields_test_world_p_core_transform[:],false,false,true,nil,false}`,
        `tables[1]={"Body","core",typeid_of(p_core.Body),type_info_of(p_core.Body),offset_of(Toy_World,bodies),.World,false,.None,false,nil,"",nil,false,false,true,locks_1,false}`,
        `locks_1[0]={int(offset_of(Toy_World,transforms))-int(offset_of(Toy_World,bodies)),1,test_world_lock_names_toy_world[:],"Transform"}`,
        `tables[3]={"Toy_Score_1","toy",typeid_of(Toy_Score),type_info_of(Toy_Score),offset_of(Toy_World,pair)+1*size_of((^Toy_World)(nil).pair[0]),.World,false,.None,true,default_test_world_toy_score,`,
        `storages[0]={"Clock","core",typeid_of(p_core.Clock),type_info_of(p_core.Clock),offset_of(Toy_World,clock),.World,.None,default_test_world_p_core_clock,false,nil,false,false,"",false,false,{reset=reset_test_world_p_core_clock},false}`,
        `storages[1]={"Score","toy",`,
        `storages[2]={"plain","",typeid_of(type_of((^Toy_World)(nil).plain)),`,
        `offset_of(Toy_Shared,problems),.Shared,.None,nil,true,nil,false,false,"",false,false,{free=free_test_world_p_core_problems},false}`,
        `offset_of(Toy_Shared,quality),.Shared,.Machine,nil,false,for_device_test_world_p_core_quality,`,
        "default_test_world_p_core_clock :: proc(dst:rawptr) {(cast(^p_core.Clock)dst)^=p_core.clock_default()}",
        "info.sizes={.World=size_of(Toy_World),.Shared=size_of(Toy_Shared),.Editor=1}",
        "info.aligns={.World=align_of(Toy_World),.Shared=align_of(Toy_Shared),.Editor=1}",
        "when W==Toy_World {info,ok=test_info_toy_world(allocator)}",
    }) {
        testing.expectf(t,strings.contains(text,wanted),"the generated world lacks %s in\n%s",wanted,text)
    }
    // Written again from the same sources it is left as it is; without a world, it goes.
    errors=test_worlds_write(engine,"",{toy},true)
    again,_:=os.read_entire_file(file,context.temp_allocator)
    testing.expect(t,len(errors)==0 && string(again)==text)

    Case :: struct {what,from,to,says:string}
    cases:=[]Case{
        {"no header","    using world:Test_World,\n","","using world:Test_World"},
        {"a component held as a value","transforms:core.Table(core.Transform)","transforms:core.Transform","core.Table(Transform)"},
        {"a storage held as a table","clock:core.Clock","clock:core.Table(core.Clock)","holds it as a value"},
        {"a storage of the application in the World","plain:[dynamic]u32","plain:core.Quality","with host"},
        {"a by_world storage held as a value","core.By_World(core.Problems)","core.Problems","core.By_World(Problems)"},
        {"a table in the struct of the application","quality:core.Quality","quality:core.Table(core.Transform)","a table goes in the World"},
        {"a type that is no component or storage","Toy_Score :: struct {points:int}","Toy_Score :: struct {points:int}\nToy_Other :: core.Missing","core.Missing"},
        {"a table held twice","plain:[dynamic]u32","again:core.Table(core.Transform)","twice"},
        {"an array of tables without a number","[2]core.Table(Toy_Score)","[COUNT]core.Table(Toy_Score)","as a number"},
        {"a struct of the application that is not declared",`host="Toy_Shared"`,`host="Toy_Missing"`,"Toy_Missing is not a struct"},
        {"a group that is no struct","using group:Toy_Group","using group:core.Missing","a group"},
    }
    for c in cases {
        changed,_:=strings.replace(valid,c.from,c.to,1)
        if c.what=="a type that is no component or storage" {changed,_=strings.replace(changed,"plain:[dynamic]u32","plain:Toy_Other",1)}
        testing.expect_value(t,os.write_entire_file(world,changed),nil)
        errors=test_worlds_write(engine,"",{toy},true)
        said:=strings.join(errors,"\n")
        testing.expectf(t,len(errors)>0 && strings.contains(said,c.says) && strings.contains(said,"toy_test.odin("),"%s: %q",c.what,said)
    }
    testing.expect_value(t,os.write_entire_file(world,"package toy\n"),nil)
    errors=test_worlds_write(engine,"",{toy},true)
    testing.expect(t,len(errors)==0 && !os.is_file(file),fmt.tprint(errors))
}
