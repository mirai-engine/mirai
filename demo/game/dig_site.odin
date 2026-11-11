package game

import "core:math"
import "core:math/linalg"
import "mirai:core"
import cam "mirai:engine/camera"
import inp "mirai:engine/input"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import terrain "plugins:terrain/runtime"

// The dig of the scene dig. The Volume under it digs a pit by itself at the
// start of a Play, a ball every `interval` seconds from the surface down, and Use
// digs a ball where the player looks. What each dig takes (terrain.Terrain_Digs)
// goes to an inventory of cubic metres by material, and the ore drops that
// terrain_debris spawns are picked up by walking over them: the rules of a
// mining game are of the game, not of the engine.

DIG_MATERIALS :: 8
DIG_REACH :: f32(2.5) // metres from the eyes where Use digs
PICKUP_REACH :: f32(1.4)

@(component,description="Digs a pit into this Volume terrain at the start of a Play, and where the player looks with Use.")
Dig_Site :: struct {
    radius:f32 `mirai:"min=0.1,unit=m"`, // of each ball it digs
    digs:u32,                            // balls it digs by itself
    interval:f32 `mirai:"min=0,unit=s"`, // between those
    dug:u32 `mirai:"readonly"`,          // of those, the ones it dug
    next:u64 `mirai:"readonly,hidden"`,  // the tick it digs the next one at
}

DIG_SITE_DEFAULT :: Dig_Site{radius=1.6,digs=14,interval=1.0/6}

@(component,description="A drop of the dig: walking over it puts it in the inventory.")
Dig_Pickup :: struct {
    material:base.Asset_Id,
}

// What the players took, by material: cubic metres dug and drops picked up. On a
// core.Keep root: it passes to the next scene, and a save keeps it.
@(component)
Dig_Inventory :: struct {
    materials:[DIG_MATERIALS]base.Asset_Id,
    cubic_metres:[DIG_MATERIALS]f32,
    drops:[DIG_MATERIALS]u32,
    count:int,
}

@(step="fixed",stage="react")
dig_site :: proc(
    commands:core.Commands,sites:^core.Table(Dig_Site),pickups:^core.Table(Dig_Pickup,.Read),players:^core.Table(Player,.Read),
    sight:cam.Sight,actions:inp.Input_Of(Action),worlds:^core.Table(core.World_Transform,.Read),
    requests:^terrain.Terrain_Requests,digs:core.Ref(terrain.Terrain_Digs),inventories:^core.Table(Dig_Inventory),network:core.Network,time:core.Time,
) {
    site_entity,found:=core.sole(sites)
    if !found || network.role==.Client {return}
    if core.count(inventories)==0 {
        run:=core.commands_create(commands)
        core.commands_add(commands,run,core.Keep{})
        core.commands_add(commands,run,Dig_Inventory{})
        return
    }
    inventory:=core.edit_at(inventories,0)
    site:=core.edit_at(sites,0)
    if site.interval>0 && site.dug<site.digs && core.due(time,site.next) {
        // Down a spiral, a little deeper each time: a pit with walls through every stratum.
        i:=f32(site.dug)
        center:=[3]f32{math.cos(i*1.9)*1.5,0.3-i*0.42,math.sin(i*1.9)*1.5}
        site_world,_:=core.get(worlds,site_entity)
        terrain.dig(requests,{kind=.Carve,center=mm.transform_point(site_world.transform,center),radius=site.radius,amount=1,blend=0.3},site_entity)
        site.dug+=1
        site.next=core.deadline(time,site.interval)
    }
    for row in 0..<core.count(players) {
        e:=core.entity_at(players,row)
        origin,ahead,aimed:=cam.aim(sight,e)
        if !aimed || !inp.pressed(actions,e,.Use) {continue}
        terrain.dig(requests,{kind=.Carve,center=origin+ahead*DIG_REACH,radius=site.radius*0.8,amount=1,blend=0.2})
    }
    for dig in digs.digs.items {
        for taken,i in dig.layers {if taken>0 {inventory.cubic_metres[inventory_slot(inventory,dig.materials[i])]+=taken}}
    }
    for row in 0..<core.count(pickups) {
        drop:=core.entity_at(pickups,row)
        at,placed:=core.get(worlds,drop)
        if !placed {continue}
        for player in 0..<core.count(players) {
            body,found:=core.get(worlds,core.entity_at(players,player))
            if !found || linalg.length(body.position-at.position)>PICKUP_REACH {continue}
            inventory.drops[inventory_slot(inventory,core.at(pickups,row).material)]+=1
            core.commands_destroy(commands,drop)
            break
        }
    }
}

// The slot of a material: its own, or the last once every slot is taken.
@(private="file")
inventory_slot :: proc(inventory:^Dig_Inventory,material:base.Asset_Id) -> int {
    for i in 0..<inventory.count {if inventory.materials[i]==material {return i}}
    if inventory.count<DIG_MATERIALS {
        inventory.materials[inventory.count]=material
        inventory.count+=1
    }
    return inventory.count-1
}

// A material of the inventory, as dig_hud.ui lists it.
Dig_Hud_Row :: struct {
    name:[48]u8 `mirai:"text"`,
    cubic_metres:f32,
    drops:i32,
    picked:bool, // some of its drops were picked up
}

// What dig_hud.ui shows: what the player took, by material.
@(component,description="The HUD of a dig: what was dug and picked up, by material.")
Dig_Hud :: struct {
    rows:[DIG_MATERIALS]Dig_Hud_Row,
    count:i32,
}

@(step="frame")
dig_hud :: proc(huds:^core.Table(Dig_Hud),inventories:^core.Table(Dig_Inventory,.Read),assets:^host.Assets) {
    if core.count(huds)==0 {return}
    // The inventory is on the Keep root the first tick of a dig makes: none before it.
    inventory:Dig_Inventory
    if core.count(inventories)>0 {inventory=core.at(inventories,0)}
    next:=Dig_Hud{count=i32(inventory.count)}
    for i in 0..<inventory.count {
        row:=&next.rows[i]
        name:[base.ASSET_ID_TEXT]u8
        base.text_set(row.name[:],assets!=nil?host.assets_name(assets,inventory.materials[i],&name):"Material")
        row.cubic_metres=inventory.cubic_metres[i]
        row.drops,row.picked=i32(inventory.drops[i]),inventory.drops[i]>0
    }
    for row in 0..<core.count(huds) {
        core.edit_at(huds,row)^=next
    }
}
