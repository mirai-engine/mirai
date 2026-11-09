package main

import "core:fmt"
import "core:math"
import "core:os"
import "mirai:asset"
import "mirai:core"
import game "mirai:demo/game"
import "mirai:engine/gui"
import render "mirai:engine/render"
import "mirai:std/base"
import "mirai:std/serial"

// The scene of the game interfaces (game/interface_demo.odin), whose .ui are
// the files of assets/ui/interface: a HUD with three styles, a menu of
// options, an inventory to drag items in, a conversation and a name tag over
// a pillar. The items and the conversation are tables of game data in
// assets/data.

ICON_SIZE :: 64

Icon_Shape :: enum u8 {Sword,Potion,Shield,Gem,Coin}

// An item of the inventory drawn on the CPU: a shape of a color with a rim,
// transparent around it.
@(private)
write_item_icon :: proc(o:^Out,shape:Icon_Shape,color:[3]f32) -> base.Asset_Id {
    names:=[Icon_Shape]string{.Sword="sword",.Potion="potion",.Shield="shield",.Gem="gem",.Coin="coin"}
    id:=asset.content_id(PROJECT,"texture",fmt.tprintf("item_%s",names[shape]))
    pixels:=make([]u8,ICON_SIZE*ICON_SIZE*4,context.temp_allocator)
    for y in 0..<ICON_SIZE {
        for x in 0..<ICON_SIZE {
            p:=[2]f32{f32(x)+0.5-ICON_SIZE/2,f32(y)+0.5-ICON_SIZE/2}
            // Signed distance: negative inside.
            d:f32
            switch shape {
            case .Sword:
                // A blade along the diagonal and a guard across it.
                u:=(p.x+p.y)*0.7071;v:=(p.x-p.y)*0.7071
                blade:=max(abs(v)-4,abs(u+2)-22)
                guard:=max(abs(u-14)-3,abs(v)-12)
                d=min(blade,guard)
            case .Potion:
                body:=math.sqrt(p.x*p.x+(p.y-6)*(p.y-6))-17
                neck:=max(abs(p.x)-5,abs(p.y+16)-9)
                d=min(body,neck)
            case .Shield:
                d=max(abs(p.x)-20,abs(p.y+2)-22)+0.0
                if p.y>4 {d=max(d,math.sqrt(p.x*p.x+(p.y-4)*(p.y-4)*0.6)-20)}
            case .Gem:
                d=(abs(p.x)+abs(p.y)*0.8)-24
            case .Coin:
                d=math.sqrt(p.x*p.x+p.y*p.y)-24
            }
            coverage:=clamp(0.5-d,0,1)
            rim:=clamp(1-abs(d+3),0,1)
            shade:=color*(0.75+0.25*clamp(-p.y/30,-1,1))
            c:=shade*(1-rim)+[3]f32{1,1,1}*rim*0.9
            at:=(y*ICON_SIZE+x)*4
            pixels[at],pixels[at+1],pixels[at+2]=u8(clamp(c.r,0,1)*255),u8(clamp(c.g,0,1)*255),u8(clamp(c.b,0,1)*255)
            pixels[at+3]=u8(coverage*255)
        }
    }
    file:=fmt.tprintf("assets/textures/item_%s.tex",names[shape])
    asset.content_check(&o.content,file,asset.texture_save(path(o,file),&o.content.types,{id=id,width=ICON_SIZE,height=ICON_SIZE,format=.RGBA8,flags={.Srgb},mips={pixels}}))
    return id
}

ITEMS_FILE :: "assets/data/items.records"
LINES_FILE :: "assets/data/merchant_lines.records"
ANSWERS_FILE :: "assets/data/merchant_answers.records"

// The items of the inventory and what the merchant of the conversation says.
@(private)
write_interface_records :: proc(o:^Out,icons:[5]base.Asset_Id) {
    item :: proc(name,en,es:string,icon:base.Asset_Id,rarity:game.Item_Rarity,stack:i32,texts:^[dynamic]Text_Out) -> Row_Out(game.Item) {
        title:=record_text_of(ITEMS_FILE,name,en,es)
        append(texts,title)
        return {name,{title=title.text,icon=icon,rarity=rarity,stack=stack}}
    }
    item_texts:=make([dynamic]Text_Out,context.temp_allocator)
    items:=[]Row_Out(game.Item){
        item("sword","Sword","Espada",icons[0],.Rare,1,&item_texts),
        item("potion","Potion","Poción",icons[1],.Common,10,&item_texts),
        item("shield","Shield","Escudo",icons[2],.Common,1,&item_texts),
        item("gem","Gem","Gema",icons[3],.Epic,5,&item_texts),
        item("coins","Coins","Monedas",icons[4],.Common,99,&item_texts),
    }
    write_records(o,ITEMS_FILE,"game.Item",game.Item,items,item_texts[:])

    line_texts:=make([dynamic]Text_Out,context.temp_allocator)
    merchant:=record_text_of(LINES_FILE,"merchant","Merchant","Mercader")
    append(&line_texts,merchant)
    line :: proc(name,en,es:string,next:string,speaker:Text_Out,texts:^[dynamic]Text_Out) -> Row_Out(game.Dialogue_Line) {
        said:=record_text_of(LINES_FILE,name,en,es)
        append(texts,said)
        value:=game.Dialogue_Line{speaker=speaker.text,text=said.text}
        if next!="" {value.next=record_ref(game.Dialogue_Line,LINES_FILE,next)}
        return {name,value}
    }
    lines:=[]Row_Out(game.Dialogue_Line){
        line("greet","Welcome, traveler. Looking for something?","Bienvenido, viajero. ¿Buscas algo?","",merchant,&line_texts),
        line("wares","Only potions today. Come back tomorrow for the rest.","Hoy solo pociones. Vuelve mañana por lo demás.","greet",merchant,&line_texts),
        line("news","They say a gem glows inside the old pillar.","Dicen que una gema brilla dentro del pilar viejo.","greet",merchant,&line_texts),
        line("gem","Ha! Then keep it between us.","¡Ja! Entonces que quede entre nosotros.","",merchant,&line_texts),
    }
    write_records(o,LINES_FILE,"game.Dialogue_Line",game.Dialogue_Line,lines,line_texts[:])

    answer_texts:=make([dynamic]Text_Out,context.temp_allocator)
    answer :: proc(name,from,en,es,to:string,texts:^[dynamic]Text_Out,requires:="",sets:="") -> Row_Out(game.Dialogue_Choice) {
        said:=record_text_of(ANSWERS_FILE,name,en,es)
        append(texts,said)
        value:=game.Dialogue_Choice{line=record_ref(game.Dialogue_Line,LINES_FILE,from),text=said.text}
        if to!="" {value.to=record_ref(game.Dialogue_Line,LINES_FILE,to)}
        base.text_set(value.requires[:],requires)
        base.text_set(value.sets[:],sets)
        return {name,value}
    }
    answers:=[]Row_Out(game.Dialogue_Choice){
        answer("wares","greet","Show me your wares.","Muéstrame lo que vendes.","wares",&answer_texts),
        answer("news","greet","Any news?","¿Alguna novedad?","news",&answer_texts,sets="heard"),
        answer("gem","greet","I found the gem of the pillar.","Encontré la gema del pilar.","gem",&answer_texts,requires="heard"),
        answer("bye","greet","Goodbye.","Adiós.","",&answer_texts),
    }
    write_records(o,ANSWERS_FILE,"game.Dialogue_Choice",game.Dialogue_Choice,answers,answer_texts[:])
}

write_interface_scene :: proc(o:^Out) {
    icons:=[5]base.Asset_Id{
        write_item_icon(o,.Sword,{0.75,0.8,0.86}),
        write_item_icon(o,.Potion,{0.9,0.2,0.25}),
        write_item_icon(o,.Shield,{0.25,0.45,0.9}),
        write_item_icon(o,.Gem,{0.7,0.3,0.95}),
        write_item_icon(o,.Coin,{0.98,0.78,0.2}),
    }
    hud,menu,inventory,tag,dialogue:=ui_id("interface_hud"),ui_id("interface_menu"),ui_id("interface_inventory"),ui_id("interface_tag"),ui_id("interface_dialogue")
    write_interface_records(o,icons)
    if o.content.failed {return}

    s:asset.Scene_Builder
    asset.builder_init(&s,&o.content,asset.KIND_SCENE,asset.content_id(PROJECT,"scene","interface"))
    defer asset.builder_destroy(&s)
    environment,turn,to_sun,disc:=sky_of(o,.Day,SCENE_SUN,LAMPLIT,1.5)
    sky_set(&s,&environment,turn)
    sun:=render.Sun{color={1,0.96,0.9},illuminance=lux(LAMPLIT,1.5),disc=disc}
    sun_entity:=asset.builder_entity(&s,"Sun",{position={0,6,0}})
    pose:=sun_pose(to_sun,{0,6,0})
    asset.builder_set(&s,sun_entity,pose)
    asset.builder_set(&s,sun_entity,sun)
    solid(&s,asset.builder_entity(&s,"Floor",{position={0,-0.05,0},scale={14,0.1,14}}),"Tiles")
    solid(&s,asset.builder_entity(&s,"Pillar",{position={0,1,-3},scale={0.6,2,0.6}}),"Marble")
    spawn_point(&s,{0,0,4})

    demo:=game.Interface_Demo{health=100,most=100,coins=120,quality=2,subtitles=true}
    base.text_set(demo.player[:],"Ana")
    // Rows of the same item top each other up when one is let go over the other.
    Stock :: struct {item:string,count:i32}
    stock:=[?]Stock{{"sword",1},{"potion",5},{"shield",1},{"gem",3},{"coins",64},{"potion",2},{"gem",1}}
    for slot,i in stock {demo.items[i]={item=record_ref(game.Item,ITEMS_FILE,slot.item),count=slot.count}}
    demo.item_count=i32(len(stock))
    demo.talk=record_ref(game.Dialogue_Line,LINES_FILE,"greet")
    // The demo is the tag over the pillar too: a World_Widget binds the component of its own entity.
    holder:=asset.builder_entity(&s,game.INTERFACE_DEMO,{position={0,2.6,-3}})
    asset.builder_set(&s,holder,demo)
    widget:=gui.WORLD_WIDGET_DEFAULT
    widget.asset,widget.size,widget.scale,widget.facing,widget.pivot=tag,{280,90},0.006,.Billboard,.Bottom_Center
    asset.builder_set(&s,holder,widget)

    screen :: proc(s:^asset.Scene_Builder,name:string,asset_id:base.Asset_Id,holder:base.Entity_Id,input:gui.UI_Input,order:i32,back,hidden:bool) {
        e:=asset.builder_entity(s,name)
        sc:=gui.UI_Screen{asset=asset_id,entity=core.Entity(holder),input=input,order=order,back=back}
        asset.builder_set(s,e,sc)
        if hidden {asset.builder_set(s,e,render.Hidden{})}
    }
    screen(&s,game.INTERFACE_HUD,hud,holder,.Passive,0,false,false)
    screen(&s,game.INTERFACE_INVENTORY,inventory,holder,.Menu,10,true,true)
    screen(&s,game.INTERFACE_DIALOGUE,dialogue,holder,.Menu,15,true,true)
    screen(&s,game.INTERFACE_MENU,menu,holder,.Modal,20,true,true)
    asset.builder_save(&s,path(o,"assets/scenes/interface.scene"))
}
