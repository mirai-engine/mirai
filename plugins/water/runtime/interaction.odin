package water

import "core:math"
import "core:math/linalg"
import "mirai:core"
import phys "plugins:physics/runtime"

// What the bodies in the water show of it, read from the physics after its
// step and never given back: one that enters the water fast throws a splash
// through the channel CHANNEL_SPLASHES, one that moves under the surface
// leaves bubbles through CHANNEL_BUBBLES, and a camera under the water has
// motes around it through CHANNEL_MOTES: the emitters of each channel start
// the particles. A body stays wet after it leaves the water and dries in
// WET_SECONDS (water_wet_render). Presentation alone: nothing of it enters
// the simulation, a snapshot or a rollback.

CHANNEL_SPLASHES :: core.Birth_Channel(3)
CHANNEL_BUBBLES :: core.Birth_Channel(4)
CHANNEL_MOTES :: core.Birth_Channel(5)
SPLASH_SPEED :: f32(1.5)   // m/s down through the surface below which a body makes no splash
SPLASH_ENTERED :: f32(0.05) // share of a body under the surface past which it is in
SPLASH_PAUSE :: 30          // ticks a body makes no other splash after one
SPLASH_DROPS :: 24          // of a body of a cubic metre entering at SPLASH_SPEED
SPLASH_MOST :: 160          // drops of one splash
BUBBLE_SPEED :: f32(0.6)    // m/s below which a body under the surface leaves no bubbles
BUBBLE_UNDER :: f32(0.25)   // share of a body under the surface past which it bubbles
BUBBLE_PAUSE :: 6           // ticks between the bubbles of a body
BUBBLE_COUNT :: 4           // of a body of a cubic metre moving at BUBBLE_SPEED
BUBBLE_MOST :: 48           // bubbles of one birth
BUBBLE_DEPTH :: f32(0.1)    // m under the surface the highest bubbles start
MOTE_PAUSE :: 20            // ticks between the motes around a camera under the water
MOTE_COUNT :: 24            // motes of one birth, which the effect spreads around the camera
WET_SECONDS :: f32(6)       // a body soaked dries in this long out of the water
WET_CAPACITY :: 256         // bodies in the water or drying out of it

@(private)
Wet_Mark :: struct {
    entity:core.Entity,
    center:[3]f32, // where the physics found it last
    share:f32,     // of it under the surface in the tick before
    wet:f32,       // 0 dry to 1 soaked
    pause:u32,     // ticks left before it splashes again
    bubbles:u32,   // ticks left before it bubbles again
}

// The bodies the last tick found in the water, to see which enter it, and
// those that left it while they dry.
@(storage)
Water_Wet :: struct {
    marks:[WET_CAPACITY]Wet_Mark,
    count:int,
    motes:u32, // ticks left before the next motes around the camera
}

// The birth of the splash of a body that had `before` of itself under the
// surface in the tick before; false when it does not splash.
splash_of :: proc "contextless" (body:phys.Fluid_Body,before:f32) -> (birth:core.Birth,ok:bool) {
    if !(body.whole>0) {return}
    share:=body.volume/body.whole
    down:=-body.velocity.y
    if before>SPLASH_ENTERED || share<=SPLASH_ENTERED || down<SPLASH_SPEED {return}
    drops:=f32(SPLASH_DROPS)*math.cbrt(body.whole)*(down/SPLASH_SPEED)
    birth={
        channel=CHANNEL_SPLASHES,
        position={body.center.x,body.surface,body.center.z},
        velocity={0.3*body.velocity.x,0.35*down,0.3*body.velocity.z},
        size=clamp(math.cbrt(body.whole),0.5,3),
        count=u32(clamp(drops,4,SPLASH_MOST)),
    }
    return birth,true
}

// The bubbles a body under the surface leaves behind it as it moves, by its
// size and its speed; false when it is out of the water or still.
bubbles_of :: proc "contextless" (body:phys.Fluid_Body) -> (birth:core.Birth,ok:bool) {
    if !(body.whole>0) || body.volume/body.whole<BUBBLE_UNDER {return}
    speed:=linalg.length(body.velocity)
    if !(speed>=BUBBLE_SPEED) {return}
    size:=math.cbrt(body.whole)
    behind:=body.center-body.velocity*(0.5*body.reach/speed)
    behind.y=min(behind.y,body.surface-BUBBLE_DEPTH)
    birth={
        channel=CHANNEL_BUBBLES,
        position=behind,
        velocity=0.25*body.velocity,
        size=clamp(size,0.5,1.5),
        count=u32(clamp(f32(BUBBLE_COUNT)*size*speed/BUBBLE_SPEED,1,BUBBLE_MOST)),
    }
    return birth,true
}

// How wet a body is after dt seconds with share of it under the surface: as
// much as is under, or what it was drying towards none in WET_SECONDS.
wet_after :: proc "contextless" (before,share,dt:f32) -> f32 {
    return clamp(max(share,before-dt/WET_SECONDS),0,1)
}

@(step="fixed",loops="game editor",stage="simulate",after="physics_step")
water_bodies :: proc(wet:^Water_Wet,physics:core.Ref(phys.Physics_State),births:^core.Births,view:core.View,time:core.Time) {
    if !time.playing || !(time.dt>0) {return}
    found:[WET_CAPACITY]phys.Fluid_Body
    count:=min(phys.fluid_bodies(physics,found[:]),WET_CAPACITY)
    bodies_step(wet,found[:count],physics,births,time.dt)
    camera,_,known:=phys.fluid_at(physics,view.position)
    if !known || !(camera.density>0) {
        wet.motes=0
    } else if wet.motes>0 {
        wet.motes-=1
    } else {
        core.push(&births.queue,core.Birth{channel=CHANNEL_MOTES,position=view.position,count=MOTE_COUNT})
        wet.motes=MOTE_PAUSE
    }
}

// The marks of a tick from the bodies the physics found in the water: what
// each pushes to the channels, and how wet each is. A body the physics no
// longer finds left the water and dries, unless it sleeps where the tick
// before found it under the surface.
@(private)
bodies_step :: proc(wet:^Water_Wet,found:[]phys.Fluid_Body,physics:core.Ref(phys.Physics_State),births:^core.Births,dt:f32) {
    marks:[WET_CAPACITY]Wet_Mark
    taken:[WET_CAPACITY]bool // the marks of the tick before that a body found again takes
    count:=0
    for body,i in found {
        if count==WET_CAPACITY {break}
        // The step lists its bodies in about the same order each tick: look first where it was.
        before:=Wet_Mark{entity=body.entity}
        for k in 0..<wet.count {
            at:=(i+k)%wet.count
            if wet.marks[at].entity==body.entity {before,taken[at]=wet.marks[at],true;break}
        }
        share:=body.whole>0?body.volume/body.whole:0
        mark:=Wet_Mark{
            entity=body.entity,center=body.center,share=share,wet=wet_after(before.wet,share,dt),
            pause=before.pause>0?before.pause-1:0,bubbles=before.bubbles>0?before.bubbles-1:0,
        }
        if birth,splashes:=splash_of(body,before.share);splashes && mark.pause==0 {
            core.push(&births.queue,birth)
            mark.pause=SPLASH_PAUSE
        }
        if birth,bubbles:=bubbles_of(body);bubbles && mark.bubbles==0 {
            core.push(&births.queue,birth)
            mark.bubbles=BUBBLE_PAUSE
        }
        marks[count]=mark
        count+=1
    }
    for mark,at in wet.marks[:wet.count] {
        if taken[at] || count==WET_CAPACITY {continue}
        sample,_,known:=phys.fluid_at(physics,mark.center)
        left:=Wet_Mark{entity=mark.entity,center=mark.center,wet=wet_after(mark.wet,0,dt)}
        if known && sample.density>0 {left.share,left.wet=mark.share,mark.wet}
        if left.wet>0 {
            marks[count]=left
            count+=1
        }
    }
    wet.marks=marks
    wet.count=count
}
