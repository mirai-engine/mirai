package playtest_editor

import "core:testing"
import "mirai:asset"
import img "mirai:cook/image"

// What the audit flags is a trap and not what a game means: a black that no
// texture, light or metal changes, a scene nearly all blended, a cursor hidden
// over buttons and keys a screen takes from the player, a frame the player
// sees nothing in, a rig that plays and stands still and a bone that leaves
// its place in one tick.
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
    Frame_Case :: struct {stats:img.Image_Stats,dark,blown:bool,what:string}
    for c in ([]Frame_Case{
        {{black_percent=99.5,mean_luma=0.001},true,false,"a camera inside a wall"},
        {{black_percent=60,mean_luma=0.03,p5=0,p95=0.2},false,false,"a night scene with its lights"},
        {{saturated_percent=99,p5=0.95,mean_luma=0.99},false,true,"a sun a thousand times too strong"},
        {{saturated_percent=99,p5=0.05,mean_luma=0.2},false,false,"a red that saturates one channel"},
        {{saturated_percent=40,p5=0.5,mean_luma=0.8},false,false,"snow under a bright sky"},
    }) {
        dark,blown:=audit_exposure(c.stats)
        testing.expectf(t,dark==c.dark && blown==c.blown,"%s: dark %v blown %v",c.what,dark,blown)
    }
    rest:=[][3]f32{{0,0,0},{0,1,0},{0,1.6,0},{0.3,1.4,0}}
    walked:=[][3]f32{{0,0,0},{0,1,0.02},{0,1.6,0.01},{0.32,1.38,0.05}}
    headless:=[][3]f32{{0,0,0},{0,1,0},{0,0,0},{0.3,1.4,0}}
    Rig_Case :: struct {before,after:[][3]f32,extent:f32,played:int,snap,frozen:bool,what:string}
    for c in ([]Rig_Case{
        {rest,walked,1.6,10,false,false,"a walk"},
        {rest,rest,1.6,10,false,true,"a clip that plays and does not move it"},
        {rest,rest,1.6,1,false,false,"a clip that just started"},
        {rest,headless,1.6,10,true,false,"a head that drops to the feet in one tick"},
        {rest,rest[:3],1.6,10,false,false,"another skeleton"},
    }) {
        most,bone:=audit_bones_moved(c.before,c.after)
        snap:=bone>=0 && audit_bone_snap(most,c.extent)
        frozen:=bone>=0 && audit_rig_frozen(c.played,most)
        testing.expectf(t,snap==c.snap && frozen==c.frozen,"%s: snap %v frozen %v (%.3f m, bone %d)",c.what,snap,frozen,most,bone)
    }
    _,headless_bone:=audit_bones_moved(rest,headless)
    testing.expect_value(t,headless_bone,2)
}
