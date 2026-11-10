package terrain

import "mirai:core"
import "mirai:std/base"

// The dust a terrain raises where a game digs it: each dig of a terrain with
// a Terrain_Dust gives births to the channel of each layer it took, of the
// color of that layer, at the middle of what it took (Terrain_Digs). An
// emitter with a Particle_Channel of that channel shows them with its
// effect; another channel for a layer gives it another effect. Dust is of
// each end of a network session, as the edits it follows: a rollback that
// repeats a tick does not start its births twice (vfx channels).

CHANNEL_DUST :: "dust"

@(component,description="The dust a game's digs of this terrain raise: births on the channel of each layer, of its color, by the cubic metres taken.")
Terrain_Dust :: struct {
    layers:[LAYERS_MAX]Dust_Layer,       // by the index of the layer
    per_cubic_metre:f32 `mirai:"min=0"`, // particles for each cubic metre taken
    most:u32,                            // particles one dig starts at most, over every layer
    speed:f32 `mirai:"min=0,unit=m/s"`,  // up, besides what the effect gives them
    size:f32 `mirai:"min=0"`,            // multiplies that of the effect; 0: 1
}

Dust_Layer :: struct {
    channel:[core.CHANNEL_NAME_BYTES]u8 `mirai:"text"`, // empty: no dust
    color:[4]f32 `mirai:"color"`, // multiplies that of the effect; zero: white
}

TERRAIN_DUST_DEFAULT :: Terrain_Dust{
    layers={0..<LAYERS_MAX={channel={0='d',1='u',2='s',3='t'},color={1,1,1,1}}},
    per_cubic_metre=40,
    most=96,
    speed=1.5,
}

@(step="fixed",loops="game",stage="react")
terrain_dust :: proc(digs:core.Ref(Terrain_Digs),dusts:core.Read(Terrain_Dust),births:^core.Births) {
    for dig in digs.digs.items {
        dust,found:=core.get(dusts,dig.owner)
        if !found {continue}
        budget:=min(f32(dust.most),dig.volume*dust.per_cubic_metre)
        for layer,i in dust.layers {
            layer:=layer
            channel:=core.birth_channel(base.text_get(layer.channel[:]))
            if channel==0 || !(dig.layers[i]>0) {continue}
            count:=u32(budget*dig.layers[i]/dig.volume+0.5)
            if count==0 {continue}
            core.push(&births.queue,core.Birth{channel=channel,position=dig.center,velocity={0,dust.speed,0},color=layer.color,size=dust.size,count=count})
        }
    }
}
