package core

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"

@(private="file") @(storage,reset="described_reset") Described_Reset :: struct {value:i32}

// Declarations on one line right above others: each keeps its attributes.
@(private="file") @(storage,keep) Described_Kept :: struct {value:i32}
Described_Plain :: struct {value:i32}
@(private="file") @(component,replicated) Described_Sent :: struct {value:i32}
@(private="file")
@(component,single)
Described_Single :: struct {value:i32}

@(private="file")
Described_Lines :: struct {
    using world:Test_World,
    sent:Table(Described_Sent),
    single:Table(Described_Single),
    kept:Described_Kept,
    plain:Described_Plain,
}

@(private="file")
Described_Array :: struct {
    using world:Test_World,
    sent:[3]Table(Described_Sent),
}

@(private="file")
Described_World :: struct {
    using world:Test_World,
    transforms:Table(Transform),
    paces:Table(Own_Pace),
    disabled:Table(Disabled),
    hierarchy:Hierarchy,
    time:Time,
    frame:Frame_Time,
    clock:Clock,
    plain:Described_Plain,
    reset:Described_Reset,
}

@(private="file")
described_types :: proc(types:^[dynamic]Test_Type) {
    append(types,
        test_type(Described_Plain,default=proc(dst:^Described_Plain) {dst.value=3}),
        test_type(Described_Reset,reset=proc(value:^Described_Reset) {value.value=-1}),
    )
}

@(private="file")
Described_Shared :: struct {
    settings:Simulation_Settings,
    problems:By_World(Problems),
}

// A test world says of each table and storage what the attributes of its
// type say, starts and copies them as a generated one does, and one that a
// generated World could not be is refused saying which type is wrong.
@(test)
a_test_world_is_described_as_the_declarations_of_its_types_say :: proc(t:^testing.T) {
    info,ok:=test_info(t,Described_World,Described_Shared,Test_None,described_types)
    if !ok {return}
    defer test_info_destroy(&info)
    transforms,paces:=info.tables[0],info.tables[1]
    testing.expect(t,transforms.name=="Transform" && transforms.library=="core" && transforms.shared && transforms.replicated==.None && transforms.default!=nil && transforms.description!="")
    testing.expect(t,paces.replicated==.All && !paces.shared)
    time,settings,problems:=info.storages[1],info.storages[6],info.storages[7]
    testing.expect(t,time.keep && time.place==.World && time.setting==.None)
    testing.expect(t,settings.place==.Shared && settings.setting==.Project && settings.default!=nil)
    testing.expect(t,problems.by_world && problems.place==.Shared)

    a,b:Described_World
    testing.expect(t,world_init(&info,.World,&a,context.allocator) && world_init(&info,.World,&b,context.allocator))
    defer world_destroy(&info,.World,&a)
    defer world_destroy(&info,.World,&b)
    testing.expect(t,a.transforms.base && a.disabled.base && a.paces.base,"the components of core are the base of every entity")
    testing.expect(t,a.clock.scale==1 && a.frame.alpha==1 && a.plain.value==3,"a storage starts as its default")
    a.time.tick,a.frame.alpha,a.clock.scale,a.plain.value,a.reset.value=7,0.5,2,9,9
    testing.expect(t,world_copy(&info,&b,&a))
    testing.expect(t,b.time.tick==7 && b.clock.scale==2 && b.plain.value==9 && b.frame.alpha==1,"what says copy=false stays")
    testing.expect(t,world_clear(&info,&a))
    testing.expect(t,a.time.tick==7 && a.clock.scale==2,"what says keep survives clearing the World")
    testing.expect(t,a.plain.value==3 && a.reset.value==-1,"a derived storage goes back to its default, or to what its reset leaves")
    world_swap(&info,&a,&b)
    testing.expect(t,a.plain.value==9 && b.plain.value==3 && a.frame.alpha==0.5 && b.frame.alpha==1,"a swap trades what two Worlds hold, but for what says copy=false")

    if lines,read:=test_info(t,Described_Lines);read {
        defer test_info_destroy(&lines)
        sent,single:=lines.tables[0],lines.tables[1]
        kept,plain:=lines.storages[0],lines.storages[1]
        testing.expect(t,sent.replicated==.All && !sent.single && kept.keep,"a declaration on one line has its attributes")
        testing.expect(t,single.single && single.replicated==.None && !plain.keep,"and the declaration below it does not")
    }

    // An array of tables is a table of its type for each element.
    array:Described_Array
    if test_world_init(t,&array) {
        defer test_world_destroy(&array)
        tables:=test_world_info(&array).tables
        if testing.expect_value(t,len(tables),3) {
            for table,k in tables {
                testing.expectf(t,table.name==fmt.tprintf("Described_Sent_%d",k) && table.replicated==.All && table.offset==offset_of(Described_Array,sent)+uintptr(k*size_of(Table(Described_Sent))),"element %d: %v",k,table)
            }
        }
        e:=create(&array.entities)
        for &table,k in array.sent {add(&table,e,Described_Sent{i32(k)})}
        testing.expect_value(t,test_world_settle(&array),3)
        copied:Described_Array
        if test_world_init(t,&copied) {
            defer test_world_destroy(&copied)
            testing.expect(t,test_world_copy(&copied,&array))
            for &table,k in copied.sent {
                value,found:=get(read(&table),e)
                testing.expectf(t,found && value.value==i32(k),"each element copies as a table of its own: %d",k)
            }
        }
    }

    Case :: struct {what:string,world:^runtime.Type_Info,shared:^runtime.Type_Info,names:string}
    cases:=[]Case{
        {"no header",type_info_of(struct {transforms:Table(Transform)}),nil,"Test_World"},
        {"a storage held as a table",type_info_of(struct {using world:Test_World,hierarchy:Table(Hierarchy)}),nil,"Hierarchy"},
        {"a component held as a value",type_info_of(struct {using world:Test_World,transform:Transform}),nil,"Transform"},
        {"a storage of the application in the World",type_info_of(struct {using world:Test_World,settings:Simulation_Settings}),nil,"Simulation_Settings"},
        {"a by_world storage held as a value",type_info_of(struct {using world:Test_World}),type_info_of(struct {problems:Problems}),"Problems"},
        {"a type that is no component or storage",type_info_of(struct {using world:Test_World,seen:Seen}),nil,"Seen"},
        {"a procedure its attributes name was not given",type_info_of(struct {using world:Test_World,reset:Described_Reset}),nil,"described_reset"},
    }
    for c in cases {
        made,problem:=made_build({.World=c.world,.Shared=c.shared,.Editor=nil},test_types_none,context.allocator)
        testing.expectf(t,made==nil && strings.contains(problem,c.names),"%s: %q",c.what,problem)
        made_destroy(made)
    }
}
