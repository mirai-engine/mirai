package editor

import "core:os"
import "core:strings"
import "core:testing"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"

// The rows of the Graphics popup come from the tags of the fields of the
// settings of the machine, and each one names the choice a value is at.
@(test)
graphics_rows_are_the_tagged_fields_of_the_settings_of_the_machine :: proc(t:^testing.T) {
    storages:=[1]core.Storage_Info{{name="Graphics_Settings",type=erender.Graphics_Settings,info=type_info_of(erender.Graphics_Settings),setting=.Machine}}
    info:=core.World_Info{storages=storages[:]}
    s:=Session{info=&info}
    defer free_all(context.temp_allocator)
    rows:=graphics_rows_of(&s)
    if !testing.expect_value(t,len(rows),15) {return}
    Case :: struct {label:string, change:proc(g:^erender.Graphics_Settings), choice:string, rate:bool}
    cases:=[?]Case{
        {"Resolution",proc(g:^erender.Graphics_Settings) {g.resolution=1440},"1440",false},
        {"Resolution",proc(g:^erender.Graphics_Settings) {g.resolution=600},"",false},
        {"Antialiasing",proc(g:^erender.Graphics_Settings) {g.antialiasing={0='o',1='f',2='f'}},"Off",false},
        {"Antialiasing",proc(g:^erender.Graphics_Settings) {g.antialiasing={0='x'}},"TAA",false},
        {"Light samples",proc(g:^erender.Graphics_Settings) {g.light_samples=31},"31",false},
        {"Light samples",proc(g:^erender.Graphics_Settings) {g.light_samples=20},"",false},
        {"Light resolution",proc(g:^erender.Graphics_Settings) {g.light_half_resolution=false},"Full",false},
        {"Glass shadows",proc(g:^erender.Graphics_Settings) {g.glass_shadows=true},"Colored",false},
        {"Glass layers",proc(g:^erender.Graphics_Settings) {g.glass_layers=2},"2",false},
        {"Textures",proc(g:^erender.Graphics_Settings) {g.textures=.Ultra},"8K",false},
        {"Reflections",proc(g:^erender.Graphics_Settings) {g.reflections=.Traced},"Traced",false},
        {"Frame limit",proc(g:^erender.Graphics_Settings) {g.frame_limit=0},"Off",true},
        {"Frame generation",proc(g:^erender.Graphics_Settings) {g.frame_generation=false},"Off",true},
        {"Show FPS",proc(g:^erender.Graphics_Settings) {g.show_fps=true},"On",true},
    }
    for c in cases {
        g:=erender.GRAPHICS_SETTINGS_DEFAULT
        c.change(&g)
        found:=false
        for &row in rows {
            if row.label!=c.label {continue}
            found=true
            choice:=graphics_row_choice(&row,&g)
            testing.expectf(t,(choice>=0?row.choices[choice]:"")==c.choice,"%s: %d of %v",c.label,choice,row.choices)
            testing.expectf(t,row.rate==c.rate,"%s goes to the card of the frame rate: %v",c.label,row.rate)
        }
        testing.expectf(t,found,"a row %s",c.label)
    }
}

// A choice of the popup takes effect at once and holds when the settings are
// read again: it goes to the engine layer, and a field the project fixes is
// taken out of the project, which would otherwise win again.
@(test)
a_graphics_choice_holds_also_where_the_project_fixed_it :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"editor-graphics-choice")
    if folder=="" {return}
    root,engine:=project.path(folder,"project",allocator=context.temp_allocator),project.path(folder,"engine",allocator=context.temp_allocator)
    testing.expect(t,os.make_directory_all(root)==nil && os.make_directory_all(engine)==nil)
    testing.expect(t,os.write_entire_file(project.settings_file(.Project,root,engine,context.temp_allocator),`{"Layer_Setting": {"quality": 0}}`)==nil)
    info,made:=test_info(t,Layer_World)
    if !made {return}
    defer test_info_destroy(&info)
    world:Layer_World
    if !testing.expect(t,core.world_init(&info,.World,&world,context.allocator)) {return}
    defer core.world_destroy(&info,.World,&world)
    gui:Editor_Ui
    app:host.App
    s:=Session{info=&info,edit_world=&world,app=&app,gui=&gui,project_root=root,engine_root=engine,has_project=true}
    defer settings_engine_free(&s)
    settings_load(&s)
    testing.expect_value(t,world.setting.quality,0)
    row:=Graphics_Row{storage=info.storages_by_type[Layer_Setting],type={kind=.Int,size=4},offset=offset_of(Layer_Setting,quality),label="Quality",choices={"Off","60","120"},values={0,60,120}}
    for choice in ([]int{2,1}) {
        testing.expect(t,graphics_row_commit(&s,&row,choice))
        testing.expect_value(t,world.setting.quality,i32(row.values[choice]))
        settings_load(&s)
        testing.expect_value(t,world.setting.quality,i32(row.values[choice]))
    }
    data,_:=os.read_entire_file(project.settings_file(.Project,root,engine,context.temp_allocator),context.temp_allocator)
    testing.expect(t,!strings.contains(string(data),`"quality"`),string(data))
    data,_=os.read_entire_file(project.settings_file(.Engine,root,engine,context.temp_allocator),context.temp_allocator)
    testing.expect(t,strings.contains(string(data),`"quality": 60`),string(data))
    testing.expect(t,!graphics_row_commit(&s,&row,3))
}
