package author

import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:ui"

// The params of a reading read against the types of the assets, with no file.
call_args :: proc(reading:^Reading,types:^asset.Types,params:string) -> Tree_Args {
    reading^={raw=params,allocator=context.temp_allocator}
    args:=Tree_Args{reading=reading,types=types}
    args.keys,args.values,_=tree_object(reading,params,"params")
    return args
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
    reading:Reading
    args:=call_args(&reading,&types,"{}")
    _,_,ok:=document_apply(&args,&r,-1,`{"styles":{"primary":{"family":"Control","defaults":["Button","Checkbox"]}}}`)
    if !testing.expectf(t,ok,"%s",reading.problem) {return}
    primary:=tree_style_row(&r,"primary")
    testing.expect(t,.Button not_in r.style_infos[look].defaults)
    third:=records_insert(&r,0,.Button)
    testing.expect_value(t,int(r.nodes[third].style),primary)
    check:=records_insert(&r,0,.Checkbox)
    testing.expect_value(t,int(r.nodes[check].style),primary)
    // A kind takes only a style of its family.
    args=call_args(&reading,&types,"{}")
    _,_,ok=document_apply(&args,&r,-1,`{"styles":{"primary":{"family":"Control","defaults":["Text"]}}}`)
    testing.expect(t,!ok)
    testing.expect(t,strings.has_prefix(reading.problem,"styles.primary: defaults: a Text takes a style of family Text"),reading.problem)
}
