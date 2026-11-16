package importer

import "core:os"
import "core:path/filepath"
import "core:testing"
import "mirai:ui"

@(test)
the_names_of_the_images_of_packs_say_what_they_show :: proc(t:^testing.T) {
    Case :: struct {path:string,family:ui.Prompt_Family,input:ui.Prompt_Input,key:string}
    cases:=[?]Case{
        {"keyboard_mouse/keyboard_a.png",.Keyboard,.Key,"A"},
        {"keyboard_mouse/keyboard_shift.png",.Keyboard,.Key,"Left_Shift"},
        {"keyboard_mouse/keyboard_arrows_left.png",.Keyboard,.Key,"Left"},
        {"keyboard_mouse/mouse_scroll_vertical.png",.Keyboard,.Mouse_Wheel,""},
        {"keyboard_mouse/mouse_left.png",.Keyboard,.Mouse_Left,""},
        {"xbox/xbox_button_color_x.png",.Xbox,.West,""},
        {"xbox/xbox_lt.png",.Xbox,.Trigger_Left,""},
        {"xbox/xbox_button_menu.png",.Xbox,.Start,""},
        {"playstation/playstation_trigger_l1.png",.PlayStation,.Shoulder_Left,""},
        {"playstation/playstation_trigger_r2.png",.PlayStation,.Trigger_Right,""},
        {"playstation/playstation_stick_l_press.png",.PlayStation,.Stick_Left_Press,""},
        {"playstation/playstation5_button_create.png",.PlayStation,.Back,""},
        // Xelu's names.
        {"Xbox Series/XboxSeriesX_A.png",.Xbox,.South,""},
        {"PS5/PS5_Circle.png",.PlayStation,.East,""},
        {"Keyboard & Mouse/Dark/Esc_Key_Dark.png",.Keyboard,.Key,"Escape"},
        {"Keyboard & Mouse/Dark/Mouse_Right_Key_Dark.png",.Keyboard,.Mouse_Right,""},
        {"Keyboard & Mouse/Dark/Page_Up_Key_Dark.png",.Keyboard,.Key,"Page_Up"},
    }
    for c in cases {
        family,input,key,_,ok:=prompts_name_entry(c.path)
        testing.expectf(t,ok && family==c.family && input==c.input && key==c.key,"%s: %v %v %s %v",c.path,family,input,key,ok)
    }
    _,_,_,_,known:=prompts_name_entry("xbox/xbox_guide_light.png")
    testing.expect(t,!known,"a name that says no input")
    _,_,_,plain,_:=prompts_name_entry("keyboard_mouse/keyboard_a.png")
    _,_,_,outline,_:=prompts_name_entry("keyboard_mouse/keyboard_a_outline.png")
    testing.expect(t,plain<outline,"the plainest variant wins")
}

// The folder of the Kenney pack names, by itself, every input its manifest maps.
@(test)
the_folder_of_the_kenney_pack_maps_what_its_manifest_maps :: proc(t:^testing.T) {
    folder,_:=filepath.join({#directory,"../../plugins/prompts_kenney/assets"},context.temp_allocator)
    manifest_path,_:=filepath.join({folder,"kenney.prompts.json"},context.temp_allocator)
    text,error:=os.read_entire_file(manifest_path,context.temp_allocator)
    if !testing.expect(t,error==nil) {return}
    manifest,message:=prompts_manifest(string(text),folder,context.temp_allocator)
    testing.expect_value(t,message,"")
    found,_:=prompts_folder(folder,context.temp_allocator)
    for m in manifest {
        hit:=false
        for f in found {if f.family==m.family && f.input==m.input && f.key==m.key {hit=true;break}}
        testing.expectf(t,hit,"%v %v %s (%s) is found",m.family,m.input,m.key,filepath.base(m.image))
    }
}
