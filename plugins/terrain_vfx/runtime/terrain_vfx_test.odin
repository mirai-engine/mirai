package terrain_vfx

import "core:testing"
import "mirai:core"
import "mirai:std/base"
import terrain "plugins:terrain/runtime"
import vfx "plugins:vfx/runtime"

@(private="file")
Dust_World :: struct {
    using world:core.Test_World,
    dusts:core.Table(Terrain_Dust),
    digs:terrain.Terrain_Digs,
    channels:vfx.Particle_Channels,
}

@(test)
a_dig_raises_dust_of_each_layer_it_took_on_its_channel :: proc(t:^testing.T) {
    w:Dust_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    dusty,bare:=core.create(&w.entities),core.create(&w.entities)
    dust:=TERRAIN_DUST_DEFAULT
    dust.layers[1].color={1,0,0,1}
    base.text_set(dust.layers[1].channel[:],"gravel")
    dust.layers[3].channel={}
    core.add(&w.dusts,dusty,dust)
    core.test_world_settle(&w)
    core.push(&w.digs.digs,terrain.Terrain_Dig{owner=dusty,center={1,2,3},volume=1,layers={0.5,0.25,0,0.25}})
    core.push(&w.digs.digs,terrain.Terrain_Dig{owner=bare,volume=1,layers={1,0,0,0}})
    terrain_dust(core.ref(&w.digs),core.read(&w.dusts),&w.channels)
    pushes:=w.channels.queue.items[:]
    testing.expect_value(t,len(pushes),2)
    if len(pushes)!=2 {return}
    testing.expect(t,pushes[0].channel==base.name_hash(CHANNEL_DUST) && pushes[0].birth.count==20 && pushes[0].birth.position==[3]f32{1,2,3})
    testing.expect(t,pushes[1].channel==base.name_hash("gravel") && pushes[1].birth.count==10 && pushes[1].birth.color==[4]f32{1,0,0,1})
}
