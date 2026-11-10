package render

import "mirai:core"
import "mirai:host"
import gpu "mirai:render"
import "mirai:std/base"
import mm "mirai:std/math"

// The sky is the light that comes from far away and what shows behind the
// scene: a component of an entity, so it turns with it, changes while the
// game runs, replicates and is saved. The world uses one at a time
// (@(component,single)): turning one on turns off the one that was on, which
// keeps its values. Without one on and shown no light comes from the sky and
// the background is black.
//
// A change of the sky the game, an animation or a cinematic drives is state
// of the component: what it changes from and fade, how much of it still
// shows, from 1 to 0; the renderer draws the mix and keeps no state of its
// own. Turning a sky on with a duration (activate) blends from the one that
// was on: that arrival is of each end, never replicated nor saved.

// The air of an atmosphere: a spherical planet whose air scatters the light
// of the sun (Rayleigh: the blue of the sky; Mie: the haze and the white
// around the sun) and absorbs it (Mie and ozone, which keeps the zenith blue
// at dusk). Their densities fall with altitude.
Air :: struct {
    rayleigh:[3]f32 `mirai:"min=0,unit=1/km"`,       // of the light a kilometre of air at the ground crosses, the share it scatters, per channel
    rayleigh_height:f32 `mirai:"min=0.01,unit=km"`,  // it thins by e every this much higher
    mie:[3]f32 `mirai:"min=0,unit=1/km"`,            // of the light a kilometre of haze at the ground crosses, the share it scatters
    mie_absorption:[3]f32 `mirai:"min=0,unit=1/km"`, // and the share it absorbs
    mie_height:f32 `mirai:"min=0.01,unit=km"`,
    mie_anisotropy:f32 `mirai:"min=0,max=0.999"`,    // how much of what the haze scatters goes on forward: the glow around the sun
    ozone:[3]f32 `mirai:"min=0,unit=1/km"`,          // of the light a kilometre of the middle of the ozone layer crosses, the share it absorbs
    ozone_altitude:f32 `mirai:"min=0,unit=km"`,      // of the middle of the layer
    ozone_width:f32 `mirai:"min=0.01,unit=km"`,      // how far from its middle the layer thins to nothing
    planet_radius:f32 `mirai:"min=1,unit=km"`,
    thickness:f32 `mirai:"min=1,unit=km"`,           // of the air, from the ground to where it ends
    ground_albedo:[3]f32 `mirai:"color"`,            // of the ground of the planet, which shows below the horizon
    altitude:f32 `mirai:"unit=m"`,                   // of the y 0 of the world over the ground of the planet
}

// The Earth of Hillaire 2020.
AIR_DEFAULT :: Air{
    rayleigh={0.005802,0.013558,0.0331},rayleigh_height=8,
    mie={0.003996,0.003996,0.003996},mie_absorption={0.000444,0.000444,0.000444},mie_height=1.2,mie_anisotropy=0.8,
    ozone={0.00065,0.001881,0.000085},ozone_altitude=25,ozone_width=15,
    planet_radius=6360,thickness=100,ground_albedo={0.3,0.3,0.3},
}

// The air in the units of the renderer, metres.
air_metres :: proc(air:Air) -> gpu.Air {
    KM :: f32(1000)
    return {
        rayleigh=air.rayleigh/KM,rayleigh_height=air.rayleigh_height*KM,
        mie=air.mie/KM,mie_absorption=air.mie_absorption/KM,mie_height=air.mie_height*KM,mie_anisotropy=air.mie_anisotropy,
        ozone=air.ozone/KM,ozone_altitude=air.ozone_altitude*KM,ozone_width=air.ozone_width*KM,
        ground_radius=air.planet_radius*KM,thickness=air.thickness*KM,ground_albedo=air.ground_albedo,altitude=air.altitude,
    }
}

// What a sky shows: its luminance and its image, or its atmosphere.
Sky_Look :: struct {
    luminance:[3]f32 `mirai:"color"`, // nits; with an image, what multiplies its values
    image:base.Asset_Id,              // the whole sky, twice as wide as tall, its horizon across its middle; none: a gradient of luminance
    atmosphere:bool,                  // the air of the sky lit by the sun, as Sky.atmosphere
}

@(component,single,replicated,description="The light of the sky and what shows behind the scene. Its image turns with the entity. The world uses one at a time: turning one on turns off the one that was on; without one, no light comes from the sky and the background is black.")
Sky :: struct {
    luminance:[3]f32 `mirai:"color,section=Light"`, // nits; with an image, what multiplies its values
    image:base.Asset_Id,              // the whole sky, twice as wide as tall, its horizon across its middle; none: a gradient of luminance
    background:[3]f32 `mirai:"color,section=Background"`, // the luminance behind the scene, nits
    use_background:bool,
    atmosphere:bool `mirai:"section=Light"`, // the air lit by the Sun, in place of luminance and image: the sky, the light of the sun and the haze of what is far follow its direction and its illuminance, so a day is turning the sun
    air:Air `mirai:"section=Air"`,           // of the atmosphere
    from:Sky_Look `mirai:"section=Change"`, // what a change on its way comes from
    fade:f32 `mirai:"min=0,max=1"`,         // how much of from still shows: 1 as the change starts, 0 once it is done
    arrival_from:Sky_Look `mirai:"local,transient,hidden"`, // the sky that was on before this one turned on
    arrival:f32 `mirai:"local,transient,hidden"`,           // how much of it still shows
    arrival_rate:f32 `mirai:"local,transient,hidden"`,      // what arrival loses a second
}

// The air lit by the Sun, so that a Sky and a Sun alone are a clear day at any
// direction of the sun. Without a Sun on, what a world with no sun has always
// had: the light of a clear sky (under 100000 lux) and a dark backdrop.
SKY_DEFAULT :: Sky{luminance={5000,5000,5000},background={27,37,64},use_background=true,atmosphere=true,air=AIR_DEFAULT}

// The sky and the sun the editor draws instead of those on, off or not, and
// the look of the view as inside the box of the section: the environment of a
// section, seen alone. Nothing of the world changes, it is not saved, and Play
// starts without it.
@(storage)
Environment_Preview :: struct {
    sky,sun:core.Entity, // none: the one on
    section:core.Entity, // the Scene_Reference previewed; none: the look of where the view is
}

// The sky the preview names, when it has one.
@(private)
sky_previewed :: proc(skies:core.Read(Sky),preview:core.Ref(Environment_Preview)) -> (e:core.Entity,sky:Sky,found:bool) {
    if preview.ptr==nil || preview.sky==core.NONE || skies.table==nil {return}
    row:=core.raw_row(core.raw(skies.table),preview.sky)
    if row<0 {return}
    return preview.sky,skies.table.values[row],true
}

// Turns on a sky, a sun or both, each turning off the one that was on. seconds
// above zero blends the sky from the one that was on over that time.
Environment_Request :: struct {
    sky,sun:core.Entity,
    seconds:f32,
}

@(storage,queue)
Environment_Requests :: struct {queue:core.Queue(Environment_Request)}

activate :: proc(r:^Environment_Requests,sky:core.Entity=core.NONE,sun:core.Entity=core.NONE,seconds:f32=0) {
    core.push(&r.queue,Environment_Request{sky,sun,seconds})
}

// The sky that lights the world: the one on, unless it or what it hangs from is hidden.
sky_active :: proc(skies:core.Read(Sky),hidden:core.Read(Hidden),parents:core.Read(core.Parent)) -> (e:core.Entity,sky:Sky,found:bool) {
    if core.count(skies)==0 {return}
    e=core.entity_at(skies,0)
    if is_hidden(hidden,parents,e) {return core.NONE,{},false}
    return e,core.at(skies,0),true
}

// Takes the requests to turn skies and suns on, and brings the arrival of the
// sky on to its end.
@(step="frame",loops="game editor")
environment_activate :: proc(
    requests:^Environment_Requests,skies:^core.Table(Sky),suns:^core.Table(Sun),frame:core.Frame_Time,problems:^core.Problems,
) {
    for r in core.take(&requests.queue) {
        if r.sun!=core.NONE {
            if core.raw_row(core.raw(suns),r.sun)<0 {
                core.report(problems,r.sun,"render.activate","the entity asked to light as the sun has no Sun; give it one, or name another")
            } else {
                core.enable(suns,r.sun)
            }
        }
        if r.sky==core.NONE {continue}
        row:=core.raw_row(core.raw(skies),r.sky)
        if row<0 {
            core.report(problems,r.sky,"render.activate","the entity asked to be the sky has no Sky; give it one, or name another")
            continue
        }
        if core.count(skies)>0 && core.entity_at(skies,0)==r.sky {continue}
        // Only how it arrives is written, in its row, on or off: the rest stays as what drives it wrote it.
        next:=(^Sky)(core.raw_edit(core.raw(skies),type_info_of(Sky),r.sky))
        next.arrival,next.arrival_rate=0,0
        if r.seconds>0 && core.count(skies)>0 {
            next.arrival_from=sky_look_now(core.at(core.read(skies),0))
            next.arrival,next.arrival_rate=1,1/r.seconds
        }
        core.enable(skies,r.sky)
    }
    if core.count(skies)==0 || frame.dt<=0 {return}
    if on:=core.at(core.read(skies),0);on.arrival>0 {
        sky:=core.edit(skies,core.entity_at(skies,0))
        sky.arrival=max(sky.arrival-sky.arrival_rate*frame.dt,0)
    }
}

// What a sky shows now, with the change on its way taken where it is.
@(private)
sky_look_now :: proc(sky:Sky) -> Sky_Look {
    if sky.fade<=0 {return {sky.luminance,sky.image,sky.atmosphere}}
    // An image cannot be half of another: the look keeps the one that shows most.
    look:=Sky_Look{luminance=mm.lerp(sky.luminance,sky.from.luminance,sky.fade),image=sky.image,atmosphere=sky.atmosphere}
    if sky.fade>0.5 {look.image,look.atmosphere=sky.from.image,sky.from.atmosphere}
    return look
}

// What the renderer draws of the sky on: luminance, image and the turn of
// its entity, mixed with what it arrives or changes from. Without one, black.
sky_environment :: proc(e:core.Entity,sky:Sky,found,sunlit:bool,worlds:core.Read(core.World_Transform),a:^host.Assets) -> gpu.Environment {
    if !found {return {use_background=true}}
    // The air shows only when lit, and then nothing shows behind it.
    atmosphere:=sky.atmosphere && sunlit
    environment:=gpu.Environment{sky=sky.luminance,background=sky.background,use_background=sky.use_background && !atmosphere}
    if world,ok:=core.get(worlds,e);ok {environment.sky_orientation=world.rotation}
    environment.sky_texture=sky_texture(a,sky.image)
    environment.sky_atmosphere=atmosphere
    environment.air=air_metres(sky.air)
    switch {
    case sky.arrival>0:
        environment.sky_from,environment.sky_from_texture,environment.sky_from_weight=sky.arrival_from.luminance,sky_texture(a,sky.arrival_from.image),min(sky.arrival,1)
        environment.sky_from_atmosphere=sky.arrival_from.atmosphere
    case sky.fade>0:
        environment.sky_from,environment.sky_from_texture,environment.sky_from_weight=sky.from.luminance,sky_texture(a,sky.from.image),min(sky.fade,1)
        environment.sky_from_atmosphere=sky.from.atmosphere
    }
    return environment
}

@(private)
sky_texture :: proc(a:^host.Assets,image:base.Asset_Id) -> gpu.Texture_Handle {
    if image=={} {return 0}
    if texture:=host.assets_texture_image(a,image);texture!=nil && !texture.failed {return texture.handle}
    return 0
}
