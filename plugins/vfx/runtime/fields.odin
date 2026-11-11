package vfx

import "core:math/linalg"
import "mirai:core"
import erender "mirai:engine/render"
import volume "mirai:engine/volume"

// The particles of the world fall and blow as the bodies and the foliage do:
// each one, on the GPU, with the gravity and the wind of where it is, from
// the same volumes (volume.Gravity, volume.Wind) combined as engine/volume
// combines them. Its effect says what share of the gravity it takes
// (effect gravity) and its drag how fast it reaches the wind. The particles
// of an effect view are of no place: they fall with GRAVITY.

GRAVITY_VOLUMES :: 8 // the most a particle combines; past it the lowest priorities are left out

// particles.slang Particle_Gravity: every Gravity of the world in the order they apply.
Gpu_Gravity :: struct {
    count:[4]u32,
    volumes:[GRAVITY_VOLUMES]volume.Gpu_Volume,
    pulls:[GRAVITY_VOLUMES][4]f32,   // Down: xyz its acceleration, m/s2; Center: xyz its center
    centers:[GRAVITY_VOLUMES][4]f32, // x 1 toward a center; y its acceleration, m/s2; z its surface, m (0: as strong at any distance)
}

// particles.slang: what pool_prepare puts in the rows of the frame for the
// particles of the world, relative to the origin of the frame.
Gpu_Fields :: struct {
    fallback:[4]f32, // xyz the gravity where no Gravity rules
    gravity:Gpu_Gravity,
    wind:volume.Gpu_Wind,
}
#assert(size_of(Gpu_Fields)==16+16+GRAVITY_VOLUMES*(80+32)+size_of(volume.Gpu_Wind))

// The gravity and the wind of the world, from its fields.
fields_of :: proc(gravities:^core.Table(volume.Gravity,$A),winds:^core.Table(volume.Wind,.Read),zones:volume.Where) -> (f:Gpu_Fields) {
    f.fallback.xyz=volume.GRAVITY_WORLD
    if winds!=nil {f.wind=volume.gpu_wind(winds,zones)}
    if gravities==nil {return}
    rows:[GRAVITY_VOLUMES]i32
    n:=volume.ordered(zones,gravities,rows[:])
    g:=&f.gravity
    for i in 0..<n {
        e:=core.entity_at(gravities,int(rows[i]))
        v,at,_:=volume.placed(zones,e)
        world,_:=core.get(zones.worlds,e)
        field:=core.at(gravities,int(rows[i]))
        g.volumes[i]=volume.gpu_volume(v,at,field.zone)
        switch field.pull {
        case .Down:
            g.pulls[i].xyz=volume.gravity_of(field,world.transform,{})
        case .Center:
            scale:=linalg.abs(world.scale)
            g.pulls[i].xyz=world.position
            g.centers[i]={1,field.acceleration,field.radius*max(scale.x,scale.y,scale.z),0}
        }
    }
    g.count.x=u32(n)
    return
}

// The strongest gravity and the fastest wind anywhere in fields, m/s2 and m/s:
// a particle reaches no faster than the wind its drag takes it to.
fields_most :: proc "contextless" (f:Gpu_Fields) -> (gravity,wind:f32) {
    gravity=linalg.length(f.fallback.xyz)
    g:=f.gravity
    for i in 0..<min(g.count.x,GRAVITY_VOLUMES) {
        gravity=max(gravity,abs(g.centers[i].y) if g.centers[i].x!=0 else linalg.length(g.pulls[i].xyz))
    }
    for i in 0..<min(f.wind.count.x,volume.WIND_VOLUMES) {wind=max(wind,linalg.length(f.wind.values[i].xyz))}
    return
}

// The fields of fields_of for the particles of a frame whose places are relative to origin.
fields_relative :: proc "contextless" (f:Gpu_Fields,origin:[3]f32) -> Gpu_Fields {
    f:=f
    g:=&f.gravity
    for i in 0..<min(g.count.x,GRAVITY_VOLUMES) {
        g.volumes[i]=volume.gpu_volume_relative(g.volumes[i],origin)
        if g.centers[i].x!=0 {g.pulls[i].xyz=erender.origin_point(g.pulls[i].xyz,origin)}
    }
    f.wind=volume.gpu_wind_relative(f.wind,origin)
    return f
}
