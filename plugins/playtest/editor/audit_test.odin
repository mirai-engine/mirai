package playtest_editor

import "core:testing"
import "mirai:asset"

// What the audit flags is a trap and not what a game means: a black that no
// texture, light or metal changes, a scene nearly all blended, a cursor hidden
// over buttons and keys a screen takes from the player.
@(test)
the_audit_tells_a_trap_from_what_a_game_means :: proc(t:^testing.T) {
    black:=asset.MATERIAL_DEFAULTS
    black.base_color={0.01,0.01,0.01}
    textured,metal,glowing,unlit,glass,grey:=black,black,black,black,black,asset.MATERIAL_DEFAULTS
    textured.maps.base_color.texture={1,2}
    metal.metallic=1
    glowing.emission={1,0,0}
    unlit.unlit=true
    glass.transmission=1
    grey.base_color={0.2,0.2,0.2}
    Material_Case :: struct {material:asset.Material_Info,black:bool,what:string}
    for c in ([]Material_Case{{black,true,"black dielectric"},{textured,false,"textured"},{metal,false,"metal"},{glowing,false,"emissive"},{unlit,false,"unlit"},{glass,false,"glass"},{grey,false,"grey"}}) {
        m:=c.material
        testing.expectf(t,audit_black(&m)==c.black,"%s: black %v",c.what,!c.black)
    }
    Blend_Case :: struct {meshes,blended:int,ratio:f32,heavy:bool}
    for c in ([]Blend_Case{{19,19,0.25,false},{20,5,0.25,true},{20,4,0.25,false},{100,0,0,false},{40,40,1,true}}) {
        testing.expectf(t,audit_blend_heavy(c.meshes,c.blended,c.ratio)==c.heavy,"%v",c)
    }
    Input_Case :: struct {buttons:int,captured,modal,keyboard,driving:bool,cursor,keys:bool}
    for c in ([]Input_Case{
        {2,true,false,false,true,true,false},  // a menu over a game that holds the mouse
        {2,false,false,false,true,false,false},
        {0,true,false,false,true,false,false},  // a game that holds the mouse with no menu
        {0,false,false,true,true,false,true},   // a HUD that kept the focus while the player drives
        {0,false,true,true,true,false,false},   // a Modal screen takes the keys on purpose
        {0,false,false,true,false,false,false}, // no body to drive: the keys are the menu's
    }) {
        cursor,keys:=audit_input_traps(c.buttons,c.captured,c.modal,c.keyboard,c.driving)
        testing.expectf(t,cursor==c.cursor && keys==c.keys,"%v: cursor %v keys %v",c,cursor,keys)
    }
}
