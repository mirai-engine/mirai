package host

import "core:mem"
import "core:testing"
import "mirai:asset"
import anim "mirai:std/anim"
import "mirai:std/base"
import "mirai:ui"

@(private="file")
ROUNDTRIP_ID :: base.Asset_Id{0x51,7}

// Records of a .ui with a node of each family, named styles with a variant,
// a font, an image, a clip, a sequence, a localized text, a grid and paths of
// the game.
@(private="file")
Roundtrip_Records :: struct {
    nodes:[10]ui.Tree_Node,
    styles:[3]ui.Node_Style,
    style_infos:[3]ui.Tree_Style_Info,
    variants:[1]ui.Tree_Style_Variant,
    images:[1]ui.Tree_Image,
    fonts:[1]ui.Tree_Font,
    anims:[3]ui.Tree_Anim,
    tracks:[2]ui.Tree_Track,
    keys:[4]anim.Keyframe,
    parts:[2]ui.Anim,
    anim_sets:[1]ui.Anim_Set,
    grid_tracks:[1]ui.Grid_Tracks,
    text:[dynamic]u8,
}

@(private="file")
roundtrip_records :: proc(r:^Roundtrip_Records) -> ui.Tree_Data {
    r.text=make([dynamic]u8,context.temp_allocator)
    t:=&r.text
    r.styles={{},{text={font=ui.FONT_TREE,size=24,color={255,255,255,255}}},{fill={40,40,40,255},radius={4,4,4,4},text={size=14}}}
    ui.tree_text_set(r.style_infos[1].name[:],"Title");r.style_infos[1].family=.Text
    ui.tree_text_set(r.style_infos[2].name[:],"Button");r.style_infos[2].family=.Control
    r.variants={ui.tree_variant_record(2,"big",{.Hovered},{fields={.Fill},values={fill={90,90,90,255}}})}
    r.images={{texture={0x7e,3},uv={0,0,0.5,0.5},border={2,2,2,2},border_uv={0.1,0.1,0.1,0.1},fit=.Contain}}
    ui.tree_text_set(r.images[0].name[:],"coin")
    r.fonts={{font={0xf0,2}}}
    r.keys={{time=0,value={0,0,0,0}},{time=0.25,value={1,0,0,0},ease=.Linear},{time=0,value={1,1,0,0}},{time=0.5,value={1.2,1.2,0,0},ease=.Linear}}
    r.tracks={{.Opacity,0,2},{.Scale,2,2}}
    r.anims={{kind=.Clip,first=0,count=1},{kind=.Clip,first=1,count=1,loop=.Loop},{kind=.Sequence,first=0,count=2}}
    ui.tree_text_set(r.anims[2].name[:],"intro")
    r.parts={1,2}
    r.anim_sets={{shown=3,hidden=1}}
    r.grid_tracks={{count=2,columns={0=ui.fixed(40),1=ui.GROW}}}
    r.nodes={
        ui.tree_node_record(t,-1,{kind=.Box,name="hud",layout={width=ui.GROW,height=ui.GROW,direction=.Column,gap=4},anims=1}),
        ui.tree_node_record(t,0,{kind=.Text,name="title",text="hud.score",style=1,flags={.Localized},fields={0={"coins","Game.coins"}}}),
        ui.tree_node_record(t,0,{kind=.Image,name="coin",image=1}),
        ui.tree_node_record(t,0,{kind=.Progress,name="health",bind_value="Game.health",layout={width=ui.fixed(120),height=ui.fixed(8)}}),
        ui.tree_node_record(t,0,{kind=.Button,name="play",text="Play",style=2,variant="big",action="Confirm",nav={2="grid"}}),
        ui.tree_node_record(t,0,{kind=.Box,name="grid",layout={direction=.Grid,columns=2,tracks=1}}),
        ui.tree_node_record(t,5,{kind=.Checkbox,name="mute",bind_value="Game.muted"}),
        ui.tree_node_record(t,5,{kind=.Slider,name="volume",range={0,1,0.1},bind_value="Game.volume"}),
        ui.tree_node_record(t,0,{kind=.List,name="items",bind_items="Game.items"}),
        ui.tree_node_record(t,8,{kind=.Text,name="item",bind_text="name"}),
    }
    return {nodes=r.nodes[:],styles=r.styles[:],style_infos=r.style_infos[:],
        variants=r.variants[:],images=r.images[:],fonts=r.fonts[:],anims=r.anims[:],tracks=r.tracks[:],keys=r.keys[:],parts=r.parts[:],anim_sets=r.anim_sets[:],
        grid_tracks=r.grid_tracks[:],text=r.text[:]}
}

@(private="file")
same_rows :: proc(a,b:[]$T) -> bool {
    return len(a)==len(b) && mem.compare(mem.slice_to_bytes(a),mem.slice_to_bytes(b))==0
}

@(private="file")
same_data :: proc(t:^testing.T,a,b:ui.Tree_Data) {
    testing.expect(t,same_rows(a.nodes,b.nodes),"nodes")
    testing.expect(t,same_rows(a.components,b.components),"components")
    testing.expect(t,same_rows(a.overrides,b.overrides),"overrides")
    testing.expect(t,same_rows(a.styles,b.styles),"styles")
    testing.expect(t,same_rows(a.style_infos,b.style_infos),"style_infos")
    testing.expect(t,same_rows(a.variants,b.variants),"variants")
    testing.expect(t,same_rows(a.images,b.images),"images")
    testing.expect(t,same_rows(a.fonts,b.fonts),"fonts")
    testing.expect(t,same_rows(a.anims,b.anims),"anims")
    testing.expect(t,same_rows(a.tracks,b.tracks),"tracks")
    testing.expect(t,same_rows(a.keys,b.keys),"keys")
    testing.expect(t,same_rows(a.parts,b.parts),"parts")
    testing.expect(t,same_rows(a.anim_sets,b.anim_sets),"anim_sets")
    testing.expect(t,same_rows(a.grid_tracks,b.grid_tracks),"grid_tracks")
    testing.expect(t,same_rows(a.text,b.text),"text")
}

// The tree the records build, as the game would load it.
@(private="file")
roundtrip_load :: proc(tree:^ui.Widget_Tree,data:ui.Tree_Data) -> bool {
    textures:=make([]u32,len(data.images),context.temp_allocator)
    fonts:=make([]u8,len(data.fonts),context.temp_allocator)
    for &f,i in fonts {f=u8(i+1)}
    return ui.tree_load(tree,data,{textures=textures,fonts=fonts},context.temp_allocator)
}

@(test)
a_ui_written_to_its_file_reads_back_the_same_records_and_tree :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    r:Roundtrip_Records
    data:=roundtrip_records(&r)
    bytes,error:=ui_tree_bytes(&types,ROUNDTRIP_ID,data,{},context.temp_allocator)
    if !testing.expect_value(t,error,asset.Error.None) {return}
    file:asset.Asset
    if !testing.expect_value(t,asset.asset_take(&file,bytes,context.temp_allocator),asset.Error.None) {return}
    defer asset.asset_close(&file)
    testing.expect_value(t,file.blob.header.id,ROUNDTRIP_ID)
    testing.expect_value(t,file.blob.header.kind,asset.KIND_UI)
    testing.expect(t,asset.ui_check(&file,&types),"What ui_tree_document writes passes the check of mirai asset verify")
    read,read_error:=ui_tree_view(&file,&types)
    if !testing.expect_value(t,read_error,asset.Error.None) {return}
    same_data(t,data,read)

    // Both build the same tree, the template and its override expanded.
    a,b:ui.Widget_Tree
    if !testing.expect(t,roundtrip_load(&a,data) && roundtrip_load(&b,read)) {return}
    defer {ui.tree_destroy(&a);ui.tree_destroy(&b)}
    testing.expect_value(t,a.node_count,10)
    testing.expect_value(t,b.node_count,a.node_count)
    testing.expect(t,mem.compare(mem.slice_to_bytes(a.nodes[:a.node_count]),mem.slice_to_bytes(b.nodes[:b.node_count]))==0,"The nodes of both trees are the same")
    testing.expect_value(t,string(b.strings[:b.string_length]),string(a.strings[:a.string_length]))

    // What it writes again is the same file.
    again,again_error:=ui_tree_bytes(&types,ROUNDTRIP_ID,read,{},context.temp_allocator)
    testing.expect_value(t,again_error,asset.Error.None)
    testing.expect(t,same_rows(bytes,again),"Writing what was read gives the same bytes")
}

// A file of a .ui with only the tables given, unchecked: what a tool or a
// broken file may hold.
@(private="file")
raw_ui :: proc(t:^testing.T,types:^asset.Types,data:ui.Tree_Data,file:^asset.Asset) -> bool {
    doc:asset.Document
    asset.document_init(&doc,asset.KIND_UI,ROUNDTRIP_ID,context.temp_allocator)
    defer asset.document_destroy(&doc)
    doc.kind_version=asset.UI_VERSION
    put :: proc(doc:^asset.Document,types:^asset.Types,name:string,rows:[]$T,flags:=asset.Table_Flags{}) -> bool {
        if len(rows)==0 {return true}
        _,error:=asset.document_put(doc,types,name,rows,flags)
        return error==.None
    }
    ok:=put(&doc,types,asset.UI_TABLE_NODES,data.nodes) && put(&doc,types,asset.UI_TABLE_STYLES,data.styles) && put(&doc,types,asset.UI_TABLE_ANIMS,data.anims) &&
        put(&doc,types,asset.UI_TABLE_TRACKS,data.tracks) && put(&doc,types,asset.UI_TABLE_KEYS,data.keys) && put(&doc,types,asset.UI_TABLE_ANIM_SETS,data.anim_sets) &&
        put(&doc,types,asset.UI_TABLE_TEXT,data.text,{.Bulk})
    if !testing.expect(t,ok) {return false}
    bytes,error:=asset.document_bytes(&doc,context.temp_allocator)
    return testing.expect_value(t,error,asset.Error.None) && testing.expect_value(t,asset.asset_take(file,bytes,context.temp_allocator),asset.Error.None)
}

// ui_check, ui.tree_load and ui_tree_document agree on records: the check
// of mirai asset verify takes what the game loads and the editor writes.
@(private="file")
check_agrees :: proc(t:^testing.T,types:^asset.Types,data:ui.Tree_Data,valid:bool,what:string,loc:=#caller_location) {
    file:asset.Asset
    if !raw_ui(t,types,data,&file) {return}
    defer asset.asset_close(&file)
    testing.expect_value(t,asset.ui_check(&file,types),valid,loc=loc)
    read,error:=ui_tree_view(&file,types)
    testing.expect_value(t,error,asset.Error.None,loc=loc)
    tree:ui.Widget_Tree
    loaded:=roundtrip_load(&tree,read)
    if loaded {ui.tree_destroy(&tree)}
    testing.expectf(t,loaded==valid,"ui.tree_load and ui_check disagree on %s",what,loc=loc)
    doc:asset.Document
    written:=ui_tree_document(&doc,types,ROUNDTRIP_ID,read,{},context.temp_allocator)
    if written==.None {asset.document_destroy(&doc)}
    testing.expect_value(t,written,asset.Error.None if valid else asset.Error.Invalid,loc=loc)
}

@(test)
the_check_of_a_ui_refuses_rows_outside_their_tables_as_the_tree_does :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    text:=transmute([]u8)string("Hello")
    nodes:=[3]ui.Tree_Node{{kind=.Box,parent=-1},{kind=.Text,parent=0,text={0,5}},{kind=.Image,parent=0}}
    styles:=[1]ui.Node_Style{}
    anims:=[1]ui.Tree_Anim{{kind=.Clip,first=0,count=1}}
    tracks:=[1]ui.Tree_Track{{.Opacity,0,2}}
    keys:=[2]anim.Keyframe{{time=0},{time=0.5,value={1,0,0,0}}}
    sets:=[1]ui.Anim_Set{{shown=1}}
    good:=ui.Tree_Data{nodes=nodes[:],styles=styles[:],anims=anims[:],tracks=tracks[:],keys=keys[:],anim_sets=sets[:],text=text}
    check_agrees(t,&types,good,true,"valid records")

    bad:=nodes
    bad[2].parent=5
    check_agrees(t,&types,{nodes=bad[:],styles=styles[:],text=text},false,"a parent after its node")
    bad=nodes
    bad[2].parent=1
    check_agrees(t,&types,{nodes=bad[:],styles=styles[:],text=text},false,"a parent that holds nothing")
    bad=nodes
    bad[1].text={3,5}
    check_agrees(t,&types,{nodes=bad[:],styles=styles[:],text=text},false,"a text past the end of the texts")
    bad=nodes
    bad[1].style=4
    check_agrees(t,&types,{nodes=bad[:],styles=styles[:],text=text},false,"a style that does not exist")
    bad=nodes
    bad[2].image=1
    check_agrees(t,&types,{nodes=bad[:],styles=styles[:],text=text},false,"an image that does not exist")
    bad=nodes
    bad[0].anims=2
    check_agrees(t,&types,{nodes=bad[:],styles=styles[:],anims=anims[:],tracks=tracks[:],keys=keys[:],anim_sets=sets[:],text=text},false,"a set of animations that does not exist")
    late:=keys
    late[1].time=-1
    check_agrees(t,&types,{nodes=nodes[:],styles=styles[:],anims=anims[:],tracks=tracks[:],keys=late[:],anim_sets=sets[:],text=text},false,"keys out of time order")
    wide:=tracks
    wide[0].key_count=3
    check_agrees(t,&types,{nodes=nodes[:],styles=styles[:],anims=anims[:],tracks=wide[:],keys=keys[:],anim_sets=sets[:],text=text},false,"a track past its keys")
    far:=sets
    far[0].hidden=2
    check_agrees(t,&types,{nodes=nodes[:],styles=styles[:],anims=anims[:],tracks=tracks[:],keys=keys[:],anim_sets=far[:],text=text},false,"a set that names an animation that does not exist")
}
