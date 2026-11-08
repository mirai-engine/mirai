package game

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "mirai:core"
import gui "mirai:engine/gui"
import inp "mirai:engine/input"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:ui"
import terrain "plugins:terrain/runtime"

// The dig of the scene dig. The Volume under it digs a pit by itself at the
// start of a Play, a ball every few ticks from the surface down, and Use
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
    every:u32,                           // ticks between those
}

DIG_SITE_DEFAULT :: Dig_Site{radius=1.6,digs=14,every=10}

@(component,description="A drop of the dig: walking over it puts it in the inventory.")
Dig_Pickup :: struct {
    material:base.Asset_Id,
}

// What the player took, by material: cubic metres dug and drops picked up.
@(storage)
Dig_Inventory :: struct {
    materials:[DIG_MATERIALS]base.Asset_Id,
    cubic_metres:[DIG_MATERIALS]f32,
    drops:[DIG_MATERIALS]u32,
    count:int,
    dug:u32, // balls the sites dug by themselves
}

@(step="fixed",stage="react")
dig_site :: proc(
    commands:core.Commands,sites:core.Read(Dig_Site),pickups:core.Read(Dig_Pickup),players:core.Read(Player),
    drivables:core.Read(inp.Drivable),actions:inp.Input_Of(Action),worlds:core.Read(core.World_Transform),
    requests:^terrain.Terrain_Requests,digs:core.Ref(terrain.Terrain_Digs),inventory:^Dig_Inventory,network:core.Network,time:core.Time,
) {
    site_entity,found:=core.sole(sites)
    if !found || network.role==.Client {return}
    site:=core.at(sites,0)
    if site.every>0 && inventory.dug<site.digs && time.tick%u64(site.every)==0 {
        // Down a spiral, a little deeper each time: a pit with walls through every stratum.
        i:=f32(inventory.dug)
        center:=[3]f32{math.cos(i*1.9)*1.5,0.3-i*0.42,math.sin(i*1.9)*1.5}
        site_world,_:=core.get(worlds,site_entity)
        terrain.dig(requests,{kind=.Subtract,shape=.Sphere,center=mm.transform_point(site_world.transform,center),radius=site.radius,amount=1,blend=0.3},site_entity)
        inventory.dug+=1
    }
    for row in 0..<core.count(players) {
        e:=core.entity_at(players,row)
        origin,ahead,aimed:=inp.aim(drivables,worlds,e)
        if !aimed || !inp.pressed(actions,e,.Use) {continue}
        terrain.dig(requests,{kind=.Subtract,shape=.Sphere,center=origin+ahead*DIG_REACH,radius=site.radius*0.8,amount=1,blend=0.2})
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

// What the player took, by material, while the scene has a site.
@(step="ui")
dig_hud :: proc(g:^gui.Gui,sites:core.Read(Dig_Site),inventory:core.Ref(Dig_Inventory),app:^host.App) {
    ctx:=gui.gui_context(g)
    if ctx==nil || core.count(sites)==0 {return}
    panel:=hud_box(ctx,"dig.inventory",.Top_Left,.Top_Left,{12,12},ui.fixed(300),ui.fit(),{0,0,0,160},ui.padding_xy(12,8))
    panel.layout.direction=.Column
    panel.layout.gap=4
    if ui.box(ctx,panel) {
        ui.label(ctx,"Dug",size=18)
        for i in 0..<inventory.count {
            name:[base.ASSET_ID_TEXT]u8
            label:=app.assets!=nil?host.assets_name(app.assets,inventory.materials[i],&name):"Material"
            line:=fmt.tprintf("%s  %.2f m3",label,inventory.cubic_metres[i])
            if inventory.drops[i]>0 {line=fmt.tprintf("%s   %d picked up",line,inventory.drops[i])}
            ui.label(ctx,line,size=13,color={225,225,230,255})
        }
        ui.text(ctx,"Use: dig where you look    walk over the ore to pick it up",{size=12,color={255,210,116,255},wrap=.Words},width=ui.fixed(276))
    }
}
