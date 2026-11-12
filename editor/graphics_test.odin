package editor

import "core:testing"
import "mirai:core"
import erender "mirai:engine/render"

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
