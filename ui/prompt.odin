package ui

import "core:math"

// The prompt of an input, drawn as the device the player holds shows it: a
// key is a cap with its name, a mouse lights its button and a gamepad button
// carries the mark of its family. Drawn with the analytic shapes, so it stays
// sharp at any size and needs no texture.

Prompt_Family :: enum u8 {Keyboard,Xbox,PlayStation,Nintendo}

Prompt_Input :: enum u8 {
    Key, // Prompt.text names it
    Mouse_Left,Mouse_Right,Mouse_Middle,Mouse_Move,Mouse_Wheel,
    South,East,West,North,
    Shoulder_Left,Shoulder_Right,Trigger_Left,Trigger_Right,
    Stick_Left,Stick_Right,Stick_Left_Press,Stick_Right_Press,
    Dpad,Dpad_Up,Dpad_Down,Dpad_Left,Dpad_Right,
    Start,Back,
    Plus, // between the inputs of a chord, held together
}

Prompt :: struct {
    family:Prompt_Family, // of a gamepad input; keys and mouse look the same in every family
    input:Prompt_Input,
    text:string, // the name of a Key
    quad:Quad,   // the image a pack of prompts has for it; with none (.Solid) it is drawn
    aspect:f32,  // width over height of that image; 0 is 1
}
PROMPT_CAPACITY :: 8 // inputs of one action that are shown


// The prompts of an action (name_hash of its name) side by side, as high as
// a fixed height of the layout or one and a half times the size of the text.
// Without any, nothing: a text next to it is a node of its own.
prompt :: proc(ctx:^Context,id:Id,action:u64,style:Text_Style,layout:Layout) {
    found:[PROMPT_CAPACITY]Prompt
    count:=0
    if game:=&ctx.game;game.prompts!=nil && action!=0 {count=game.prompts(game.user,action,game.family,found[:])}
    height:=layout.height.value if layout.height.kind==.Fixed else max(style.size,12)*1.5
    if count==0 {return}
    widget_add(ctx,id,{.Passive})
    if !element_open(ctx,{id=id,layout={width=layout.width,height=fixed(height),direction=.Row,gap=height*0.12,align_y=.Center}}) {return}
    for shown in found[:count] {prompt_glyph(ctx,shown,height)}
    element_close(ctx)
}

// The prompts of an action as boxes in the line of the text begun, as high as height.
@(private)
prompt_boxes :: proc(ctx:^Context,action:u64,height:f32) {
    found:[PROMPT_CAPACITY]Prompt
    count:=0
    if game:=&ctx.game;game.prompts!=nil && action!=0 {count=game.prompts(game.user,action,game.family,found[:])}
    for shown,i in found[:count] {
        p:=shown
        if p.quad.kind==.Solid {p.text=text_store(ctx,p.text)}
        width:=height*p.aspect if p.quad.kind!=.Solid && p.aspect>0 else prompt_width(ctx,p,height)
        text_box(ctx,width,height,{kind=.Prompt,prompt=p},gap=height*0.12 if i<count-1 else 0)
    }
}

// One prompt as a leaf of the layout, as high as height: the image of its
// pack, or else its drawing.
prompt_glyph :: proc(ctx:^Context,p:Prompt,height:f32) {
    p:=p
    if p.quad.kind==.Solid {p.text=text_store(ctx,p.text)}
    width:=height*p.aspect if p.quad.kind!=.Solid && p.aspect>0 else prompt_width(ctx,p,height)
    element_leaf(ctx,{layout={width=fixed(width),height=fixed(height)},custom=paint_add(ctx,{kind=.Prompt,prompt=p})})
}

// A prompt where the layout placed it: the image of its pack, or its drawing.
@(private)
prompt_paint :: proc(ctx:^Context,r:Rect,p:Prompt) {
    if p.quad.kind!=.Solid {
        draw_image(ctx,r,p.quad)
        return
    }
    prompt_draw(ctx,r,p)
}

@(private="file") PROMPT_CAP_TOP :: Color{242,242,246,255}
@(private="file") PROMPT_CAP_EDGE :: Color{150,150,162,255}
@(private="file") PROMPT_CAP_TEXT :: Color{30,30,36,255}
@(private="file") PROMPT_PAD :: Color{46,46,52,255}
@(private="file") PROMPT_PAD_RIM :: Color{88,88,98,255}
@(private="file") PROMPT_PAD_TEXT :: Color{240,240,244,255}
@(private="file") PROMPT_LIT :: Color{64,140,255,255}

// The width a glyph takes at a height: square but for keys with a long name
// and the buttons on the shoulders.
prompt_width :: proc(ctx:^Context,g:Prompt,height:f32) -> f32 {
    #partial switch g.input {
    case .Key:
        if prompt_arrow(g.text)>=0 {return height}
        name:=prompt_key_name(g.text)
        width:=text_width(&ctx.font,name,prompt_key_size(name,height),FONT_SEMIBOLD)+height*0.5
        return max(height,width)
    case .Mouse_Left,.Mouse_Right,.Mouse_Middle,.Mouse_Move,.Mouse_Wheel: return height*0.8
    case .Shoulder_Left,.Shoulder_Right,.Trigger_Left,.Trigger_Right: return height*1.45
    case .Start,.Back: return height*(1.3 if g.family==.PlayStation else 1)
    case .Plus: return height*0.4
    }
    return height
}

prompt_draw :: proc(ctx:^Context,r:Rect,g:Prompt) {
    h:=r.h
    if h<=0 || r.w<=0 {return}
    center:=[2]f32{r.x+r.w*0.5,r.y+h*0.5}
    switch g.input {
    case .Key:                   prompt_key(ctx,r,g.text)
    case .Mouse_Left,.Mouse_Right,.Mouse_Middle,.Mouse_Move,.Mouse_Wheel: prompt_mouse(ctx,r,g.input)
    case .South,.East,.West,.North: prompt_face(ctx,center,h*0.5,g)
    case .Shoulder_Left,.Shoulder_Right,.Trigger_Left,.Trigger_Right: prompt_shoulder(ctx,r,g)
    case .Stick_Left,.Stick_Right,.Stick_Left_Press,.Stick_Right_Press: prompt_stick(ctx,center,h*0.5,g)
    case .Dpad,.Dpad_Up,.Dpad_Down,.Dpad_Left,.Dpad_Right: prompt_dpad(ctx,center,h*0.5,g.input)
    case .Start,.Back:           prompt_menu(ctx,r,g)
    case .Plus:
        s,w:=h*0.16,h*0.07
        draw_line(ctx,center-{s,0},center+{s,0},w,PROMPT_CAP_EDGE)
        draw_line(ctx,center-{0,s},center+{0,s},w,PROMPT_CAP_EDGE)
    }
}

@(private="file")
prompt_label :: proc(ctx:^Context,r:Rect,text:string,size:f32,color:Color) {
    clip_push(ctx,r)
    draw_text(ctx,text,r.x+(r.w-text_width(&ctx.font,text,size,FONT_SEMIBOLD))*0.5,r.y+text_leading(size,r.h),size,color,FONT_SEMIBOLD)
    clip_pop(ctx)
}

// Arrow keys by name: 0 up, 1 right, 2 down, 3 left; -1 for any other.
@(private="file")
prompt_arrow :: proc(name:string) -> int {
    switch name {
    case "Up": return 0
    case "Right": return 1
    case "Down": return 2
    case "Left": return 3
    }
    return -1
}

@(private="file")
prompt_key_name :: proc(name:string) -> string {
    switch name {
    case "Escape": return "Esc"
    case "Return","Enter": return "Enter"
    case "Left_Shift","Right_Shift": return "Shift"
    case "Left_Control","Right_Control": return "Ctrl"
    case "Left_Alt","Right_Alt": return "Alt"
    case "Backspace": return "Back"
    }
    return name
}

@(private="file")
prompt_key_size :: proc(name:string,height:f32) -> f32 {return height*(0.46 if len(name)<=1 else 0.34)}

@(private="file")
prompt_key :: proc(ctx:^Context,r:Rect,name:string) {
    h:=r.h
    radius:=h*0.18
    draw_rounded(ctx,r,radius,PROMPT_CAP_EDGE)
    top:=Rect{r.x+h*0.04,r.y+h*0.03,r.w-h*0.08,h*0.83}
    draw_rounded(ctx,top,radius*0.85,PROMPT_CAP_TOP)
    if arrow:=prompt_arrow(name);arrow>=0 {
        c:=[2]f32{top.x+top.w*0.5,top.y+top.h*0.5}
        s:=h*0.2
        angle:=f32(arrow)*math.PI*0.5
        point :: proc(c:[2]f32,angle:f32,x,y:f32) -> [2]f32 {
            sin,cos:=math.sin(angle),math.cos(angle)
            return c+{x*cos-y*sin,x*sin+y*cos}
        }
        draw_triangle(ctx,point(c,angle,0,-s),point(c,angle,s,s*0.7),point(c,angle,-s,s*0.7),PROMPT_CAP_TEXT)
        return
    }
    shown:=prompt_key_name(name)
    prompt_label(ctx,top,shown,prompt_key_size(shown,h),PROMPT_CAP_TEXT)
}

@(private="file")
prompt_mouse :: proc(ctx:^Context,r:Rect,input:Prompt_Input) {
    h:=r.h
    body:=Rect{r.x+(r.w-h*0.62)*0.5,r.y+h*0.04,h*0.62,h*0.92}
    radius:=body.w*0.5
    draw_shape(ctx,body,{fill=PROMPT_CAP_TOP,stroke=PROMPT_CAP_EDGE,stroke_width=h*0.05,radii={radius,radius,radius,radius}})
    split:=body.y+body.h*0.42
    half:=body.w*0.5
    #partial switch input {
    case .Mouse_Left:  draw_shape(ctx,{body.x,body.y,half,split-body.y},{fill=PROMPT_LIT,radii={radius,0,0,0}})
    case .Mouse_Right: draw_shape(ctx,{body.x+half,body.y,half,split-body.y},{fill=PROMPT_LIT,radii={0,radius,0,0}})
    }
    draw_line(ctx,{body.x+h*0.03,split},{body.x+body.w-h*0.03,split},h*0.04,PROMPT_CAP_EDGE)
    draw_line(ctx,{body.x+half,body.y+h*0.03},{body.x+half,split},h*0.04,PROMPT_CAP_EDGE)
    wheel:=Rect{body.x+half-h*0.055,body.y+h*0.12,h*0.11,h*0.2}
    draw_rounded(ctx,wheel,wheel.w*0.5,PROMPT_LIT if input==.Mouse_Middle || input==.Mouse_Wheel else PROMPT_CAP_EDGE)
    c:=[2]f32{body.x+half,body.y+body.h*0.72}
    s:=h*0.07
    if input==.Mouse_Move {
        for side in 0..<4 {
            angle:=f32(side)*math.PI*0.5
            dir:=[2]f32{math.cos(angle),math.sin(angle)}
            normal:=[2]f32{-dir.y,dir.x}
            tip:=c+dir*h*0.15
            draw_triangle(ctx,tip,tip-dir*s+normal*s,tip-dir*s-normal*s,PROMPT_LIT)
        }
    }
    if input==.Mouse_Wheel {
        draw_triangle(ctx,{c.x,c.y-s*2.2},{c.x+s,c.y-s*0.9},{c.x-s,c.y-s*0.9},PROMPT_LIT)
        draw_triangle(ctx,{c.x,c.y+s*2.2},{c.x-s,c.y+s*0.9},{c.x+s,c.y+s*0.9},PROMPT_LIT)
    }
}

@(private="file")
prompt_disc :: proc(ctx:^Context,c:[2]f32,radius:f32) {
    draw_circle(ctx,c,radius,PROMPT_PAD)
    draw_ring(ctx,c,radius-radius*0.06,radius*0.08,PROMPT_PAD_RIM)
}

// Line with its ends pushed out by half its width, so that strokes meet
// without a notch.
@(private="file")
prompt_stroke :: proc(ctx:^Context,a,b:[2]f32,width:f32,color:Color) {
    d:=b-a
    length:=math.sqrt(d.x*d.x+d.y*d.y)
    if length<=0 {return}
    e:=d/length*width*0.5
    draw_line(ctx,a-e,b+e,width,color)
}

@(private="file")
prompt_face :: proc(ctx:^Context,c:[2]f32,radius:f32,g:Prompt) {
    prompt_disc(ctx,c,radius)
    r:=Rect{c.x-radius,c.y-radius,radius*2,radius*2}
    size:=radius*1.05
    switch g.family {
    case .Keyboard,.Xbox:
        letters:=[4]string{"A","B","X","Y"}
        colors:=[4]Color{{108,194,74,255},{232,70,60,255},{59,130,224,255},{242,194,48,255}}
        index:=int(g.input)-int(Prompt_Input.South)
        prompt_label(ctx,r,letters[index],size,colors[index])
    case .Nintendo:
        // The east button is A on a Nintendo pad: the letters sit where its labels are.
        letters:=[4]string{"B","A","Y","X"}
        prompt_label(ctx,r,letters[int(g.input)-int(Prompt_Input.South)],size,PROMPT_PAD_TEXT)
    case .PlayStation:
        s:=radius*0.42
        w:=radius*0.13
        #partial switch g.input {
        case .South:
            color:=Color{143,184,234,255}
            draw_line(ctx,c+{-s,-s},c+{s,s},w,color)
            draw_line(ctx,c+{-s,s},c+{s,-s},w,color)
        case .East:
            draw_ring(ctx,c,s,w,{240,106,114,255})
        case .West:
            side:=s*1.6
            draw_rounded_stroke(ctx,{c.x-side*0.5,c.y-side*0.5,side,side},w*0.4,w,{229,154,214,255})
        case .North:
            color:=Color{79,209,181,255}
            top,left,right:=c+{0,-s*1.05},c+{-s*1.05,s*0.75},c+{s*1.05,s*0.75}
            prompt_stroke(ctx,top,left,w,color)
            prompt_stroke(ctx,left,right,w,color)
            prompt_stroke(ctx,right,top,w,color)
        }
    }
}

@(private="file")
prompt_shoulder :: proc(ctx:^Context,r:Rect,g:Prompt) {
    h:=r.h
    trigger:=g.input==.Trigger_Left || g.input==.Trigger_Right
    left:=g.input==.Shoulder_Left || g.input==.Trigger_Left
    body:=r
    radii:=[4]f32{h*0.3,h*0.3,h*0.3,h*0.3}
    if trigger {
        // Rounded on top, the side of the finger.
        radii={h*0.5,h*0.5,h*0.16,h*0.16}
    } else {
        body={r.x,r.y+h*0.14,r.w,h*0.72}
        radii={body.h*0.5,body.h*0.5,body.h*0.5,body.h*0.5}
        if left {radii[0]=body.h*0.25} else {radii[1]=body.h*0.25}
    }
    draw_shape(ctx,body,{fill=PROMPT_PAD,stroke=PROMPT_PAD_RIM,stroke_width=h*0.05,radii=radii})
    names:[2][2]string
    switch g.family {
    case .Keyboard,.Xbox: names={{"LB","RB"},{"LT","RT"}}
    case .PlayStation:    names={{"L1","R1"},{"L2","R2"}}
    case .Nintendo:       names={{"L","R"},{"ZL","ZR"}}
    }
    prompt_label(ctx,body,names[trigger?1:0][left?0:1],h*0.4,PROMPT_PAD_TEXT)
}

@(private="file")
prompt_stick :: proc(ctx:^Context,c:[2]f32,radius:f32,g:Prompt) {
    prompt_disc(ctx,c,radius)
    press:=g.input==.Stick_Left_Press || g.input==.Stick_Right_Press
    left:=g.input==.Stick_Left || g.input==.Stick_Left_Press
    draw_circle(ctx,c,radius*0.62,{70,70,80,255})
    draw_ring(ctx,c,radius*0.62,radius*0.07,{120,120,132,255})
    name:=left?"L":"R"
    if press {
        switch g.family {
        case .Keyboard,.Xbox,.Nintendo: name=left?"LS":"RS"
        case .PlayStation:              name=left?"L3":"R3"
        }
        draw_ring(ctx,c,radius*0.84,radius*0.07,PROMPT_LIT)
    }
    prompt_label(ctx,{c.x-radius,c.y-radius,radius*2,radius*2},name,radius*(0.62 if len(name)==1 else 0.5),PROMPT_PAD_TEXT)
}

@(private="file")
prompt_dpad :: proc(ctx:^Context,c:[2]f32,radius:f32,input:Prompt_Input) {
    arm:=radius*0.66
    long:=radius*1.9
    vertical:=Rect{c.x-arm*0.5,c.y-long*0.5,arm,long}
    horizontal:=Rect{c.x-long*0.5,c.y-arm*0.5,long,arm}
    draw_rounded(ctx,{vertical.x-radius*0.08,vertical.y-radius*0.08,vertical.w+radius*0.16,vertical.h+radius*0.16},arm*0.3,PROMPT_PAD_RIM)
    draw_rounded(ctx,{horizontal.x-radius*0.08,horizontal.y-radius*0.08,horizontal.w+radius*0.16,horizontal.h+radius*0.16},arm*0.3,PROMPT_PAD_RIM)
    draw_rounded(ctx,vertical,arm*0.24,PROMPT_PAD)
    draw_rounded(ctx,horizontal,arm*0.24,PROMPT_PAD)
    s:=arm*0.4
    reach:=long*0.5-arm*0.3
    for side in 0..<4 {
        if input!=.Dpad && int(input)-int(Prompt_Input.Dpad_Up)!=side {continue}
        // Up, down, left, right.
        dirs:=[4][2]f32{{0,-1},{0,1},{-1,0},{1,0}}
        dir:=dirs[side]
        normal:=[2]f32{-dir.y,dir.x}
        tip:=c+dir*reach
        color:=PROMPT_PAD_TEXT if input!=.Dpad else Color{170,170,182,255}
        draw_triangle(ctx,tip,tip-dir*s*1.3+normal*s,tip-dir*s*1.3-normal*s,color)
    }
}

@(private="file")
prompt_menu :: proc(ctx:^Context,r:Rect,g:Prompt) {
    h:=r.h
    start:=g.input==.Start
    switch g.family {
    case .Nintendo:
        c:=[2]f32{r.x+r.w*0.5,r.y+h*0.5}
        prompt_disc(ctx,c,h*0.4)
        s,w:=h*0.18,h*0.08
        draw_line(ctx,c-{s,0},c+{s,0},w,PROMPT_PAD_TEXT)
        if start {draw_line(ctx,c-{0,s},c+{0,s},w,PROMPT_PAD_TEXT)}
    case .PlayStation:
        body:=Rect{r.x,r.y+h*0.22,r.w,h*0.56}
        draw_shape(ctx,body,{fill=PROMPT_PAD,stroke=PROMPT_PAD_RIM,stroke_width=h*0.05,radii={body.h*0.5,body.h*0.5,body.h*0.5,body.h*0.5}})
        c:=[2]f32{body.x+body.w*0.5,body.y+body.h*0.5}
        w:=h*0.06
        if start {
            for i in -1..=1 {
                y:=c.y+f32(i)*h*0.1
                draw_line(ctx,{c.x-h*0.14,y},{c.x+h*0.14,y},w,PROMPT_PAD_TEXT)
            }
        } else {
            for i in -1..=1 {
                x:=c.x+f32(i)*h*0.1
                draw_line(ctx,{x,c.y-h*0.12},{x,c.y+h*0.12},w,PROMPT_PAD_TEXT)
            }
        }
    case .Keyboard,.Xbox:
        c:=[2]f32{r.x+r.w*0.5,r.y+h*0.5}
        prompt_disc(ctx,c,h*0.4)
        w:=h*0.055
        if start {
            for i in -1..=1 {
                y:=c.y+f32(i)*h*0.1
                draw_line(ctx,{c.x-h*0.15,y},{c.x+h*0.15,y},w,PROMPT_PAD_TEXT)
            }
        } else {
            s:=h*0.17
            draw_rounded_stroke(ctx,{c.x-s*0.85,c.y-s*0.85,s*1.2,s*1.2},h*0.03,w,PROMPT_PAD_TEXT)
            draw_rounded(ctx,{c.x-s*0.35,c.y-s*0.35,s*1.2,s*1.2},h*0.03,PROMPT_PAD_TEXT)
        }
    }
}
