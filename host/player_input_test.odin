package host

import "core:testing"
import "mirai:ui"

// A shipped game's menu is driven from the script: keys and buttons reach the
// UI, and the pointer stays where the script left it so a release lands on the
// widget that was pressed.
@(test)
the_script_of_the_player_drives_the_ui :: proc(t:^testing.T) {
    script:=new(Player_Script,context.temp_allocator)
    line,parsed:=player_script_parse("# a menu\n3 3 Enter\n5 5 pointer:120.5,40 mouse:Left\n9 9 pointer:7,8\n",script)
    testing.expectf(t,parsed,"line %d",line)

    pressed:=player_script_input(script,3)
    held:=ui.Input{pointer_absent=true}
    player_script_ui(&held,pressed,{},false)
    testing.expect(t,.Enter in held.keys_pressed && .Enter in held.keys_down && .Enter in held.keys_repeated)
    testing.expect(t,held.pointer_absent,"no pointer until the script places one")

    for c in ([]struct{frame:int,pointer:[2]f32,points:bool}{
        {4,{},false},
        {5,{120.5,40},true},
        {6,{120.5,40},true},
        {9,{7,8},true},
        {100,{7,8},true},
    }) {
        pointer,points:=player_script_pointer(script,c.frame)
        testing.expectf(t,pointer==c.pointer && points==c.points,"frame %d: %v %v",c.frame,pointer,points)
    }

    click:=ui.Input{pointer_absent=true,keys_down={.Tab}}
    pointer,points:=player_script_pointer(script,5)
    player_script_ui(&click,player_script_input(script,5),pointer,points)
    testing.expect(t,.Left in click.pressed && .Left in click.down)
    testing.expect_value(t,click.clicks,u8(1))
    testing.expect_value(t,click.pointer,[2]f32{120.5,40})
    testing.expect(t,!click.pointer_absent)
    testing.expect(t,.Tab in click.keys_down,"what the devices gave stays")

    release:=ui.Input{}
    pointer,points=player_script_pointer(script,6)
    player_script_ui(&release,player_script_input(script,6),pointer,points)
    testing.expect(t,.Left in release.released && release.pointer==[2]f32{120.5,40})

    for wrong in ([]string{"1 1 pointer:1","1 1 pointer:a,2","1 1 pointer:nan,2","1 1 pointer:1,inf"}) {
        _,valid:=player_script_parse(wrong,script)
        testing.expectf(t,!valid,"'%s' is not a line",wrong)
    }
}
