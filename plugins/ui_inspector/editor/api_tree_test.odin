package ui_inspector_editor

import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:editor/api"
import "mirai:std/serial"
import "mirai:ui"

// The params of a call read against the types of the assets, with no file.
@(private)
call_args :: proc(call:^api.Call,types:^asset.Types,params:string) -> Tree_Args {
    call^={raw=params,allocator=context.temp_allocator}
    args:=Tree_Args{call=call,types=types}
    args.keys,args.values,_=tree_object(call,params,"params")
    return args
}

@(test)
a_node_added_with_its_children_is_a_tree_in_pre_order :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    r:Records
    if !testing.expect(t,records_load(&r,ui_empty_data(),context.allocator)) {return}
    defer records_destroy(&r)
    call:api.Call
    args:=call_args(&call,&types,`{"kind":"Box","name":"panel","children":[
        {"kind":"Text","name":"title","text":"Inventory"},
        {"kind":"Box","name":"actions","fields":{"layout":{"gap":8}},"children":[{"kind":"Button","name":"use","text":"Use"},{"kind":"Button","name":"drop"}]}]}`)
    row:=tree_add_apply(&args,&r)
    if !testing.expectf(t,row==1,"%v %s",row,call.error.message) {return}
    Expected :: struct {name:string,parent:i32}
    expected:=[?]Expected{{"panel",-1},{"title",1},{"actions",1},{"use",3},{"drop",3}}
    if !testing.expect_value(t,len(r.nodes),1+len(expected)) {return}
    for e,i in expected {
        n:=&r.nodes[i+1]
        testing.expect_value(t,serial.text_field(n.name[:]),e.name)
        testing.expect_value(t,n.parent,e.parent)
    }
    testing.expect_value(t,records_text(&r,r.nodes[2].text),"Inventory")
    testing.expect_value(t,r.nodes[3].layout.gap,f32(8))
    testing.expect(t,records_load_as_tree(&r))
}

@(test)
a_new_node_takes_the_style_the_file_names_for_its_kind :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    r:Records
    if !testing.expect(t,records_load(&r,ui_empty_data(),context.allocator)) {return}
    defer records_destroy(&r)
    // A box next to a card is not a card unless the file says so.
    append(&r.styles,ui.Node_Style{radius=8})
    append(&r.style_infos,ui.Tree_Style_Info{family=.Box})
    card:=records_insert(&r,0,.Box)
    r.nodes[card].style=u16(len(r.styles)-1)
    beside:=records_insert(&r,0,.Box)
    testing.expect_value(t,r.nodes[beside].style,u16(0))
    // The first button brings the look of its kind, and the file names it for the next ones.
    first:=records_insert(&r,0,.Button)
    look:=int(r.nodes[first].style)
    testing.expect(t,look>0 && .Button in r.style_infos[look].defaults)
    second:=records_insert(&r,0,.Button)
    testing.expect_value(t,int(r.nodes[second].style),look)
    // A style named for them takes its place.
    call:api.Call
    args:=call_args(&call,&types,`{"style":"primary","family":"Control","defaults":["Button","Checkbox"]}`)
    primary:=tree_style_apply(&args,&r)
    if !testing.expectf(t,primary>0,"%s",call.error.message) {return}
    testing.expect(t,.Button not_in r.style_infos[look].defaults)
    third:=records_insert(&r,0,.Button)
    testing.expect_value(t,int(r.nodes[third].style),primary)
    check:=records_insert(&r,0,.Checkbox)
    testing.expect_value(t,int(r.nodes[check].style),primary)
    // A kind takes only a style of its family.
    wrong:=call_args(&call,&types,`{"style":"primary","defaults":["Text"]}`)
    testing.expect_value(t,tree_style_apply(&wrong,&r),-1)
    testing.expect(t,strings.has_prefix(call.error.message,"defaults: a Text takes a style of family Text"),call.error.message)
}

@(test)
a_child_that_cannot_be_added_says_where_it_is :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    Case :: struct {params,message:string}
    cases:=[?]Case{
        {`{"kind":"Box","children":[{"kind":"Text"},{"kind":"Box","children":[{"kind":"Nope"}]}]}`,"children[1]: children[0]: kind 'Nope'"},
        {`{"kind":"Text","children":[{"kind":"Text"}]}`,"children[0]: parent: a Text holds no nodes"},
        {`{"kind":"Box","children":[{"kind":"Text","parent":"panel"}]}`,"children[0].parent: a child goes last"},
        {`{"kind":"Box","children":{"kind":"Text"}}`,"children must be an array"},
    }
    for c in cases {
        r:Records
        if !testing.expect(t,records_load(&r,ui_empty_data(),context.allocator)) {return}
        call:api.Call
        args:=call_args(&call,&types,c.params)
        testing.expect_value(t,tree_add_apply(&args,&r),-1)
        testing.expectf(t,strings.has_prefix(call.error.message,c.message),"%s gave '%s'",c.params,call.error.message)
        records_destroy(&r)
    }
}

