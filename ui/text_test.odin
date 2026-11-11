package ui

import "core:testing"

@(test)
text_edit_begins_with_the_accepted_characters_selected :: proc(t:^testing.T) {
    e:Text_Edit
    text_edit_begin(&e,7,"Floating block")
    testing.expect_value(t,text_edit_value(&e),"Floating block")
    lo,hi:=text_edit_selection(&e)
    testing.expect(t,lo==0 && hi==14 && e.cursor==14 && !e.modified)
    text_edit_begin(&e,7,"12a.5x-",.Number)
    testing.expect_value(t,text_edit_value(&e),"12.5-")
    text_edit_begin(&e,7,"#fF09zz",.Hex)
    testing.expect_value(t,text_edit_value(&e),"#fF09")
    text_edit_begin(&e,7,"abcdef",.Any,4,false)
    testing.expect_value(t,text_edit_value(&e),"abcd")
    lo,hi=text_edit_selection(&e)
    testing.expect(t,lo==4 && hi==4,"Without selecting, the caret waits at the end")
    text_edit_begin(&e,7,"café")
    testing.expect_value(t,text_edit_value(&e),"caf")
}

@(test)
text_edit_inserts_replaces_and_removes :: proc(t:^testing.T) {
    e:Text_Edit
    text_edit_begin(&e,1,"abc")
    text_edit_insert(&e,'x')
    testing.expect_value(t,text_edit_value(&e),"x")
    text_edit_insert(&e,'y');text_edit_insert(&e,'z')
    testing.expect_value(t,text_edit_value(&e),"xyz")
    text_edit_move(&e,1,false)
    text_edit_insert(&e,'-')
    testing.expect_value(t,text_edit_value(&e),"x-yz")
    testing.expect_value(t,e.cursor,2)
    text_edit_remove(&e,e.cursor-1)
    testing.expect_value(t,text_edit_value(&e),"xyz")
    testing.expect_value(t,e.cursor,1)
    text_edit_remove(&e,e.cursor)
    testing.expect_value(t,text_edit_value(&e),"xz")
    testing.expect_value(t,e.cursor,1)
    text_edit_remove(&e,-1);text_edit_remove(&e,99)
    testing.expect_value(t,text_edit_value(&e),"xz")
    // A selection is replaced by what is typed and removed whole.
    text_edit_begin(&e,1,"hello world",.Any,TEXT_EDIT_CAPACITY,false)
    text_edit_move(&e,0,false);text_edit_move(&e,5,true)
    text_edit_insert(&e,'J')
    testing.expect_value(t,text_edit_value(&e),"J world")
    text_edit_move(&e,7,true)
    testing.expect(t,text_edit_delete_selection(&e))
    testing.expect_value(t,text_edit_value(&e),"J")
    testing.expect(t,!text_edit_delete_selection(&e),"Nothing selected, nothing removed")
    // Characters the filter refuses and those beyond the capacity are dropped.
    text_edit_begin(&e,1,"12",.Number,4,false)
    text_edit_insert(&e,'a');text_edit_insert(&e,'3');text_edit_insert(&e,'4');text_edit_insert(&e,'5')
    testing.expect_value(t,text_edit_value(&e),"1234")
    text_edit_insert(&e,7)
    testing.expect_value(t,text_edit_value(&e),"1234")
}

@(test)
text_edit_finds_words_by_class :: proc(t:^testing.T) {
    e:Text_Edit
    text_edit_begin(&e,1,"Point light_02  (copy)")
    lo,hi:=text_edit_word(&e,1)
    testing.expect(t,lo==0 && hi==5)
    lo,hi=text_edit_word(&e,8)
    testing.expect(t,lo==6 && hi==14,"Letters, digits and underscores are one word")
    lo,hi=text_edit_word(&e,14)
    testing.expect(t,lo==14 && hi==16,"A run of spaces is a word of its own")
    lo,hi=text_edit_word(&e,16)
    testing.expect(t,lo==16 && hi==17)
    lo,hi=text_edit_word(&e,99)
    testing.expect(t,lo==21 && hi==22,"Past the end: the last character")
    text_edit_begin(&e,1,"-12.5e3",.Number)
    lo,hi=text_edit_word(&e,2)
    testing.expect(t,lo==0 && hi==7,"A number is one word")
    text_edit_begin(&e,1,"")
    lo,hi=text_edit_word(&e,0)
    testing.expect(t,lo==0 && hi==0)
}

Test_Text :: struct {
    name:[32]u8,name_length:int,
    filter:[32]u8,filter_length:int,
    code:[8]u8,code_length:int,
    note:[96]u8,note_length:int,
    result,filter_result,code_result,note_result:Text_Result,
    clipboard:[64]u8,clipboard_length:int,
}
test_text_build :: proc(ctx:^Context,user:rawptr) {
    s:=cast(^Test_Text)user
    if panel(ctx,id(ctx,"panel"),{width=fixed(120),height=FIT,gap=4}) {
        s.result=text_field(ctx,id(ctx,"name"),s.name[:],&s.name_length,{size=10})
        s.filter_result=text_field(ctx,id(ctx,"filter"),s.filter[:],&s.filter_length,{size=10,live=true,keep_caret=true,placeholder="Find"})
        s.code_result=text_field(ctx,id(ctx,"code"),s.code[:],&s.code_length,{size=10,filter=.Hex})
        s.note_result=text_field(ctx,id(ctx,"note"),s.note[:],&s.note_length,{size=10,multiline=true,enter_inserts=true,rows=3})
    }
}
test_text_frame :: proc(ctx:^Context,input:^Input,s:^Test_Text) {test_frame(ctx,input,test_text_build,s)}
// Without an atlas a character of size 10 is 5 wide, and the text of a field
// begins 8 units inside it.
test_text_point :: proc(ctx:^Context,input:^Input,field:Id,index:f32) {
    rect,_:=widget_rect(ctx,field)
    input.pointer={rect.x+8+index*5,rect.y+rect.h*0.5}
}
test_text_init :: proc(t:^testing.T,ctx:^Context,s:^Test_Text,input:^Input) {
    desc:=TEST_SMALL
    desc.clipboard_user=s
    desc.clipboard_set=proc(user:rawptr,text:string) {s:=cast(^Test_Text)user;s.clipboard_length=copy(s.clipboard[:],text)}
    desc.clipboard_get=proc(user:rawptr,buffer:[]u8) -> int {s:=cast(^Test_Text)user;return copy(buffer,s.clipboard[:s.clipboard_length])}
    testing.expect(t,test_context_init(ctx,desc))
    s.name_length=copy(s.name[:],"hello world")
    input^=test_input()
    test_text_frame(ctx,input,s)
}

@(test)
the_first_click_on_a_field_selects_all_and_the_next_places_the_caret :: proc(t:^testing.T) {
    ctx:Context;s:Test_Text;input:Input
    test_text_init(t,&ctx,&s,&input)
    defer context_destroy(&ctx)
    e:=&ctx.edit
    test_text_point(&ctx,&input,id(&ctx,"name"),3)
    test_text_frame(&ctx,&input,&s)
    test_press(&input)
    frame:=test_frame(&ctx,&input,test_text_build,&s)
    testing.expect(t,s.result.began && s.result.editing && frame.keyboard_consumed)
    lo,hi:=text_edit_selection(e)
    testing.expect(t,lo==0 && hi==11)
    testing.expect_value(t,ctx.focus,id(&ctx,"name"))
    field:=test_paint(&ctx,"hello world")
    testing.expect(t,field.kind==.Field && field.caret==11 && field.selection==[2]int{0,11} && field.fill==tone(&ctx,"well") && field.stroke==tone(&ctx,"accent"),"The selection shows over the fill of the field")
    test_release(&input)
    test_text_frame(&ctx,&input,&s)
    // A second click places the caret at the nearest boundary.
    test_text_point(&ctx,&input,id(&ctx,"name"),3.2)
    test_text_frame(&ctx,&input,&s)
    test_press(&input)
    test_text_frame(&ctx,&input,&s)
    lo,hi=text_edit_selection(e)
    testing.expect(t,lo==3 && hi==3 && e.cursor==3)
    // Dragging with the button down selects from there.
    test_text_point(&ctx,&input,id(&ctx,"name"),7.9)
    test_text_frame(&ctx,&input,&s)
    lo,hi=text_edit_selection(e)
    testing.expect(t,lo==3 && hi==8 && e.cursor==8)
    test_text_point(&ctx,&input,id(&ctx,"name"),1)
    test_text_frame(&ctx,&input,&s)
    lo,hi=text_edit_selection(e)
    testing.expect(t,lo==1 && hi==3 && e.cursor==1,"The selection follows the pointer to either side of where it began")
    test_release(&input)
    test_text_frame(&ctx,&input,&s)
    // Shift and a click extend the selection from the caret.
    test_text_point(&ctx,&input,id(&ctx,"name"),5.5) // the space before is half as wide
    input.modifiers={.Shift}
    test_text_frame(&ctx,&input,&s)
    test_press(&input)
    test_text_frame(&ctx,&input,&s)
    lo,hi=text_edit_selection(e)
    testing.expect(t,lo==3 && hi==6)
    test_release(&input)
    input.modifiers={}
    test_text_frame(&ctx,&input,&s)
    // A double click selects the word under the pointer and a triple click everything.
    test_text_point(&ctx,&input,id(&ctx,"name"),7.4)
    test_text_frame(&ctx,&input,&s)
    test_press(&input,2)
    test_text_frame(&ctx,&input,&s)
    lo,hi=text_edit_selection(e)
    testing.expect(t,lo==6 && hi==11)
    test_release(&input)
    test_text_frame(&ctx,&input,&s)
    test_press(&input,3)
    test_text_frame(&ctx,&input,&s)
    lo,hi=text_edit_selection(e)
    testing.expect(t,lo==0 && hi==11)
    test_release(&input)
    test_text_frame(&ctx,&input,&s)
    testing.expect(t,s.result.editing && !s.result.changed && string(s.name[:s.name_length])=="hello world")
}

@(test)
the_keyboard_edits_the_field_and_enter_applies_it :: proc(t:^testing.T) {
    ctx:Context;s:Test_Text;input:Input
    test_text_init(t,&ctx,&s,&input)
    defer context_destroy(&ctx)
    e:=&ctx.edit
    step :: proc(ctx:^Context,input:^Input,s:^Test_Text,key:Key,modifiers:Modifiers={}) {
        test_key(input,key);input.modifiers=modifiers
        test_text_frame(ctx,input,s)
        input.modifiers={}
    }
    test_text_point(&ctx,&input,id(&ctx,"name"),0)
    test_text_frame(&ctx,&input,&s)
    test_press(&input);test_release(&input)
    test_text_frame(&ctx,&input,&s)
    // Without Shift an arrow collapses the selection to that edge.
    step(&ctx,&input,&s,.Left)
    testing.expect(t,e.cursor==0 && e.anchor==0)
    step(&ctx,&input,&s,.A,{.Primary})
    step(&ctx,&input,&s,.Right)
    testing.expect(t,e.cursor==11 && e.anchor==11)
    step(&ctx,&input,&s,.Left)
    testing.expect_value(t,e.cursor,10)
    step(&ctx,&input,&s,.Left,{.Shift})
    step(&ctx,&input,&s,.Left,{.Shift})
    lo,hi:=text_edit_selection(e)
    testing.expect(t,lo==8 && hi==10 && e.cursor==8)
    step(&ctx,&input,&s,.Right,{.Shift})
    lo,hi=text_edit_selection(e)
    testing.expect(t,lo==9 && hi==10)
    step(&ctx,&input,&s,.Home)
    testing.expect(t,e.cursor==0 && e.anchor==0)
    step(&ctx,&input,&s,.End,{.Shift})
    lo,hi=text_edit_selection(e)
    testing.expect(t,lo==0 && hi==11)
    step(&ctx,&input,&s,.Home,{.Shift})
    testing.expect(t,e.cursor==0 && e.anchor==0,"Shift moves the caret alone: back on its anchor nothing is selected")
    step(&ctx,&input,&s,.A,{.Primary})
    // Typing replaces the selection; Backspace and Delete remove around the caret.
    test_type(&input,"Hi!")
    test_text_frame(&ctx,&input,&s)
    testing.expect_value(t,text_edit_value(e),"Hi!")
    testing.expect(t,e.modified && !s.result.changed && string(s.name[:s.name_length])=="hello world","The value waits for Enter")
    step(&ctx,&input,&s,.Backspace)
    testing.expect_value(t,text_edit_value(e),"Hi")
    step(&ctx,&input,&s,.Home)
    step(&ctx,&input,&s,.Delete)
    testing.expect_value(t,text_edit_value(e),"i")
    step(&ctx,&input,&s,.Backspace)
    testing.expect_value(t,text_edit_value(e),"i")
    step(&ctx,&input,&s,.A,{.Primary})
    step(&ctx,&input,&s,.Backspace)
    testing.expect_value(t,text_edit_value(e),"")
    test_type(&input,"New name")
    test_text_frame(&ctx,&input,&s)
    step(&ctx,&input,&s,.Enter)
    testing.expect(t,s.result.committed && s.result.changed && !s.result.editing)
    testing.expect_value(t,string(s.name[:s.name_length]),"New name")
    testing.expect_value(t,ctx.edit.id,Id(0))
    test_text_frame(&ctx,&input,&s)
    testing.expect(t,!s.result.committed && test_paint(&ctx,"New name").caret==-1)
}

@(test)
escape_discards_the_edit_and_a_click_elsewhere_applies_it :: proc(t:^testing.T) {
    ctx:Context;s:Test_Text;input:Input
    test_text_init(t,&ctx,&s,&input)
    defer context_destroy(&ctx)
    begin :: proc(ctx:^Context,input:^Input,s:^Test_Text) {
        test_text_point(ctx,input,id(ctx,"name"),0)
        test_text_frame(ctx,input,s)
        test_press(input);test_release(input)
        test_text_frame(ctx,input,s)
    }
    begin(&ctx,&input,&s)
    test_type(&input,"draft")
    test_text_frame(&ctx,&input,&s)
    test_key(&input,.Escape)
    test_text_frame(&ctx,&input,&s)
    testing.expect(t,s.result.cancelled && !s.result.changed && !s.result.editing)
    // The Escape that cancelled the field is spent: escape() does not report it to the host.
    testing.expect(t,ctx.escape_used)
    testing.expect_value(t,string(s.name[:s.name_length]),"hello world")
    // A click away from the field applies what was typed.
    begin(&ctx,&input,&s)
    test_type(&input,"kept")
    test_text_frame(&ctx,&input,&s)
    input.pointer={500,400}
    test_text_frame(&ctx,&input,&s)
    test_press(&input);test_release(&input)
    test_text_frame(&ctx,&input,&s)
    testing.expect(t,s.result.committed && s.result.changed)
    testing.expect_value(t,string(s.name[:s.name_length]),"kept")
    // An untouched field commits nothing; Tab ends the edit too.
    begin(&ctx,&input,&s)
    test_key(&input,.Tab)
    test_text_frame(&ctx,&input,&s)
    testing.expect(t,s.result.committed && !s.result.changed && s.result.tab==1)
    // Clicking another field moves the edit there.
    begin(&ctx,&input,&s)
    test_type(&input,"moved")
    test_text_frame(&ctx,&input,&s)
    test_text_point(&ctx,&input,id(&ctx,"code"),0)
    test_text_frame(&ctx,&input,&s)
    test_press(&input);test_release(&input)
    test_text_frame(&ctx,&input,&s)
    testing.expect(t,s.result.committed && s.code_result.began && ctx.edit.id==id(&ctx,"code"))
    testing.expect_value(t,string(s.name[:s.name_length]),"moved")
    test_type(&input,"#12xyzAB99")
    test_text_frame(&ctx,&input,&s)
    testing.expect_value(t,text_edit_value(&ctx.edit),"#12AB99")
    test_type(&input,"00")
    test_text_frame(&ctx,&input,&s)
    testing.expect(t,text_edit_value(&ctx.edit)=="#12AB990","The field takes as many characters as its buffer")
}

@(test)
a_live_field_follows_every_key_and_shows_its_placeholder :: proc(t:^testing.T) {
    ctx:Context;s:Test_Text;input:Input
    test_text_init(t,&ctx,&s,&input)
    defer context_destroy(&ctx)
    placeholder:^Paint
    for &p in ctx.paints[:ctx.paint_count] {if p.placeholder=="Find" {placeholder=&p}}
    testing.expect(t,placeholder!=nil && placeholder.text=="")
    s.filter_length=copy(s.filter[:],"cr")
    test_text_point(&ctx,&input,id(&ctx,"filter"),0)
    test_text_frame(&ctx,&input,&s)
    test_press(&input);test_release(&input)
    test_text_frame(&ctx,&input,&s)
    lo,hi:=text_edit_selection(&ctx.edit)
    testing.expect(t,lo==2 && hi==2,"A filter keeps its text and puts the caret at its end")
    test_type(&input,"ate")
    test_text_frame(&ctx,&input,&s)
    testing.expect(t,s.filter_result.changed && s.filter_result.editing)
    testing.expect_value(t,string(s.filter[:s.filter_length]),"crate")
    test_key(&input,.Backspace)
    test_text_frame(&ctx,&input,&s)
    testing.expect_value(t,string(s.filter[:s.filter_length]),"crat")
    test_key(&input,.Escape)
    test_text_frame(&ctx,&input,&s)
    testing.expect(t,s.filter_result.cancelled)
    testing.expect_value(t,string(s.filter[:s.filter_length]),"crat")
}

@(test)
the_clipboard_goes_through_the_callbacks_of_the_host :: proc(t:^testing.T) {
    ctx:Context;s:Test_Text;input:Input
    test_text_init(t,&ctx,&s,&input)
    defer context_destroy(&ctx)
    e:=&ctx.edit
    key :: proc(ctx:^Context,input:^Input,s:^Test_Text,k:Key) {
        test_key(input,k);input.modifiers={.Primary}
        test_text_frame(ctx,input,s)
        input.modifiers={}
    }
    test_text_point(&ctx,&input,id(&ctx,"name"),0)
    test_text_frame(&ctx,&input,&s)
    test_press(&input);test_release(&input)
    test_text_frame(&ctx,&input,&s)
    text_edit_move(e,0,false);text_edit_move(e,5,true)
    key(&ctx,&input,&s,.C)
    testing.expect_value(t,string(s.clipboard[:s.clipboard_length]),"hello")
    testing.expect_value(t,text_edit_value(e),"hello world")
    text_edit_move(e,5,false);text_edit_move(e,11,true)
    key(&ctx,&input,&s,.X)
    testing.expect_value(t,string(s.clipboard[:s.clipboard_length])," world")
    testing.expect_value(t,text_edit_value(e),"hello")
    text_edit_move(e,0,false)
    key(&ctx,&input,&s,.V)
    testing.expect_value(t,text_edit_value(e)," worldhello")
    testing.expect_value(t,e.cursor,6)
    // What a field does not accept is not pasted, and letters with Ctrl are not typed.
    s.clipboard_length=copy(s.clipboard[:],"a\tb\néc")
    key(&ctx,&input,&s,.V)
    testing.expect_value(t,text_edit_value(e)," worldabchello")
    test_type(&input,"c");input.modifiers={.Primary}
    test_text_frame(&ctx,&input,&s)
    testing.expect_value(t,text_edit_value(e)," worldabchello")
}

@(test)
a_field_undoes_its_edits_and_goes_by_words :: proc(t:^testing.T) {
    ctx:Context;s:Test_Text;input:Input
    test_text_init(t,&ctx,&s,&input)
    defer context_destroy(&ctx)
    e:=&ctx.edit
    // One frame each: what is typed, or a key; want: the text after it.
    Step :: struct {typed:string,key:Key,modifiers:Modifiers,clip:string,want:Maybe(string)}
    Case :: struct {name,initial:string,steps:[]Step,cursor:int}
    P :: Modifiers{.Primary}
    undo,redo:=Step{key=.Z,modifiers=P},Step{key=.Y,modifiers=P}
    cases:=[]Case{
        {"undo takes back a paste and a run of typing","",{{typed="a"},{typed="b"},{typed="c"},{key=.V,modifiers=P,clip="xyz",want="abcxyz"},
            {key=.Z,modifiers=P,want="abc"},{key=.Z,modifiers=P,want=""},{key=.Y,modifiers=P,want="abc"},{key=.Z,modifiers=P+{.Shift},want="abcxyz"}},6},
        {"a paste over a selection is one step","hello world",{{key=.V,modifiers=P,clip="xyz",want="xyz"},undo},11},
        {"a run of Backspace is one step","hello world",{{key=.End},{key=.Backspace},{key=.Backspace},{key=.Delete},{key=.Backspace,want="hello wo"},undo},11},
        {"a moved caret ends a run","",{{typed="a"},{typed="b"},{key=.Left},{key=.Right},{typed="c",want="abc"},undo},2},
        {"undo past the first edit and redo past the last do nothing","ab",{{key=.End},{typed="c"},undo,undo,undo,{key=.Z,modifiers=P,want="ab"},redo,{key=.Y,modifiers=P,want="abc"}},3},
        {"an edit forgets what was undone","",{{typed="a"},undo,{typed="b"},{key=.Y,modifiers=P,want="b"}},1},
        {"the caret goes by words","hello big world",{{key=.End},{key=.Left,modifiers=P},{key=.Left,modifiers=P},{key=.Backspace,modifiers=P,want="big world"},
            {key=.Right,modifiers=P},{key=.Delete,modifiers=P,want="big"},undo,{key=.Right,modifiers=P+{.Shift}}},9},
    }
    for c in cases {
        s.name_length=copy(s.name[:],c.initial)
        edit_request(&ctx,id(&ctx,"name"))
        test_text_frame(&ctx,&input,&s)
        for step,i in c.steps {
            if step.clip!="" {s.clipboard_length=copy(s.clipboard[:],step.clip)}
            if step.typed!="" {test_type(&input,step.typed)} else {test_key(&input,step.key)}
            input.modifiers=step.modifiers
            test_text_frame(&ctx,&input,&s)
            input.modifiers={}
            if want,ok:=step.want.?;ok {testing.expectf(t,text_edit_value(e)==want,"%s, step %v: %q",c.name,i+1,text_edit_value(e))}
        }
        testing.expectf(t,e.cursor==c.cursor,"%s: the caret at %v",c.name,e.cursor)
        test_key(&input,.Escape)
        test_text_frame(&ctx,&input,&s)
    }
}

@(test)
long_text_scrolls_to_keep_the_caret_in_sight :: proc(t:^testing.T) {
    ctx:Context;s:Test_Text;input:Input
    test_text_init(t,&ctx,&s,&input)
    defer context_destroy(&ctx)
    e:=&ctx.edit
    s.name_length=copy(s.name[:],"abcdefghijklmnopqrstuvwxyz0123")
    test_text_frame(&ctx,&input,&s)
    test_text_point(&ctx,&input,id(&ctx,"name"),0)
    test_text_frame(&ctx,&input,&s)
    test_press(&input);test_release(&input)
    test_text_frame(&ctx,&input,&s)
    test_text_frame(&ctx,&input,&s)
    // 30 characters are 150 wide in a field with 104 of room.
    testing.expect_value(t,e.scroll,f32(46))
    test_key(&input,.Home)
    test_text_frame(&ctx,&input,&s)
    testing.expect_value(t,e.scroll,f32(0))
    test_key(&input,.End)
    test_text_frame(&ctx,&input,&s)
    testing.expect_value(t,e.scroll,f32(46))
    paint:=test_paint(&ctx,"abcdefghijklmnopqrstuvwxyz0123")
    testing.expect_value(t,paint.scroll,f32(46))
    // A click lands on the character that is drawn there.
    test_text_point(&ctx,&input,id(&ctx,"name"),2)
    test_text_frame(&ctx,&input,&s)
    test_press(&input);test_release(&input)
    test_text_frame(&ctx,&input,&s)
    testing.expect_value(t,e.cursor,11)
}

@(test)
a_field_that_stops_being_built_ends_its_edit :: proc(t:^testing.T) {
    ctx:Context;s:Test_Text;input:Input
    test_text_init(t,&ctx,&s,&input)
    defer context_destroy(&ctx)
    test_text_point(&ctx,&input,id(&ctx,"name"),0)
    test_text_frame(&ctx,&input,&s)
    test_press(&input);test_release(&input)
    test_text_frame(&ctx,&input,&s)
    testing.expect(t,ctx.edit.id!=0)
    frame:=test_frame(&ctx,&input,nil)
    testing.expect(t,ctx.edit.id==0 && !frame.keyboard_consumed)
}

@(test)
a_multiline_field_keeps_its_breaks_wraps_and_moves_by_lines :: proc(t:^testing.T) {
    ctx:Context;s:Test_Text;input:Input
    test_text_init(t,&ctx,&s,&input)
    defer context_destroy(&ctx)
    e:=&ctx.edit
    note:=id(&ctx,"note")
    rect,_:=widget_rect(&ctx,note)
    testing.expect(t,rect.h>=3*10*TEXT_LINE,"Three rows of text fit in the field")
    test_text_point(&ctx,&input,note,0)
    test_text_frame(&ctx,&input,&s)
    test_press(&input)
    test_text_frame(&ctx,&input,&s)
    test_release(&input)
    testing.expect(t,s.note_result.editing && e.multiline)
    // Enter adds a line instead of applying the text.
    test_type(&input,"ab")
    test_text_frame(&ctx,&input,&s)
    test_key(&input,.Enter)
    test_text_frame(&ctx,&input,&s)
    test_type(&input,"cd")
    test_text_frame(&ctx,&input,&s)
    testing.expect_value(t,text_edit_value(e),"ab\ncd")
    testing.expect(t,s.note_result.editing && !s.note_result.committed,"Enter keeps the field open")
    // Up and Down keep the units the caret had from the start of its line.
    testing.expect_value(t,e.cursor,5)
    test_key(&input,.Up)
    test_text_frame(&ctx,&input,&s)
    testing.expect_value(t,e.cursor,2)
    test_key(&input,.Down)
    test_text_frame(&ctx,&input,&s)
    testing.expect_value(t,e.cursor,5)
    // Home and End belong to the line, not to the whole text.
    test_key(&input,.Home)
    test_text_frame(&ctx,&input,&s)
    testing.expect_value(t,e.cursor,3)
    test_key(&input,.End)
    test_text_frame(&ctx,&input,&s)
    testing.expect_value(t,e.cursor,5)
    // A long line wraps inside the field and the caret stays on its own row.
    _,_,_,count:=text_edit_line_of(&ctx,e,10,e.cursor)
    testing.expect_value(t,count,2)
    test_key(&input,.Backspace)
    test_text_frame(&ctx,&input,&s)
    test_key(&input,.Backspace)
    test_text_frame(&ctx,&input,&s)
    testing.expect_value(t,text_edit_value(e),"ab\n")
    test_type(&input,"one two three four five six")
    test_text_frame(&ctx,&input,&s)
    _,_,_,count=text_edit_line_of(&ctx,e,10,e.cursor)
    testing.expect(t,count>2,"The text wraps at the width of the field")
    _,second:=text_edit_line_at(&ctx,e,10,1)
    testing.expect(t,e.wrap>0 && second<e.length)
    // The field commits its whole text, line breaks included.
    test_key(&input,.Tab)
    test_text_frame(&ctx,&input,&s)
    testing.expect(t,s.note_result.committed)
    testing.expect_value(t,string(s.note[:s.note_length]),"ab\none two three four five six")
}

@(test)
a_multiline_edit_holds_a_long_message_and_moves_through_all_its_lines :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    long:[1024]u8
    for i in 0..<len(long) {long[i]='x' if i%2==0 else '\n'}
    e:Text_Edit
    text_edit_begin(&e,1,string(long[:]),.Any,TEXT_EDIT_CAPACITY,false,true)
    testing.expect_value(t,e.length,1024)
    e.wrap=200
    row,_,_,count:=text_edit_line_of(&ctx,&e,10,e.cursor)
    testing.expect_value(t,count,513)
    testing.expect_value(t,row,512)
    for _ in 0..<512 {text_edit_line_move(&ctx,&e,10,-1,false)}
    testing.expect_value(t,e.cursor,0)
    for _ in 0..<300 {text_edit_line_move(&ctx,&e,10,1,false)}
    row,_,_,_=text_edit_line_of(&ctx,&e,10,e.cursor)
    testing.expect_value(t,row,300)
}
