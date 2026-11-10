package ui

import "core:testing"

Test_Editor :: struct {
    tab:int,
    name:[64]u8,name_length:int,
    position,rotation,scale:[3]f64,
    color:[3]f32,
    transform_open,light_open:bool,
    visible:bool,
    scroll:[2]f32,
    intensity:f64,
    kind:int,
    cast_shadows:bool,
    rows:int,           // extra property rows in Details
    clicked:Id,
    menu_chosen:int,
}

test_editor_default :: proc() -> Test_Editor {
    e:=Test_Editor{position={1,2.8,0},scale={1,1,1},color={0.08,0.65,0.5},transform_open=true,light_open=true,visible=true,intensity=4,cast_shadows=true}
    e.name_length=copy(e.name[:],"Floating block")
    return e
}

test_editor_build :: proc(ctx:^Context,user:rawptr) {
    e:=cast(^Test_Editor)user
    th:=&ctx.theme
    width,height:=ctx.size.x,ctx.size.y
    // ------------------------------------------------------------ top bar
    if menu_bar(ctx,id(ctx,"bar")) {
    if box(ctx,{width=GROW,height=GROW,gap=2,align_y=.Center}) {
        titles:=[4]string{"File","Edit","View","Help"}
        for title,i in titles {
            if menu(ctx,id(ctx,"menu",i+1),title) {
                if menu_item(ctx,id(ctx,"new",i+1),"New scene",{shortcut="Ctrl+N"}) {e.menu_chosen=i*10+1}
                if menu_item(ctx,id(ctx,"open",i+1),"Open...",{shortcut="Ctrl+O"}) {e.menu_chosen=i*10+2}
                menu_separator(ctx)
                if menu_item(ctx,id(ctx,"snap",i+1),"Snap to grid",{checked=true}) {e.menu_chosen=i*10+3}
                menu_item(ctx,id(ctx,"off",i+1),"Close scene",{disabled=true})
            }
        }
    }
    button(ctx,id(ctx,"document"),{label="skeletal",icon=.Grid,style=.Field,width=120,height=28,size=11})
    if box(ctx,{width=GROW,height=GROW,gap=8,align_x=.End,align_y=.Center}) {
        if button(ctx,id(ctx,"graphics"),{label="Graphics",style=.Field,width=92,height=24,center=true}).clicked {e.clicked=id(ctx,"graphics")}
        button(ctx,id(ctx,"build"),{label="Build",style=.Field,width=92,height=24,center=true})
        if button(ctx,id(ctx,"play"),{label="Play",icon=.Play,style=.Accent,width=92,height=24,center=true}).clicked {e.clicked=id(ctx,"play")}
    }
    }

    if box(ctx,{id=id(ctx,"document_toolbar"),width=fixed(width),height=fixed(44),float={to=.Surface,offset={0,th.bar_height},layer=LAYER_BAR},fill=th.panel,block=true,padding=padding_xy(16,0),gap=6,align_y=.Center}) {
        spacer(ctx)
        if segments(ctx,FIT,28) {
            button(ctx,id(ctx,"space"),{icon=.Relative,style=.Ghost,height=24,width=24})
            icons:=[3]Icon{.Move,.Rotate,.Scale}
            for tool,i in icons {button(ctx,id(ctx,"tool",i+1),{icon=tool,style=.Tab,active=i==0,height=24,width=29})}
            button(ctx,id(ctx,"snap"),{icon=.Grid,style=.Ghost,height=24,width=24})
        }
        spacer(ctx)
    }
    top:=th.bar_height+44+th.margin
    content_width:=f32(320)
    if panel(ctx,id(ctx,"content"),{width=fixed(content_width),height=FIT,padding=padding_all(8),gap=6,offset={th.margin,top}}) {
        tabs(ctx,id(ctx,"create_tabs"),{"Editor","Content Browser","AI"},&e.tab,height=26)
        switch e.tab {
        case 0:
            groups:=[3]struct {name:string,icons:[]Icon,color:Color,first:int}{
                {"Shapes",{.Cube,.Sphere,.Cylinder,.Cone,.Prism,.Pyramid},{140,180,240,255},1},
                {"Logic",{.Spawn,.Group},{175,165,230,255},7},
                {"Lighting",{.Light,.Sun,.Spot},{255,214,120,255},9},
            }
            for group,index in groups {
                if box(ctx,{width=GROW,height=FIT,direction=.Column,gap=4}) {
                    open:=true
                    collapsible(ctx,id(ctx,"create_group",index+1),group.name,&open)
                    for row:=0;row<len(group.icons);row+=4 {
                        if grid_row(ctx,40,4) {
                            for i in row..<min(row+4,len(group.icons)) {card(ctx,id(ctx,"card",group.first+i),{icon=group.icons[i],icon_color=group.color,icon_size=32,width=fixed(40)})}
                        }
                    }
                }
            }
        case 1:
            if box(ctx,{width=GROW,height=fixed(24),gap=2,align_y=.Center}) {
                label(ctx,"Assets",th.font_small,th.text)
                spacer(ctx)
                icon_button(ctx,id(ctx,"reload"),.Refresh,22,.Ghost,"",th.text_muted)
                icon_button(ctx,id(ctx,"kinds"),.Filter,22,.Ghost,"",th.text_muted)
            }
            folders:=[6]string{"models","crate.glb","barrel.glb","materials","metal","scene"}
            depths:=[6]int{0,1,1,0,1,0}
            for name,i in folders {
                tree_row(ctx,id(ctx,"entry",i+1),{label=name,depth=depths[i],folder=depths[i]==0 && i!=5,open=true,icon=.Mesh if i<3 else (.Sphere if i<5 else .Grid),icon_color={110,210,200,255},height=28})
            }
        case 2:
            label(ctx,"AI",th.font_title,th.text)
            paragraph(ctx,"Floating block",th.font_small,th.text_muted)
            label(ctx,"Message",th.font_small,th.text_faint)
        }
    }

    // ------------------------------------------------------------ details
    details_width:=f32(312)
    max_height:=max(height-top-th.margin,1)
    if panel(ctx,id(ctx,"details"),{width=fixed(details_width),height=FIT,anchor=.Top_Right,pivot=.Top_Right,offset={-th.margin,top}}) {
        if scroll_area(ctx,id(ctx,"details_scroll"),&e.scroll,{width=fixed(details_width),height=FIT,max_height=max_height,padding=padding_all(8),gap=4}) {
            if box(ctx,{width=GROW,height=FIT,align_y=.Center}) {
                label(ctx,"Details",th.font_title,th.text)
                spacer(ctx)
            }
            if box(ctx,{width=GROW,height=fixed(28),gap=5,align_y=.Center}) {
                preview:=paint_add(ctx,{kind=.Box,fill=th.field,radius=th.radius_control,center=true,icon=.Cube,icon_color={140,180,240,255},icon_size=18})
                element_leaf(ctx,{layout={width=fixed(28),height=fixed(28)},custom=preview})
                text_field(ctx,id(ctx,"name"),e.name[:],&e.name_length,{height=28,size=th.font,bare=true})
                if button(ctx,id(ctx,"visible"),{icon=.Eye if e.visible else .Eye_Off,icon_color=th.text if e.visible else th.text_faint,style=.Ghost,width=24,height=24}).clicked {e.visible=!e.visible}
            }
            inner:=details_width-16
            if collapsible(ctx,id(ctx,"transform"),"Transform",&e.transform_open,{width=inner}).open {
                if property(ctx,"Position") {vector_field(ctx,id(ctx,"position"),e.position[:],{number={speed=0.02}})}
                if property(ctx,"Rotation") {vector_field(ctx,id(ctx,"rotation"),e.rotation[:],{number={speed=0.5,decimals=1}})}
                if property(ctx,"Scale") {vector_field(ctx,id(ctx,"scale"),e.scale[:],{number={speed=0.01}})}
            }
            if collapsible(ctx,id(ctx,"light"),"Light",&e.light_open,{width=inner,removable=true}).open {
                if box(ctx,{width=GROW,height=fixed(24),gap=4,align_y=.Center}) {
                    dropdown(ctx,id(ctx,"kind"),{list={"Point","Spot","Sun"}},&e.kind,{width=-1,height=24})
                }
                if property(ctx,"Color") {color_swatch(ctx,id(ctx,"color"),e.color)}
                if property(ctx,"Intensity") {number_field(ctx,id(ctx,"intensity"),&e.intensity,{speed=0.05,decimals=2,min=0,has_min=true})}
                if box(ctx,{width=GROW,height=fixed(th.row),gap=4,align_y=.Center}) {
                    label(ctx,"Cast shadows",th.font_small,th.text_muted,0)
                    checkbox(ctx,id(ctx,"shadows"),&e.cast_shadows)
                }
            }
            for i in 0..<e.rows {
                if property(ctx,"Value") {vector_field(ctx,id(ctx,"extra",i+1),e.position[:],{})}
            }
            if button(ctx,id(ctx,"component_add"),{label="Add component",icon=.Plus,style=.Field,width=-1,height=28}).clicked {e.clicked=id(ctx,"component_add")}
            spacer(ctx,-1,2)
        }
    }
}

@(test)
the_editor_panels_keep_the_metrics_of_the_editor :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_FONT))
    defer context_destroy(&ctx)
    e:=test_editor_default()
    th:=THEME_EDITOR
    input:=test_input(1440,900)
    test_frame(&ctx,&input,test_editor_build,&e)
    test_frame(&ctx,&input,test_editor_build,&e)
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
    testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"bar")),{0,0,1440,40}))
    testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"document_toolbar")),{0,40,1440,44}))
    content:=test_rect(t,&ctx,id(&ctx,"content"))
    testing.expect(t,test_rect_near(content,{16,100,320,302}))
    card_rect:=test_rect(t,&ctx,id(&ctx,"card",1))
    testing.expect(t,test_rect_near(card_rect,{24,166,40,40}))
    details:=test_rect(t,&ctx,id(&ctx,"details"))
    testing.expect(t,test_near(details.w,312) && test_near(details.x+details.w,1424) && test_near(details.y,100))
    name:=test_rect(t,&ctx,id(&ctx,"name"))
    testing.expect(t,test_near(name.h,28) && test_near(name.x,details.x+8+28+5))
    x_field:=test_rect(t,&ctx,id_derive(&ctx,id(&ctx,"position"),"axis",1))
    z_field:=test_rect(t,&ctx,id_derive(&ctx,id(&ctx,"position"),"axis",3))
    testing.expect(t,test_near(x_field.x,details.x+8+th.label_width+4) && test_near(x_field.h,th.row))
    testing.expect(t,test_near(x_field.w,(312-16-th.label_width-3*4)/3,0.5))
    testing.expect(t,test_near(z_field.x+z_field.w,details.x+details.w-8,0.5))
    play:=test_rect(t,&ctx,id(&ctx,"play"))
    build:=test_rect(t,&ctx,id(&ctx,"build"))
    testing.expect(t,test_rect_near(play,{1440-10-92,(th.bar_height-24)*0.5,92,24}))
    testing.expect(t,test_near(play.x-build.x-build.w,8))
    first,last:=test_rect(t,&ctx,id(&ctx,"space")),test_rect(t,&ctx,id(&ctx,"snap"))
    testing.expect(t,test_near((first.x+last.x+last.w)*0.5,720,1),"The tools sit at the center of the document toolbar")
}

@(test)
the_editor_panels_have_the_colors_of_the_editor :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_FONT))
    defer context_destroy(&ctx)
    e:=test_editor_default()
    input:=test_input(1440,900)
    test_frame(&ctx,&input,test_editor_build,&e)
    frame:=test_frame(&ctx,&input,test_editor_build,&e)
    testing.expect(t,!frame.overflow)
    scene:=Color{90,60,30,255}
    image:=test_raster(&ctx,frame,1440,900,1,scene)
    defer test_image_destroy(&image)
    test_image_dump(&image,"editor")
    th:=THEME_EDITOR
    px :: proc(image:^Test_Image,r:Rect,dx,dy:f32) -> [4]u8 {return test_pixel(image,int(r.x+dx),int(r.y+dy))}
    testing.expect(t,test_color_near(test_pixel(&image,600,0),th.bar_top,1))
    testing.expect(t,test_color_near(test_pixel(&image,600,38),th.bar_bottom,1))
    testing.expect(t,test_color_near(test_pixel(&image,600,39),th.border,1))
    testing.expect(t,test_color_near(test_pixel(&image,600,40),th.panel,1))
    testing.expect(t,test_color_near(test_pixel(&image,600,84),scene),"The scene shows under the document toolbar")
    content:=test_rect(t,&ctx,id(&ctx,"content"))
    testing.expect(t,test_color_near(px(&image,content,6,6),th.panel))
    testing.expect(t,test_color_near(px(&image,content,40,0),th.border))
    testing.expect(t,test_color_near(px(&image,content,0,60),th.border))
    testing.expect(t,test_color_near(px(&image,content,content.w-1,60),th.border))
    testing.expect(t,test_color_near(px(&image,content,40,content.h+2),scene),"The flat panel has no surrounding shadow")
    active_tab:=test_rect(t,&ctx,id_derive(&ctx,id(&ctx,"create_tabs"),"tab",1))
    idle_tab:=test_rect(t,&ctx,id_derive(&ctx,id(&ctx,"create_tabs"),"tab",2))
    testing.expect(t,test_color_near(px(&image,active_tab,3,11),th.accent))
    testing.expect(t,test_color_near(px(&image,idle_tab,idle_tab.w*0.5,3),th.well))
    testing.expect(t,test_count_color(&image,active_tab,th.on_accent,80)>10,"Text on the accent is light")
    testing.expect(t,test_count_color(&image,idle_tab,th.text_muted,80)>10,"Idle tabs are muted")
    card_rect:=test_rect(t,&ctx,id(&ctx,"card",1))
    testing.expect(t,test_color_near(px(&image,card_rect,5,5),th.field))
    testing.expect(t,test_color_near(px(&image,card_rect,30,0),th.divider))
    testing.expect(t,test_count_color(&image,card_rect,{140,180,240,255})>20)
    // The strip is three points wide, three from the edge: checks its inside,
    // the field's inside after it and its border. The pixels of the fractional
    // border get analytic coverage.
    for axis in 0..<3 {
        field:=test_rect(t,&ctx,id_derive(&ctx,id(&ctx,"position"),"axis",axis+1))
        testing.expect(t,test_color_near(px(&image,field,field.w-4,11),th.well))
        testing.expect(t,test_color_near(px(&image,field,4,11),th.axis[axis]))
        testing.expect(t,test_color_near(px(&image,field,8,11),th.well))
        testing.expect(t,test_color_near(px(&image,field,field.w*0.5,0),th.well_stroke))
        testing.expect(t,test_count_color(&image,field,th.text,90)>4,"The value is drawn in the text color")
    }
    // The accent button, the swatch and the checkbox.
    play:=test_rect(t,&ctx,id(&ctx,"play"))
    testing.expect(t,test_color_near(px(&image,play,4,13),th.accent))
    swatch:=test_rect(t,&ctx,id(&ctx,"color"))
    testing.expect(t,test_color_near(px(&image,swatch,swatch.w*0.5,13),rgb_color(e.color)))
    testing.expect(t,test_color_near(px(&image,swatch,swatch.w*0.5,0),th.border))
    check:=test_rect(t,&ctx,id(&ctx,"shadows"))
    testing.expect(t,test_rect_near(check,{check.x,check.y,16,16}))
    testing.expect(t,test_color_near(px(&image,check,8,0),th.accent),"A checked box is outlined with the accent")
    testing.expect(t,test_count_color(&image,check,th.accent)>30)
    name:=test_rect(t,&ctx,id(&ctx,"name"))
    testing.expect(t,test_color_near(px(&image,name,name.w-4,4),th.panel))
    testing.expect(t,test_count_color(&image,name,th.text,80)>30)
}
