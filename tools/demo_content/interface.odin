package main

import "core:fmt"
import "core:math"
import "mirai:asset"

// The icons of the inventory the interfaces of the interface scene
// (game/interface_demo.odin) show; the items of its table name them by their ids.

ICON_SIZE :: 64

Icon_Shape :: enum u8 {Sword,Potion,Shield,Gem,Coin}

// An item of the inventory drawn on the CPU: a shape of a color with a rim,
// transparent around it.
@(private)
write_item_icon :: proc(o:^Out,shape:Icon_Shape,color:[3]f32) {
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
    file:=fmt.tprintf("assets/interface/item_%s.tex",names[shape])
    asset.content_check(&o.content,file,asset.texture_save(path(o,file),&o.content.types,{id=id,width=ICON_SIZE,height=ICON_SIZE,format=.RGBA8,flags={.Srgb},mips={pixels}}))
}

write_interface_icons :: proc(o:^Out) {
    write_item_icon(o,.Sword,{0.75,0.8,0.86})
    write_item_icon(o,.Potion,{0.9,0.2,0.25})
    write_item_icon(o,.Shield,{0.25,0.45,0.9})
    write_item_icon(o,.Gem,{0.7,0.3,0.95})
    write_item_icon(o,.Coin,{0.98,0.78,0.2})
}
