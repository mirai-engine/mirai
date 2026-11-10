package volume

import "mirai:core"
import mm "mirai:std/math"
import "mirai:render/abi"

// Where the air moves, which the foliage and the particles follow. It blows
// along the forward (-Z) of its entity; without any, the air is still.
@(component,replicated,description="Where the air moves, which the foliage and the particles follow: along the forward of its entity, where its Volume says; without a Volume, in the whole world.")
Wind :: struct {
    speed:f32 `mirai:"min=0,unit=m/s"`,
    gusts:f32 `mirai:"min=0"`, // cycles per second of what sways in it
}

WIND_DEFAULT :: Wind{speed=4,gusts=0.6}

// The wind as numbers that mix: xyz its velocity, m/s; w its gusts.
wind_value :: proc "contextless" (w:Wind,pose:mm.Transform) -> [4]f32 {
    v:=mm.quat_rotate(pose.rotation,[3]f32{0,0,-w.speed})
    return {v.x,v.y,v.z,w.gusts}
}

// The wind at a point, as wind_value.
wind_at :: proc(winds:core.Read(Wind),volumes:core.Read(Volume),worlds:core.Read(core.World_Transform),point:[3]f32) -> [4]f32 {
    if winds.table==nil {return {}}
    Winds :: struct {winds:core.Read(Wind),worlds:core.Read(core.World_Transform)}
    of :: proc(w:Winds,row:i32) -> [4]f32 {
        pose,placed:=core.get(w.worlds,core.entity_at(w.winds,int(row)))
        if !placed {pose.transform=mm.TRANSFORM_IDENTITY}
        return wind_value(core.at(w.winds,int(row)),pose.transform)
    }
    return combine(gather(volumes,worlds,winds,point),[4]f32{},Winds{winds,worlds},of,mix_linear)
}

WIND_VOLUMES :: abi.WIND_VOLUMES // the most a shader combines; past it the lowest priorities are left out

// volume.slang Gpu_Wind: every wind of the world in the order they apply.
Gpu_Wind :: struct {
    count:[4]u32,
    volumes:[WIND_VOLUMES]Gpu_Volume,
    values:[WIND_VOLUMES][4]f32, // as wind_value
}

gpu_wind :: proc(winds:core.Read(Wind),volumes:core.Read(Volume),worlds:core.Read(core.World_Transform)) -> (g:Gpu_Wind) {
    rows:[WIND_VOLUMES]i32
    n:=ordered(volumes,worlds,winds,rows[:])
    for i in 0..<n {
        e:=core.entity_at(winds,int(rows[i]))
        v,at,_:=placed(volumes,worlds,e)
        pose,found:=core.get(worlds,e)
        if !found {pose.transform=mm.TRANSFORM_IDENTITY}
        g.volumes[i]=gpu_volume(v,at)
        g.values[i]=wind_value(core.at(winds,int(rows[i])),pose.transform)
    }
    g.count.x=u32(n)
    return
}

// The winds of gpu_wind for a shader whose places are relative to origin.
gpu_wind_relative :: proc "contextless" (g:Gpu_Wind,origin:[3]f32) -> Gpu_Wind {
    g:=g
    for &v in g.volumes[:min(g.count.x,WIND_VOLUMES)] {v=gpu_volume_relative(v,origin)}
    return g
}
