package ui

import "core:math"

// Vector icons drawn with the primitives of draw.odin on a 16 unit grid, so
// they stay sharp at any size and density. Values from Custom on are the
// drawings the context was given (icon_custom_set), and from User on they are
// drawn by Context.draw_user.
Icon :: enum u8 {
    None,Cube,Mesh,Light,Sun,Group,Prefab,Eye,Eye_Off,Plus,Cross,Play,Check,Import,Move,Rotate,Refresh,
    Checkbox,Checkbox_Checked,Scale,Grid,Sphere,Cylinder,Cone,Prism,Pyramid,Spot,Spawn,Stop,Relative,Absolute,
    Chevron_Down,Chevron_Right,Edit,Revert,Save_Prefab,Filter,Texture,Particles,
    Palette,Axis,Gauge,Sparkle,Lightning,Target,Layers,Split,Collider,Focus,Dot,History,Material,Chevron_Up,Sound,
    Rows,Text,Button,Slider,Field,List,Radio,Dropdown,Scroll,Spacer,
    Align_Left,Align_Center_X,Align_Right,Align_Top,Align_Center_Y,Align_Bottom,Link,Speech,Speech_Empty,
    Scene,Plane,Area_Light,Magnet,Copy,
    Custom=80,
    User=128,
}
icon_user :: proc "contextless" (index:u8) -> Icon {return Icon(u8(Icon.User)+index)}

ICON_PART_CAPACITY :: 6
ICON_POINT_CAPACITY :: 12
ICON_CUSTOM_CAPACITY :: 48

Icon_Part_Kind :: enum u8 {
    Line, // through its points
    Loop, // through its points and back to the first
    Fill, // the convex polygon of its points
    Disc, // around its first point
    Ring,
}

// A part of an icon given as data. Points are on the 16 unit grid of the
// icon, from its center, y downwards.
Icon_Part :: struct {
    kind:Icon_Part_Kind,
    count:u8,     // points of a Line, a Loop or a Fill
    shade:u8,     // percent of the color it is drawn with; 0: all of it
    width:f32,    // of the stroke of a Line, a Loop or a Ring, units
    radius:f32,   // of a Disc or a Ring, units
    points:[ICON_POINT_CAPACITY][2]f32,
}

// An icon as data: what a library that is no part of this one draws with.
Icon_Drawing :: struct {
    parts:[ICON_PART_CAPACITY]Icon_Part,
    count:u8,
}

icon_custom :: proc "contextless" (index:int) -> Icon {return Icon(int(Icon.Custom)+index)}

// A part of a drawing from its points; a Disc and a Ring take their center from the first.
icon_part :: proc "contextless" (kind:Icon_Part_Kind,points:[][2]f32,width:f32=1.3,radius:f32=0,shade:u8=0) -> (part:Icon_Part) {
    part.kind,part.width,part.radius,part.shade=kind,width,radius,shade
    part.count=u8(min(len(points),ICON_POINT_CAPACITY))
    copy(part.points[:],points)
    return
}

icon_drawing :: proc "contextless" (parts:..Icon_Part) -> (drawing:Icon_Drawing) {
    drawing.count=u8(min(len(parts),ICON_PART_CAPACITY))
    copy(drawing.parts[:],parts)
    return
}

// Gives the context the drawing of icon_custom(index). False out of its capacity.
icon_custom_set :: proc(ctx:^Context,index:int,drawing:Icon_Drawing) -> bool {
    if index<0 || index>=ICON_CUSTOM_CAPACITY {return false}
    ctx.icons[index]=drawing
    return true
}

@(private)
draw_icon_drawing :: proc(ctx:^Context,drawing:^Icon_Drawing,r:Rect,color:Color) {
    u:=min(r.w,r.h)/16
    c:=[2]f32{r.x+r.w/2,r.y+r.h/2}
    for &part in drawing.parts[:min(int(drawing.count),ICON_PART_CAPACITY)] {
        shaded:=part.shade>0?color_shade(color,f32(part.shade)/100):color
        points:[ICON_POINT_CAPACITY][2]f32
        count:=min(int(part.count),ICON_POINT_CAPACITY)
        for point,i in part.points[:count] {points[i]=c+point*u}
        width:=max(part.width*u,1)
        switch part.kind {
        case .Line: if count>=2 {draw_polyline(ctx,points[:count],width,shaded)}
        case .Loop: if count>=3 {draw_polyline(ctx,points[:count],width,shaded,true)}
        case .Fill: for i in 2..<count {draw_triangle(ctx,points[0],points[i-1],points[i],shaded)}
        case .Disc: draw_circle(ctx,c+part.points[0]*u,part.radius*u,shaded)
        case .Ring: draw_ring(ctx,c+part.points[0]*u,part.radius*u,width,shaded)
        }
    }
}

// Points of an arc of an ellipse from one angle to another, in degrees, y downwards.
@(private="file")
icon_arc :: proc(center:[2]f32,rx,ry,from,to:f32) -> (points:[17][2]f32) {
    for &p,i in points {a:=math.to_radians(from+(to-from)*f32(i)/16);p=center+{math.cos(a)*rx,math.sin(a)*ry}}
    return
}

draw_icon :: proc(ctx:^Context,icon:Icon,r:Rect,color:Color) {
    if icon>=.User {
        if ctx.draw_user!=nil {ctx.draw_user(ctx.draw_user_data,ctx,{name=u64(icon)-u64(Icon.User),rect=r,fill=color,item=-1})}
        return
    }
    if icon>=.Custom {
        if index:=int(icon)-int(Icon.Custom);index<ICON_CUSTOM_CAPACITY {draw_icon_drawing(ctx,&ctx.icons[index],r,color)}
        return
    }
    s:=min(r.w,r.h);c:=[2]f32{r.x+r.w/2,r.y+r.h/2};u:=s/16
    // Objects of a scene share one line drawing: a stroke that grows with the
    // icon and a faint fill on the face that faces up.
    line:=max(1.4*u,1.2)
    face:=color_alpha(color,u8(f32(color[3])*0.28))
    #partial switch icon {
    case .Cube,.Prefab:
        top,tr,br,bottom,bl,tl,mid:=c+{0,-7*u},c+{6.5*u,-3.5*u},c+{6.5*u,4*u},c+{0,7.5*u},c+{-6.5*u,4*u},c+{-6.5*u,-3.5*u},c+{0,0}
        // A prefab is the cube with its top face solid: one look for the
        // asset, an instance in the scene and its actions.
        draw_quad_colors(ctx,{top,tr,mid,tl},icon==.Prefab?{color,color,color,color}:{face,face,face,face})
        draw_polyline(ctx,{top,tr,br,bottom,bl,tl},line,color,true)
        draw_line(ctx,mid,tl,line,color);draw_line(ctx,mid,tr,line,color);draw_line(ctx,mid,bottom,line,color)
    case .Mesh:
        // A net of triangles around one vertex, its corners marked.
        ring:=[5][2]f32{c+{0,-7*u},c+{6.5*u,-2.5*u},c+{4.5*u,6*u},c+{-4*u,6.5*u},c+{-7*u,-0.5*u}}
        m:=c+{0,u}
        draw_polyline(ctx,ring[:],line,color,true)
        for p in ring {draw_line(ctx,m,p,line*0.7,color)}
        for p in ring {draw_circle(ctx,p,1.5*u,color)}
        draw_circle(ctx,m,1.5*u,color)
    case .Light:
        bulb:[13][2]f32
        for &p,i in bulb {a:=math.to_radians(f32(225)-f32(270)*f32(i)/12);p=c+{0,-1.5*u}+[2]f32{math.cos(a),-math.sin(a)}*5*u}
        draw_polyline(ctx,bulb[:],line,color)
        draw_line(ctx,bulb[0],c+{-2.5*u,4*u},line,color);draw_line(ctx,bulb[12],c+{2.5*u,4*u},line,color)
        draw_line(ctx,c+{-2.5*u,4.5*u},c+{2.5*u,4.5*u},line,color)
        draw_line(ctx,c+{-1.5*u,7*u},c+{1.5*u,7*u},line,color)
    case .Area_Light:
        draw_rounded(ctx,{c.x-6.5*u,c.y-7*u,13*u,6*u},1.2*u,face)
        draw_rounded_stroke(ctx,{c.x-6.5*u,c.y-7*u,13*u,6*u},1.2*u,line,color)
        for x in ([3]f32{-4,0,4}) {draw_line(ctx,c+{x*u,1.5*u},c+{x*1.4*u,6.5*u},line,color)}
    case .Plane:
        quad:=[4][2]f32{c+{0,-4.5*u},c+{7.5*u,0},c+{0,4.5*u},c+{-7.5*u,0}}
        draw_quad_colors(ctx,quad,{face,face,face,face})
        draw_polyline(ctx,quad[:],line,color,true)
        draw_line(ctx,c+{-3.75*u,-2.25*u},c+{3.75*u,2.25*u},line*0.6,color)
        draw_line(ctx,c+{3.75*u,-2.25*u},c+{-3.75*u,2.25*u},line*0.6,color)
    case .Scene:
        // A folded map.
        sheet:=[8][2]f32{c+{-7*u,-5*u},c+{-2.3*u,-7*u},c+{2.3*u,-5*u},c+{7*u,-7*u},c+{7*u,5*u},c+{2.3*u,7*u},c+{-2.3*u,5*u},c+{-7*u,7*u}}
        draw_quad_colors(ctx,{sheet[1],sheet[2],sheet[5],sheet[6]},{face,face,face,face})
        draw_polyline(ctx,sheet[:],line,color,true)
        draw_line(ctx,sheet[1],sheet[6],line,color);draw_line(ctx,sheet[2],sheet[5],line,color)
    case .Particles:
        centers:=[3][2]f32{c+{-2*u,1*u},c+{4.5*u,-4.5*u},c+{5*u,5*u}}
        radii:=[3]f32{5.2*u,2.6*u,1.9*u}
        for center,i in centers {
            r:=radii[i];k:=r*.27
            points:=[8][2]f32{center+{0,-r},center+{k,-k},center+{r,0},center+{k,k},center+{0,r},center+{-k,k},center+{-r,0},center+{-k,-k}}
            draw_polyline(ctx,points[:],1.2*u,color,true)
        }
    case .Sun:
        draw_circle(ctx,c,3.5*u,color)
        for i in 0..<8 {
            a:=f32(i)*math.PI/4;d:=[2]f32{math.cos(a),math.sin(a)}
            draw_line(ctx,c+d*5.5*u,c+d*7.5*u,1.5,color)
        }
    case .Group:
        // The corners of a selection around the entities it holds.
        for corner in ([4][2]f32{{-1,-1},{1,-1},{1,1},{-1,1}}) {
            draw_polyline(ctx,{c+{corner.x*7,corner.y*3.5}*u,c+corner*7*u,c+{corner.x*3.5,corner.y*7}*u},line,color)
        }
        draw_rounded(ctx,{c.x-3.5*u,c.y-3.5*u,3*u,3*u},0.8*u,color)
        draw_rounded(ctx,{c.x+0.5*u,c.y-3.5*u,3*u,3*u},0.8*u,color)
        draw_rounded(ctx,{c.x-3.5*u,c.y+0.5*u,7*u,3*u},0.8*u,color)
    case .Eye,.Eye_Off:
        points:[17][2]f32
        for i in 0..<9 {t:=f32(i)/8;x:=(t*2-1)*7*u;h:=(1-(t*2-1)*(t*2-1))*4.5*u;points[i]=c+{x,-h};points[16-i]=c+{x,h}}
        draw_polyline(ctx,points[:16],1.5,color,true)
        draw_circle(ctx,c,2.2*u,color)
        if icon==.Eye_Off {draw_line(ctx,c+{-7*u,-6*u},c+{7*u,6*u},1.8,color)}
    case .Plus:
        draw_line(ctx,c+{-5*u,0},c+{5*u,0},1.8,color);draw_line(ctx,c+{0,-5*u},c+{0,5*u},1.8,color)
    case .Cross:
        draw_line(ctx,c+{-4*u,-4*u},c+{4*u,4*u},1.6,color);draw_line(ctx,c+{4*u,-4*u},c+{-4*u,4*u},1.6,color)
    case .Play:
        draw_triangle(ctx,c+{-4*u,-6*u},c+{6*u,0},c+{-4*u,6*u},color)
    case .Stop:
        draw_rounded(ctx,{c.x-5*u,c.y-5*u,10*u,10*u},1.5*u,color)
    case .Check:
        points:=[3][2]f32{c+{-5*u,0},c+{-1.5*u,4*u},c+{5.5*u,-4.5*u}}
        draw_polyline(ctx,points[:],1.8,color)
    case .Checkbox,.Checkbox_Checked:
        draw_rounded_stroke(ctx,{c.x-6*u,c.y-6*u,12*u,12*u},1.5*u,1.3,color)
        if icon==.Checkbox_Checked {
            points:=[3][2]f32{c+{-3.5*u,0},c+{-0.8*u,2.7*u},c+{3.5*u,-2.8*u}}
            draw_polyline(ctx,points[:],1.5,color)
        }
    case .Filter:
        points:=[6][2]f32{c+{-6*u,-5*u},c+{6*u,-5*u},c+{1.5*u,0.5*u},c+{1.5*u,5.5*u},c+{-1.5*u,4*u},c+{-1.5*u,0.5*u}}
        draw_polyline(ctx,points[:],1.5,color,true)
    case .Save_Prefab:
        // Leave the lower-right corner open for the outlined cube badge.
        body:=[6][2]f32{c+{-1*u,7*u},c+{-7*u,7*u},c+{-7*u,-7*u},c+{3*u,-7*u},c+{5*u,-5*u},c+{5*u,-1*u}}
        draw_polyline(ctx,body[:],1.3*u,color)
        slot:=[4][2]f32{c+{-4*u,-7*u},c+{-4*u,-3*u},c+{2*u,-3*u},c+{2*u,-7*u}}
        draw_polyline(ctx,slot[:],1.2*u,color)
        label:=[4][2]f32{c+{-4*u,7*u},c+{-4*u,1*u},c+{-1*u,1*u},c+{-1*u,5*u}}
        draw_polyline(ctx,label[:],1.2*u,color)
        top,left,right,mid:=c+{3.5*u,0.5*u},c+{0,2.5*u},c+{7*u,2.5*u},c+{3.5*u,4.5*u}
        bottom,bl,br:=c+{3.5*u,8*u},c+{0,6*u},c+{7*u,6*u}
        cube:=[6][2]f32{top,right,br,bottom,bl,left}
        draw_polyline(ctx,cube[:],1.2*u,color,true)
        draw_line(ctx,left,mid,1.2*u,color);draw_line(ctx,right,mid,1.2*u,color);draw_line(ctx,mid,bottom,1.2*u,color)
    case .Import:
        draw_line(ctx,c+{0,-7*u},c+{0,2*u},1.6,color)
        draw_line(ctx,c+{-3.5*u,-1.5*u},c+{0,2*u},1.6,color);draw_line(ctx,c+{3.5*u,-1.5*u},c+{0,2*u},1.6,color)
        points:=[4][2]f32{c+{-6.5*u,1*u},c+{-6.5*u,6.5*u},c+{6.5*u,6.5*u},c+{6.5*u,1*u}}
        draw_polyline(ctx,points[:],1.6,color)
    case .Move:
        draw_line(ctx,c+{-7*u,0},c+{7*u,0},1.5,color);draw_line(ctx,c+{0,-7*u},c+{0,7*u},1.5,color)
        for d in ([4][2]f32{{1,0},{-1,0},{0,1},{0,-1}}) {
            tip:=c+d*7*u;p:=[2]f32{-d.y,d.x}
            draw_triangle(ctx,tip+d*1*u,tip-d*3*u+p*2.5*u,tip-d*3*u-p*2.5*u,color)
        }
    case .Rotate,.Refresh:
        points:[13][2]f32
        for i in 0..<13 {a:=math.PI*(-0.15+1.55*f32(i)/12);points[i]=c+[2]f32{math.cos(a),math.sin(a)}*5.5*u}
        draw_polyline(ctx,points[:],1.6,color)
        tip:=points[12];d:=points[12]-points[11]
        d/=math.sqrt(d.x*d.x+d.y*d.y)
        p:=[2]f32{-d.y,d.x}
        draw_triangle(ctx,tip+d*3*u,tip-p*3*u,tip+p*3*u,color)
    case .Revert:
        points:=[4][2]f32{c+{-6*u,-2*u},c+{2*u,-2*u},c+{5*u,1*u},c+{5*u,5*u}}
        draw_polyline(ctx,points[:],1.5,color)
        draw_line(ctx,c+{-6*u,-2*u},c+{-2*u,-6*u},1.5,color)
        draw_line(ctx,c+{-6*u,-2*u},c+{-2*u,2*u},1.5,color)
    case .Edit:
        d:=[2]f32{1,-1}/math.sqrt(f32(2));p:=[2]f32{1,1}/math.sqrt(f32(2))
        lo,hi:=c-d*5*u,c+d*6*u
        draw_quad_colors(ctx,{lo-p*1.8*u,hi-p*1.8*u,hi+p*1.8*u,lo+p*1.8*u},{color,color,color,color})
        draw_triangle(ctx,lo-p*1.8*u,lo+p*1.8*u,lo-d*3*u,color)
    case .Scale:
        draw_rounded_stroke(ctx,{c.x-7*u,c.y-1*u,8*u,8*u},1,1.5,color)
        draw_line(ctx,c+{-1*u,1*u},c+{6*u,-6*u},1.5,color)
        draw_line(ctx,c+{6*u,-6*u},c+{1.5*u,-6*u},1.5,color);draw_line(ctx,c+{6*u,-6*u},c+{6*u,-1.5*u},1.5,color)
    case .Grid:
        for i in 0..<3 {
            o:=(f32(i)-1)*4.5*u
            draw_line(ctx,c+{-7*u,o},c+{7*u,o},1.2,color);draw_line(ctx,c+{o,-7*u},c+{o,7*u},1.2,color)
        }
    // A horseshoe open upwards, its two poles solid above its arms.
    case .Magnet:
        outer:=icon_arc(c+{0,0.5*u},6.5*u,6.5*u,180,0)
        inner:=icon_arc(c+{0,0.5*u},2.5*u,2.5*u,0,180)
        body:[38][2]f32
        body[0],body[18],body[19],body[37]=c+{-6.5*u,-3*u},c+{6.5*u,-3*u},c+{2.5*u,-3*u},c+{-2.5*u,-3*u}
        copy(body[1:18],outer[:]);copy(body[20:37],inner[:])
        draw_polyline(ctx,body[:],1.3*u,color,true)
        // Round joints: the segments of a curve leave seams between their ends at large sizes.
        for p in body {draw_circle(ctx,p,0.65*u,color)}
        for x in ([2]f32{-7.15,1.85}) {draw_rounded(ctx,{c.x+x*u,c.y-7.5*u,5.3*u,2.9*u},0.6*u,color)}
    // Filled triangles: they read at the small sizes of rows and menus.
    case .Chevron_Down:
        draw_triangle(ctx,c+{-5*u,-2.5*u},c+{5*u,-2.5*u},c+{0,2.5*u},color)
    case .Chevron_Right:
        draw_triangle(ctx,c+{-2.5*u,-5*u},c+{2.5*u,0},c+{-2.5*u,5*u},color)
    case .Chevron_Up:
        draw_triangle(ctx,c+{0,-2.5*u},c+{5*u,2.5*u},c+{-5*u,2.5*u},color)
    // A parent box with a child hanging from it.
    case .Relative:
        draw_rounded_stroke(ctx,{c.x-7*u,c.y-7*u,6*u,6*u},1,1.5,color)
        elbow:=[3][2]f32{c+{-4*u,-1*u},c+{-4*u,4*u},c+{0.5*u,4*u}}
        draw_polyline(ctx,elbow[:],1.5,color)
        draw_rect(ctx,{c.x+1*u,c.y+1*u,6*u,6*u},color)
    // A globe.
    case .Absolute:
        draw_ring(ctx,c,6.5*u,1.5,color)
        draw_line(ctx,c+{-6.5*u,0},c+{6.5*u,0},1.2,color)
        meridian:[16][2]f32
        for i in 0..<16 {a:=2*math.PI*f32(i)/16;meridian[i]=c+{math.cos(a)*3*u,math.sin(a)*6.5*u}}
        draw_polyline(ctx,meridian[:],1.2,color,true)
    case .Sphere:
        draw_circle(ctx,c,7*u,face)
        draw_ring(ctx,c,7*u,line,color)
        equator,meridian:=icon_arc(c,7*u,2.6*u,0,180),icon_arc(c,2.6*u,7*u,-90,90)
        draw_polyline(ctx,equator[:],line,color)
        draw_polyline(ctx,meridian[:],line*0.7,color)
    case .Cylinder:
        draw_ellipse(ctx,c+{0,-4.5*u},6*u,2.2*u,face)
        lid,base:=icon_arc(c+{0,-4.5*u},6*u,2.2*u,0,360),icon_arc(c+{0,4.5*u},6*u,2.2*u,0,180)
        draw_polyline(ctx,lid[:],line,color,true)
        draw_line(ctx,c+{-6*u,-4.5*u},c+{-6*u,4.5*u},line,color);draw_line(ctx,c+{6*u,-4.5*u},c+{6*u,4.5*u},line,color)
        draw_polyline(ctx,base[:],line,color)
    case .Cone:
        apex:=c+{0,-7.5*u}
        front,back:=icon_arc(c+{0,4.5*u},6.5*u,2.2*u,0,180),icon_arc(c+{0,4.5*u},6.5*u,2.2*u,180,360)
        draw_polyline(ctx,front[:],line,color)
        draw_polyline(ctx,back[:],line*0.6,color_alpha(color,140))
        draw_line(ctx,apex,c+{-6.5*u,4.5*u},line,color);draw_line(ctx,apex,c+{6.5*u,4.5*u},line,color)
    case .Prism:
        f1,f2,f3:=c+{-7*u,6*u},c+{2*u,6*u},c+{-2.5*u,-2*u}
        d:=[2]f32{5*u,-3.5*u}
        draw_quad_colors(ctx,{f3,f3+d,f2+d,f2},{face,face,face,face})
        draw_polyline(ctx,{f1,f2,f3},line,color,true)
        draw_polyline(ctx,{f3,f3+d,f2+d,f2},line,color)
    case .Pyramid:
        apex,left,front,right:=c+{0,-7.5*u},c+{-7*u,3.5*u},c+{-1*u,7*u},c+{7*u,3*u}
        draw_triangle(ctx,apex,left,front,face)
        draw_polyline(ctx,{apex,left,front,right},line,color,true)
        draw_line(ctx,apex,front,line,color)
    case .Spot:
        draw_rounded_stroke(ctx,{c.x-3.5*u,c.y-7.5*u,7*u,4.5*u},u,line,color)
        draw_quad_colors(ctx,{c+{-2.5*u,-3*u},c+{2.5*u,-3*u},c+{6.5*u,7*u},c+{-6.5*u,7*u}},{face,face,color_alpha(color,0),color_alpha(color,0)})
        draw_line(ctx,c+{-2.5*u,-3*u},c+{-6.5*u,7*u},line*0.8,color);draw_line(ctx,c+{2.5*u,-3*u},c+{6.5*u,7*u},line*0.8,color)
    case .Spawn:
        draw_line(ctx,c+{-4.5*u,-7.5*u},c+{-4.5*u,7*u},1.6,color)
        draw_triangle(ctx,c+{-4.5*u,-7.5*u},c+{6.5*u,-4*u},c+{-4.5*u,-0.5*u},color)
        draw_ellipse(ctx,c+{-4.5*u,7*u},3.5*u,1.2*u,color_alpha(color,140))
    // The icons of the prototype drawn on a 24 unit grid, at two thirds.
    case .Palette:
        draw_ring(ctx,c,6*u,1.5*u,color)
        for p in ([3][2]f32{{-3,-2},{1,-3.5},{3,0}}) {draw_circle(ctx,c+p*u,u,color)}
    case .Gauge:
        arc:[17][2]f32
        for &p,i in arc {a:=math.to_radians(f32(149)+f32(242)*f32(i)/16);p=c+([2]f32{math.cos(a),math.sin(a)}*7+{0,1.4})*u}
        draw_polyline(ctx,arc[:],1.5*u,color)
        draw_line(ctx,c,c+{4*u,-3*u},1.5*u,color)
        for tick in ([4][2][2]f32{{{-6,1},{-4,1}},{{-3,-5},{-2,-3}},{{3,-5},{2,-3}},{{4,1},{6,1}}}) {draw_line(ctx,c+tick[0]*u,c+tick[1]*u,1.5*u,color)}
        draw_circle(ctx,c,u,color)
    case .Axis:
        o:=c+{-5.33*u,5.33*u}
        draw_line(ctx,o,c+{-5.33*u,-5.33*u},1.3*u,color)
        draw_line(ctx,o,c+{5.33*u,5.33*u},1.3*u,color)
        draw_line(ctx,o,c+{0.67*u,-0.67*u},1.3*u,color)
    case .Sparkle:
        big:=[8][2]f32{{0,-6},{1.27,-2.6},{4.67,-1.33},{1.27,-0.07},{0,3.33},{-1.27,-0.07},{-4.67,-1.33},{-1.27,-2.6}}
        small:=[8][2]f32{{4.67,2},{5.2,3.47},{6.67,4},{5.2,4.53},{4.67,6},{4.13,4.53},{2.67,4},{4.13,3.47}}
        for &p in big {p=c+p*u}
        for &p in small {p=c+p*u}
        draw_polyline(ctx,big[:],1.3*u,color,true)
        draw_polyline(ctx,small[:],1.1*u,color,true)
    case .Lightning:
        bolt:=[6][2]f32{{0.67,-6.67},{-5.33,1.33},{-0.67,1.33},{-1.33,6.67},{5.33,-2},{0.67,-2}}
        for &p in bolt {p=c+p*u}
        draw_polyline(ctx,bolt[:],1.3*u,color,true)
    case .Target:
        draw_ring(ctx,c,6*u,1.3*u,color)
        draw_ring(ctx,c,3.33*u,1.3*u,color)
        draw_circle(ctx,c,0.9*u,color)
    case .Layers:
        top:=[4][2]f32{{0,-6.67},{6.67,-3.33},{0,0},{-6.67,-3.33}}
        middle:=[3][2]f32{{-6.67,0},{0,3.33},{6.67,0}}
        bottom:=[3][2]f32{{-6.67,3.33},{0,6.67},{6.67,3.33}}
        for &p in top {p=c+p*u}
        for &p in middle {p=c+p*u}
        for &p in bottom {p=c+p*u}
        draw_polyline(ctx,top[:],1.3*u,color,true)
        draw_polyline(ctx,middle[:],1.3*u,color)
        draw_polyline(ctx,bottom[:],1.3*u,color)
    case .Copy:
        // A sheet over the one it copies.
        draw_polyline(ctx,{c+{-2.5*u,2.5*u},c+{-6*u,2.5*u},c+{-6*u,-6*u},c+{2.5*u,-6*u},c+{2.5*u,-2.5*u}},1.3*u,color)
        draw_rounded_stroke(ctx,{c.x-2.5*u,c.y-2.5*u,8.5*u,8.5*u},1.33*u,1.3*u,color)
    case .Split:
        draw_rounded_stroke(ctx,{c.x-6*u,c.y-6*u,12*u,12*u},1.33*u,1.3*u,color)
        draw_line(ctx,c+{0,-6*u},c+{0,6*u},1.3*u,color)
        draw_line(ctx,c+{-6*u,0},c+{6*u,0},1.3*u,color)
    // The outline of a box as dashes.
    case .Collider:
        e,k:=f32(5.33),f32(3.2)
        for corner in ([4][2]f32{{-1,-1},{1,-1},{1,1},{-1,1}}) {
            bend:=[3][2]f32{c+{corner.x*e,corner.y*k}*u,c+corner*e*u,c+{corner.x*k,corner.y*e}*u}
            draw_polyline(ctx,bend[:],1.3*u,color)
        }
        for side in ([4][2]f32{{0,-1},{1,0},{0,1},{-1,0}}) {
            along:=[2]f32{-side.y,side.x}
            draw_line(ctx,c+(side*e-along*1.1)*u,c+(side*e+along*1.1)*u,1.3*u,color)
        }
    case .Focus:
        draw_ring(ctx,c,2*u,1.3*u,color)
        for corner in ([4][2]f32{{-1,-1},{1,-1},{1,1},{-1,1}}) {
            bend:=[4][2]f32{c+{corner.x*6,corner.y*3.33}*u,c+{corner.x*6,corner.y*4.67}*u,c+corner*5.6*u,c+{corner.x*4.67,corner.y*6}*u}
            tail:=[2][2]f32{bend[3],c+{corner.x*3.33,corner.y*6}*u}
            draw_polyline(ctx,bend[:],1.3*u,color)
            draw_polyline(ctx,tail[:],1.3*u,color)
        }
    case .Dot:
        draw_circle(ctx,c,2.67*u,color)
    // A clock whose rim turns back.
    case .History:
        rim:[17][2]f32
        for &p,i in rim {a:=math.to_radians(f32(180)-f32(311.8)*f32(i)/16);p=c+[2]f32{math.cos(a),math.sin(a)}*6*u}
        draw_polyline(ctx,rim[:],1.3*u,color)
        corner:=[3][2]f32{c+{-6*u,-6*u},c+{-6*u,-2.67*u},c+{-2.67*u,-2.67*u}}
        draw_polyline(ctx,corner[:],1.3*u,color)
        draw_line(ctx,rim[16],c+{-6*u,-2.67*u},1.3*u,color)
        hands:=[3][2]f32{c+{0,-3.33*u},c,c+{2.67*u,1.33*u}}
        draw_polyline(ctx,hands[:],1.3*u,color)
    case .Material:
        draw_ring(ctx,c,6*u,1.3*u,color)
        shine:=[4][2]f32{c+{-3*u,-1.67*u},c+{-2.5*u,-2.7*u},c+{-1.5*u,-3.4*u},c+{-0.33*u,-3.67*u}}
        draw_polyline(ctx,shine[:],1.3*u,color)
    // A speaker and the waves it gives.
    case .Sound:
        draw_quad_colors(ctx,{c+{-7*u,-2.5*u},c+{-3.5*u,-2.5*u},c+{-3.5*u,2.5*u},c+{-7*u,2.5*u}},{color,color,color,color})
        draw_quad_colors(ctx,{c+{-3.5*u,-2.5*u},c+{u,-6.5*u},c+{u,6.5*u},c+{-3.5*u,2.5*u}},{color,color,color,color})
        for radius in ([2]f32{3.5,6.5}) {
            arc:[9][2]f32
            for &p,i in arc {a:=math.to_radians(f32(-50)+f32(100)*f32(i)/8);p=c+{u,0}+[2]f32{math.cos(a),math.sin(a)}*radius*u}
            draw_polyline(ctx,arc[:],1.3*u,color)
        }
    // A picture in its frame: the sun over two hills.
    case .Texture:
        draw_rounded_stroke(ctx,{c.x-7*u,c.y-6*u,14*u,12*u},1.5*u,1.4,color)
        draw_circle(ctx,c+{-3.3*u,-2.5*u},1.5*u,color)
        hills:=[5][2]f32{c+{-6.3*u,4*u},c+{-3.2*u,1.2*u},c+{-1.2*u,3*u},c+{2.6*u,-1.2*u},c+{6.3*u,3.2*u}}
        draw_polyline(ctx,hills[:],1.4,color)
    // The widgets of an interface, as their kinds look.
    case .Rows:
        draw_rounded_stroke(ctx,{c.x-6*u,c.y-6*u,12*u,12*u},1.33*u,1.3*u,color)
        draw_line(ctx,c+{-6*u,0},c+{6*u,0},1.3*u,color)
    case .Text:
        draw_line(ctx,c+{-5*u,-5.5*u},c+{5*u,-5.5*u},1.8*u,color)
        draw_line(ctx,c+{0,-5.5*u},c+{0,6*u},1.8*u,color)
    case .Button:
        draw_rounded_stroke(ctx,{c.x-7*u,c.y-4*u,14*u,8*u},2.5*u,1.3*u,color)
        draw_line(ctx,c+{-3*u,0},c+{3*u,0},1.5*u,color)
    case .Slider:
        draw_line(ctx,c+{-7*u,0},c+{7*u,0},1.3*u,color)
        draw_circle(ctx,c+{-1.5*u,0},2.8*u,color)
    case .Field:
        draw_rounded_stroke(ctx,{c.x-7*u,c.y-4*u,14*u,8*u},1.33*u,1.3*u,color)
        draw_line(ctx,c+{-3.5*u,-2*u},c+{-3.5*u,2*u},1.3*u,color)
    case .List:
        for y in ([3]f32{-4.5,0,4.5}) {
            draw_circle(ctx,c+{-5.5*u,y*u},1.2*u,color)
            draw_line(ctx,c+{-2.5*u,y*u},c+{6.5*u,y*u},1.3*u,color)
        }
    case .Radio:
        draw_ring(ctx,c,6*u,1.3*u,color)
        draw_circle(ctx,c,2.6*u,color)
    case .Dropdown:
        draw_rounded_stroke(ctx,{c.x-7*u,c.y-4*u,14*u,8*u},1.33*u,1.3*u,color)
        draw_triangle(ctx,c+{1.5*u,-1.2*u},c+{4.5*u,-1.2*u},c+{3*u,1.3*u},color)
    case .Scroll:
        draw_rounded_stroke(ctx,{c.x-7*u,c.y-7*u,14*u,14*u},1.33*u,1.3*u,color)
        draw_line(ctx,c+{3*u,-7*u},c+{3*u,7*u},1.3*u,color)
        draw_rounded(ctx,{c.x+4*u,c.y-5*u,2*u,5*u},0.8*u,color)
    // A line where the content aligns and two bars of the content.
    case .Align_Left,.Align_Center_X,.Align_Right:
        x:=f32(-6) if icon==.Align_Left else 6 if icon==.Align_Right else 0
        draw_line(ctx,c+{x*u,-7*u},c+{x*u,7*u},1.3*u,color)
        for bar in ([2][2]f32{{-3.5,9},{1.5,5}}) {
            w:=bar[1]
            left:=x+1.5 if icon==.Align_Left else x-1.5-w if icon==.Align_Right else -w/2
            draw_rounded(ctx,{c.x+left*u,c.y+(bar[0]-1)*u,w*u,3*u},0.6*u,color)
        }
    case .Align_Top,.Align_Center_Y,.Align_Bottom:
        y:=f32(-6) if icon==.Align_Top else 6 if icon==.Align_Bottom else 0
        draw_line(ctx,c+{-7*u,y*u},c+{7*u,y*u},1.3*u,color)
        for bar in ([2][2]f32{{-3.5,9},{1.5,5}}) {
            h:=bar[1]
            top:=y+1.5 if icon==.Align_Top else y-1.5-h if icon==.Align_Bottom else -h/2
            draw_rounded(ctx,{c.x+(bar[0]-1)*u,c.y+top*u,3*u,h*u},0.6*u,color)
        }
    // Two links of a chain, across.
    // A bubble of speech with a tail: a text of the game in its languages.
    case .Speech,.Speech_Empty:
        draw_rounded_stroke(ctx,{c.x-7*u,c.y-6*u,14*u,9.5*u},3*u,1.3*u,color)
        draw_polyline(ctx,{c+{-3.5*u,3.5*u},c+{-4.5*u,6.5*u},c+{-0.5*u,3.5*u}},1.3*u,color)
        if icon==.Speech {
            draw_line(ctx,c+{-3.5*u,-2.5*u},c+{3.5*u,-2.5*u},1.2*u,color)
            draw_line(ctx,c+{-3.5*u,0},c+{1.5*u,0},1.2*u,color)
        }
    case .Link:
        for side in ([2]f32{-1,1}) {
            loop:[13][2]f32
            middle:=[2]f32{side*2.4,-side*2.4}
            along:=[2]f32{0.7071,-0.7071}
            across:=[2]f32{0.7071,0.7071}
            for &p,i in loop {
                a:=f32(i)/12*2*math.PI
                p=c+(middle+along*math.cos(a)*4.6+across*math.sin(a)*2.2)*u
            }
            draw_polyline(ctx,loop[:12],1.4*u,color,true)
        }
    case .Spacer:
        draw_line(ctx,c+{-6.5*u,-5*u},c+{-6.5*u,5*u},1.3*u,color)
        draw_line(ctx,c+{6.5*u,-5*u},c+{6.5*u,5*u},1.3*u,color)
        draw_line(ctx,c+{-4*u,0},c+{4*u,0},1.3*u,color)
        draw_triangle(ctx,c+{-4.5*u,0},c+{-2*u,-2*u},c+{-2*u,2*u},color)
        draw_triangle(ctx,c+{4.5*u,0},c+{2*u,2*u},c+{2*u,-2*u},color)
    }
}
