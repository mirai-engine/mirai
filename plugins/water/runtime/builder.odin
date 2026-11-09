package water

import "mirai:asset"
import "mirai:std/base"
import mm "mirai:std/math"
import phys "plugins:physics/runtime"

// A sea a content tool adds to its scene: a plane of Fluid_Volume everything
// under its height is in, with its look and its waves.
builder_sea :: proc(b:^asset.Scene_Builder,name:string,height:f32=0,look:=WATER_DEFAULT,waves:=phys.FLUID_WAVES_DEFAULT,density:f32=1025) -> base.Entity_Id {
    e:=asset.builder_entity(b,name,mm.Transform{position={0,height,0}})
    if e==0 {return 0}
    asset.builder_set(b,e,phys.fluid_volume_sea(density))
    asset.builder_set(b,e,look)
    asset.builder_set(b,e,waves)
    return e
}
