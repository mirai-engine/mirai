package game

import "core:testing"
import "mirai:core"
import inp "mirai:engine/input"
import terrain "plugins:terrain/runtime"

@(private="file")
Dig_World :: struct {
    using world:core.Test_World,
    sites:core.Table(Dig_Site),
    pickups:core.Table(Dig_Pickup),
    players:core.Table(Player),
    drivables:core.Table(inp.Drivable),
    worlds:core.Table(core.World_Transform),
    inventories:core.Table(Dig_Inventory),
    keeps:core.Table(core.Keep),
    requests:terrain.Terrain_Requests,
    digs:terrain.Terrain_Digs,
}

@(private="file")
dig_types :: proc(types:^[dynamic]core.Test_Type) {
    append(types,core.test_type(Dig_Site,default=proc(dst:^Dig_Site) {dst^=DIG_SITE_DEFAULT}))
}

// What the players take is run state: a component on a core.Keep root, which
// passes to the next scene and a save keeps, made by the first tick of the
// site; a drop walked over is counted on it.
@(test)
the_inventory_of_the_dig_lives_on_a_root_that_keeps :: proc(t:^testing.T) {
    w:=new(Dig_World)
    defer free(w)
    if !core.test_world_init(t,w,dig_types) {return}
    defer core.test_world_destroy(w)
    commands:=core.commands(w,core.test_world_info(w))
    site,player,drop:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    core.add(&w.sites,site,DIG_SITE_DEFAULT)
    core.add(&w.players,player,Player{})
    core.add(&w.worlds,player,core.World_Transform{})
    core.add(&w.pickups,drop,Dig_Pickup{material={7,7}})
    core.add(&w.worlds,drop,core.World_Transform{})
    core.test_world_settle(w)
    tick :: proc(w:^Dig_World,commands:core.Commands) {
        dig_site(commands,&w.sites,core.read(&w.pickups),core.read(&w.players),core.read(&w.drivables),{},core.read(&w.worlds),&w.requests,core.ref(&w.digs),&w.inventories,{},{tick=1,dt=1.0/60,playing=true})
        core.test_world_settle(w)
    }
    tick(w,commands)
    root,made:=core.sole(core.read(&w.inventories))
    testing.expect(t,made && core.has(core.read(&w.keeps),root),"the first tick makes the root of the run, kept")
    testing.expect(t,core.alive(&w.entities,drop),"nothing is counted before the root is there")
    tick(w,commands)
    inventory,found:=core.get(core.read(&w.inventories),root)
    testing.expect(t,found && inventory.count==1 && inventory.drops[0]==1 && inventory.materials[0]=={7,7})
    testing.expect(t,!core.alive(&w.entities,drop),"the drop walked over is taken")
}
