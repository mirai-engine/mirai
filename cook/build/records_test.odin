package build

import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

@(private="file")
Records_Fixture :: struct {
    p:project.Project,
    game,assets:string,
}

@(private="file")
records_fixture :: proc(t:^testing.T,f:^Records_Fixture,game_source:string,editor_source:="") -> bool {
    folder:=base.test_folder(t,"records")
    if folder=="" {return false}
    engine:=project.path(folder,"engine",allocator=context.temp_allocator)
    root:=project.path(folder,"project",allocator=context.temp_allocator)
    f.game=project.path(root,"game",allocator=context.temp_allocator)
    f.assets=project.path(root,"assets",allocator=context.temp_allocator)
    folders:=[]string{project.path(engine,"core",allocator=context.temp_allocator),f.game,project.path(root,"editor",allocator=context.temp_allocator),f.assets}
    for path in folders {
        if !testing.expect(t,os.make_directory_all(path)==nil) {return false}
    }
    core_source:=`package core
Record :: struct($T:typeid) {table:[2]u64,row:u64}
Records :: struct($T:typeid) {set:rawptr}
Text :: struct {key:[64]u8}
@(component)
Spin :: struct {speed:f32}
`
    testing.expect(t,os.write_entire_file(project.path(folders[0],"core.odin",allocator=context.temp_allocator),core_source)==nil)
    testing.expect(t,os.write_entire_file(project.path(f.game,"game.odin",allocator=context.temp_allocator),game_source)==nil)
    if editor_source!="" {testing.expect(t,os.write_entire_file(project.path(folders[2],"editor.odin",allocator=context.temp_allocator),editor_source)==nil)}
    f.p=project.Project{root=root,engine_root=engine}
    return true
}

@(private="file")
column :: proc(name:string,kind:asset.Records_Kind,type:="",description:="") -> (c:asset.Records_Column) {
    base.text_set(c.name[:],name)
    c.kind=kind
    base.text_set(c.type[:],type)
    base.text_set(c.description[:],description)
    return
}

// Writes a table of the assets: one that declares type with columns and the
// default given, whose layout T has, or one that holds rows of type.
@(private="file")
records_put :: proc(t:^testing.T,f:^Records_Fixture,path,type:string,columns:[]asset.Records_Column,default:^$T,description:="",declares:=true) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    schema:serial.Schema
    serial.schema_init(&schema,context.temp_allocator)
    defer serial.schema_destroy(&schema)
    value_type,_:=serial.schema_add_type_info(&schema,type_info_of(T))
    info:asset.Records_Info
    base.text_set(info.type[:],type)
    base.text_set(info.description[:],description)
    info.declares=declares
    bytes,error:=asset.records_bytes(&types,{id={u64(len(path)),7},info=info,columns=columns,schema=&schema,value_type=value_type,defaults=mem.ptr_to_bytes(default) if declares else nil},context.temp_allocator)
    testing.expect_value(t,error,asset.Error.None)
    testing.expect(t,os.write_entire_file(project.path(f.assets,path,allocator=context.temp_allocator),bytes)==nil)
}

@(private="file") Rarity_Row :: enum u8 {Common,Rare}
@(private="file") Weapon_Row :: struct {damage:f32,rarity:Rarity_Row,ammo:core.Record(int),title:core.Text}
@(private="file") Ammo_Row :: struct {count:i32}

// A .records that declares its type generates, into the package of the game,
// the struct of its rows with the tags and descriptions of its columns, the
// enums of its enum columns and its default; the generator reads it as a
// record type of both worlds, whose steps receive core.Records(T); a table of
// rows of another's type generates nothing.
@(test)
a_records_file_generates_its_type_and_reaches_the_world_info :: proc(t:^testing.T) {
    source:=`package game
import "mirai:core"
@(component)
Holder :: struct {weapon:core.Record(Weapon)}
Stats :: struct {speed:f32}
@(private) Hidden :: struct {x:f32}
@(step="fixed")
fire :: proc(weapons:core.Records(Weapon),holders:^core.Table(Holder,.Read)) {}
`
    f:Records_Fixture
    if !records_fixture(t,&f,source) {return}
    damage:=column("damage",.Float,description="per hit")
    damage.has_min=true
    base.text_set(damage.unit[:],"hp")
    rarity:=column("rarity",.Enum,"Weapon_Rarity")
    base.text_set(rarity.values[:],"Common Rare")
    weapon:=[]asset.Records_Column{damage,rarity,column("ammo",.Record,"Ammo"),column("title",.Text)}
    default:=Weapon_Row{damage=10,rarity=.Rare}
    records_put(t,&f,"weapons.records","Weapon",weapon,&default,"A weapon a player can hold")
    ammo:=Ammo_Row{}
    records_put(t,&f,"ammo.records","Ammo",[]asset.Records_Column{column("count",.Int)},&ammo)
    records_put(t,&f,"more_ammo.records","Ammo",nil,&ammo,declares=false)
    if errors:=records_write(&f.p);!testing.expectf(t,len(errors)==0,"%v",errors) {return}
    generated,read:=os.read_entire_file(project.path(f.game,RECORDS_FILE,allocator=context.temp_allocator),context.temp_allocator)
    if !testing.expect(t,read==nil) {return}
    text:=string(generated)
    for wanted in ([]string{
        "package game\n",
        `import "mirai:core"`,
        "Weapon_Rarity :: enum u8 {Common,Rare}",
        `@(record="weapons.records",description="A weapon a player can hold")`,
        "    damage:f32 `mirai:\"min=0,unit=hp\"`, // per hit\n",
        "    rarity:Weapon_Rarity,\n",
        "    ammo:core.Record(Ammo),\n",
        "    title:core.Text,\n",
        "WEAPON_DEFAULT :: Weapon{damage=10,rarity=.Rare}",
        `@(record="ammo.records")`,
    }) {testing.expectf(t,strings.contains(text,wanted),"%q not in\n%s",wanted,text)}
    testing.expect(t,!strings.contains(text,"AMMO_DEFAULT"),"A default of zeros is no constant")

    output:=world_generate(&f.p,context.temp_allocator)
    if !testing.expectf(t,len(output.errors)==0,"%v",output.errors) {return}
    for world in ([]string{output.game_world,output.editor_world}) {
        testing.expectf(t,strings.contains(world,`records[1]={"Weapon","game",typeid_of(p_game.Weapon),type_info_of(p_game.Weapon),typeid_of(p_core.Record(p_game.Weapon)),record_default_game_weapon,true}`),"%s",world)
        testing.expect(t,strings.contains(world,`record_default_game_weapon :: proc(dst:rawptr) {(cast(^p_game.Weapon)dst)^=p_game.WEAPON_DEFAULT}`))
        testing.expect(t,strings.contains(world,`p_core.Records(p_game.Weapon){p_host.app_record_set(app,1)}`))
        testing.expect(t,strings.contains(world,`{"Stats","",type_info_of(p_game.Stats)}`),"A type of the package is one a column may hold")
        testing.expect(t,!strings.contains(world,"p_game.Hidden") && !strings.contains(world,`{"Holder",""`),"Neither a private type nor a component")
        testing.expect(t,strings.contains(world,"info.records,info.record_codes=records,record_codes"))
        testing.expect(t,!strings.contains(world,"weapon:p_game.Weapon"),"A record is no data of the World")
    }

    // Without tables that declare a type, the file goes.
    testing.expect(t,os.remove(project.path(f.assets,"weapons.records",allocator=context.temp_allocator))==nil)
    testing.expect(t,os.remove(project.path(f.assets,"ammo.records",allocator=context.temp_allocator))==nil)
    testing.expect(t,os.remove(project.path(f.assets,"more_ammo.records",allocator=context.temp_allocator))==nil)
    testing.expect_value(t,len(records_write(&f.p)),0)
    testing.expect(t,!os.exists(project.path(f.game,RECORDS_FILE,allocator=context.temp_allocator)))
}

// A struct of code marked @(record), a type two tables declare and a column
// that names a record type no table declares are errors that say what to
// do instead.
@(test)
records_declared_where_they_are_not_are_errors :: proc(t:^testing.T) {
    f:Records_Fixture
    if !records_fixture(t,&f,"package game\n@(record)\nLine :: struct {text:f32}\n") {return}
    output:=world_generate(&f.p,context.temp_allocator)
    found:=false
    for message in output.errors {found||=strings.contains(message,"Line is a @(record) in code") && strings.contains(message,"columns of its .records")}
    testing.expectf(t,found,"%v",output.errors)

    g:Records_Fixture
    if !records_fixture(t,&g,"package game\n") {return}
    ammo:=Ammo_Row{}
    records_put(t,&g,"a.records","Ammo",[]asset.Records_Column{column("count",.Int)},&ammo)
    records_put(t,&g,"b.records","Ammo",[]asset.Records_Column{column("count",.Int)},&ammo)
    errors:=records_write(&g.p)
    testing.expectf(t,len(errors)==1 && strings.contains(errors[0],"both declare the record type Ammo"),"%v",errors)

    h:Records_Fixture
    if !records_fixture(t,&h,"package game\n") {return}
    lost:=Weapon_Row{}
    choice:=column("rarity",.Enum,"R")
    base.text_set(choice.values[:],"Common Rare")
    records_put(t,&h,"w.records","Weapon",[]asset.Records_Column{column("damage",.Float),choice,column("ammo",.Record,"Bullet"),column("title",.Text)},&lost)
    errors=records_write(&h.p)
    testing.expectf(t,len(errors)>0 && strings.contains(errors[0],"names the record type Bullet, which no .records declares"),"%v",errors)
}

// What a step cannot receive as rows is an error that says what to do instead.
@(test)
records_of_a_component_are_errors :: proc(t:^testing.T) {
    f:Records_Fixture
    if !records_fixture(t,&f,"package game\nimport \"mirai:core\"\n@(component)\nHeld :: struct {value:f32}\n@(step=\"fixed\")\nread :: proc(rows:core.Records(Held)) {}\n") {return}
    output:=world_generate(&f.p,context.temp_allocator)
    found:=false
    for message in output.errors {found||=strings.contains(message,"the parameter rows of read is core.Records(Held)")}
    testing.expectf(t,found,"%v",output.errors)
}

// A procedure @(draw="name") of the game is in World_Info.draws of both
// worlds, by the name the Draw nodes of the interfaces say.
@(test)
a_draw_procedure_reaches_the_world_info_by_its_name :: proc(t:^testing.T) {
    source:=`package game
import "mirai:ui"
@(draw="minimap")
minimap_draw :: proc(ctx:^ui.Context,node:ui.Draw_Node) {}
@(draw="graph")
graph_draw :: proc(ctx:^ui.Context,node:ui.Draw_Node) {}
`
    f:Records_Fixture
    if !records_fixture(t,&f,source) {return}
    output:=world_generate(&f.p,context.temp_allocator)
    if !testing.expectf(t,len(output.errors)==0,"%v",output.errors) {return}
    for text in ([]string{output.game_world,output.editor_world}) {
        testing.expectf(t,strings.contains(text,`draws[0]={"minimap",rawptr(p_game.minimap_draw)}`) && strings.contains(text,`draws[1]={"graph",rawptr(p_game.graph_draw)}`),"%s",text)
        testing.expect(t,strings.contains(text,"draws:=make([]p_core.Draw_Info,2)") && strings.contains(text,"info.draws=draws"))
    }
}
