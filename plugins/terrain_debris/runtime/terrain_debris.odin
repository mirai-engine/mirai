package terrain_debris

import "core:math"
import "mirai:core"
import "mirai:engine/scene"
import "mirai:host"
import "mirai:std/base"
import phys "plugins:physics/runtime"
import terrain "plugins:terrain/runtime"

// What a game's digs of a terrain leave besides the hole: pieces, prefabs
// with a body that fly out of it with the material their layer had, and
// drops, prefabs to pick up. Each layer of a Terrain_Debris says which and
// how many cubic metres taken give one; what a dig takes short of one is
// owed to the next dig of that terrain. A prefab with Replicate is born on
// the server and replicated: in a network session nothing is born on a
// client, which sees what the server sends.

TERRAINS :: 16 // terrains of a world whose owed cubic metres are kept

@(component,description="Pieces with physics and drops to pick up that a game's digs of this terrain spawn, by layer.")
Terrain_Debris :: struct {
    layers:[terrain.LAYERS_MAX]Debris_Layer, // by the index of the layer
    pieces_per_tick:u32,                     // pieces it spawns in a tick at most
    drops_per_tick:u32,                      // drops it spawns in a tick at most
    speed:f32 `mirai:"min=0,unit=m/s"`,      // pieces leave the middle of what was taken this fast, up and out
}

Debris_Layer :: struct {
    piece:base.Asset_Id `mirai:"kind=.prefab"`, // a prefab with a Rigid_Body; none: no pieces
    piece_volume:f32 `mirai:"min=0,unit=m3"`, // cubic metres taken for each piece
    drop:base.Asset_Id `mirai:"kind=.prefab"`,  // a prefab to pick up; none: no drops
    drop_volume:f32 `mirai:"min=0,unit=m3"`,  // cubic metres taken for each drop
}

TERRAIN_DEBRIS_DEFAULT :: Terrain_Debris{
    layers={0..<terrain.LAYERS_MAX={piece_volume=0.5,drop_volume=2}},
    pieces_per_tick=8,
    drops_per_tick=4,
    speed=3,
}

// Cubic metres taken that did not reach a piece or a drop yet, by terrain.
@(storage)
Debris_Owed :: struct {
    terrains:[TERRAINS]Owed,
    count:int,
}

Owed :: struct {
    owner:core.Entity,
    pieces,drops:[terrain.LAYERS_MAX]f32,
}

@(step="fixed",loops="game",stage="react")
terrain_debris :: proc(
    commands:core.Commands,app:^host.App,digs:core.Ref(terrain.Terrain_Digs),debris:core.Read(Terrain_Debris),
    owed:^Debris_Owed,bodies:^phys.Body_Requests,network:core.Network,time:core.Time,problems:^core.Problems,
) {
    if network.role==.Client || len(digs.digs.items)==0 {return}
    rooms:[TERRAINS][2]u32
    touched:[TERRAINS]bool
    for dig in digs.digs.items {
        config,found:=core.get(debris,dig.owner)
        if !found {continue}
        slot:=owed_of(owed,dig.owner,debris)
        if slot<0 {
            core.report(problems,dig.owner,"terrain_debris.terrains","more than %d terrains with Terrain_Debris are dug in this world; what this one takes spawns nothing: give Terrain_Debris to fewer terrains",TERRAINS)
            continue
        }
        if !touched[slot] {rooms[slot],touched[slot]={config.pieces_per_tick,config.drops_per_tick},true}
        o:=&owed.terrains[slot]
        for layer,i in config.layers {
            taken:=dig.layers[i]
            if !(taken>0) {continue}
            seed:=u64(time.tick)*0x9e3779b97f4a7c15+u64(i)*0xbf58476d1ce4e5b9+u64(dig.owner)
            if layer.piece!={} {
                for _ in 0..<debris_count(&o.pieces[i],taken,layer.piece_volume,&rooms[slot][0]) {
                    direction:=spread(&seed)
                    root,ok:=debris_spawn(commands,app,layer.piece,dig.center+direction*dig.radius*0.2,dig.owner,problems)
                    if ok && config.speed>0 {phys.set_velocity(bodies,root,(direction+{0,1,0})*config.speed*0.5)}
                }
            }
            if layer.drop!={} {
                for _ in 0..<debris_count(&o.drops[i],taken,layer.drop_volume,&rooms[slot][1]) {
                    debris_spawn(commands,app,layer.drop,dig.center+spread(&seed)*dig.radius*0.1,dig.owner,problems)
                }
            }
        }
    }
}

// How many prefabs of volume cubic metres each what is owed and taken gives,
// up to the room left in the tick. What the room did not take is owed only up
// to one more: a dig larger than the tick holds does not pour out after it.
debris_count :: proc "contextless" (owed:^f32,taken,volume:f32,room:^u32) -> (count:u32) {
    if !(volume>0) || !(taken>0) {return 0}
    owed^+=taken
    whole:=u32(min(owed^/volume,f32(room^)+1))
    count=min(whole,room^)
    room^-=count
    owed^-=f32(count)*volume
    if count<whole {owed^=min(owed^,volume)}
    return
}

// The slot of the owed cubic metres of a terrain; one of a terrain that lost
// its Terrain_Debris is taken back. -1 when all are taken.
@(private)
owed_of :: proc(owed:^Debris_Owed,owner:core.Entity,debris:core.Read(Terrain_Debris)) -> int {
    for i in 0..<owed.count {if owed.terrains[i].owner==owner {return i}}
    for i in 0..<owed.count {
        if !core.has(debris,owed.terrains[i].owner) {owed.terrains[i]={owner=owner};return i}
    }
    if owed.count>=TERRAINS {return -1}
    owed.terrains[owed.count]={owner=owner}
    owed.count+=1
    return owed.count-1
}

// A direction out of a hemisphere a little above the horizon, the same for
// the same seed on every end.
@(private)
spread :: proc "contextless" (seed:^u64) -> [3]f32 {
    next :: proc "contextless" (seed:^u64) -> f32 {
        seed^=seed^*6364136223846793005+1442695040888963407
        return f32(seed^>>40)/f32(1<<24)
    }
    turn:=next(seed)*math.TAU
    up:=0.2+next(seed)*0.6
    side:=math.sqrt(1-up*up)
    return {math.cos(turn)*side,up,math.sin(turn)*side}
}

@(private)
debris_spawn :: proc(commands:core.Commands,app:^host.App,prefab:base.Asset_Id,at:[3]f32,owner:core.Entity,problems:^core.Problems) -> (root:core.Entity,ok:bool) {
    transform:=core.TRANSFORM_IDENTITY
    transform.position=at
    report,error:=scene.spawn_prefab(commands,app,{prefab=prefab,transform=transform})
    if error!=.None {
        name:[base.ASSET_ID_TEXT]u8
        core.report(problems,owner,"terrain_debris.prefab","the debris prefab %s of this terrain could not spawn (%v): give each layer of Terrain_Debris a .prefab of the assets, or none",host.assets_name(app.assets,prefab,&name),error)
        return
    }
    return report.root,true
}
