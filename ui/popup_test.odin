package ui

import "core:fmt"
import "core:strings"
import "core:testing"

Test_Menus :: struct {
    chosen:int,
    under:int,       // clicks on the button under the menus
    snap:bool,
    selected:int,
    changed:int,
    modal:bool,
    modal_choice:int,
    escaped:int,
}
test_menus_build :: proc(ctx:^Context,user:rawptr) {
    s:=cast(^Test_Menus)user
    if menu_bar(ctx,id(ctx,"bar")) {
        if menu(ctx,id(ctx,"file"),"File") {
            if menu_item(ctx,id(ctx,"new"),"New scene",{shortcut="Ctrl+N"}) {s.chosen=1}
            if menu_item(ctx,id(ctx,"open"),"Open...",{shortcut="Ctrl+O"}) {s.chosen=2}
            menu_separator(ctx)
            if menu_item(ctx,id(ctx,"quit"),"Quit",{shortcut="Ctrl+Q",disabled=true}) {s.chosen=3}
        }
        if menu(ctx,id(ctx,"edit"),"Edit") {
            if menu_item(ctx,id(ctx,"snap"),"Snap to grid",{checked=s.snap}) {s.snap=!s.snap;s.chosen=4}
        }
    }
    if panel(ctx,id(ctx,"panel"),{width=fixed(300),height=FIT,padding=padding_all(10),gap=10,offset={0,38}}) {
        if button(ctx,id(ctx,"under"),{label="Under",variant="field",width=-1}).clicked {s.under+=1}
        if dropdown(ctx,id(ctx,"kind"),{list={"Point","Spot","Sun"}},&s.selected,{width=96}) {s.changed+=1}
        spacer(ctx,-1,200)
        if button(ctx,id(ctx,"below"),{label="Below",variant="field",width=-1}).clicked {s.under+=1}
    }
    if s.modal {
        if modal(ctx,id(ctx,"modal"),{width=400}) {
            label(ctx,"Save changes?",16)
            if box(ctx,{width=GROW,height=fixed(30),gap=8,align_y=.Center}) {
                spacer(ctx)
                if button(ctx,id(ctx,"cancel"),{label="Cancel",variant="field",height=30}).clicked {s.modal_choice=2;s.modal=false}
                if button(ctx,id(ctx,"save"),{label="Save",variant="accent",height=30}).clicked {s.modal_choice=1;s.modal=false}
            }
        }
    }
    if escape(ctx) {s.escaped+=1;s.modal=false}
}
test_menus_frame :: proc(ctx:^Context,input:^Input,s:^Test_Menus) -> Frame {return test_frame(ctx,input,test_menus_build,s)}
// The items of a menu with the tint of the pointer.
test_menu_hovered :: proc(ctx:^Context) -> (count:int) {
    hover:=color_hover(ctx)
    for &p in ctx.paints[:ctx.paint_count] {if p.kind==.Rect && p.fill==hover {count+=1}}
    return
}
test_icon_paint :: proc(ctx:^Context,icon:Icon) -> ^Paint {
    for &p in ctx.paints[:ctx.paint_count] {if p.kind==.Icon && p.icon==icon {return &p}}
    return nil
}
test_click :: proc(ctx:^Context,input:^Input,build:Test_Build,user:rawptr,target:Id) {
    rect,_:=widget_rect(ctx,target)
    test_point(input,rect)
    test_frame(ctx,input,build,user)
    test_press(input)
    test_frame(ctx,input,build,user)
    test_release(input)
    test_frame(ctx,input,build,user)
}

@(test)
a_menu_opens_under_its_title_and_an_item_closes_it :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:Test_Menus
    input:=test_input(800,600)
    test_menus_frame(&ctx,&input,&s)
    file:=test_rect(t,&ctx,id(&ctx,"file"))
    testing.expect(t,test_near(file.x,10) && test_near(file.y,(metric(&ctx,"bar_height")-26)*0.5) && test_near(file.h,26))
    testing.expect(t,test_paint(&ctx,"New scene")==nil)
    test_click(&ctx,&input,test_menus_build,&s,id(&ctx,"file"))
    testing.expect(t,menu_is_open(&ctx,id(&ctx,"file")))
    item:=test_rect(t,&ctx,id(&ctx,"new"))
    // Two units under the bar and inside the margin of the surface, as wide
    // as a menu at least, its items metric(&ctx,"control") tall inside 4 of padding.
    first:=Rect{metric(&ctx,"margin")+4,metric(&ctx,"bar_height")+2+4,MENU_WIDTH-8,metric(&ctx,"control")}
    testing.expectf(t,test_rect_near(item,first),"%v",item)
    testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"open")),{first.x,first.y+metric(&ctx,"control"),first.w,metric(&ctx,"control")}))
    testing.expect(t,test_near(test_rect(t,&ctx,id(&ctx,"quit")).y,first.y+2*metric(&ctx,"control")+9))
    title:=test_holder(&ctx,"File")
    testing.expect_value(t,title.fill,tone(&ctx,"field_active"))
    testing.expect_value(t,test_paint(&ctx,"New scene").style.color,tone(&ctx,"text"))
    shortcut:=test_paint(&ctx,"Ctrl+N")
    testing.expect(t,shortcut!=nil && shortcut.style.color==tone(&ctx,"text_muted"))
    testing.expect(t,test_menu_hovered(&ctx)==0,"Nothing is under the pointer")
    // A disabled item is drawn at 40 % of its opacity.
    testing.expect_value(t,test_paint(&ctx,"Quit").style.color,color_faded(tone(&ctx,"text")))
    testing.expect_value(t,test_paint(&ctx,"Ctrl+Q").style.color,color_faded(tone(&ctx,"text_muted")))
    // Under the pointer an item takes the tint of a hovered row.
    test_point(&input,item)
    frame:=test_menus_frame(&ctx,&input,&s)
    testing.expect_value(t,test_menu_hovered(&ctx),1)
    testing.expect_value(t,test_paint(&ctx,"New scene").style.color,tone(&ctx,"text"))
    testing.expect(t,frame.pointer_consumed && frame.keyboard_consumed)
    test_press(&input)
    test_menus_frame(&ctx,&input,&s)
    testing.expect_value(t,s.chosen,1)
    testing.expect(t,!menu_is_open(&ctx,id(&ctx,"file")))
    test_release(&input)
    test_menus_frame(&ctx,&input,&s)
    testing.expect(t,test_paint(&ctx,"New scene")==nil)
    // A disabled item does nothing and leaves the menu open.
    test_click(&ctx,&input,test_menus_build,&s,id(&ctx,"file"))
    s.chosen=0
    test_click(&ctx,&input,test_menus_build,&s,id(&ctx,"quit"))
    testing.expect(t,s.chosen==0 && menu_is_open(&ctx,id(&ctx,"file")))
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
}

@(test)
pointing_at_another_title_switches_menus_and_a_checked_item_shows_its_check :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:=Test_Menus{snap=true}
    input:=test_input(800,600)
    test_menus_frame(&ctx,&input,&s)
    // Closed menus do not open by pointing at them.
    test_point(&input,test_rect(t,&ctx,id(&ctx,"edit")))
    test_menus_frame(&ctx,&input,&s)
    test_menus_frame(&ctx,&input,&s)
    testing.expect(t,ctx.popup.count==0)
    test_click(&ctx,&input,test_menus_build,&s,id(&ctx,"file"))
    test_point(&input,test_rect(t,&ctx,id(&ctx,"edit")))
    test_menus_frame(&ctx,&input,&s)
    test_menus_frame(&ctx,&input,&s)
    testing.expect(t,menu_is_open(&ctx,id(&ctx,"edit")) && !menu_is_open(&ctx,id(&ctx,"file")))
    testing.expect(t,test_paint(&ctx,"Snap to grid")!=nil)
    check:=test_icon_paint(&ctx,.Check)
    testing.expect(t,check!=nil && check.icon_color==tone(&ctx,"accent_hover") && check.icon_size==13,"A checked item ends in its check")
    edit:=test_rect(t,&ctx,id(&ctx,"edit"))
    testing.expect(t,test_near(test_rect(t,&ctx,id(&ctx,"snap")).x,edit.x+4),"The menu hangs under its own title")
    // The title of the open menu closes it.
    test_press(&input)
    test_menus_frame(&ctx,&input,&s)
    test_release(&input)
    test_menus_frame(&ctx,&input,&s)
    testing.expect_value(t,ctx.popup.count,0)
}

@(test)
a_press_outside_a_popup_closes_it_and_does_nothing_else :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:Test_Menus
    input:=test_input(800,600)
    test_menus_frame(&ctx,&input,&s)
    test_click(&ctx,&input,test_menus_build,&s,id(&ctx,"file"))
    testing.expect_value(t,ctx.popup.count,1)
    // The button lies beside the menu.
    under:=test_rect(t,&ctx,id(&ctx,"under"))
    input.pointer={under.x+under.w-5,under.y+5}
    test_menus_frame(&ctx,&input,&s)
    test_press(&input)
    test_menus_frame(&ctx,&input,&s)
    test_release(&input)
    test_menus_frame(&ctx,&input,&s)
    testing.expect(t,ctx.popup.count==0 && s.under==0,"The press that closes a popup reaches nothing")
    test_press(&input)
    test_menus_frame(&ctx,&input,&s)
    test_release(&input)
    test_menus_frame(&ctx,&input,&s)
    testing.expect_value(t,s.under,1)
    // Escape closes it too, before anything else hears the key.
    test_click(&ctx,&input,test_menus_build,&s,id(&ctx,"file"))
    test_key(&input,.Escape)
    test_menus_frame(&ctx,&input,&s)
    testing.expect(t,ctx.popup.count==0 && s.escaped==0)
    test_key(&input,.Escape)
    test_menus_frame(&ctx,&input,&s)
    testing.expect_value(t,s.escaped,1)
    // A press on nothing at all.
    test_click(&ctx,&input,test_menus_build,&s,id(&ctx,"file"))
    input.pointer={700,500}
    test_menus_frame(&ctx,&input,&s)
    test_press(&input)
    test_menus_frame(&ctx,&input,&s)
    testing.expect_value(t,ctx.popup.count,0)
}

@(test)
a_dropdown_lists_its_options_under_its_button :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:=Test_Menus{selected=1}
    input:=test_input(800,600)
    test_menus_frame(&ctx,&input,&s)
    button_rect:=test_rect(t,&ctx,id(&ctx,"kind"))
    testing.expect(t,test_near(button_rect.w,96) && test_paint(&ctx,"Spot")!=nil)
    test_click(&ctx,&input,test_menus_build,&s,id(&ctx,"kind"))
    list:=id_derive(&ctx,id(&ctx,"kind"),"list")
    testing.expect(t,popup_is_open(&ctx,list))
    popup_rect:=test_rect(t,&ctx,list)
    // 4 under the button, at least 180 wide, three rows and 4 of padding.
    testing.expectf(t,test_rect_near(popup_rect,{max(button_rect.x,metric(&ctx,"margin")),button_rect.y+button_rect.h+4,180,3*metric(&ctx,"row")+8}),"Popup %v from button %v",popup_rect,button_rect)
    current:=test_element_paint(&ctx,id_derive(&ctx,list,"row",2))
    testing.expect(t,current!=nil && current.fill==tone(&ctx,"accent_soft"),"The chosen option has the check and the row of the keyboard")
    point:=test_element_paint(&ctx,id_derive(&ctx,list,"row",1))
    testing.expect(t,point!=nil && point.fill==Color{})
    testing.expect(t,test_near(test_text_rect(&ctx,"Point").x-test_rect(t,&ctx,id_derive(&ctx,list,"row",1)).x,28),"Rows without a check leave its room")
    // The keyboard moves the row and Enter takes it.
    test_key(&input,.Down)
    test_menus_frame(&ctx,&input,&s)
    test_key(&input,.Down)
    test_menus_frame(&ctx,&input,&s)
    test_key(&input,.Enter)
    test_menus_frame(&ctx,&input,&s)
    testing.expect(t,s.selected==2 && s.changed==1 && !popup_is_open(&ctx,list))
    test_menus_frame(&ctx,&input,&s)
    testing.expect(t,test_paint(&ctx,"Sun")!=nil)
    // The pointer picks a row by clicking it.
    test_click(&ctx,&input,test_menus_build,&s,id(&ctx,"kind"))
    row_id:=id_derive(&ctx,list,"row",1)
    test_point(&input,test_rect(t,&ctx,row_id))
    test_menus_frame(&ctx,&input,&s)
    test_menus_frame(&ctx,&input,&s)
    highlighted:=test_element_paint(&ctx,row_id)
    testing.expect(t,highlighted!=nil && highlighted.fill==tone(&ctx,"accent_soft"),"The row under a pointer that moves becomes the row of the keyboard")
    test_press(&input)
    test_menus_frame(&ctx,&input,&s)
    testing.expect(t,s.selected==0 && s.changed==2 && !popup_is_open(&ctx,list))
    test_release(&input)
    // Choosing what was chosen changes nothing.
    test_click(&ctx,&input,test_menus_build,&s,id(&ctx,"kind"))
    test_key(&input,.Enter)
    test_menus_frame(&ctx,&input,&s)
    testing.expect(t,s.changed==2 && !popup_is_open(&ctx,list))
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
}

@(test)
a_dropdown_moves_one_current_row_the_same_with_any_look :: proc(t:^testing.T) {
    Picker :: struct {options:Options,look:^Node_Style,selected,changes:int}
    build :: proc(ctx:^Context,user:rawptr) {
        s:=cast(^Picker)user
        if panel(ctx,id(ctx,"panel"),{width=fixed(240),height=FIT,padding=padding_all(8)}) {
            if dropdown(ctx,id(ctx,"pick"),s.options,&s.selected,{width=-1,look=s.look}) {s.changes+=1}
        }
    }
    names:[40]string
    for &name,i in names {name=fmt.tprintf("Option %d",i)}
    style:=TEST_CONTROL_STYLE
    // The editor's texts and a game's joined text go through the same list.
    for c in ([]Picker{{options={list=names[:]}},{options={joined=strings.join(names[:],"|",context.temp_allocator)},look=&style}}) {
        ctx:Context
        owned,ambient,scratch:Test_Counter
        desc:=TEST_SMALL
        desc.navigation=true
        desc.allocator=test_counter(&owned,context.allocator)
        testing.expect(t,test_context_init(&ctx,desc))
        defer context_destroy(&ctx)
        ctx.release_activates=true
        s:=c
        s.selected=20
        input:=test_input()
        test_frame(&ctx,&input,build,&s)
        pick:=id(&ctx,"pick")
        list:=id_derive(&ctx,pick,"list")
        row_id :: proc(ctx:^Context,list:Id,index:int) -> Id {return id_derive(ctx,list,"row",index+1)}
        current :: proc(ctx:^Context,list:Id) -> int {
            entry:=popup_find(ctx,list)
            return entry.cursor if entry!=nil else -2
        }
        // Opened by the keys, the current row is the chosen option, in sight,
        // and only the rows in sight are built, without allocating.
        ctx.focus,ctx.focus_ring=pick,true
        test_key(&input,.Enter)
        test_frame(&ctx,&input,build,&s)
        owned.requests=0
        {
            context.allocator=test_counter(&ambient,context.allocator)
            context.temp_allocator=test_counter(&scratch,context.temp_allocator)
            for _ in 0..<3 {test_frame(&ctx,&input,build,&s)}
        }
        testing.expect(t,owned.requests==0 && ambient.requests==0 && scratch.requests==0,"An open list does not allocate")
        testing.expect_value(t,current(&ctx,list),20)
        built:=0
        for i in 0..<len(names) {if _,found:=widget_rect(&ctx,row_id(&ctx,list,i));found {built+=1}}
        _,shown:=widget_rect(&ctx,row_id(&ctx,list,20))
        testing.expectf(t,shown && built>0 && built<=12,"%d rows built of %d",built,len(names))
        // The keys move it, Enter chooses it and the focus is on the dropdown.
        test_key(&input,.Down)
        test_frame(&ctx,&input,build,&s)
        testing.expect_value(t,current(&ctx,list),21)
        test_key(&input,.Enter)
        test_frame(&ctx,&input,build,&s)
        testing.expect(t,s.selected==21 && s.changes==1 && !popup_is_open(&ctx,list) && ctx.focus==pick)
        // The pointer moving onto a row makes it current, the d-pad goes on
        // from there and accept chooses it.
        test_click(&ctx,&input,build,&s,pick)
        test_frame(&ctx,&input,build,&s)
        testing.expect_value(t,current(&ctx,list),21)
        test_point(&input,test_rect(t,&ctx,row_id(&ctx,list,15)))
        test_frame(&ctx,&input,build,&s)
        testing.expect_value(t,current(&ctx,list),15)
        input.pad={.Down}
        test_frame(&ctx,&input,build,&s)
        testing.expect_value(t,current(&ctx,list),16)
        input.pad={.Accept}
        test_frame(&ctx,&input,build,&s)
        testing.expect(t,s.selected==16 && s.changes==2 && !popup_is_open(&ctx,list) && ctx.focus==pick)
        // A click on a row chooses it, and Escape closes the list with the focus where it was.
        test_click(&ctx,&input,build,&s,pick)
        test_frame(&ctx,&input,build,&s)
        test_click(&ctx,&input,build,&s,row_id(&ctx,list,12))
        testing.expect(t,s.selected==12 && ctx.focus==pick)
        test_click(&ctx,&input,build,&s,pick)
        test_key(&input,.Escape)
        test_frame(&ctx,&input,build,&s)
        testing.expect(t,s.selected==12 && !popup_is_open(&ctx,list) && ctx.focus==pick)
        testing.expect_value(t,ctx.stats.layout_errors,u32(0))
    }
}

@(test)
a_popup_that_does_not_fit_below_opens_above_and_stays_inside :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    input:=test_input(800,600)
    // A popup of 180 by 86 hung from each anchor: where the layout puts it in the frame that opens it.
    Case :: struct {anchor:Rect,desc:Popup,origin:[2]f32}
    Placed :: struct {using c:Case,open:bool}
    cases:=[]Case{
        {{100,100,96,26},{},{100,130}},
        {{100,100,96,26},{align_right=true},{metric(&ctx,"margin"),130}},
        {{100,540,96,26},{},{100,450}},
        {{700,100,96,26},{},{800-180-metric(&ctx,"margin"),130}},
        {{100,300,96,26},{side=.Above},{100,300-86-4}},
        // Nor over the bar of the surface.
        {{0,0,96,10},{},{metric(&ctx,"margin"),metric(&ctx,"bar_height")+2}},
        {{100,100,96,26},{within={300,0,200,0}},{300,130}},
    }
    build :: proc(ctx:^Context,user:rawptr) {
        s:=cast(^Placed)user
        list:=id(ctx,"list")
        if !s.open {popup_open(ctx,list,s.anchor);s.open=true}
        desc:=s.desc
        desc.width=180
        if popup(ctx,list,desc) {spacer(ctx,10,78)}
    }
    for c in cases {
        s:=Placed{c=c}
        popup_close(&ctx)
        frame:=test_frame(&ctx,&input,build,&s)
        placed:=test_rect(t,&ctx,id(&ctx,"list"))
        testing.expectf(t,test_rect_near(placed,{c.origin.x,c.origin.y,180,86}),"from %v: %v, expected at %v",c.anchor,placed,c.origin)
        // Its first frame draws it, inside its rectangle, in no layer of its own.
        testing.expect(t,len(frame.layers)==0 && len(frame.vertices)>0)
    }
    // A submenu hangs beside its item, on the other side of it where it does not fit.
    side :: proc(ctx:^Context,user:rawptr) {
        s:=cast(^Placed)user
        list:=id(ctx,"list")
        if !s.open {
            popup_open(ctx,list,s.anchor)
            popup_find(ctx,list).side=true
            s.open=true
        }
        if popup(ctx,list,{width=180}) {spacer(ctx,10,78)}
    }
    for c in ([]Case{{anchor={100,100,200,26},origin={304,96}},{anchor={500,100,200,26},origin={500-180-4,96}}}) {
        s:=Placed{c=c}
        popup_close(&ctx)
        test_frame(&ctx,&input,side,&s)
        placed:=test_rect(t,&ctx,id(&ctx,"list"))
        testing.expectf(t,test_rect_near(placed,{c.origin.x,c.origin.y,180,86}),"beside %v: %v, expected at %v",c.anchor,placed,c.origin)
    }
    frame_begin(&ctx,input)
    frame_end(&ctx)
}

@(test)
a_modal_takes_every_press_and_its_buttons_answer :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:=Test_Menus{modal=true}
    input:=test_input(800,600)
    frame:=test_menus_frame(&ctx,&input,&s)
    testing.expect(t,frame.keyboard_consumed)
    dialog:=test_rect(t,&ctx,id(&ctx,"modal"))
    testing.expect(t,test_near(dialog.w,400) && test_near(dialog.x,200) && test_near(dialog.y+dialog.h*0.5,300),"Centered in the surface")
    // 18 of padding, the title, 12 of gap and the row of buttons.
    testing.expect(t,test_near(dialog.h,18+22+12+30+18))
    backdrop:=test_rect(t,&ctx,id_derive(&ctx,id(&ctx,"modal"),"backdrop"))
    testing.expect(t,test_rect_near(backdrop,{0,0,800,600}))
    // What is under the backdrop is out of reach.
    test_click(&ctx,&input,test_menus_build,&s,id(&ctx,"under"))
    testing.expect(t,s.under==0 && s.modal)
    testing.expect_value(t,ctx.hot,id_derive(&ctx,id(&ctx,"modal"),"backdrop"))
    test_click(&ctx,&input,test_menus_build,&s,id(&ctx,"save"))
    testing.expect(t,s.modal_choice==1 && !s.modal)
    test_menus_frame(&ctx,&input,&s)
    frame=test_menus_frame(&ctx,&input,&s)
    testing.expect(t,!frame.keyboard_consumed)
    // Escape reaches the caller, which closes the dialog.
    s.modal=true
    test_menus_frame(&ctx,&input,&s)
    test_key(&input,.Escape)
    test_menus_frame(&ctx,&input,&s)
    testing.expect(t,s.escaped==1 && !s.modal)
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
}


Test_Submenus :: struct {
    chosen:int,
    right:bool, // the menu sits at the right edge of the surface
}
test_submenus_build :: proc(ctx:^Context,user:rawptr) {
    s:=cast(^Test_Submenus)user
    if box(ctx,{width=fixed(surface_size(ctx).x),height=fixed(40),align_x=.End if s.right else .Start,float={to=.Surface,offset={0,40}}}) {
        if button(ctx,id(ctx,"open"),{label="Modes",variant="field",width=120}).clicked {
            anchor,_:=widget_rect(ctx,id(ctx,"open"))
            popup_open(ctx,id(ctx,"modes"),anchor)
        }
    }
    if popup(ctx,id(ctx,"modes"),{min_width=200,align_right=s.right}) {
        menu_header(ctx,"Shading")
        if menu_item(ctx,id(ctx,"lit"),"Lit",{icon=.Light,checked=true}) {s.chosen=1}
        menu_header(ctx,"Lighting")
        if submenu(ctx,id(ctx,"gi"),"GI",{icon=.Layers}) {
            if menu_item(ctx,id(ctx,"raw"),"Raw") {s.chosen=2}
            if menu_item(ctx,id(ctx,"filtered"),"Filtered",{disabled=true}) {s.chosen=3}
        }
        if menu_item(ctx,id(ctx,"depth"),"Depth",{icon=.Layers}) {s.chosen=4}
        direct:=false
        if submenu(ctx,id(ctx,"direct"),"Direct",{icon=.Light,chosen=&direct}) {
            if menu_item(ctx,id(ctx,"diffuse"),"Diffuse") {s.chosen=6}
        }
        if direct {s.chosen=5}
    }
}

@(test)
a_submenu_that_is_a_choice_is_chosen_by_a_click_and_opened_by_pointing :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:Test_Submenus
    input:=test_input(800,600)
    test_frame(&ctx,&input,test_submenus_build,&s)
    test_click(&ctx,&input,test_submenus_build,&s,id(&ctx,"open"))
    test_point(&input,test_rect(t,&ctx,id(&ctx,"direct")))
    test_frame(&ctx,&input,test_submenus_build,&s)
    test_frame(&ctx,&input,test_submenus_build,&s)
    testing.expect(t,popup_is_open(&ctx,id_derive(&ctx,id(&ctx,"direct"),"submenu")))
    test_click(&ctx,&input,test_submenus_build,&s,id(&ctx,"diffuse"))
    testing.expect(t,s.chosen==6 && ctx.popup.count==0)
    test_click(&ctx,&input,test_submenus_build,&s,id(&ctx,"open"))
    test_point(&input,test_rect(t,&ctx,id(&ctx,"direct")))
    test_frame(&ctx,&input,test_submenus_build,&s)
    test_frame(&ctx,&input,test_submenus_build,&s)
    testing.expect_value(t,ctx.popup.count,2)
    // A click on it while its submenu is open chooses it too.
    test_click(&ctx,&input,test_submenus_build,&s,id(&ctx,"direct"))
    testing.expect_value(t,s.chosen,5)
    testing.expect_value(t,ctx.popup.count,0)
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
}

@(test)
a_submenu_opens_beside_its_item_and_another_item_closes_it :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:Test_Submenus
    input:=test_input(800,600)
    test_frame(&ctx,&input,test_submenus_build,&s)
    test_click(&ctx,&input,test_submenus_build,&s,id(&ctx,"open"))
    testing.expect(t,popup_is_open(&ctx,id(&ctx,"modes")))
    gi:=test_rect(t,&ctx,id(&ctx,"gi"))
    list:=id_derive(&ctx,id(&ctx,"gi"),"submenu")
    testing.expect(t,!popup_is_open(&ctx,list))
    // Pointing at it opens it: its first item level with it, past the edge of the menu.
    test_point(&input,gi)
    test_frame(&ctx,&input,test_submenus_build,&s)
    test_frame(&ctx,&input,test_submenus_build,&s)
    testing.expect(t,popup_is_open(&ctx,list))
    raw:=test_rect(t,&ctx,id(&ctx,"raw"))
    testing.expectf(t,test_near(raw.y,gi.y) && test_near(raw.x,gi.x+gi.w+8),"%v beside %v",raw,gi)
    // Its items are chosen as any other, which closes every menu.
    test_click(&ctx,&input,test_submenus_build,&s,id(&ctx,"raw"))
    testing.expect(t,s.chosen==2 && ctx.popup.count==0)
    // Another item of the menu closes it.
    test_click(&ctx,&input,test_submenus_build,&s,id(&ctx,"open"))
    test_point(&input,test_rect(t,&ctx,id(&ctx,"gi")))
    test_frame(&ctx,&input,test_submenus_build,&s)
    test_frame(&ctx,&input,test_submenus_build,&s)
    testing.expect_value(t,ctx.popup.count,2)
    test_point(&input,test_rect(t,&ctx,id(&ctx,"depth")))
    test_frame(&ctx,&input,test_submenus_build,&s)
    test_frame(&ctx,&input,test_submenus_build,&s)
    testing.expect(t,ctx.popup.count==1 && popup_is_open(&ctx,id(&ctx,"modes")))
    // Escape closes the submenu first.
    test_point(&input,test_rect(t,&ctx,id(&ctx,"gi")))
    test_frame(&ctx,&input,test_submenus_build,&s)
    test_frame(&ctx,&input,test_submenus_build,&s)
    test_key(&input,.Escape)
    test_frame(&ctx,&input,test_submenus_build,&s)
    testing.expect(t,ctx.popup.count==1 && !popup_is_open(&ctx,list))
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
}

@(test)
a_submenu_at_the_right_edge_opens_on_the_left_of_its_menu :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:=Test_Submenus{right=true}
    input:=test_input(800,600)
    test_frame(&ctx,&input,test_submenus_build,&s)
    test_click(&ctx,&input,test_submenus_build,&s,id(&ctx,"open"))
    gi:=test_rect(t,&ctx,id(&ctx,"gi"))
    test_point(&input,gi)
    test_frame(&ctx,&input,test_submenus_build,&s)
    test_frame(&ctx,&input,test_submenus_build,&s)
    test_frame(&ctx,&input,test_submenus_build,&s)
    list:=test_rect(t,&ctx,id_derive(&ctx,id(&ctx,"gi"),"submenu"))
    testing.expectf(t,list.x+list.w<=gi.x && list.x>=metric(&ctx,"margin"),"%v left of %v",list,gi)
}

@(test)
headers_title_the_groups_of_a_menu_and_rule_off_all_but_the_first :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:Test_Submenus
    input:=test_input(800,600)
    test_frame(&ctx,&input,test_submenus_build,&s)
    test_click(&ctx,&input,test_submenus_build,&s,id(&ctx,"open"))
    shading,lighting:=test_paint(&ctx,"Shading"),test_paint(&ctx,"Lighting")
    testing.expect(t,shading!=nil && lighting!=nil && shading.style.color==tone(&ctx,"text_faint") && shading.size==10)
    rules:=0
    for &p in ctx.paints[:ctx.paint_count] {if p.kind==.Rect && p.fill==tone(&ctx,"border") {rules+=1}}
    testing.expect_value(t,rules,1)
    modes:=test_rect(t,&ctx,id(&ctx,"modes"))
    lit:=test_rect(t,&ctx,id(&ctx,"lit"))
    gi:=test_rect(t,&ctx,id(&ctx,"gi"))
    // 4 of padding, the first header, its item, the rule and the second header.
    testing.expectf(t,test_near(lit.y,modes.y+4+24) && test_near(gi.y,lit.y+metric(&ctx,"control")+1+24),"%v %v %v",modes,lit,gi)
    testing.expect(t,test_icon_paint(&ctx,.Light)!=nil && test_icon_paint(&ctx,.Chevron_Right)!=nil)
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
}

Test_Zoom :: struct {
    offset:f32,
    zoomed:f32,
}
test_zoom_build :: proc(ctx:^Context,user:rawptr) {
    s:=cast(^Test_Zoom)user
    if panel(ctx,id(ctx,"panel"),{width=fixed(200),height=FIT}) {
        list:=id(ctx,"list")
        s.zoomed+=zoom(ctx,list)
        first,last:=list_begin(ctx,list,&s.offset,100,20,100)
        for index in first..<last {row(ctx,id(ctx,"item",index+1),{label="Item",height=20})}
        list_end(ctx,list,100,last,20)
    }
}

@(test)
ctrl_and_the_wheel_zoom_an_area_without_scrolling_it :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:Test_Zoom
    input:=test_input()
    test_frame(&ctx,&input,test_zoom_build,&s)
    test_point(&input,test_rect(t,&ctx,id(&ctx,"list")))
    test_frame(&ctx,&input,test_zoom_build,&s)
    input.wheel={0,-2}
    test_frame(&ctx,&input,test_zoom_build,&s)
    testing.expect(t,s.offset>0 && s.zoomed==0,"The wheel alone scrolls")
    s.offset=0
    input.modifiers={.Primary}
    input.wheel={0,1.5}
    test_frame(&ctx,&input,test_zoom_build,&s)
    testing.expect(t,s.offset==0 && s.zoomed==1.5,"With Ctrl it zooms and does not scroll")
    // Away from the area it is not for it.
    input.pointer={500,500}
    input.wheel={0,1}
    test_frame(&ctx,&input,test_zoom_build,&s)
    testing.expect_value(t,s.zoomed,f32(1.5))
}

test_disabled_build :: proc(ctx:^Context,user:rawptr) {
    if box(ctx,{width=FIT,height=FIT,gap=4}) {
        button(ctx,id(ctx,"ghost"),{icon=.Play,variant="ghost",width=26,height=26,disabled=true})
        button(ctx,id(ctx,"tab"),{icon=.Stop,variant="tab",icon_color=tone(ctx,"accent"),width=26,height=26,disabled=true})
        button(ctx,id(ctx,"field"),{label="Field",variant="field",disabled=true})
        button(ctx,id(ctx,"accent"),{label="Accent",variant="accent",disabled=true})
    }
}

@(test)
a_disabled_button_shows_no_fill_of_its_own_and_a_faded_glyph :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    input:=test_input()
    test_frame(&ctx,&input,test_disabled_build)
    // The pointer on it does not light it either.
    test_point(&input,test_rect(t,&ctx,id(&ctx,"ghost")))
    test_frame(&ctx,&input,test_disabled_build)
    for &p in ctx.paints[:ctx.paint_count] {
        if p.kind!=.Box {continue}
        #partial switch p.icon {
        case .Play: testing.expect(t,p.fill==Color{} && p.stroke==Color{} && p.icon_color==color_faded(tone(&ctx,"text")),"A ghost shows its glyph alone, without the border of the pointer")
        case .Stop: testing.expect(t,p.fill==Color{} && p.icon_color==color_faded(tone(&ctx,"accent")),"A segment keeps the color of its glyph, faded")
        }
        if p.text=="Field" {testing.expect(t,p.fill==color_faded(tone(&ctx,"field")) && p.style.color==color_faded(tone(&ctx,"text")))}
        if p.text=="Accent" {testing.expect(t,p.fill==color_faded(tone(&ctx,"accent")) && p.style.color==color_faded(tone(&ctx,"on_accent")))}
    }
}

Test_Closable :: struct {
    open:bool,
    presses:int, // on the button inside the dialog
}
test_closable_build :: proc(ctx:^Context,user:rawptr) {
    s:=cast(^Test_Closable)user
    if !s.open {return}
    closed:=false
    if modal(ctx,id(ctx,"dialog"),{width=300,close=&closed}) {
        label(ctx,"Settings",16)
        if button(ctx,id(ctx,"inside"),{label="Inside",variant="field",width=-1}).clicked {s.presses+=1}
    }
    if closed {s.open=false}
}

// A dialog that can be dismissed closes by its cross and by a press outside
// it; a press inside does what the press is for.
@(test)
a_closable_dialog_closes_by_its_cross_and_by_a_press_outside :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:=Test_Closable{open=true}
    input:=test_input(800,600)
    test_frame(&ctx,&input,test_closable_build,&s)
    test_frame(&ctx,&input,test_closable_build,&s)
    test_click(&ctx,&input,test_closable_build,&s,id(&ctx,"inside"))
    testing.expect(t,s.open && s.presses==1,"a press inside does not close it")
    test_click(&ctx,&input,test_closable_build,&s,id_derive(&ctx,id(&ctx,"dialog"),"close"))
    testing.expect(t,!s.open,"the cross closes it")
    s.open=true
    test_frame(&ctx,&input,test_closable_build,&s)
    test_frame(&ctx,&input,test_closable_build,&s)
    test_point(&input,{10,500,1,1})
    test_frame(&ctx,&input,test_closable_build,&s)
    test_press(&input)
    test_frame(&ctx,&input,test_closable_build,&s)
    testing.expect(t,!s.open,"a press outside closes it")
}

test_own_cross_build :: proc(ctx:^Context,user:rawptr) {
    s:=cast(^Test_Closable)user
    if !s.open {return}
    closed:=false
    dialog:=id(ctx,"dialog")
    if modal(ctx,dialog,{width=300,close=&closed,own_cross=true}) {
        if button(ctx,id_derive(ctx,dialog,"close"),{icon=.Cross,variant="ghost",width=24,height=24}).clicked {s.open=false}
    }
    if closed {s.open=false}
}

// A dialog that draws its own cross gets none in the corner, so the two do
// not share an id, and a press outside still closes it.
@(test)
a_dialog_with_its_own_cross_has_one_and_closes_by_a_press_outside :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:=Test_Closable{open=true}
    input:=test_input(800,600)
    test_frame(&ctx,&input,test_own_cross_build,&s)
    test_frame(&ctx,&input,test_own_cross_build,&s)
    testing.expect_value(t,ctx.stats.layout_errors,0)
    _,corner:=widget_rect(&ctx,id_derive(&ctx,id(&ctx,"dialog"),"corner"))
    testing.expect(t,!corner,"no cross in the corner")
    test_point(&input,{10,500,1,1})
    test_frame(&ctx,&input,test_own_cross_build,&s)
    test_press(&input)
    test_frame(&ctx,&input,test_own_cross_build,&s)
    testing.expect(t,!s.open,"a press outside closes it")
}

@(test)
a_menu_keeps_the_column_of_icons_only_when_an_item_has_an_icon :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,{}));defer context_destroy(&ctx)
    input:=test_input()
    build :: proc(ctx:^Context,user:rawptr) {
        iconed:=(cast(^bool)user)^
        if menu_button(ctx,id(ctx,"effort"),"Low",{popup={min_width=1}}) {
            menu_item(ctx,id(ctx,"low"),"Low",{icon=.Check if iconed else .None})
            menu_item(ctx,id(ctx,"medium"),"Medium",{checked=true})
        }
    }
    widths:[2]f32
    for iconed,index in ([2]bool{false,true}) {
        iconed:=iconed
        test_frame(&ctx,&input,build,&iconed)
        popup_open(&ctx,id_derive(&ctx,id(&ctx,"effort"),"menu"),test_rect(t,&ctx,id(&ctx,"effort")))
        for _ in 0..<3 {test_frame(&ctx,&input,build,&iconed)}
        menu:=test_rect(t,&ctx,id_derive(&ctx,id(&ctx,"effort"),"menu"))
        low:=test_rect(t,&ctx,id(&ctx,"low"))
        widths[index]=low.w
        testing.expect(t,low.x>=menu.x && low.x<menu.x+8,"an item starts at the padding of its menu")
        popup_close(&ctx)
    }
    testing.expectf(t,test_near(widths[1]-widths[0],MENU_ICON+7,0.5),"the column of icons takes room only in a menu with icons: %v",widths)
}

Test_Rows :: struct {taken:int}
test_rows_build :: proc(ctx:^Context,user:rawptr) {
    s:=cast(^Test_Rows)user
    if popup(ctx,id(ctx,"rows"),{width=200,search="Search"}) {
        for index in 0..<3 {
            row:=id(ctx,"row",index+1)
            if popup_row(ctx,row).clicked {s.taken=index+1}
            if box(ctx,{id=row,width=GROW,height=fixed(30)}) {label(ctx,"Row")}
        }
    }
}

@(test)
rows_a_popup_draws_itself_move_with_the_keys_of_its_search_as_items_do :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:Test_Rows
    input:=test_input(800,600)
    test_frame(&ctx,&input,test_rows_build,&s)
    popup_open(&ctx,id(&ctx,"rows"),{10,10,100,20})
    test_frame(&ctx,&input,test_rows_build,&s)
    test_frame(&ctx,&input,test_rows_build,&s)
    test_key(&input,.Down)
    test_frame(&ctx,&input,test_rows_build,&s)
    test_key(&input,.Enter)
    test_frame(&ctx,&input,test_rows_build,&s)
    testing.expect_value(t,s.taken,2)
}
