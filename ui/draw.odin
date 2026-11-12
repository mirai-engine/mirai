package ui

import "core:math"
import "core:mem"
import "mirai:std/base"

// Geometry is written into the preallocated vertex array of the context as a
// triangle list split into commands by scissor rectangle and surface. Nothing
// here calls a graphics API, allocates or grows a buffer: vertices that do not
// fit are counted in Stats.dropped_vertices.
//
// Two clips exist. The scissor belongs to the containers of the screen (scroll
// areas, clipped panels): it travels in the command and whole shapes outside
// it are skipped. The clip is applied to the geometry here, interpolating
// colors and texture coordinates: text inside its box, the contents of a
// field, and everything a world panel draws, which never leaves its rectangle.

Affine :: matrix[2,3]f32
AFFINE_IDENTITY :: Affine{1,0,0,0,1,0}

SCISSOR_DEPTH :: 16
CLIP_DEPTH :: 16

@(private)
Clip_Entry :: struct {
    local,surface:Rect,
    clipping:bool,
    scope:Affine, // the transform the local rectangle was given under
}

@(private)
Draw :: struct {
    vertices:[]Vertex,count:int,
    region:base.Region, // of vertices when the context made them: committed up to the most a frame used
    commands:[]Draw_Command,command_count:int,
    scissor:Rect,scissor_stack:[SCISSOR_DEPTH]Rect,scissor_depth,scissor_skipped:int,
    clip:Rect,          // in the space shapes are given in
    clip_surface:Rect,  // the same clip in layout units of the surface, past every transform
    clipping:bool,
    clip_stack:[CLIP_DEPTH]Clip_Entry,clip_depth,clip_skipped:int,
    surface:u32,
    layered:bool,       // isolated layers compose here: on the screen, or in a panel drawn into a texture
    bounds:Rect,        // the surface, in layout units
    scope:Affine,       // layout units to layout units: the transform of the animated subtree
    scope_inverse:Affine,
    m:Affine,           // layout units to surface units: scope, then the scale of the surface
    tint:[4]f32,        // multiplies every color
    fade:[2]f32,        // x where what is drawn starts to fade and where it is gone, in the space of the clip; equal: none
    shear:f32,          // textured quads lean right by this much per unit above shear_base: the glyphs of italics
    shear_base:f32,     // the baseline of the line draw_text draws
    color2:Color,       // when set: textured quads go from their color at band[0] down to this at band[1]
    band:[2]f32,
    transformed:bool,   // scope is not the identity
    scale:f32,          // layout units to surface units
    ppu:f32,            // device pixels per layout unit
    pixel:f32,          // one device pixel in layout units: the width of the antialiasing fade
    font_quad:u32,
    dirty:bool,         // the next vertices begin a command
    split:bool,         // they begin one even with the scissor and the surface of the last: a retained subtree starts or ends
    shapes:[]Shape,shape_count:int,
    layers:[]Layer,layer_count:int,
    composition_stack:[COMPOSITION_DEPTH]Composition_Entry,
    composition_depth,accepted_layers,skipped_layers,suppressed:int,
    dropped_shapes,dropped_layers:u32,
    dropped_vertices,dropped_commands:u32,
}

@(private)
draw_reset :: proc(d:^Draw,bounds:Rect,scale,density:f32) {
    d.count=0;d.command_count=0;d.scissor_depth=0;d.scissor_skipped=0
    d.shape_count=0;d.layer_count=0;d.composition_depth=0;d.accepted_layers=0;d.skipped_layers=0;d.suppressed=0
    d.dropped_shapes=0;d.dropped_layers=0
    d.dropped_vertices=0;d.dropped_commands=0;d.shear=0
    draw_surface(d,0,bounds,scale,scale*density,false,true)
}

// Selects the surface the next shapes belong to. contained: nothing is drawn
// outside its bounds, whatever the renderer does with the scissor.
@(private)
draw_surface :: proc(d:^Draw,surface:u32,bounds:Rect,scale,ppu:f32,contained,layered:bool) {
    d.surface=surface;d.layered=layered;d.bounds=bounds;d.scissor=bounds
    d.scale=scale;d.ppu=max(ppu,0.001);d.pixel=1/d.ppu
    d.scope=AFFINE_IDENTITY;d.scope_inverse=AFFINE_IDENTITY
    d.m={scale,0,0,0,scale,0};d.tint={1,1,1,1};d.transformed=false
    d.clip_depth=0;d.clip_skipped=0;d.clipping=contained;d.clip=bounds;d.clip_surface=bounds
    d.dirty=true
}

// The box of a rectangle seen through a transform: exact for offsets and scales.
@(private)
rect_through :: proc "contextless" (m:Affine,r:Rect) -> Rect {
    lo,hi:=[2]f32{max(f32),max(f32)},[2]f32{min(f32),min(f32)}
    for corner in ([4][2]f32{{r.x,r.y},{r.x+r.w,r.y},{r.x+r.w,r.y+r.h},{r.x,r.y+r.h}}) {
        p:=[2]f32{m[0,0]*corner.x+m[0,1]*corner.y+m[0,2],m[1,0]*corner.x+m[1,1]*corner.y+m[1,2]}
        lo={min(lo.x,p.x),min(lo.y,p.y)};hi={max(hi.x,p.x),max(hi.y,p.y)}
    }
    return {lo.x,lo.y,hi.x-lo.x,hi.y-lo.y}
}

// scope: layout units to layout units, applied before the scale of the surface.
@(private)
draw_transform :: proc(d:^Draw,scope:Affine,tint:[4]f32,identity:bool) {
    s:=d.scale
    d.m={scope[0,0]*s,scope[0,1]*s,scope[0,2]*s,scope[1,0]*s,scope[1,1]*s,scope[1,2]*s}
    d.tint=tint;d.transformed=!identity
    if d.scope!=scope {
        d.scope=scope
        d.scope_inverse=AFFINE_IDENTITY if identity else affine_inverse(scope)
        // A clip set by a container outside this subtree, seen from inside it.
        if d.clipping {d.clip=rect_through(d.scope_inverse,d.clip_surface)}
    }
}

@(private)
draw_scissor :: proc "contextless" (d:^Draw) -> Rect {
    if d.scissor.w<=0 || d.scissor.h<=0 {return {d.scissor.x*d.scale,d.scissor.y*d.scale,-1,-1}}
    return {d.scissor.x*d.scale,d.scissor.y*d.scale,d.scissor.w*d.scale,d.scissor.h*d.scale}
}

// counted: what does not fit is added to the dropped ones.
@(private)
draw_reserve :: proc(d:^Draw,n:int,counted:=true) -> []Vertex {
    if d.suppressed>0 || d.scissor.w<=0 || d.scissor.h<=0 {return nil}
    if d.count+n>len(d.vertices) || d.region.data!=nil && !base.region_commit(&d.region,(d.count+n)*size_of(Vertex)) {
        if counted {d.dropped_vertices+=u32(n)}
        return nil
    }
    if d.dirty || d.command_count==0 {
        scissor:=draw_scissor(d)
        last:=&d.commands[d.command_count-1] if d.command_count>0 else nil
        if last==nil || d.split || last.kind!=.Triangles || last.scissor!=scissor || last.surface!=d.surface {
            if d.command_count>=len(d.commands)-d.accepted_layers {
                if counted {d.dropped_commands+=1;d.dropped_vertices+=u32(n)}
                return nil
            }
            d.commands[d.command_count]={first=u32(d.count),scissor=scissor,surface=d.surface}
            d.command_count+=1
        }
        d.dirty,d.split=false,false
    }
    out:=d.vertices[d.count:][:n]
    d.count+=n;d.commands[d.command_count-1].count+=u32(n)
    return out
}

@(private)
draw_tint :: #force_inline proc "contextless" (d:^Draw,c:Color) -> [4]f32 {
    return [4]f32{f32(c[0]),f32(c[1]),f32(c[2]),f32(c[3])}/255*d.tint
}
@(private)
draw_point :: #force_inline proc "contextless" (d:^Draw,p:[2]f32) -> [3]f32 {
    return {d.m[0,0]*p.x+d.m[0,1]*p.y+d.m[0,2],d.m[1,0]*p.x+d.m[1,1]*p.y+d.m[1,2],0}
}
// Whole shapes outside the scissor produce nothing. A transformed shape is
// never skipped: its place on the surface is not the one given here.
@(private)
draw_outside :: #force_inline proc "contextless" (d:^Draw,x0,y0,x1,y1:f32) -> bool {
    if d.transformed {return false}
    s:=d.scissor
    return x1<=s.x || y1<=s.y || x0>=s.x+s.w || y0>=s.y+s.h
}

// Room for n vertices of a shape that lies between (x0,y0) and (x1,y1), when
// none of its triangles would be cut by the clip, skipped by the scissor or
// left out for lack of room: they can be written as they are. nil otherwise.
@(private="file")
draw_whole :: proc(d:^Draw,x0,y0,x1,y1:f32,n:int) -> []Vertex {
    if d.clipping && (x0<d.clip.x || y0<d.clip.y || x1>d.clip.x+d.clip.w || y1>d.clip.y+d.clip.h) {return nil}
    if !d.transformed {
        s:=d.scissor
        if x0<=s.x || y0<=s.y || x1>=s.x+s.w || y1>=s.y+s.h {return nil}
    }
    return draw_reserve(d,n,false)
}

@(private="file")
vertex_at :: #force_inline proc "contextless" (d:^Draw,p:[2]f32,color:[4]f32) -> Vertex {
    return {position=draw_point(d,p),color=color}
}

// ---------------------------------------------------------------- scissor and clip

// A scissor or a clip nested deeper than its stack holds is not applied, and
// is counted in Stats.dropped_clips.
scissor_push :: proc(ctx:^Context,r:Rect) {
    d:=&ctx.draw
    if d.scissor_depth>=SCISSOR_DEPTH {d.scissor_skipped+=1;ctx.stats.dropped_clips+=1;return}
    d.scissor_stack[d.scissor_depth]=d.scissor;d.scissor_depth+=1
    d.scissor=rect_intersect(d.scissor,rect_through(d.scope,r) if d.transformed else r);d.dirty=true
}
scissor_pop :: proc(ctx:^Context) {
    d:=&ctx.draw
    if d.scissor_skipped>0 {d.scissor_skipped-=1;return}
    if d.scissor_depth<=0 {return}
    d.scissor_depth-=1;d.scissor=d.scissor_stack[d.scissor_depth];d.dirty=true
}

// What is drawn until clip_pop is cut to r, inside the clips already set.
clip_push :: proc(ctx:^Context,r:Rect) {
    d:=&ctx.draw
    if d.clip_depth>=CLIP_DEPTH {d.clip_skipped+=1;ctx.stats.dropped_clips+=1;return}
    d.clip_stack[d.clip_depth]={d.clip,d.clip_surface,d.clipping,d.scope};d.clip_depth+=1
    surface:=rect_through(d.scope,r) if d.transformed else r
    if d.clipping {d.clip=rect_intersect(d.clip,r);d.clip_surface=rect_intersect(d.clip_surface,surface)} else {d.clip=r;d.clip_surface=surface}
    d.clipping=true
}
clip_pop :: proc(ctx:^Context) {
    d:=&ctx.draw
    if d.clip_skipped>0 {d.clip_skipped-=1;return}
    if d.clip_depth<=0 {return}
    d.clip_depth-=1
    entry:=d.clip_stack[d.clip_depth]
    d.clip,d.clip_surface,d.clipping=entry.local,entry.surface,entry.clipping
    if d.clipping && entry.scope!=d.scope {d.clip=rect_through(d.scope_inverse,d.clip_surface)}
}

// ---------------------------------------------------------------- triangles and rectangles

// Clips a triangle against the active clip (Sutherland-Hodgman), interpolating
// vertex colors, and appends the resulting fan.
draw_triangle_colors :: proc(ctx:^Context,a,b,c:[2]f32,ca,cb,cc:Color) {
    d:=&ctx.draw
    if draw_outside(d,min(a.x,b.x,c.x),min(a.y,b.y,c.y),max(a.x,b.x,c.x),max(a.y,b.y,c.y)) {return}
    if !d.clipping {
        out:=draw_reserve(d,3)
        if out==nil {return}
        out[0],out[1],out[2]=vertex_at(d,a,draw_tint(d,ca)),vertex_at(d,b,draw_tint(d,cb)),vertex_at(d,c,draw_tint(d,cc))
        return
    }
    points:[8][2]f32;colors:[8][4]f32
    points[0],points[1],points[2]=a,b,c
    colors[0],colors[1],colors[2]=draw_tint(d,ca),draw_tint(d,cb),draw_tint(d,cc)
    count:=3
    if d.clipping {
        clip:=d.clip
        limits:=[4]f32{clip.x,clip.x+clip.w,clip.y,clip.y+clip.h}
        for edge in 0..<4 {
            out_points:[8][2]f32;out_colors:[8][4]f32;n:=0
            axis:=edge/2;limit:=limits[edge];keep_above:=edge%2==0
            for i in 0..<count {
                p,q:=points[i],points[(i+1)%count]
                inside_p:=p[axis]>=limit if keep_above else p[axis]<=limit
                inside_q:=q[axis]>=limit if keep_above else q[axis]<=limit
                if inside_p {out_points[n]=p;out_colors[n]=colors[i];n+=1}
                if inside_p!=inside_q {
                    t:=(limit-p[axis])/(q[axis]-p[axis])
                    out_points[n]=p+(q-p)*t;out_colors[n]=colors[i]+(colors[(i+1)%count]-colors[i])*t;n+=1
                }
            }
            if n<3 {return}
            points,colors,count=out_points,out_colors,n
        }
    }
    out:=draw_reserve(d,(count-2)*3)
    if out==nil {return}
    first:=Vertex{position=draw_point(d,points[0]),color=colors[0]}
    for i in 1..<count-1 {
        out[(i-1)*3]=first
        out[(i-1)*3+1]={position=draw_point(d,points[i]),color=colors[i]}
        out[(i-1)*3+2]={position=draw_point(d,points[i+1]),color=colors[i+1]}
    }
}
draw_triangle :: proc(ctx:^Context,a,b,c:[2]f32,color:Color) {draw_triangle_colors(ctx,a,b,c,color,color,color)}
draw_quad_colors :: proc(ctx:^Context,p:[4][2]f32,c:[4]Color) {
    draw_triangle_colors(ctx,p[0],p[1],p[2],c[0],c[1],c[2])
    draw_triangle_colors(ctx,p[0],p[2],p[3],c[0],c[2],c[3])
}

draw_rect :: proc(ctx:^Context,r:Rect,color:Color) {
    if r.w<=0||r.h<=0||color[3]==0 {return}
    d:=&ctx.draw
    x,y,ex,ey:=r.x,r.y,r.x+r.w,r.y+r.h
    if d.clipping {
        x,y=max(x,d.clip.x),max(y,d.clip.y)
        ex,ey=min(ex,d.clip.x+d.clip.w),min(ey,d.clip.y+d.clip.h)
        if ex<=x||ey<=y {return}
    }
    if draw_outside(d,x,y,ex,ey) {return}
    out:=draw_reserve(d,6)
    if out==nil {return}
    tint:=draw_tint(d,color)
    a:=Vertex{position=draw_point(d,{x,y}),color=tint};b:=Vertex{position=draw_point(d,{ex,y}),color=tint}
    c:=Vertex{position=draw_point(d,{ex,ey}),color=tint};e:=Vertex{position=draw_point(d,{x,ey}),color=tint}
    out[0],out[1],out[2],out[3],out[4],out[5]=a,b,c,a,c,e
}
draw_rect_gradient :: proc(ctx:^Context,r:Rect,top,bottom:Color) {
    if r.w<=0||r.h<=0 {return}
    draw_quad_colors(ctx,{{r.x,r.y},{r.x+r.w,r.y},{r.x+r.w,r.y+r.h},{r.x,r.y+r.h}},{top,top,bottom,bottom})
}
draw_rect_lines :: proc(ctx:^Context,r:Rect,thickness:f32,color:Color) {
    t:=min(thickness,min(r.w,r.h)*0.5)
    draw_rect(ctx,{r.x,r.y,r.w,t},color)
    draw_rect(ctx,{r.x,r.y+r.h-t,r.w,t},color)
    draw_rect(ctx,{r.x,r.y+t,t,r.h-2*t},color)
    draw_rect(ctx,{r.x+r.w-t,r.y+t,t,r.h-2*t},color)
}

// One quad per shape: the radius and the border do not add geometry.
draw_shape :: proc(ctx:^Context,r:Rect,style:Shape_Style) {
    if r.w<=0 || r.h<=0 || style.fill[3]==0 && style.fill2[3]==0 && style.stroke[3]==0 {return}
    radius:=style.radii
    for &v in radius {v=clamp(v,0,min(r.w,r.h)*0.5)}
    // A border is whole device pixels wide, as the edges of the boxes are.
    stroke:=style.stroke_width
    if stroke>0 {stroke=max(math.round(stroke*ctx.draw.ppu),1)*ctx.draw.pixel}
    shape:=Shape{
        bounds={r.x,r.y,r.w,r.h},radii=radius,
        fill=[4]f32{f32(style.fill[0]),f32(style.fill[1]),f32(style.fill[2]),f32(style.fill[3])}/255,
        fill2=[4]f32{f32(style.fill2[0]),f32(style.fill2[1]),f32(style.fill2[2]),f32(style.fill2[3])}/255,
        stroke=[4]f32{f32(style.stroke[0]),f32(style.stroke[1]),f32(style.stroke[2]),f32(style.stroke[3])}/255,
        params={clamp(stroke,0,min(r.w,r.h)*0.5),0,0,f32(style.gradient)},
    }
    shape_emit(ctx,shape,ctx.draw.pixel)
}

// A rounded rectangle colored by a ui program of the renderer (its id): it
// gets color, the place of each point and values, its first four floats. With
// an image of the texture table its color is that image tinted by color, and
// without a program the image alone is cut to the corners. The shape keeps the
// id in the bits of stroke.x, the texture in stroke.y and values in params.
draw_program :: proc(ctx:^Context,r:Rect,program:u32,values:[4]f32,color:Color,radii:[4]f32,image:Quad={}) {
    if r.w<=0 || r.h<=0 || program==0 && image.kind!=.Image {return}
    radius:=radii
    for &v in radius {v=clamp(v,0,min(r.w,r.h)*0.5)}
    shape:=Shape{
        bounds={r.x,r.y,r.w,r.h},radii=radius,
        fill=[4]f32{f32(color[0]),f32(color[1]),f32(color[2]),f32(color[3])}/255,
        stroke={transmute(f32)program,0,0,0},params=values,
    }
    if image.kind==.Image {
        shape.stroke[1]=transmute(f32)(image.data+1)
        shape.fill2={image.uv.x,image.uv.y,image.uv.w,image.uv.h}
    }
    shape_emit(ctx,shape,ctx.draw.pixel,.Program)
}

@(private)
shape_emit :: proc(ctx:^Context,shape:Shape,padding:f32,kind:=Quad_Kind.Shape) {
    d:=&ctx.draw
    if d.suppressed>0 {return}
    if d.shape_count>=len(d.shapes) {d.dropped_shapes+=1;return}
    r:=shape.bounds
    rect:=Rect{r[0]-padding,r[1]-padding,r[2]+2*padding,r[3]+2*padding}
    before:=d.count
    // UV are the layout coordinates; the clip interpolates UV and position together.
    draw_quad(ctx,rect,rect,{255,255,255,255},quad_pack(kind,u32(d.shape_count)))
    if d.count==before {return}
    d.shapes[d.shape_count]=shape;d.shape_count+=1
}

draw_rounded_corners :: proc(ctx:^Context,r:Rect,radii:[4]f32,color:Color) {
    draw_shape(ctx,r,{fill=color,radii=radii})
}
draw_rounded :: proc(ctx:^Context,r:Rect,radius:f32,color:Color) {
    draw_rounded_corners(ctx,r,{radius,radius,radius,radius},color)
}
draw_rounded_gradient :: proc(ctx:^Context,r:Rect,radius:f32,first,last:Color,gradient:Gradient=.Vertical) {
    draw_shape(ctx,r,{fill=first,fill2=last,radii={radius,radius,radius,radius},gradient=gradient})
}
draw_rounded_stroke :: proc(ctx:^Context,r:Rect,radius,thickness:f32,color:Color) {
    draw_shape(ctx,r,{stroke=color,stroke_width=thickness,radii={radius,radius,radius,radius}})
}

// Gaussian shadow of a rounded box; the shader integrates the coverage.
draw_blurred_shadow :: proc(ctx:^Context,r:Rect,radius,sigma:f32,offset:[2]f32,color:Color) {
    if r.w<=0 || r.h<=0 || color[3]==0 || sigma<=0 {return}
    shape:=Shape{
        bounds={r.x+offset.x,r.y+offset.y,r.w,r.h},
        radii={clamp(radius,0,min(r.w,r.h)*0.5),clamp(radius,0,min(r.w,r.h)*0.5),clamp(radius,0,min(r.w,r.h)*0.5),clamp(radius,0,min(r.w,r.h)*0.5)},
        fill=[4]f32{f32(color[0]),f32(color[1]),f32(color[2]),f32(color[3])}/255,
        params={0,2,max(sigma,0.5),0},
    }
    shape_emit(ctx,shape,max(sigma,0.5)*3)
}
// Keeps the public signature: spread drives sigma and offset shifts along Y.
draw_shadow :: proc(ctx:^Context,r:Rect,radius:f32,color:Color,spread:int=4,offset:f32=2) {
    draw_blurred_shadow(ctx,r,radius,f32(max(spread,0))*1.5,{0,offset},color)
}

// ---------------------------------------------------------------- lines and circles

// Anti-aliased line: a solid core with a one pixel fade on each side.
draw_line :: proc(ctx:^Context,a,b:[2]f32,width:f32,color:Color) {
    delta:=b-a;length:=math.sqrt(delta.x*delta.x+delta.y*delta.y)
    if length<0.0001||width<=0 {return}
    n:=[2]f32{-delta.y,delta.x}/length
    px:=ctx.draw.pixel
    core:=max(width*0.5-0.5*px,0);outer:=core+px
    solid:=color
    if width<1 {solid[3]=u8(f32(color[3])*width)}
    clear:=color_alpha(solid,0)
    d:=&ctx.draw
    reach:=[2]f32{abs(n.x),abs(n.y)}*outer
    count:=18 if core>0 else 12
    if out:=draw_whole(d,min(a.x,b.x)-reach.x,min(a.y,b.y)-reach.y,max(a.x,b.x)+reach.x,max(a.y,b.y)+reach.y,count);out!=nil {
        full,faded:=draw_tint(d,solid),draw_tint(d,clear)
        // Across the line at each end: the faded edge, the two sides of the core, the other faded edge.
        a0,a1,a2,a3:=vertex_at(d,a+n*outer,faded),vertex_at(d,a+n*core,full),vertex_at(d,a-n*core,full),vertex_at(d,a-n*outer,faded)
        b0,b1,b2,b3:=vertex_at(d,b+n*outer,faded),vertex_at(d,b+n*core,full),vertex_at(d,b-n*core,full),vertex_at(d,b-n*outer,faded)
        v:=out
        if core>0 {
            v[0],v[1],v[2],v[3],v[4],v[5]=a1,b1,b2,a1,b2,a2
            v=v[6:]
        }
        v[0],v[1],v[2],v[3],v[4],v[5]=a0,b0,b1,a0,b1,a1
        v[6],v[7],v[8],v[9],v[10],v[11]=a2,b2,b3,a2,b3,a3
        return
    }
    if core>0 {draw_quad_colors(ctx,{a+n*core,b+n*core,b-n*core,a-n*core},{solid,solid,solid,solid})}
    draw_quad_colors(ctx,{a+n*outer,b+n*outer,b+n*core,a+n*core},{clear,clear,solid,solid})
    draw_quad_colors(ctx,{a-n*core,b-n*core,b-n*outer,a-n*outer},{solid,solid,clear,clear})
}
draw_polyline :: proc(ctx:^Context,points:[][2]f32,width:f32,color:Color,closed:bool=false) {
    for i in 0..<len(points)-1 {draw_line(ctx,points[i],points[i+1],width,color)}
    if closed && len(points)>2 {draw_line(ctx,points[len(points)-1],points[0],width,color)}
}

// A smooth closed outline of many short segments. They share the sides at each point, so their faded
// edges do not pile up as those of the separate lines of draw_polyline do.
draw_outline :: proc(ctx:^Context,points:[][2]f32,width:f32,color:Color) {
    if len(points)<3 || width<=0 {return}
    across :: proc(points:[][2]f32,i:int) -> [2]f32 {
        along:=points[(i+1)%len(points)]-points[(i+len(points)-1)%len(points)]
        return [2]f32{-along.y,along.x}/max(math.sqrt(along.x*along.x+along.y*along.y),0.0001)
    }
    core:=max(width*0.5-0.5*ctx.draw.pixel,0);outer:=core+ctx.draw.pixel
    clear:=color_alpha(color,0)
    for i in 0..<len(points) {
        j:=(i+1)%len(points)
        a,b,na,nb:=points[i],points[j],across(points,i),across(points,j)
        draw_quad_colors(ctx,{a+na*outer,b+nb*outer,b+nb*core,a+na*core},{clear,clear,color,color})
        draw_quad_colors(ctx,{a+na*core,b+nb*core,b-nb*core,a-na*core},{color,color,color,color})
        draw_quad_colors(ctx,{a-na*core,b-nb*core,b-nb*outer,a-na*outer},{color,color,clear,clear})
    }
}

// Discs, ellipses and rings share the analytic ellipse evaluator.
draw_circle :: proc(ctx:^Context,center:[2]f32,radius:f32,color:Color) {
    draw_ellipse(ctx,center,radius,radius,color)
}
draw_ellipse :: proc(ctx:^Context,center:[2]f32,rx,ry:f32,color:Color) {
    if rx<=0 || ry<=0 || color[3]==0 {return}
    shape:=Shape{bounds={center.x-rx,center.y-ry,rx*2,ry*2},
        fill=[4]f32{f32(color[0]),f32(color[1]),f32(color[2]),f32(color[3])}/255,params={0,1,0,0}}
    shape_emit(ctx,shape,ctx.draw.pixel)
}
draw_ring :: proc(ctx:^Context,center:[2]f32,radius,width:f32,color:Color) {
    if radius<=0 || width<=0 || color[3]==0 {return}
    outer:=radius+width*0.5
    shape:=Shape{bounds={center.x-outer,center.y-outer,outer*2,outer*2},
        stroke=[4]f32{f32(color[0]),f32(color[1]),f32(color[2]),f32(color[3])}/255,params={min(width,outer),1,0,0}}
    shape_emit(ctx,shape,ctx.draw.pixel)
}

// The part sweep (0 to 1) of a ring of a width, or of a disc without one,
// from the top clockwise: an analytic shape, smooth at any size.
draw_arc :: proc(ctx:^Context,center:[2]f32,radius,width,sweep:f32,color:Color) {
    if radius<=0 || sweep<=0 || color[3]==0 {return}
    if sweep>=1 {
        if width>0 {draw_ring(ctx,center,radius,width,color)} else {draw_circle(ctx,center,radius,color)}
        return
    }
    c:=[4]f32{f32(color[0]),f32(color[1]),f32(color[2]),f32(color[3])}/255
    outer:=radius+width*0.5 if width>0 else radius
    shape:=Shape{bounds={center.x-outer,center.y-outer,outer*2,outer*2},params={0,1,sweep,0}}
    if width>0 {shape.stroke,shape.params.x=c,min(width,outer)} else {shape.fill=c}
    shape_emit(ctx,shape,ctx.draw.pixel)
}

// ---------------------------------------------------------------- textured quads and text

// A textured rectangle. Clipping moves the corners and their texture
// coordinates together.
draw_quad :: proc(ctx:^Context,rect,uv:Rect,color:Color,quad:u32) {
    d:=&ctx.draw
    clipped:=rect_intersect(rect,d.clip) if d.clipping else rect
    if clipped.w<=0 || clipped.h<=0 || rect.w<=0 || rect.h<=0 {return}
    if draw_outside(d,clipped.x,clipped.y,clipped.x+clipped.w,clipped.y+clipped.h) {return}
    out:=draw_reserve(d,6)
    if out==nil {return}
    u0:=uv.x+(clipped.x-rect.x)/rect.w*uv.w
    v0:=uv.y+(clipped.y-rect.y)/rect.h*uv.h
    u1:=u0+clipped.w/rect.w*uv.w
    v1:=v0+clipped.h/rect.h*uv.h
    x0,y0:=clipped.x,clipped.y;x1,y1:=x0+clipped.w,y0+clipped.h
    high:=draw_tint(d,color)
    low:=high
    if d.color2[3]>0 && d.band[1]>d.band[0] {
        other:=draw_tint(d,d.color2)
        high,low=high+(other-high)*clamp((y0-d.band[0])/(d.band[1]-d.band[0]),0,1),high+(other-high)*clamp((y1-d.band[0])/(d.band[1]-d.band[0]),0,1)
    }
    left,right:=f32(1),f32(1)
    if d.fade[1]>d.fade[0] {
        left=clamp((d.fade[1]-x0)/(d.fade[1]-d.fade[0]),0,1)
        right=clamp((d.fade[1]-x1)/(d.fade[1]-d.fade[0]),0,1)
    }
    // A sheared quad is clipped as the rectangle it leans from.
    top,bottom:=d.shear*(d.shear_base-y0),d.shear*(d.shear_base-y1)
    a:=Vertex{position=draw_point(d,{x0+top,y0}),color=high*left,quad=quad,uv={u0,v0}}
    b:=Vertex{position=draw_point(d,{x1+top,y0}),color=high*right,quad=quad,uv={u1,v0}}
    c:=Vertex{position=draw_point(d,{x1+bottom,y1}),color=low*right,quad=quad,uv={u1,v1}}
    e:=Vertex{position=draw_point(d,{x0+bottom,y1}),color=low*left,quad=quad,uv={u0,v1}}
    out[0],out[1],out[2],out[3],out[4],out[5]=a,b,c,a,c,e
}
draw_image :: proc(ctx:^Context,rect:Rect,image:Quad,tint:Color={255,255,255,255}) {
    if image.kind==.Solid {return}
    draw_quad(ctx,rect,image.uv,tint,quad_pack(image.kind,image.data))
}

// An image whose border keeps its size while the middle stretches. border:
// left, top, right and bottom, in layout units on the rectangle and as a
// fraction of the image in border_uv.
draw_nine_slice :: proc(ctx:^Context,rect:Rect,image:Quad,border,border_uv:[4]f32,tint:Color={255,255,255,255}) {
    if image.kind==.Solid || rect.w<=0 || rect.h<=0 {return}
    b:=border
    // Borders shrink together when the rectangle is smaller than both.
    if horizontal:=b[0]+b[2];horizontal>rect.w && horizontal>0 {b[0]*=rect.w/horizontal;b[2]*=rect.w/horizontal}
    if vertical:=b[1]+b[3];vertical>rect.h && vertical>0 {b[1]*=rect.h/vertical;b[3]*=rect.h/vertical}
    xs:=[4]f32{rect.x,rect.x+b[0],rect.x+rect.w-b[2],rect.x+rect.w}
    ys:=[4]f32{rect.y,rect.y+b[1],rect.y+rect.h-b[3],rect.y+rect.h}
    uv:=image.uv
    us:=[4]f32{uv.x,uv.x+border_uv[0]*uv.w,uv.x+(1-border_uv[2])*uv.w,uv.x+uv.w}
    vs:=[4]f32{uv.y,uv.y+border_uv[1]*uv.h,uv.y+(1-border_uv[3])*uv.h,uv.y+uv.h}
    quad:=quad_pack(image.kind,image.data)
    for row in 0..<3 {for column in 0..<3 {
        draw_quad(ctx,{xs[column],ys[row],xs[column+1]-xs[column],ys[row+1]-ys[row]},{us[column],vs[row],us[column+1]-us[column],vs[row+1]-vs[row]},tint,quad)
    }}
}

// Draws one run of text with its top-left corner at (x, y); a newline starts
// the next line TEXT_LINE sizes below. The pen advances in layout units with
// the kerning of the font; the baseline snaps to device pixels and each glyph
// to the nearest phase its face keeps. A glyph f lacks is drawn from the face
// of the font that has it, at the same size. A glyph the atlas does not have yet is
// asked for: the owner of the font rasterizes it then (Context_Desc.font_ask)
// or before the next frame, and until then it is left out.
draw_text :: proc(ctx:^Context,text:string,x,y,size:f32,color:Color,f:int=0) {
    font:=&ctx.font
    if !font.ready || size<=0 || f<0 || f>=font.font_count || color[3]==0 {return}
    d:=&ctx.draw
    ppu:=d.ppu
    pixels:=size*ppu
    // The faces of f and of the font that draws what f lacks (font_glyph), taken
    // when a glyph needs them.
    faces:[2]^Face
    face_from:=-1
    face:^Face
    face_index:int
    scale:f32
    exact:bool
    metrics:=&font.metrics[f]
    pen:=text_pen(font,size,f)
    at:=x
    baseline:=math.round(y*ppu+math.round(metrics.ascent*size*ppu))
    d.shear_base=baseline/ppu
    for character in text {
        kern,advance:=text_pen_step(&pen,character)
        if character=='\n' {at=x;baseline+=math.round(size*TEXT_LINE*ppu);d.shear_base=baseline/ppu;continue}
        at+=kern
        if pen.from!=face_from {
            other:=int(pen.from!=f)
            if faces[other]==nil {faces[other]=font_face(font,pen.from,pixels)}
            face,face_from=faces[other],pen.from
            if face==nil {return}
            // A size no face is close to is asked for: until it comes, the nearest one is scaled.
            if abs(face.pixel_size-pixels)>max(1,pixels*0.05) {font_face_ask(font,face_from,pixels)}
            face_index=mem.ptr_sub(face,&font.faces[0])
            scale=pixels/face.pixel_size // 1 when the face matches the size
            // A scaled face is resampled anyway: its glyphs only snap to whole pixels.
            exact=abs(scale-1)<1e-3
        }
        if index:=pen.previous;index>=0 {
            glyph:=&face.glyphs[index]
            if glyph.phases==0 {
                font_want(font,face_index,index)
                if ctx.font_ask!=nil {ctx.font_ask(ctx.font_user)}
            }
            if r:=glyph.bounds;glyph.phases>0 && r.w>0 && r.h>0 {
                // In 1/phases of a pixel: phases are 1, 2 or 4.
                phases:=i32(glyph.phases) if exact else 1
                position:=i32(math.round(at*ppu*f32(phases)))
                phase:=position&(phases-1)
                whole:=f32((position-phase)>>u32(phases>>1))
                uv:=glyph.uv
                uv.x+=f32(phase)*uv.w
                draw_quad(ctx,{(whole+r.x*scale)/ppu,(baseline+r.y*scale)/ppu,r.w*scale/ppu,r.h*scale/ppu},uv,color,d.font_quad)
            }
        }
        at+=advance
    }
}
