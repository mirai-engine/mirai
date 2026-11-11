package kit

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"
import "core:testing"
import "mirai:ui"
import stbi "vendor:stb/image"

// Shared by the tests of the package.

TEST_SMALL :: ui.Context_Desc{max_elements=1024,max_vertices=65536,max_widgets=512,max_text=16384,no_font=true}
TEST_FONT :: ui.Context_Desc{max_elements=1024,max_vertices=65536,max_widgets=512,max_text=16384}

Test_Build :: #type proc(ctx:^ui.Context,user:rawptr)

test_input :: proc(width:f32=800,height:f32=600) -> ui.Input {
    return {size={width,height},dt=1.0/60,pointer={-100,-100}}
}
// One frame: the input as it is, then its edges are forgotten.
test_frame :: proc(ctx:^ui.Context,input:^ui.Input,build:Test_Build,user:rawptr=nil) -> ui.Frame {
    ui.frame_begin(ctx,input^)
    if build!=nil {build(ctx,user)}
    frame:=ui.frame_end(ctx)
    ui.input_next_frame(input)
    return frame
}
test_rect :: proc(t:^testing.T,ctx:^ui.Context,id:ui.Id,loc:=#caller_location) -> ui.Rect {
    rect,found:=ui.widget_rect(ctx,id)
    testing.expectf(t,found,"element %v was laid out",id,loc=loc)
    return rect
}
test_near :: proc(a,b:f32,tolerance:f32=0.01) -> bool {return abs(a-b)<=tolerance}
test_rect_near :: proc(a,b:ui.Rect,tolerance:f32=0.01) -> bool {
    return test_near(a.x,b.x,tolerance)&&test_near(a.y,b.y,tolerance)&&test_near(a.w,b.w,tolerance)&&test_near(a.h,b.h,tolerance)
}
// Whether got is want with its edges rounded to device pixels at density 1:
// each moves at most half a pixel.
test_rect_snapped :: proc(got,want:ui.Rect) -> bool {
    return test_near(got.x,want.x,0.5) && test_near(got.y,want.y,0.5) && test_near(got.x+got.w,want.x+want.w,0.5) && test_near(got.y+got.h,want.y+want.h,0.5)
}
// Moves the pointer onto a rectangle and presses or releases the left button.
test_point :: proc(input:^ui.Input,rect:ui.Rect) {input.pointer={rect.x+rect.w*0.5,rect.y+rect.h*0.5}}
test_press :: proc(input:^ui.Input,clicks:u8=1) {ui.input_button(input,.Left,true,clicks)}
test_release :: proc(input:^ui.Input) {ui.input_button(input,.Left,false)}
test_key :: proc(input:^ui.Input,key:ui.Key) {
    input.keys_pressed+={key};input.keys_repeated+={key}
}
test_type :: proc(input:^ui.Input,text:string) {for c in text {ui.input_text(input,c)}}

// Counts every request an allocator gets.
Test_Counter :: struct {backing:runtime.Allocator,requests:int}
test_counter_proc :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,location:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    counter:=cast(^Test_Counter)data
    #partial switch mode {
    case .Alloc,.Alloc_Non_Zeroed,.Resize,.Resize_Non_Zeroed:counter.requests+=1
    }
    return counter.backing.procedure(counter.backing.data,mode,size,alignment,old_memory,old_size,location)
}
test_counter :: proc(counter:^Test_Counter,backing:runtime.Allocator) -> runtime.Allocator {
    counter^={backing=backing}
    return {procedure=test_counter_proc,data=counter}
}


// A software rasterizer for the draw lists of the screen surface, used by
// tests alone: it shows what a frame looks like without a GPU. Pixels are
// sampled at their centers with the top-left rule. Isolated buffers contain
// premultiplied display colors, quantized like the RGBA8 GPU targets.

Test_Image :: struct {width,height:int,pixels:[][4]u8}

// -define:UI_DUMP_DIR=<directory> writes the images of the look tests there as PNG.
UI_DUMP_DIR :: #config(UI_DUMP_DIR,"")

test_image_destroy :: proc(image:^Test_Image) {delete(image.pixels);image^={}}
test_pixel :: proc(image:^Test_Image,x,y:int) -> [4]u8 {
    if x<0 || y<0 || x>=image.width || y>=image.height {return {}}
    return image.pixels[y*image.width+x]
}
test_color_near :: proc(a:[4]u8,b:ui.Color,tolerance:int=2) -> bool {
    for i in 0..<3 {if abs(int(a[i])-int(b[i]))>tolerance {return false}}
    return true
}
// c over the opaque color under it.
test_over :: proc(c,under:ui.Color) -> ui.Color {
    a:=f32(c[3])/255
    return {u8(f32(c[0])*a+f32(under[0])*(1-a)+0.5),u8(f32(c[1])*a+f32(under[1])*(1-a)+0.5),u8(f32(c[2])*a+f32(under[2])*(1-a)+0.5),255}
}

// glyph_alpha of shaders/ui.frag.slang, with its gamma.
TEXT_GAMMA :: f32(2.2)
test_glyph_alpha :: proc(coverage:f32,color:[3]f32) -> f32 {
    c:=[3]f32{clamp(color.r,0,1),clamp(color.g,0,1),clamp(color.b,0,1)}
    luminance:=math.pow(c.r,TEXT_GAMMA)*0.2126+math.pow(c.g,TEXT_GAMMA)*0.7152+math.pow(c.b,TEXT_GAMMA)*0.0722
    src:=math.pow(luminance,1/TEXT_GAMMA)
    dst:=1-src
    if abs(src-dst)<1.0/256 {return coverage}
    blended:=math.pow(luminance*coverage+math.pow(dst,TEXT_GAMMA)*(1-coverage),1/TEXT_GAMMA)
    return clamp((blended-dst)/(src-dst),0,1)
}

@(private="file")
atlas_sample :: proc(font:^ui.Font,uv:[2]f32) -> f32 {
    if !font.ready {return 1}
    x,y:=uv.x*f32(font.width)-0.5,uv.y*f32(font.height)-0.5
    x0,y0:=int(math.floor(x)),int(math.floor(y))
    fx,fy:=x-f32(x0),y-f32(y0)
    texel :: proc(font:^ui.Font,x,y:int) -> f32 {
        if x<0 || y<0 || x>=font.width || y>=font.height {return 0}
        return f32(font.pixels[y*font.width+x])/255
    }
    top:=texel(font,x0,y0)*(1-fx)+texel(font,x0+1,y0)*fx
    bottom:=texel(font,x0,y0+1)*(1-fx)+texel(font,x0+1,y0+1)*fx
    return top*(1-fy)+bottom*fy
}

@(private="file")
raster_distance :: proc(p:[2]f32,shape:ui.Shape) -> f32 {
    half:=[2]f32{max(shape.bounds.z*0.5,1e-4),max(shape.bounds.w*0.5,1e-4)}
    q:=p-shape.bounds.xy-half
    if shape.params.y>0.5 {
        q/=half
        length:=math.sqrt(q.x*q.x+q.y*q.y)
        d:=q/half
        return length<1e-4 ? -min(half.x,half.y) : (length-1)*length/max(math.sqrt(d.x*d.x+d.y*d.y),1e-4)
    }
    radius:=q.y<0 ? (q.x<0 ? shape.radii.x : shape.radii.y) : (q.x<0 ? shape.radii.w : shape.radii.z)
    radius=clamp(radius,0,min(half.x,half.y))
    d:=[2]f32{abs(q.x)-half.x+radius,abs(q.y)-half.y+radius}
    positive:=[2]f32{max(d.x,0),max(d.y,0)}
    return math.sqrt(positive.x*positive.x+positive.y*positive.y)+min(max(d.x,d.y),0)-radius
}

@(private="file")
raster_erf :: proc(x:f32) -> f32 {
    a:=abs(x)
    t:=1/(1+0.3275911*a)
    polynomial:=(((((1.061405429*t-1.453152027)*t)+1.421413741)*t-0.284496736)*t+0.254829592)*t
    return (x<0 ? -1 : x>0 ? 1 : 0)*(1-polynomial*math.exp(-a*a))
}

@(private="file")
raster_shadow :: proc(p:[2]f32,shape:ui.Shape) -> f32 {
    sigma:=max(shape.params.z,0.5)
    top:=max(shape.bounds.y,p.y-sigma*3)
    bottom:=min(shape.bounds.y+shape.bounds.w,p.y+sigma*3)
    if bottom<=top {return 0}
    step:=(bottom-top)/8
    coverage:f32
    for i in 0..<8 {
        y:=top+(f32(i)+0.5)*step
        left,right:=shape.bounds.x,shape.bounds.x+shape.bounds.z
        radii:=shape.radii
        for &radius in radii {radius=clamp(radius,0,min(shape.bounds.z,shape.bounds.w)*0.5)}
        lr:=y<shape.bounds.y+shape.bounds.w*0.5 ? radii.x : radii.w
        rr:=y<shape.bounds.y+shape.bounds.w*0.5 ? radii.y : radii.z
        edge:=min(y-shape.bounds.y,shape.bounds.y+shape.bounds.w-y)
        ld,rd:=max(lr-edge,0),max(rr-edge,0)
        left+=lr-math.sqrt(max(lr*lr-ld*ld,0))
        right-=rr-math.sqrt(max(rr*rr-rd*rd,0))
        integral:=0.5*(raster_erf((right-p.x)*0.70710678118/sigma)-raster_erf((left-p.x)*0.70710678118/sigma))
        dy:=(y-p.y)/sigma
        coverage+=integral*math.exp(-0.5*dy*dy)*step/(2.50662827463*sigma)
    }
    return clamp(coverage,0,1)
}

@(private="file")
raster_shape :: proc(p,neighbor_x,neighbor_y:[2]f32,shape:ui.Shape) -> [4]f32 {
    if shape.params.y>1.5 {return {shape.fill.r,shape.fill.g,shape.fill.b,shape.fill.a*raster_shadow(p,shape)}}
    distance:=raster_distance(p,shape)
    aa:=max(abs(raster_distance(neighbor_x,shape)-distance)+abs(raster_distance(neighbor_y,shape)-distance),1e-4)
    outer:=clamp(0.5-distance/aa,0,1)
    amount:f32
    if shape.params.w>=0.5 {
        amount=clamp(shape.params.w<1.5 ? (p.y-shape.bounds.y)/max(shape.bounds.w,1e-4) : (p.x-shape.bounds.x)/max(shape.bounds.z,1e-4),0,1)
    }
    fill:=shape.fill*(1-amount)+shape.fill2*amount
    inner:=clamp(0.5-(distance+max(shape.params.x,0))/aa,0,1)
    border:=clamp((outer-inner)/max(outer,1e-6),0,1)*shape.stroke.a
    // As ui_arc_coverage: the sector an arc keeps, from the top clockwise.
    arc:f32=1
    if sweep:=shape.params.z;sweep>0 && sweep<1 {
        d:=p-(shape.bounds.xy+shape.bounds.zw*0.5)
        angle:=math.atan2(d.x,-d.y)
        if angle<0 {angle+=math.TAU}
        arc=clamp(0.5+min(angle,sweep*math.TAU-angle)*math.sqrt(d.x*d.x+d.y*d.y)/aa,0,1)
    }
    alpha:=(border+fill.a*(1-border))*outer*arc
    rgb:=(shape.stroke.rgb*border+fill.rgb*fill.a*(1-border))*outer*arc
    return alpha>1e-6 ? [4]f32{rgb.r/alpha,rgb.g/alpha,rgb.b/alpha,alpha} : [4]f32{}
}

@(private="file")
raster_blend :: proc(target:^[4]f32,source:[4]f32,premultiplied:=false) {
    a:=clamp(source.a,0,1)
    color:=source
    if !premultiplied {color.rgb*=a}
    color.a=a
    color+=target^*(1-a)
    for k in 0..<4 {target[k]=math.floor(clamp(color[k],0,1)*255+0.5)/255}
}

@(private="file")
raster_sample :: proc(pixels:[][4]f32,width,height:int,p:[2]f32) -> [4]f32 {
    x,y:=int(math.floor(p.x)),int(math.floor(p.y))
    fx,fy:=p.x-f32(x),p.y-f32(y)
    a:=pixels[clamp(y,0,height-1)*width+clamp(x,0,width-1)]
    b:=pixels[clamp(y,0,height-1)*width+clamp(x+1,0,width-1)]
    c:=pixels[clamp(y+1,0,height-1)*width+clamp(x,0,width-1)]
    d:=pixels[clamp(y+1,0,height-1)*width+clamp(x+1,0,width-1)]
    return (a*(1-fx)+b*fx)*(1-fy)+(c*(1-fx)+d*fx)*fy
}

@(private="file")
raster_blur :: proc(source:[][4]f32,width,height:int,sigma:f32,allocator:runtime.Allocator) -> [][4]f32 {
    horizontal:=make([][4]f32,width*height,allocator)
    result:=make([][4]f32,width*height,allocator)
    defer delete(horizontal,allocator)
    blur_sigma:=max(sigma,0.5)
    step:=max(blur_sigma*3/12,1)
    for pass in 0..<2 {
        input:=pass==0 ? source : horizontal
        output:=pass==0 ? horizontal : result
        for y in 0..<height {
            for x in 0..<width {
                sum:[4]f32
                total:f32
                for i in -12..=12 {
                    offset:=f32(i)*step
                    weight:=math.exp(-0.5*offset*offset/(blur_sigma*blur_sigma))
                    p:=[2]f32{f32(x),f32(y)}
                    p[pass]+=offset
                    sum+=raster_sample(input,width,height,p)*weight
                    total+=weight
                }
                for k in 0..<4 {output[y*width+x][k]=math.floor(clamp(sum[k]/total,0,1)*255+0.5)/255}
            }
        }
    }
    return result
}

// Draws the commands of the screen at density device pixels per point.
test_raster :: proc(ctx:^ui.Context,frame:ui.Frame,width,height:int,density:f32,background:ui.Color,allocator:=context.allocator) -> Test_Image {
    image:=Test_Image{width,height,make([][4]u8,width*height,allocator)}
    targets:[16][][4]f32
    targets[0]=make([][4]f32,width*height,allocator)
    defer delete(targets[0],allocator)
    initial:=[4]f32{f32(background.r),f32(background.g),f32(background.b),f32(background.a)}/255
    initial.rgb*=initial.a
    for &pixel in targets[0] {pixel=initial}
    layers:[16]ui.Layer
    depth:=0
    edge :: proc(a,b,p:[2]f32) -> f32 {return (b.x-a.x)*(p.y-a.y)-(b.y-a.y)*(p.x-a.x)}
    // An edge of a triangle wound with positive area owns the pixels on it
    // when it is a left or a top edge.
    owns :: proc(a,b:[2]f32) -> bool {return b.y<a.y || (b.y==a.y && b.x>a.x)}
    for command in frame.commands {
        if command.surface!=0 {continue}
        sx0:=max(int(math.floor(command.scissor.x*density+0.5)),0)
        sy0:=max(int(math.floor(command.scissor.y*density+0.5)),0)
        sx1:=min(int(math.floor((command.scissor.x+command.scissor.w)*density+0.5)),width)
        sy1:=min(int(math.floor((command.scissor.y+command.scissor.h)*density+0.5)),height)
        switch command.kind {
        case .Begin_Layer:
            depth+=1
            assert(depth<len(targets))
            layer:=frame.layers[command.layer]
            layers[depth]=layer
            if layer.backdrop_blur>0 {
                targets[depth]=raster_blur(targets[depth-1],width,height,layer.backdrop_blur*density,allocator)
            } else {targets[depth]=make([][4]f32,width*height,allocator)}
            continue
        case .End_Layer:
            assert(depth>0)
            layer:=layers[depth]
            mask:=ui.Shape{bounds={layer.bounds.x*density,layer.bounds.y*density,layer.bounds.w*density,layer.bounds.h*density},radii={layer.radius*density,layer.radius*density,layer.radius*density,layer.radius*density}}
            for y in sy0..<sy1 {
                for x in sx0..<sx1 {
                    p:=[2]f32{f32(x)+0.5,f32(y)+0.5}
                    dx,dy:=p,p
                    dx.x=f32(x~1)+0.5;dy.y=f32(y~1)+0.5
                    d:=raster_distance(p,mask)
                    aa:=max(abs(raster_distance(dx,mask)-d)+abs(raster_distance(dy,mask)-d),1e-4)
                    coverage:=clamp(0.5-d/aa,0,1)*clamp(layer.opacity,0,1)
                    raster_blend(&targets[depth-1][y*width+x],targets[depth][y*width+x]*coverage,true)
                }
            }
            delete(targets[depth],allocator);targets[depth]=nil;depth-=1
            continue
        case .Triangles:
        }
        vertices:=frame.vertices[command.first:][:command.count]
        for i:=0;i+2<len(vertices);i+=3 {
            v:=[3]ui.Vertex{vertices[i],vertices[i+1],vertices[i+2]}
            p:=[3][2]f32{v[0].position.xy*density,v[1].position.xy*density,v[2].position.xy*density}
            area:=edge(p[0],p[1],p[2])
            if area==0 {continue}
            if area<0 {v[1],v[2]=v[2],v[1];p[1],p[2]=p[2],p[1];area=-area}
            x0:=max(int(math.floor(min(p[0].x,p[1].x,p[2].x))),sx0)
            y0:=max(int(math.floor(min(p[0].y,p[1].y,p[2].y))),sy0)
            x1:=min(int(math.ceil(max(p[0].x,p[1].x,p[2].x))),sx1)
            y1:=min(int(math.ceil(max(p[0].y,p[1].y,p[2].y))),sy1)
            own:=[3]bool{owns(p[1],p[2]),owns(p[2],p[0]),owns(p[0],p[1])}
            for y in y0..<y1 {
                for x in x0..<x1 {
                    center:=[2]f32{f32(x)+0.5,f32(y)+0.5}
                    w:=[3]f32{edge(p[1],p[2],center),edge(p[2],p[0],center),edge(p[0],p[1],center)}
                    inside:=true
                    for k in 0..<3 {if w[k]<0 || (w[k]==0 && !own[k]) {inside=false}}
                    if !inside {continue}
                    w/=area
                    color:=v[0].color*w[0]+v[1].color*w[1]+v[2].color*w[2]
                    uv:=v[0].uv*w[0]+v[1].uv*w[1]+v[2].uv*w[2]
                    if ui.quad_kind(v[0].quad)==.Shape {
                        nx,ny:=center,center
                        nx.x=f32(x~1)+0.5;ny.y=f32(y~1)+0.5
                        wx:=[3]f32{edge(p[1],p[2],nx),edge(p[2],p[0],nx),edge(p[0],p[1],nx)}/area
                        wy:=[3]f32{edge(p[1],p[2],ny),edge(p[2],p[0],ny),edge(p[0],p[1],ny)}/area
                        uvx:=v[0].uv*wx[0]+v[1].uv*wx[1]+v[2].uv*wx[2]
                        uvy:=v[0].uv*wy[0]+v[1].uv*wy[1]+v[2].uv*wy[2]
                        color*=raster_shape(uv,uvx,uvy,frame.shapes[ui.quad_data(v[0].quad)])
                    }
                    if ui.quad_kind(v[0].quad)==.Glyph {
                        color.a*=test_glyph_alpha(atlas_sample(&ctx.font,uv),color.rgb)
                    }
                    raster_blend(&targets[depth][y*width+x],color)
                }
            }
        }
    }
    assert(depth==0)
    for pixel,i in targets[0] {
        straight:=pixel
        if pixel.a>0 {straight.rgb/=pixel.a}
        for k in 0..<4 {image.pixels[i][k]=u8(clamp(straight[k]*255+0.5,0,255))}
    }
    return image
}

test_image_dump :: proc(image:^Test_Image,name:string) {
    if UI_DUMP_DIR=="" {return}
    path:=strings.clone_to_cstring(fmt.tprintf("%s/%s.png",UI_DUMP_DIR,name),context.temp_allocator)
    stbi.write_png(path,c.int(image.width),c.int(image.height),4,raw_data(image.pixels),c.int(image.width*4))
}

// How many pixels of a rectangle (in pixels) are closer to color than tolerance.
test_count_color :: proc(image:^Test_Image,r:ui.Rect,color:ui.Color,tolerance:int=24) -> int {
    count:=0
    for y in int(r.y)..<int(r.y+r.h) {
        for x in int(r.x)..<int(r.x+r.w) {
            if test_color_near(test_pixel(image,x,y),color,tolerance) {count+=1}
        }
    }
    return count
}

test_image_load :: proc(path:string,allocator:=context.allocator) -> (image:Test_Image,ok:bool) {
    w,h,channels:c.int
    data:=stbi.load(strings.clone_to_cstring(path,context.temp_allocator),&w,&h,&channels,4)
    if data==nil {return}
    defer stbi.image_free(data)
    image={int(w),int(h),make([][4]u8,int(w*h),allocator)}
    copy(image.pixels,(cast([^][4]u8)data)[:w*h])
    return image,true
}

Test_Difference :: struct {pixels,different:int,largest:int,mean:f32}
// Compares a rectangle of two images. different: pixels with a channel
// further apart than tolerance.
test_image_compare :: proc(a,b:^Test_Image,r:ui.Rect,tolerance:int) -> (d:Test_Difference) {
    total:=0
    for y in int(r.y)..<int(r.y+r.h) {
        for x in int(r.x)..<int(r.x+r.w) {
            pa,pb:=test_pixel(a,x,y),test_pixel(b,x,y)
            worst:=0
            for k in 0..<3 {worst=max(worst,abs(int(pa[k])-int(pb[k])))}
            d.pixels+=1;total+=worst
            d.largest=max(d.largest,worst)
            if worst>tolerance {d.different+=1}
        }
    }
    if d.pixels>0 {d.mean=f32(total)/f32(d.pixels)}
    return
}
// A rectangle of an image, enlarged: for looking at details.
test_image_crop :: proc(image:^Test_Image,r:ui.Rect,zoom:int,allocator:=context.allocator) -> Test_Image {
    out:=Test_Image{int(r.w)*zoom,int(r.h)*zoom,make([][4]u8,int(r.w)*zoom*int(r.h)*zoom,allocator)}
    for y in 0..<out.height {
        for x in 0..<out.width {out.pixels[y*out.width+x]=test_pixel(image,int(r.x)+x/zoom,int(r.y)+y/zoom)}
    }
    return out
}

test_image_decode :: proc(data:[]u8,allocator:=context.allocator) -> (image:Test_Image,ok:bool) {
    w,h,channels:c.int
    pixels:=stbi.load_from_memory(raw_data(data),c.int(len(data)),&w,&h,&channels,4)
    if pixels==nil {return}
    defer stbi.image_free(pixels)
    image={int(w),int(h),make([][4]u8,int(w*h),allocator)}
    copy(image.pixels,(cast([^][4]u8)pixels)[:w*h])
    return image,true
}

// The paint of the last frame that shows this text.
// The paint of what says text: a widget that draws it, or the text whose first span it is.
test_paint :: proc(ctx:^ui.Context,text:string) -> ^ui.Paint {
    for &p in ctx.paints[:ctx.paint_count] {if p.text==text {return &p}}
    return nil
}

// context_init with the theme of the editor as the sheet.
test_context_init :: proc(ctx:^ui.Context,desc:ui.Context_Desc) -> bool {
    if !ui.context_init(ctx,desc) {return false}
    if !theme_set(ctx) {ui.context_destroy(ctx);return false}
    return true
}

test_click :: proc(ctx:^ui.Context,input:^ui.Input,build:Test_Build,user:rawptr,target:ui.Id) {
    rect,_:=ui.widget_rect(ctx,target)
    test_point(input,rect)
    test_frame(ctx,input,build,user)
    test_press(input)
    test_frame(ctx,input,build,user)
    test_release(input)
    test_frame(ctx,input,build,user)
}
TEST_CONTROL_STYLE :: ui.Node_Style{
    fill={10,20,30,255},stroke={40,50,60,255},track={70,80,90,255},knob={100,110,120,255},mark={130,140,150,255},
    radius={1,2,3,4},stroke_width=2,text={size=10,color={200,200,200,255}},
}
