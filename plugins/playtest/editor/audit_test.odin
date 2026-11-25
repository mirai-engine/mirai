package playtest_editor

import "core:testing"
import "mirai:asset"
import img "mirai:cook/image"
import "mirai:core"
import mm "mirai:std/math"

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
        {{black_percent=93,mean_luma=0.004,p95=0.03},true,false,"an interior whose exposure is far too low"},
        {{black_percent=60,mean_luma=0.03,p5=0,p95=0.2},false,false,"a night scene with its lights"},
        {{saturated_percent=99,p5=0.95,p50=0.99,mean_luma=0.99},false,true,"a sun a thousand times too strong"},
        {{saturated_percent=72,p5=0.3,p50=0.92,mean_luma=0.8},false,true,"daylight at the exposure of an interior"},
        {{saturated_percent=99,p5=0.05,p50=0.2,mean_luma=0.2},false,false,"a red that saturates one channel"},
        {{saturated_percent=40,p5=0.5,p50=0.75,mean_luma=0.8},false,false,"snow under a bright sky"},
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

// An effect in view that changes a spot of pixels or more is seen; one off
// the image, behind the camera or so far that it should cover a few pixels is
// not judged; one in view that changes a few pixels is unseen.
@(test)
an_effect_in_view_that_changes_no_pixel_is_unseen :: proc(t:^testing.T) {
    view:=core.View{position={0,0,0},rotation=1,fov=1,near=0.1,far=100,size={256,144}}
    Effect_Case :: struct {at:[3]f32,reach:f32,pixels:int,unseen:bool,what:string}
    for c in ([]Effect_Case{
        {{0,0,-5},1,0,true,"ahead, drawing nothing"},
        {{1,0.5,-5},1,AUDIT_UNSEEN_PIXELS-1,true,"ahead to the side, drawing a few pixels"},
        {{0,0,-5},1,AUDIT_UNSEEN_PIXELS,false,"ahead, drawing a spot"},
        {{0,0,-80},0.3,0,false,"so far that it should take a few pixels"},
        {{0,0,5},1,0,false,"behind the camera"},
        {{40,0,-5},1,0,false,"far to the right"},
        {{0,9,-5},1,0,false,"far above"},
    }) {
        unseen:=audit_unseen(c.pixels,audit_covered(view,c.at,c.reach))
        testing.expectf(t,unseen==c.unseen,"%s: unseen %v",c.what,unseen)
    }
}

// A mesh in other units is drawn far from its size; one a level scales by a
// few times is not; one far from the others of its mesh is out of place.
@(test)
a_mesh_drawn_far_from_its_size_is_flagged :: proc(t:^testing.T) {
    Far_Case :: struct {scale:[3]f32,far:bool,what:string}
    for c in ([]Far_Case{
        {{100,100,100},true,"a fish in meters drawn as if in centimeters"},
        {{-100,100,100},true,"the same fish mirrored"},
        {{0.01,0.01,0.01},false,"a mesh in centimeters drawn at its size"},
        {{3,3,3},false,"a rock three times its size"},
        {{500,1,500},false,"a ground stretched on two axes"},
        {{1,-1,1},false,"a mirrored prop"},
    }) {
        testing.expectf(t,audit_scale_far(c.scale)==c.far,"%s: far %v",c.what,!c.far)
    }
    Kin_Case :: struct {ratio:f32,odd:bool,what:string}
    for c in ([]Kin_Case{{12,true,"a fish twelve times its school"},{0.05,true,"one twenty times smaller"},{4,false,"a fish four times its school"}}) {
        _,odd:=mm.scale_beyond({c.ratio,c.ratio,c.ratio},AUDIT_SCALE_KIN)
        testing.expectf(t,odd==c.odd,"%s: odd %v",c.what,!c.odd)
    }
}
