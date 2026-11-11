package ui

import "base:runtime"
import "core:math"
import "core:mem"
import "core:testing"

// Shared by the tests of the package.

TEST_SMALL :: Context_Desc{max_elements=1024,max_vertices=65536,max_widgets=512,max_text=16384,no_font=true}
TEST_FONT :: Context_Desc{max_elements=1024,max_vertices=65536,max_widgets=512,max_text=16384}

Test_Build :: #type proc(ctx:^Context,user:rawptr)

test_input :: proc(width:f32=800,height:f32=600) -> Input {
    return {size={width,height},dt=1.0/60,pointer={-100,-100}}
}
// One frame: the input as it is, then its edges are forgotten.
test_frame :: proc(ctx:^Context,input:^Input,build:Test_Build,user:rawptr=nil) -> Frame {
    frame_begin(ctx,input^)
    if build!=nil {build(ctx,user)}
    frame:=frame_end(ctx)
    input_next_frame(input)
    return frame
}
test_rect :: proc(t:^testing.T,ctx:^Context,id:Id,loc:=#caller_location) -> Rect {
    rect,found:=widget_rect(ctx,id)
    testing.expectf(t,found,"element %v was laid out",id,loc=loc)
    return rect
}
test_near :: proc(a,b:f32,tolerance:f32=0.01) -> bool {return abs(a-b)<=tolerance}
test_rect_near :: proc(a,b:Rect,tolerance:f32=0.01) -> bool {
    return test_near(a.x,b.x,tolerance)&&test_near(a.y,b.y,tolerance)&&test_near(a.w,b.w,tolerance)&&test_near(a.h,b.h,tolerance)
}
// Moves the pointer onto a rectangle and presses or releases the left button.
test_point :: proc(input:^Input,rect:Rect) {input.pointer={rect.x+rect.w*0.5,rect.y+rect.h*0.5}}
test_press :: proc(input:^Input,clicks:u8=1) {input_button(input,.Left,true,clicks)}
test_release :: proc(input:^Input) {input_button(input,.Left,false)}
test_key :: proc(input:^Input,key:Key) {
    input.keys_pressed+={key};input.keys_repeated+={key}
}
// The paint of the last frame that shows this text.
// The paint of what says text: a widget that draws it, or the text whose first span it is.
test_paint :: proc(ctx:^Context,text:string) -> ^Paint {
    for &p in test_text_pieces(ctx) {if p.text==text {return &p}}
    for &p in ctx.paints[:ctx.paint_count] {if p.text==text {return &p}}
    return nil
}
// Every piece of every line of the texts of the frame as the paint it would
// be: what it says, its style, the fill behind it, and Box when it is a chip.
test_text_pieces :: proc(ctx:^Context) -> []Paint {
    t:=&ctx.layout
    out:=make([dynamic]Paint,context.temp_allocator)
    for &leaf in t.texts[:t.text_count] {
        own:=cast(^Paint)t.nodes[leaf.node].custom
        for &line in t.lines[leaf.lines_first:][:leaf.lines_len] {
            for &piece in t.pieces[line.pieces_first:][:line.pieces_len] {
                s:=&t.spans[piece.span]
                if s.box {continue}
                style,decoration:=text_piece_style(own,s)
                p:=own^
                p.kind,p.text,p.style,p.size,p.text_color,p.decoration=.Box if s.pad>0 else .None,s.text[piece.start:][:piece.length],style,style.size,style.color,decoration
                p.fill=s.back
                append(&out,p)
            }
        }
    }
    return out[:]
}
// Whether a paint is that of a text.
test_paint_is_text :: proc(p:Paint) -> bool {return p.kind==.None && p.style.size>0}
// The lines the layout broke the text of the element id into, as they are drawn.
test_text_lines :: proc(ctx:^Context,id:Id,out:[]string) -> int {
    t:=&ctx.layout
    index:=layout_index(t,id)
    if index==0 || t.nodes[index].text<0 {return 0}
    leaf:=&t.texts[t.nodes[index].text]
    for &line,i in t.lines[leaf.lines_first:][:leaf.lines_len] {
        if i>=len(out) {break}
        out[i]=""
        if line.pieces_len==0 {continue}
        first,last:=&t.pieces[line.pieces_first],&t.pieces[line.pieces_first+line.pieces_len-1]
        if first.span==last.span {out[i]=t.spans[first.span].text[first.start:last.start+last.length]}
    }
    return int(leaf.lines_len)
}
test_type :: proc(input:^Input,text:string) {for c in text {input_text(input,c)}}

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

@(test)
context_is_created_with_the_capacities_of_its_desc :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,{max_elements=512,max_text_words=1024,max_clips=12,max_widgets=64,max_paints=128,max_vertices=1000,max_commands=8,max_text=256,max_scopes=4,max_panels=2,no_font=true}))
    defer context_destroy(&ctx)
    testing.expect_value(t,len(ctx.widgets),64)
    testing.expect_value(t,len(ctx.paints),128)
    testing.expect_value(t,len(ctx.draw.vertices),1000)
    testing.expect_value(t,len(ctx.draw.commands),8)
    testing.expect_value(t,len(ctx.text),256)
    testing.expect_value(t,len(ctx.scopes),4)
    testing.expect_value(t,len(ctx.panels),2)
    testing.expect_value(t,len(ctx.clips),13)
    testing.expect_value(t,len(ctx.layout.nodes),513)
    testing.expect_value(t,len(ctx.layout.measures[0].words),1024)
    testing.expect_value(t,len(ctx.layout.measures[1].chars),256)
}

@(test)
context_creation_fails_without_memory_and_leaves_nothing :: proc(t:^testing.T) {
    // An allocator that refuses everything after a few requests.
    Limited :: struct {backing:runtime.Allocator,left:int}
    limited_proc :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,location:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
        limited:=cast(^Limited)data
        #partial switch mode {
        case .Alloc,.Alloc_Non_Zeroed:
            if limited.left<=0 {return nil,.Out_Of_Memory}
            limited.left-=1
        }
        return limited.backing.procedure(limited.backing.data,mode,size,alignment,old_memory,old_size,location)
    }
    // Every request refused in turn, until there are enough to succeed.
    created:=false
    for allowed in 0..<64 {
        limited:=Limited{context.allocator,allowed}
        ctx:Context
        desc:=TEST_SMALL
        desc.allocator={procedure=limited_proc,data=&limited}
        if test_context_init(&ctx,desc) {context_destroy(&ctx);created=true;break}
        testing.expect_value(t,len(ctx.layout.nodes),0)
        testing.expect_value(t,len(ctx.widgets),0)
    }
    testing.expect(t,created)
}

@(test)
ids_depend_on_name_index_and_scope_and_are_never_zero :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    a,b,c:=id(&ctx,"row"),id(&ctx,"row",1),id(&ctx,"column")
    testing.expect(t,a!=b && a!=c && b!=c)
    testing.expect_value(t,id(&ctx,"row"),a)
    id_push(&ctx,id(&ctx,"list"))
    inner:=id(&ctx,"row")
    testing.expect(t,inner!=a,"A scope changes the ids made inside it")
    testing.expect_value(t,id_derive(&ctx,id(&ctx,"x"),"y"),id_derive(&ctx,id(&ctx,"x"),"y"))
    id_pop(&ctx)
    testing.expect_value(t,id_derive(&ctx,id(&ctx,"list"),"row"),inner)
    testing.expect(t,id(&ctx,"")!=0)
}

// A widget is found by its id as the frame before left it: the first of those
// that share one, and none of a frame further back, also when the generations
// of the table start over.
@(test)
widgets_are_found_by_id_as_the_previous_frame_left_them :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    input:=test_input()
    twice,once,later:=id(&ctx,"twice"),id(&ctx,"once"),id(&ctx,"later")
    test_frame(&ctx,&input,proc(ctx:^Context,_:rawptr) {
        widget_add(ctx,id(ctx,"twice"),{});widget_add(ctx,id(ctx,"once"),{});widget_add(ctx,id(ctx,"twice"),{})
    })
    testing.expect(t,widget_previous(&ctx,twice)==&ctx.previous[0] && widget_previous(&ctx,once)==&ctx.previous[1])
    testing.expect(t,widget_previous(&ctx,later)==nil)
    ctx.previous_ids.generation=max(u32)
    for _ in 0..<2 {
        test_frame(&ctx,&input,proc(ctx:^Context,_:rawptr) {
            widget_add(ctx,id(ctx,"later"),{});widget_add(ctx,id(ctx,"once"),{})
        })
        testing.expect(t,widget_previous(&ctx,later)==&ctx.previous[0] && widget_previous(&ctx,once)==&ctx.previous[1])
        _,found:=widget_rect(&ctx,twice)
        testing.expect(t,!found,"what the last frame did not build is not found")
    }
}

@(test)
frame_text_outlives_the_buffer_it_came_from_and_counts_what_does_not_fit :: proc(t:^testing.T) {
    ctx:Context
    desc:=TEST_SMALL
    desc.max_text=16
    testing.expect(t,test_context_init(&ctx,desc))
    defer context_destroy(&ctx)
    input:=test_input()
    frame_begin(&ctx,input)
    buffer:=[8]u8{'a','b','c','d','e','f','g','h'}
    stored:=text_store(&ctx,string(buffer[:]))
    buffer={}
    testing.expect_value(t,stored,"abcdefgh")
    testing.expect_value(t,text_store(&ctx,"12345678"),"12345678")
    testing.expect_value(t,text_store(&ctx,"x"),"")
    testing.expect_value(t,ctx.stats.dropped_text,u32(1))
    frame:=frame_end(&ctx)
    testing.expect(t,frame.overflow)
    frame_begin(&ctx,input)
    testing.expect_value(t,text_store(&ctx,"again"),"again")
    testing.expect(t,!frame_end(&ctx).overflow,"Overflow is of one frame; the counters add up")
    testing.expect_value(t,ctx.stats.dropped_text,u32(1))
}

@(test)
boxes_are_laid_out_in_rows_and_columns :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    input:=test_input(800,600)
    test_frame(&ctx,&input,proc(ctx:^Context,user:rawptr) {
        if box(ctx,{id=id(ctx,"root"),width=fixed(400),height=fixed(300),direction=.Column,padding={10,20,30,40},gap=5,track=true}) {
            if box(ctx,{id=id(ctx,"top"),width=GROW,height=fixed(50),gap=10,track=true}) {
                box_begin(ctx,{id=id(ctx,"a"),width=fixed(100),height=GROW,track=true});box_end(ctx,{id=id(ctx,"a")})
                box_begin(ctx,{id=id(ctx,"b"),width=GROW,height=GROW,track=true});box_end(ctx,{id=id(ctx,"b")})
            }
            if box(ctx,{id=id(ctx,"rest"),width=percent(0.5),height=GROW,align_x=.End,align_y=.Center,track=true}) {
                box_begin(ctx,{id=id(ctx,"c"),width=fixed(20),height=fixed(20),track=true});box_end(ctx,{id=id(ctx,"c")})
            }
        }
    })
    testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"root")),{0,0,400,300}))
    testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"top")),{10,20,360,50}))
    testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"a")),{10,20,100,50}))
    testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"b")),{120,20,250,50}))
    testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"rest")),{10,75,180,185}))
    testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"c")),{170,157.5,20,20}))
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
}

@(test)
floating_boxes_hang_from_the_surface_and_from_its_safe_area :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    input:=test_input(800,600)
    input.safe={40,10,20,30}
    test_frame(&ctx,&input,proc(ctx:^Context,user:rawptr) {
        box_begin(ctx,{id=id(ctx,"corner"),width=fixed(100),height=fixed(50),float={to=.Surface,anchor=.Bottom_Right,pivot=.Bottom_Right,offset={-10,-10},layer=LAYER_PANEL},track=true})
        box_end(ctx,{id=id(ctx,"corner"),float={to=.Surface}})
        if anchored(ctx,id(ctx,"hud"),.Top_Left,{5,5},{width=fixed(60),height=fixed(20)}) {spacer_tracked(ctx,"hud_in")}
        if anchored(ctx,id(ctx,"ammo"),.Bottom_Right,{0,0},{width=fixed(60),height=fixed(20)}) {spacer_tracked(ctx,"ammo_in")}
        if anchored(ctx,id(ctx,"title"),.Center,{0,0},{width=fixed(100),height=fixed(40)}) {spacer_tracked(ctx,"title_in")}
        if anchored(ctx,id(ctx,"raw"),.Top_Left,{5,5},{width=fixed(60),height=fixed(20)},0,false) {spacer_tracked(ctx,"raw_in")}
    })
    testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"corner")),{690,540,100,50}))
    testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"hud_in")),{45,15,60,20}),"Anchored elements stay inside the safe area")
    testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"ammo_in")),{720,550,60,20}))
    testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"title_in")),{360,270,100,40}))
    testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"raw_in")),{5,5,60,20}))
}

@(test)
elements_beyond_the_capacity_are_refused_and_counted :: proc(t:^testing.T) {
    ctx:Context
    desc:=TEST_SMALL
    desc.max_elements=64
    testing.expect(t,test_context_init(&ctx,desc))
    defer context_destroy(&ctx)
    input:=test_input()
    frame:=test_frame(&ctx,&input,proc(ctx:^Context,user:rawptr) {
        if box(ctx,{id=id(ctx,"column"),width=fixed(200),direction=.Column,track=true}) {
            for i in 0..<100 {
                // Containers and what they hold are skipped together.
                if box(ctx,{id=id(ctx,"row",i+1),width=GROW,height=fixed(10),track=true}) {label(ctx,"text")}
            }
        }
    })
    testing.expect(t,frame.overflow)
    testing.expect(t,ctx.stats.dropped_elements>0)
    testing.expect(t,int(ctx.stats.elements)<64)
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
    first:=test_rect(t,&ctx,id(&ctx,"row",1))
    testing.expect(t,test_rect_near(first,{0,0,200,10}),"What fits is laid out")
    // A frame that fits follows without trace of the overflow.
    frame=test_frame(&ctx,&input,proc(ctx:^Context,user:rawptr) {label(ctx,"fits")})
    testing.expect(t,!frame.overflow)
    _=math.PI;_=mem.Byte
}

// An element that fills its parent and keeps its rectangle.
spacer_tracked :: proc(ctx:^Context,name:string) {
    box_begin(ctx,{id=id(ctx,name),width=GROW,height=GROW,track=true})
    box_end(ctx,{id=id(ctx,name)})
}

mem_nil_allocator :: proc() -> runtime.Allocator {
    refuse :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,location:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
        #partial switch mode {
        case .Alloc,.Alloc_Non_Zeroed,.Resize,.Resize_Non_Zeroed:return nil,.Out_Of_Memory
        }
        return nil,nil
    }
    return {procedure=refuse}
}

Test_Nesting :: struct {probe:Id,layer:i16,effect:u16,refused,containers:int,clip,scissor:Rect,clipping:bool}
test_nesting :: proc(ctx:^Context) -> Test_Nesting {
    d:=&ctx.draw
    return {id(ctx,"probe"),ctx.layer,ctx.effect_clip,ctx.effect_refused,ctx.clip_depth,d.clip,d.scissor,d.clipping}
}
test_nested_float :: proc(i:int) -> Box {return {float={to=.Parent,layer=i16(i+1)},width=fixed(10),height=fixed(10)}}
test_nested_layer :: proc(i:int) -> Box {return {layer={enabled=true,opacity=1},fill={255,255,255,255},width=fixed(10),height=fixed(10)}}

@(test)
nesting_beyond_a_stack_is_not_applied_is_counted_and_unwinds :: proc(t:^testing.T) {
    Case :: struct {
        name:string,
        capacity:int,
        push,pop:proc(ctx:^Context,i:int),
        dropped:proc(s:^Stats) -> u32,
    }
    nesting :: proc(s:^Stats) -> u32 {return s.dropped_nesting}
    clips :: proc(s:^Stats) -> u32 {return s.dropped_clips}
    cases:=[]Case{
        {"id scopes",ID_STACK_DEPTH,proc(ctx:^Context,i:int) {id_push(ctx,id(ctx,"scope",i+1))},proc(ctx:^Context,i:int) {id_pop(ctx)},nesting},
        {"floats",LAYER_STACK_DEPTH,proc(ctx:^Context,i:int) {box_begin(ctx,test_nested_float(i))},proc(ctx:^Context,i:int) {box_end(ctx,test_nested_float(i))},nesting},
        {"layers",ID_STACK_DEPTH,proc(ctx:^Context,i:int) {box_begin(ctx,test_nested_layer(i))},proc(ctx:^Context,i:int) {box_end(ctx,test_nested_layer(i))},nesting},
        {"clips",CLIP_DEPTH,proc(ctx:^Context,i:int) {clip_push(ctx,{0,0,f32(400-i),300})},proc(ctx:^Context,i:int) {clip_pop(ctx)},clips},
        {"scissors",SCISSOR_DEPTH,proc(ctx:^Context,i:int) {scissor_push(ctx,{0,0,f32(400-i),300})},proc(ctx:^Context,i:int) {scissor_pop(ctx)},clips},
        {"suspended clips",LAYOUT_DEPTH+POPUP_DEPTH,proc(ctx:^Context,i:int) {clips_suspend(ctx)},proc(ctx:^Context,i:int) {clips_resume(ctx)},clips},
    }
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    input:=test_input()
    for c in cases {
        for over in ([]int{1,20}) {
            before:=c.dropped(&ctx.stats)
            frame_begin(&ctx,input)
            empty:=test_nesting(&ctx)
            for i in 0..<c.capacity {c.push(&ctx,i)}
            full:=test_nesting(&ctx)
            testing.expectf(t,full!=empty,"%s: a push that fits is applied",c.name)
            for i in 0..<over {c.push(&ctx,c.capacity+i)}
            testing.expectf(t,test_nesting(&ctx)==full,"%s: %d pushes past the capacity change nothing",c.name,over)
            draw_rect(&ctx,{0,0,10,10},{255,255,255,255})
            for i:=over-1;i>=0;i-=1 {c.pop(&ctx,c.capacity+i)}
            testing.expectf(t,test_nesting(&ctx)==full,"%s: their %d pops take nothing off",c.name,over)
            for i:=c.capacity-1;i>=0;i-=1 {c.pop(&ctx,i)}
            testing.expectf(t,test_nesting(&ctx)==empty,"%s: the pops of what was pushed leave it as it began",c.name)
            c.pop(&ctx,0)
            testing.expectf(t,test_nesting(&ctx)==empty,"%s: a pop with nothing pushed does nothing",c.name)
            frame:=frame_end(&ctx)
            testing.expectf(t,frame.overflow && c.dropped(&ctx.stats)-before>=u32(over),"%s: %d pushes past the capacity are counted",c.name,over)
            testing.expectf(t,len(frame.vertices)>0,"%s: the frame is drawn",c.name)
            frame=test_frame(&ctx,&input,proc(ctx:^Context,user:rawptr) {label(ctx,"fits")})
            testing.expectf(t,!frame.overflow,"%s: the next frame carries nothing of it",c.name)
        }
    }
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
}

@(test)
a_frame_with_ends_missing_or_repeated_is_closed_and_counted :: proc(t:^testing.T) {
    Case :: struct {name:string,build:Test_Build,counted:bool}
    cases:=[]Case{
        {"a clipping box left open",proc(ctx:^Context,user:rawptr) {
            box_begin(ctx,{id=id(ctx,"open"),width=fixed(120),height=fixed(40),clip_x=true,clip_y=true,track=true})
            label(ctx,"inside")
        },true},
        {"a world panel left open",proc(ctx:^Context,user:rawptr) {
            if world_panel_begin(ctx,id(ctx,"panel"),{size={100,50},position={0,0,-2},fill={0,0,0,255}}) {label(ctx,"inside")}
        },true},
        {"a composition left open",proc(ctx:^Context,user:rawptr) {
            composition_begin(ctx,{0,0,100,100},{enabled=true,opacity=0.5})
            draw_rect(ctx,{0,0,10,10},{255,255,255,255})
        },true},
        {"a frame begun inside a frame",proc(ctx:^Context,user:rawptr) {
            box_begin(ctx,{id=id(ctx,"lost"),width=fixed(10),height=fixed(10)})
            frame_begin(ctx,test_input())
            label(ctx,"kept")
        },true},
        {"a world panel inside a world panel",proc(ctx:^Context,user:rawptr) {
            if world_panel(ctx,id(ctx,"outer"),{size={100,50},position={0,0,-2}}) {
                if world_panel(ctx,id(ctx,"inner"),{size={100,50},position={0,0,-2}}) {label(ctx,"never")}
                label(ctx,"outer")
            }
        },false},
        {"ends without a begin",proc(ctx:^Context,user:rawptr) {
            id_pop(ctx);clip_pop(ctx);scissor_pop(ctx);composition_end(ctx);world_panel_end(ctx)
            box_end(ctx,{float={to=.Parent},layer={enabled=true}})
            label(ctx,"kept")
        },false},
    }
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    testing.expect_value(t,len(frame_end(&ctx).vertices),0)
    testing.expect_value(t,ctx.stats.layout_errors,u32(1))
    input:=test_input()
    for c in cases {
        errors:=ctx.stats.layout_errors
        frame:=test_frame(&ctx,&input,c.build)
        testing.expectf(t,(ctx.stats.layout_errors>errors)==c.counted,"%s: counted in layout_errors",c.name)
        begins,ends:=0,0
        for command in frame.commands {
            if command.kind==.Begin_Layer {begins+=1}
            if command.kind==.End_Layer {ends+=1}
        }
        testing.expectf(t,begins==ends,"%s: every layer the frame begins ends",c.name)
        errors=ctx.stats.layout_errors
        frame=test_frame(&ctx,&input,proc(ctx:^Context,user:rawptr) {label(ctx,"fits")})
        testing.expectf(t,!frame.overflow && ctx.stats.layout_errors==errors,"%s: the next frame carries nothing of it",c.name)
    }
    test_frame(&ctx,&input,cases[0].build)
    testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"open")),{0,0,120,40}),"a box left open is laid out as if the frame closed it")
}
