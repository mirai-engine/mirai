package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import game "mirai:demo/game"
import "mirai:engine/gui"
import "mirai:host"
import render "mirai:engine/render"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// The scene of the game interfaces (game/interface_demo.odin): a HUD with
// three styles, a menu of options, an inventory to drag items in, a
// conversation and a name tag over a pillar, and the button the menu uses
// twice, from a file of its own. The items and the conversation are tables of
// game data in assets/data.

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

// A button made once and used by other interfaces: a box that holds it, so
// an instance names it as "<instance>/button".
@(private)
button_widget :: proc(texts:^[dynamic]u8) -> ui.Tree_Data {
    styles:=make([]ui.Node_Style,2,context.temp_allocator)
    styles[1]={text={size=16,color=WHITE,font=ui.FONT_SEMIBOLD},fill={44,56,84,255},stroke={96,118,160,255},stroke_width=1,radius=8}
    variants:=make([]ui.Tree_Style_Variant,2,context.temp_allocator)
    variants[0],variants[1]=state_fill(1,.Hovered,{70,90,132,255}),state_fill(1,.Pressed,{120,160,255,255})
    nodes:=make([]ui.Tree_Node,2,context.temp_allocator)
    nodes[0]=ui.tree_node_record(texts,-1,{kind=.Box,name="frame"})
    nodes[1]=ui.tree_node_record(texts,0,{kind=.Button,name="button",text="Button",style=1,flags={.Localized},layout={width=ui.fixed(180),height=ui.fixed(40)}})
    return {nodes=nodes,styles=styles,variants=variants}
}

// The rule that fills a style with a color in a state.
@(private)
state_fill :: proc(style:u16,state:ui.Style_State,fill:ui.Color) -> ui.Tree_Style_Variant {
    return ui.tree_variant_record(style,"",{state},{fields={.Fill},values={fill=fill}})
}

@(private)
write_button :: proc(o:^Out) -> (base.Asset_Id,ui.Tree_Data) {
    id:=asset.content_id(PROJECT,"ui","interface_button")
    texts:=make([dynamic]u8,context.temp_allocator)
    data:=interface_localized(button_widget(&texts),&texts)
    asset.content_check(&o.content,"assets/ui/interface/button.ui",host.ui_tree_save(path(o,"assets/ui/interface/button.ui"),&o.content.types,id,data))
    return id,data
}

// The texts of the interfaces in English and Spanish, by the key the nodes
// below name: interface_localized writes the English as the text of the node
// and the Spanish as its translation.
INTERFACE_TEXTS :: `key,en,es
hud.coins,Coins {coins},Monedas {coins}
hud.style,Style,Estilo
hud.menu,Menu,Menú
hud.inventory,Inventory,Inventario
hud.talk,Talk,Hablar
menu.title,Options,Opciones
menu.volume,Volume,Volumen
menu.volume_tip,How loud the game sounds,Qué tan fuerte suena el juego
menu.quality,Quality,Calidad
quality.low,Low,Baja
quality.medium,Medium,Media
quality.high,High,Alta
quality.ultra,Ultra,Ultra
menu.style,HUD style,Estilo del HUD
style.classic,Classic,Clásico
style.minimal,Minimal,Mínimo
style.neon,Neon,Neón
menu.subtitles,Subtitles,Subtítulos
menu.name,Name,Nombre
menu.language,Language,Idioma
menu.resume,Resume,Continuar
menu.inventory,Inventory,Inventario
inventory.title,Inventory,Inventario
inventory.hand,In hand: <b>{item}</b>,En la mano: <b>{item}</b>
inventory.close,Close,Cerrar
dialogue.next,Continue,Continuar
`
// The records with the keys of INTERFACE_TEXTS made texts: a localized node
// (or an override of one) that names keys shows the English, under an id of
// its keys, with the Spanish as its translation.
@(private)
interface_localized :: proc(data:ui.Tree_Data,texts:^[dynamic]u8) -> ui.Tree_Data {
    data:=data
    rows:=strings.split_lines(strings.trim_space(INTERFACE_TEXTS),context.temp_allocator)[1:]
    translations:=make([dynamic]ui.Tree_Translation,context.temp_allocator)
    localize :: proc(n:^ui.Tree_Node,rows:[]string,translations:^[dynamic]ui.Tree_Translation,texts:^[dynamic]u8) {
        text:=strings.clone(ui.tree_string(texts[:],n.text),context.temp_allocator)
        if text=="" {return}
        en,es:=strings.builder_make(context.temp_allocator),strings.builder_make(context.temp_allocator)
        found:=false
        for key,i in strings.split(text,"|",context.temp_allocator) {
            english,spanish:=key,key
            for row in rows {
                columns:=strings.split(row,",",context.temp_allocator)
                if len(columns)==3 && columns[0]==key {english,spanish,found=columns[1],columns[2],true;break}
            }
            if i>0 {strings.write_byte(&en,'|');strings.write_byte(&es,'|')}
            strings.write_string(&en,english);strings.write_string(&es,spanish)
        }
        if !found {return}
        n.text_id=base.name_hash(text)
        n.text=ui.tree_string_add(texts,strings.to_string(en))
        t:=ui.Tree_Translation{id=n.text_id,text=ui.tree_string_add(texts,strings.to_string(es))}
        ui.tree_text_set(t.language[:],"es")
        append(translations,t)
    }
    for &n in data.nodes {if .Localized in n.flags {localize(&n,rows,&translations,texts)}}
    for &o in data.overrides {if .Text in o.fields {localize(&o.values,rows,&translations,texts)}}
    data.translations,data.text=translations[:],texts[:]
    return data
}

// The HUD: the name, life and coins of the player, the time, a ring that
// fills while an ability recovers and the keys of the scene. Its variants
// minimal and neon restyle the same nodes.
@(private)
write_interface_hud :: proc(o:^Out) -> base.Asset_Id {
    texts:=make([dynamic]u8,context.temp_allocator)
    id:=asset.content_id(PROJECT,"ui","interface_hud")
    styles:=[]ui.Node_Style{
        {},
        {fill={16,22,34,220},stroke={96,118,160,255},stroke_width=1,radius=12,shadow=true,shadow_color={0,0,0,120},shadow_blur=12,shadow_offset={0,4}},
        {text={size=22,color=WHITE,font=ui.FONT_SEMIBOLD}},
        {fill={235,72,72,255},track={44,48,62,255},radius=6},
        {text={size=15,color={205,214,232,255}}},
        {fill={255,190,60,255},track={44,48,62,220},stroke_width=6,fill_mode=.Radial},
        {text={size=14,color={170,182,206,255}}},
    }
    variants:=[]ui.Tree_Style_Variant{
        ui.tree_variant_record(1,"minimal",{},{fields={.Fill,.Stroke,.Shadow},values={}}),
        ui.tree_variant_record(2,"minimal",{},{fields={.Text_Font,.Text_Size,.Text_Color,.Text_Shadow},values={text={size=18,color={240,240,240,255},font=ui.FONT_MEDIUM,shadow={1,1},shadow_color={0,0,0,200}}}}),
        ui.tree_variant_record(3,"minimal",{},{fields={.Fill,.Track,.Radius},values={fill={250,250,250,255},track={255,255,255,60},radius=0}}),
        ui.tree_variant_record(4,"minimal",{},{fields={.Text_Size,.Text_Color,.Text_Shadow},values={text={size=15,color={240,240,240,255},shadow={1,1},shadow_color={0,0,0,200}}}}),
        ui.tree_variant_record(6,"minimal",{},{fields={.Text_Size,.Text_Color,.Text_Shadow},values={text={size=14,color={240,240,240,255},shadow={1,1},shadow_color={0,0,0,200}}}}),
        ui.tree_variant_record(1,"neon",{},{fields={.Fill,.Stroke,.Stroke_Width,.Radius},values={fill={12,0,28,235},stroke={0,255,220,255},stroke_width=2,radius=2}}),
        ui.tree_variant_record(2,"neon",{},{fields={.Text_Font,.Text_Size,.Text_Color},values={text={size=22,color={0,255,220,255},font=ui.FONT_SEMIBOLD}}}),
        ui.tree_variant_record(3,"neon",{},{fields={.Fill,.Track,.Radius},values={fill={255,0,200,255},track={48,0,70,255},radius=1}}),
        ui.tree_variant_record(4,"neon",{},{fields={.Text_Size,.Text_Color},values={text={size=15,color={255,130,255,255}}}}),
        ui.tree_variant_record(5,"neon",{},{fields={.Fill},values={fill={0,255,220,255}}}),
    }
    nodes:=[]ui.Tree_Node{
        ui.tree_node_record(&texts,-1,{kind=.Box,name="hud",style=1,float={to=.Safe,anchor=.Top_Left,pivot=.Top_Left,offset={24,24}},
            layout={width=ui.fixed(380),direction=.Column,padding=ui.padding_all(16),gap=10}}),
        ui.tree_node_record(&texts,0,{kind=.Text,name="name",style=2,bind_text="Interface_Demo.player"}),
        ui.tree_node_record(&texts,0,{kind=.Box,name="life",layout={gap=10,align_y=.Center}}),
        ui.tree_node_record(&texts,2,{kind=.Progress,name="health",style=3,bind_value="Interface_Demo.life",layout={width=ui.fixed(240),height=ui.fixed(12)}}),
        ui.tree_node_record(&texts,2,{kind=.Text,name="health_text",style=4,text="{health:0}/{most:0}",fields={{"health","Interface_Demo.health"},{"most","Interface_Demo.most"},{},{}}}),
        ui.tree_node_record(&texts,0,{kind=.Box,name="stats",layout={gap=18,align_y=.Center}}),
        ui.tree_node_record(&texts,5,{kind=.Text,name="coins",style=4,text="hud.coins",fields={{"coins","Interface_Demo.coins"},{},{},{}},flags={.Localized}}),
        ui.tree_node_record(&texts,5,{kind=.Text,name="time",style=4,text="{time:mm:ss}",fields={{"time","Interface_Demo.seconds"},{},{},{}}}),
        ui.tree_node_record(&texts,5,{kind=.Progress,name="cooldown",style=5,bind_value="Interface_Demo.cooldown",layout={width=ui.fixed(28),height=ui.fixed(28)}}),
        ui.tree_node_record(&texts,0,{kind=.Box,name="keys",layout={gap=8,align_y=.Center}}),
        ui.tree_node_record(&texts,9,{kind=.Prompt,name="style_key",action="hud_style",style=6,layout={height=ui.fixed(26)}}),
        ui.tree_node_record(&texts,9,{kind=.Text,name="style_label",style=6,text="hud.style",flags={.Localized}}),
        ui.tree_node_record(&texts,9,{kind=.Prompt,name="menu_key",action="menu",style=6,layout={height=ui.fixed(26)}}),
        ui.tree_node_record(&texts,9,{kind=.Text,name="menu_label",style=6,text="hud.menu",flags={.Localized}}),
        ui.tree_node_record(&texts,9,{kind=.Prompt,name="inventory_key",action="inventory",style=6,layout={height=ui.fixed(26)}}),
        ui.tree_node_record(&texts,9,{kind=.Text,name="inventory_label",style=6,text="hud.inventory",flags={.Localized}}),
        ui.tree_node_record(&texts,9,{kind=.Prompt,name="talk_key",action="talk",style=6,layout={height=ui.fixed(26)}}),
        ui.tree_node_record(&texts,9,{kind=.Text,name="talk_label",style=6,text="hud.talk",flags={.Localized}}),
    }
    data:=interface_localized({nodes=nodes,styles=styles,variants=variants},&texts)
    asset.content_check(&o.content,"assets/ui/interface/hud.ui",host.ui_tree_save(path(o,"assets/ui/interface/hud.ui"),&o.content.types,id,data))
    return id
}

// The menu of options, over the HUD: its controls write the component, a
// tooltip tells what the volume is, and its buttons are the button of
// another file, twice.
@(private)
write_interface_menu :: proc(o:^Out,button:base.Asset_Id,button_data:ui.Tree_Data) -> base.Asset_Id {
    texts:=make([dynamic]u8,context.temp_allocator)
    id:=asset.content_id(PROJECT,"ui","interface_menu")
    control:=ui.Node_Style{text={size=15,color=WHITE},fill={30,36,52,255},stroke={90,110,150,255},mark={120,160,255,255},track={52,58,76,255},knob={235,240,250,255},radius=6,stroke_width=1}
    styles:=[]ui.Node_Style{
        {},
        {fill={14,18,28,242},stroke={80,100,140,255},stroke_width=1,radius=14,shadow=true,shadow_color={0,0,0,160},shadow_blur=24,shadow_offset={0,8}},
        {text={size=26,color=WHITE,font=ui.FONT_SEMIBOLD}},
        {text={size=15,color={200,210,230,255},align_y=.Center}},
        control,
        {fill={0,0,0,235},radius=6,text={size=13,color=WHITE}},
        {text={size=13,color=WHITE}},
    }
    components:=[]ui.Tree_Component{{widget=button}}
    ui.tree_text_set(components[0].name[:],"button")
    variants:=[]ui.Tree_Style_Variant{ui.tree_variant_record(4,"",{.Hovered},{fields={.Stroke},values={stroke={140,165,215,255}}})}
    label :: proc(texts:^[dynamic]u8,parent:i32,text:string) -> ui.Tree_Node {return ui.tree_node_record(texts,parent,{kind=.Text,style=3,text=text,flags={.Localized},layout={width=ui.fixed(130),height=ui.fixed(28)}})}
    row :: proc(texts:^[dynamic]u8,name:string) -> ui.Tree_Node {return ui.tree_node_record(texts,0,{kind=.Box,name=name,layout={gap=12,align_y=.Center}})}
    nodes:=make([dynamic]ui.Tree_Node,context.temp_allocator)
    append(&nodes,ui.tree_node_record(&texts,-1,{kind=.Box,name="menu",style=1,flags={.Wrap_Y},float={to=.Surface,anchor=.Center,pivot=.Center},
        layout={width=ui.fixed(480),direction=.Column,padding=ui.padding_all(24),gap=14}}))
    append(&nodes,ui.tree_node_record(&texts,0,{kind=.Text,name="title",style=2,text="menu.title",flags={.Localized}}))
    volume:=i32(len(nodes));append(&nodes,row(&texts,"volume_row"))
    append(&nodes,label(&texts,volume,"menu.volume"))
    append(&nodes,ui.tree_node_record(&texts,volume,{kind=.Slider,name="volume",style=4,bind_value="Audio_Volumes.master",range={0,1,0.05},flags={.Focus_First},layout={width=ui.fixed(240),height=ui.fixed(22)}}))
    tip:=i32(len(nodes));append(&nodes,ui.tree_node_record(&texts,volume,{kind=.Tooltip,name="volume_tip",style=5,layout={padding=ui.padding_all(8)}}))
    append(&nodes,ui.tree_node_record(&texts,tip,{kind=.Text,style=6,text="menu.volume_tip",flags={.Localized}}))
    quality:=i32(len(nodes));append(&nodes,row(&texts,"quality_row"))
    append(&nodes,label(&texts,quality,"menu.quality"))
    append(&nodes,ui.tree_node_record(&texts,quality,{kind=.Selector,name="quality",style=4,bind_value="Interface_Demo.quality",text="quality.low|quality.medium|quality.high|quality.ultra",flags={.Localized},layout={width=ui.fixed(240),height=ui.fixed(32)}}))
    style_row:=i32(len(nodes));append(&nodes,row(&texts,"style_row"))
    append(&nodes,label(&texts,style_row,"menu.style"))
    for name,value in ([3]string{"classic","minimal","neon"}) {
        append(&nodes,ui.tree_node_record(&texts,style_row,{kind=.Radio,name=name,style=4,bind_value="Interface_Demo.style",choice=u16(value),layout={height=ui.fixed(18)}}))
        keys:=[3]string{"style.classic","style.minimal","style.neon"}
        append(&nodes,ui.tree_node_record(&texts,style_row,{kind=.Text,style=3,text=keys[value],flags={.Localized}}))
    }
    subtitles:=i32(len(nodes));append(&nodes,row(&texts,"subtitles_row"))
    append(&nodes,label(&texts,subtitles,"menu.subtitles"))
    append(&nodes,ui.tree_node_record(&texts,subtitles,{kind=.Checkbox,name="subtitles",style=4,bind_value="Interface_Demo.subtitles"}))
    name_row:=i32(len(nodes));append(&nodes,row(&texts,"name_row"))
    append(&nodes,label(&texts,name_row,"menu.name"))
    append(&nodes,ui.tree_node_record(&texts,name_row,{kind=.Field,name="name",style=4,bind_text="Interface_Demo.player",layout={width=ui.fixed(240),height=ui.fixed(30)}}))
    language:=i32(len(nodes));append(&nodes,row(&texts,"language_row"))
    append(&nodes,label(&texts,language,"menu.language"))
    append(&nodes,ui.tree_node_record(&texts,language,{kind=.Dropdown,name="language",style=4,bind_value="Interface_Demo.language",text="English|Español",layout={width=ui.fixed(240),height=ui.fixed(30)}}))
    buttons:=i32(len(nodes));append(&nodes,ui.tree_node_record(&texts,0,{kind=.Box,name="buttons",layout={gap=12}}))
    resume:=u32(len(nodes));append(&nodes,ui.tree_node_record(&texts,buttons,{kind=.Component,name="resume",component=1}))
    inventory:=u32(len(nodes));append(&nodes,ui.tree_node_record(&texts,buttons,{kind=.Component,name="inventory",component=1}))
    append(&nodes,ui.tree_node_record(&texts,0,{kind=.Action_Bar,name="actions",style=3}))
    overrides:=[]ui.Tree_Override{
        ui.tree_override_record(&texts,resume,"button",{.Text,.Action},{text="menu.resume",action="menu"}),
        ui.tree_override_record(&texts,inventory,"button",{.Text,.Action},{text="menu.inventory",action="inventory"}),
    }
    data:=interface_localized({nodes=nodes[:],styles=styles,variants=variants,components=components,overrides=overrides},&texts)
    imports:=[]ui.Tree_Data{button_data}
    asset.content_check(&o.content,"assets/ui/interface/menu.ui",host.ui_tree_save(path(o,"assets/ui/interface/menu.ui"),&o.content.types,id,data,imports))
    return id
}

// The inventory: a grid of slots, one per item of the component, that the
// pointer drags onto another slot or into the hand; each shows what it is in
// a tooltip.
@(private)
write_interface_inventory :: proc(o:^Out) -> base.Asset_Id {
    texts:=make([dynamic]u8,context.temp_allocator)
    id:=asset.content_id(PROJECT,"ui","interface_inventory")
    slot:=ui.Node_Style{fill={28,34,48,255},stroke={70,84,110,255},stroke_width=1,radius=8}
    styles:=[]ui.Node_Style{
        {},
        {fill={14,18,28,242},stroke={80,100,140,255},stroke_width=1,radius=14},
        {text={size=22,color=WHITE,font=ui.FONT_SEMIBOLD}},
        slot,
        {text={size=12,color=WHITE,align_x=.End,shadow={1,1},shadow_color={0,0,0,220}}},
        {fill={0,0,0,235},radius=6,text={size=13,color=WHITE}},
        {text={size=15,color={200,210,230,255}}},
        {fill={255,255,255,255}},
        {text={size=14,color=WHITE},fill={44,56,84,255},radius=8},
    }
    variants:=[]ui.Tree_Style_Variant{
        ui.tree_variant_record(3,"rare",{},{fields={.Stroke,.Stroke_Width},values={stroke={80,160,255,255},stroke_width=2}}),
        ui.tree_variant_record(3,"epic",{},{fields={.Stroke,.Stroke_Width},values={stroke={200,90,255,255},stroke_width=2}}),
        ui.tree_variant_record(3,"",{.Hovered},{fields={.Fill},values={fill={46,56,78,255}}}),
        state_fill(8,.Hovered,{70,90,132,255}),
        state_fill(8,.Pressed,{120,160,255,255}),
    }
    nodes:=[]ui.Tree_Node{
        ui.tree_node_record(&texts,-1,{kind=.Box,name="inventory",style=1,float={to=.Safe,anchor=.Center_Right,pivot=.Center_Right,offset={-32,0}},
            layout={width=ui.fixed(340),direction=.Column,padding=ui.padding_all(18),gap=12}}),
        ui.tree_node_record(&texts,0,{kind=.Text,name="title",style=2,text="inventory.title",flags={.Localized}}),
        ui.tree_node_record(&texts,0,{kind=.Box,name="hand_row",layout={gap=12,align_y=.Center}}),
        ui.tree_node_record(&texts,2,{kind=.Box,name="hand",style=3,flags={.Drop},layout={width=ui.fixed(64),height=ui.fixed(64),align_x=.Center,align_y=.Center}}),
        ui.tree_node_record(&texts,3,{kind=.Image,name="hand_icon",style=7,bind_image="Interface_Demo.equipped.icon",layout={width=ui.fixed(44),height=ui.fixed(44)}}),
        ui.tree_node_record(&texts,2,{kind=.Rich_Text,name="hand_text",style=6,text="inventory.hand",fields={{"item","Interface_Demo.equipped.name"},{},{},{}},flags={.Localized},layout={width=ui.fixed(220)}}),
        ui.tree_node_record(&texts,0,{kind=.List,name="slots",bind_items="Interface_Demo.items",bind_value="Interface_Demo.item_count",clip=true,flags={.Wrap_X},
            layout={width=ui.GROW,height=ui.fixed(220),direction=.Grid,columns=4,gap=8}}),
        ui.tree_node_record(&texts,6,{kind=.Box,name="slot",style=3,flags={.Draggable,.Drop},bind_variant="rarity",layout={width=ui.fixed(68),height=ui.fixed(68),align_x=.Center,align_y=.Center}}),
        ui.tree_node_record(&texts,7,{kind=.Image,name="icon",style=7,bind_image="icon",layout={width=ui.fixed(44),height=ui.fixed(44)}}),
        ui.tree_node_record(&texts,7,{kind=.Text,name="count",style=4,text="x{count}",fields={{"count","count"},{},{},{}},float={to=.Parent,anchor=.Bottom_Right,pivot=.Bottom_Right,offset={-5,-3}}}),
        ui.tree_node_record(&texts,7,{kind=.Tooltip,name="tip",style=5,layout={padding=ui.padding_all(8),direction=.Column}}),
        ui.tree_node_record(&texts,10,{kind=.Rich_Text,name="about",style=5,text="<b>{name}</b> <color=#8fc8ff>{rarity}</color>",fields={{"name","name"},{"rarity","rarity"},{},{}},layout={width=ui.fixed(180)}}),
        ui.tree_node_record(&texts,0,{kind=.Box,name="footer",layout={gap=12,align_y=.Center}}),
        ui.tree_node_record(&texts,12,{kind=.Button,name="close",style=8,text="inventory.close",flags={.Localized},action="inventory",layout={width=ui.fixed(110),height=ui.fixed(34)}}),
        ui.tree_node_record(&texts,12,{kind=.Action_Bar,name="actions",style=6}),
    }
    data:=interface_localized({nodes=nodes,styles=styles,variants=variants},&texts)
    asset.content_check(&o.content,"assets/ui/interface/inventory.ui",host.ui_tree_save(path(o,"assets/ui/interface/inventory.ui"),&o.content.types,id,data))
    return id
}

// The name of the player on a panel over a pillar that always faces the camera.
@(private)
write_interface_tag :: proc(o:^Out) -> base.Asset_Id {
    texts:=make([dynamic]u8,context.temp_allocator)
    id:=asset.content_id(PROJECT,"ui","interface_tag")
    styles:=[]ui.Node_Style{{},{fill={14,18,28,220},radius=10},{text={size=28,color=WHITE,font=ui.FONT_SEMIBOLD,align_x=.Center}},{fill={235,72,72,255},track={44,48,62,255},radius=4}}
    nodes:=[]ui.Tree_Node{
        ui.tree_node_record(&texts,-1,{kind=.Box,name="tag",style=1,layout={width=ui.GROW,height=ui.GROW,direction=.Column,padding=ui.padding_all(12),gap=8,align_x=.Center}}),
        ui.tree_node_record(&texts,0,{kind=.Text,name="name",style=2,bind_text="Interface_Demo.player"}),
        ui.tree_node_record(&texts,0,{kind=.Progress,name="health",style=3,bind_value="Interface_Demo.life",layout={width=ui.fixed(200),height=ui.fixed(10)}}),
    }
    asset.content_check(&o.content,"assets/ui/interface/tag.ui",host.ui_tree_save(path(o,"assets/ui/interface/tag.ui"),&o.content.types,id,{nodes=nodes,styles=styles,text=texts[:]}))
    return id
}

// The conversation: who speaks, what, and the answers the player can give,
// or Continue for a line without them.
@(private)
write_interface_dialogue :: proc(o:^Out) -> base.Asset_Id {
    texts:=make([dynamic]u8,context.temp_allocator)
    id:=asset.content_id(PROJECT,"ui","interface_dialogue")
    styles:=[]ui.Node_Style{
        {},
        {fill={14,18,28,242},stroke={80,100,140,255},stroke_width=1,radius=14},
        {text={size=18,color={255,200,90,255},font=ui.FONT_SEMIBOLD}},
        {text={size=17,color=WHITE}},
        {text={size=15,color=WHITE},fill={44,56,84,255},radius=8},
        {text={size=15,color={200,210,230,255}}},
    }
    variants:=[]ui.Tree_Style_Variant{
        state_fill(4,.Hovered,{70,90,132,255}),
        state_fill(4,.Pressed,{120,160,255,255}),
    }
    nodes:=[]ui.Tree_Node{
        ui.tree_node_record(&texts,-1,{kind=.Box,name="dialogue",style=1,float={to=.Safe,anchor=.Bottom_Center,pivot=.Bottom_Center,offset={0,-32}},
            layout={width=ui.fixed(640),direction=.Column,padding=ui.padding_all(18),gap=10}}),
        ui.tree_node_record(&texts,0,{kind=.Text,name="speaker",style=2,bind_text="Interface_Demo.speaker"}),
        ui.tree_node_record(&texts,0,{kind=.Text,name="said",style=3,bind_text="Interface_Demo.said",layout={width=ui.GROW}}),
        ui.tree_node_record(&texts,0,{kind=.List,name="choices",bind_items="Interface_Demo.choices",bind_value="Interface_Demo.choice_count",
            layout={width=ui.GROW,direction=.Column,gap=6}}),
        ui.tree_node_record(&texts,3,{kind=.Button,name="choice",style=4,bind_text="text",layout={width=ui.GROW,height=ui.fixed(34)}}),
        ui.tree_node_record(&texts,0,{kind=.Box,name="footer",layout={gap=12,align_y=.Center}}),
        ui.tree_node_record(&texts,5,{kind=.Button,name="next",style=4,text="dialogue.next",flags={.Localized},bind_visible="Interface_Demo.goes_on",layout={width=ui.fixed(140),height=ui.fixed(34)}}),
        ui.tree_node_record(&texts,5,{kind=.Action_Bar,name="actions",style=5}),
    }
    data:=interface_localized({nodes=nodes,styles=styles,variants=variants},&texts)
    asset.content_check(&o.content,"assets/ui/interface/dialogue.ui",host.ui_tree_save(path(o,"assets/ui/interface/dialogue.ui"),&o.content.types,id,data))
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
    button,button_data:=write_button(o)
    hud,menu,inventory,tag:=write_interface_hud(o),write_interface_menu(o,button,button_data),write_interface_inventory(o),write_interface_tag(o)
    dialogue:=write_interface_dialogue(o)
    write_interface_records(o,icons)
    if o.content.failed {return}

    s:asset.Scene_Builder
    asset.builder_init(&s,&o.content,asset.KIND_SCENE,asset.content_id(PROJECT,"scene","interface"))
    defer asset.builder_destroy(&s)
    environment,turn,to_sun,disc:=sky_of(o,.Day,render.SUN_DIRECTION,LAMPLIT,1.5)
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
