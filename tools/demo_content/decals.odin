package main

import "core:fmt"
import "core:math"
import "mirai:asset"

// The images of the decals of decals/decals.scene.

DECAL_SIZE :: 512

// An image of DECAL_SIZE made from the coverage and the color `shade` gives each texel, between -1 and 1.
@(private)
write_decal_image :: proc(o:^Out,name:string,shade:proc(x,y:f32) -> [4]f32) {
    id:=asset.content_id(PROJECT,"texture",name)
    pixels:=make([]u8,DECAL_SIZE*DECAL_SIZE*4,context.temp_allocator)
    for y in 0..<DECAL_SIZE {
        for x in 0..<DECAL_SIZE {
            // The samples of a texel reach into its neighbors: the edges of the shapes stay smooth when the image is magnified.
            sum:[4]f32
            for sample in 0..<16 {
                sx:=(f32(x)-0.25+0.5*f32(sample&3))/DECAL_SIZE*2-1
                sy:=(f32(y)-0.25+0.5*f32(sample>>2))/DECAL_SIZE*2-1
                c:=shade(sx,sy)
                sum+={c.r*c.a,c.g*c.a,c.b*c.a,c.a}
            }
            at:=(y*DECAL_SIZE+x)*4
            alpha:=sum.a/16
            color:=alpha>1e-4?sum.rgb/sum.a:[3]f32{1,1,1}
            pixels[at],pixels[at+1],pixels[at+2]=u8(clamp(color.r,0,1)*255+0.5),u8(clamp(color.g,0,1)*255+0.5),u8(clamp(color.b,0,1)*255+0.5)
            pixels[at+3]=u8(clamp(alpha,0,1)*255+0.5)
        }
    }
    file:=fmt.tprintf("assets/decals/%s.tex",name)
    asset.content_check(&o.content,file,asset.texture_save(path(o,file),&o.content.types,{id=id,width=DECAL_SIZE,height=DECAL_SIZE,format=.RGBA8,flags={.Srgb},mips={pixels}}))
}

@(private)
hash01 :: proc "contextless" (x,y:i32) -> f32 {
    h:=u32(x)*374761393+u32(y)*668265263
    h=(h~(h>>13))*1274126177
    return f32((h~(h>>16))&0xffff)/65535
}

// Smooth noise between 0 and 1.
@(private)
noise01 :: proc "contextless" (x,y:f32) -> f32 {
    ix,iy:=i32(math.floor(x)),i32(math.floor(y))
    fx,fy:=x-f32(ix),y-f32(iy)
    fx,fy=fx*fx*(3-2*fx),fy*fy*(3-2*fy)
    a,b:=hash01(ix,iy)*(1-fx)+hash01(ix+1,iy)*fx,hash01(ix,iy+1)*(1-fx)+hash01(ix+1,iy+1)*fx
    return a*(1-fy)+b*fy
}

write_decal_images :: proc(o:^Out) {
    // An arrow that points up the image.
    write_decal_image(o,"decal_arrow",proc(x,y:f32) -> [4]f32 {
        head:=y<-0.1 && abs(x)<(y+0.9)*0.75
        shaft:=y>=-0.1 && y<0.85 && abs(x)<0.22
        return {1,1,1,head || shaft?1:0}
    })
    // Two rings and the marks of a dial between them.
    write_decal_image(o,"decal_ring",proc(x,y:f32) -> [4]f32 {
        r:=math.sqrt(x*x+y*y)
        angle:=math.atan2(y,x)
        ring:=abs(r-0.86)<0.035 || abs(r-0.6)<0.02
        marks:=r>0.64 && r<0.82 && abs(math.mod(angle+math.PI,math.PI/6)-math.PI/12)<0.035/max(r,0.1)
        core:=r<0.18 || (r<0.5 && (abs(x)<0.03 || abs(y)<0.03))
        return {1,1,1,ring || marks || core?1:0}
    })
    // A stain with an uneven edge and drops around it.
    write_decal_image(o,"decal_splat",proc(x,y:f32) -> [4]f32 {
        r:=math.sqrt(x*x+y*y)
        angle:=math.atan2(y,x)
        edge:=0.5+0.22*noise01(angle*2.2+7,1.5)+0.1*noise01(angle*7+3,9.5)
        drops:=noise01(x*9+20,y*9+40)>0.83 && r<0.95
        shade:=0.75+0.25*noise01(x*6,y*6)
        return {shade,shade,shade,r<edge || drops?1:0}
    })
    // Warning stripes, with the paint worn in places.
    write_decal_image(o,"decal_stripes",proc(x,y:f32) -> [4]f32 {
        band:=math.mod(x+y+4,0.5)<0.25
        worn:=noise01(x*14+5,y*14+11)*0.6+noise01(x*40,y*40)*0.4
        color:=band?[3]f32{1,0.78,0.05}:[3]f32{0.03,0.03,0.03}
        return {color.r,color.g,color.b,abs(x)<0.97 && abs(y)<0.97 && worn>0.22?1:0}
    })
}
