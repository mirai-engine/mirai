package host

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:std/base"
import "mirai:ui"

@(private="file") UI_CHECK_ID :: base.Asset_Id{0x41,2}

// A tree with what the structure of a .ui links: a use of a widget, a List, a grid, clips of
// several tracks, a sequence and a parallel, a track no clip plays, sets,
// styles with a variant, style infos with a base, a font and a translation.
@(private="file")
ui_check_base :: proc() -> (d:ui.Tree_Data) {
    a:=context.temp_allocator
    named :: proc(kind:ui.Node_Kind,parent:i32,name:string) -> (n:ui.Tree_Node) {
        n.kind,n.parent=kind,parent
        ui.tree_text_set(n.name[:],name)
        return
    }
    // "Hi" node 1, "Hola" its translation, "Yo" an override, "Card" the label.
    d.text=slice.clone(transmute([]u8)string("HiHolaYoCard"),a)
    d.nodes=make([]ui.Tree_Node,7,a)
    d.nodes[0]=named(.Box,-1,"root");d.nodes[0].style=1;d.nodes[0].anims=1
    d.nodes[1]=named(.Text,0,"title");d.nodes[1].style=2;d.nodes[1].text={0,2};d.nodes[1].text_id=7;d.nodes[1].flags={.Localized}
    d.nodes[2]=named(.Box,0,"grid");d.nodes[2].layout.direction=.Grid;d.nodes[2].layout.tracks=1;d.nodes[2].image=1
    d.nodes[3]=named(.Text,2,"card");d.nodes[3].text={8,4}
    d.nodes[4]=named(.List,2,"items")
    d.nodes[5]=named(.Text,4,"item")
    d.nodes[6]=named(.Button,0,"ok");d.nodes[6].anims=2
    d.styles=slice.clone([]ui.Node_Style{{},{text={font=ui.FONT_TREE,size=12}},{text={size=10}}},a)
    d.variants=slice.clone([]ui.Tree_Style_Variant{ui.tree_variant_record(1,"hot",{},{values={text={font=ui.FONT_TREE}}})},a)
    d.style_infos=make([]ui.Tree_Style_Info,3,a)
    ui.tree_text_set(d.style_infos[0].name[:],"base");ui.tree_text_set(d.style_infos[1].name[:],"accent")
    ui.tree_text_set(d.style_infos[2].name[:],"accent2");d.style_infos[2].base=2
    d.fonts=slice.clone([]ui.Tree_Font{{font={0xf0,2}}},a)
    d.images=slice.clone([]ui.Tree_Image{{texture={0x7e,2}}},a)
    d.keys=slice.clone([]ui.Keyframe{{time=0},{time=0.2,value={1,0,0,0}},{time=0},{time=0.1},{time=0.3},{time=0},{time=0},{time=0.5}},a)
    d.tracks=slice.clone([]ui.Tree_Track{{.Opacity,0,2},{.Offset,2,3},{.Scale,5,1},{.Opacity,6,2}},a)
    d.parts=slice.clone([]ui.Anim{1,2,1,3},a)
    d.anims=slice.clone([]ui.Tree_Anim{{kind=.Clip,first=0,count=2},{kind=.Clip,first=2,count=1},{kind=.Sequence,first=0,count=2},{kind=.Parallel,first=2,count=2}},a)
    d.anim_sets=slice.clone([]ui.Anim_Set{{shown=1,hidden=3,clicked=4},{hovered=2,focused=4,unselected=1}},a)
    d.translations=make([]ui.Tree_Translation,1,a)
    d.translations[0]={id=7,text={2,4}};ui.tree_text_set(d.translations[0].language[:],"es")
    d.grid_tracks=slice.clone([]ui.Grid_Tracks{{count=2}},a)
    return
}

@(private="file")
ui_check_clone :: proc(d:ui.Tree_Data) -> (c:ui.Tree_Data) {
    a:=context.temp_allocator
    c.nodes,c.styles,c.variants,c.components=slice.clone(d.nodes,a),slice.clone(d.styles,a),slice.clone(d.variants,a),slice.clone(d.components,a)
    c.overrides,c.images,c.anims=slice.clone(d.overrides,a),slice.clone(d.images,a),slice.clone(d.anims,a)
    c.tracks,c.keys,c.parts,c.anim_sets,c.fonts=slice.clone(d.tracks,a),slice.clone(d.keys,a),slice.clone(d.parts,a),slice.clone(d.anim_sets,a),slice.clone(d.fonts,a)
    c.style_infos,c.translations,c.grid_tracks,c.text=slice.clone(d.style_infos,a),slice.clone(d.translations,a),slice.clone(d.grid_tracks,a),slice.clone(d.text,a)
    return
}

// The field of a clone at the place of a field of the records it was cloned from.
@(private="file")
ui_check_moved :: proc(from,to:^ui.Tree_Data,field:any) -> any {
    tables :: proc(d:^ui.Tree_Data) -> [16][]u8 {
        to_bytes :: slice.to_bytes
        return {to_bytes(d.nodes),to_bytes(d.styles),to_bytes(d.variants),to_bytes(d.components),to_bytes(d.overrides),to_bytes(d.images),to_bytes(d.anims),
            to_bytes(d.tracks),to_bytes(d.keys),to_bytes(d.parts),to_bytes(d.anim_sets),to_bytes(d.fonts),to_bytes(d.style_infos),to_bytes(d.translations),to_bytes(d.grid_tracks),d.text}
    }
    at:=uintptr(field.data)
    clone:=tables(to)
    for table,i in tables(from) {
        start:=uintptr(raw_data(table))
        if at>=start && at<start+uintptr(len(table)) {return any{&clone[i][at-start],field.id}}
    }
    panic("a field outside the records")
}

// A field of a record that names another row, a range or a name a path is made of.
@(private="file") Ui_Link :: struct {name:string,value:any}

@(private="file")
ui_check_links :: proc(d:^ui.Tree_Data,out:^[dynamic]Ui_Link) {
    add :: proc(out:^[dynamic]Ui_Link,value:any,format:string,args:..any) {append(out,Ui_Link{fmt.tprintf(format,..args),value})}
    {
        table:="nodes"
        for &n,i in d.nodes {
            add(out,n.kind,"%s[%d].kind",table,i);add(out,n.parent,"%s[%d].parent",table,i);add(out,n.name,"%s[%d].name",table,i)
            add(out,n.style,"%s[%d].style",table,i);add(out,n.image,"%s[%d].image",table,i);add(out,n.anims,"%s[%d].anims",table,i)
            add(out,n.component,"%s[%d].component",table,i);add(out,n.component_fields,"%s[%d].component_fields",table,i)
            add(out,n.text.offset,"%s[%d].text.offset",table,i);add(out,n.text.length,"%s[%d].text.length",table,i);add(out,n.layout.tracks,"%s[%d].layout.tracks",table,i)
        }
    }
    for &s,i in d.styles {add(out,s.text.font,"styles[%d].text.font",i)}
    for &v,i in d.variants {add(out,v.style,"variants[%d].style",i);add(out,v.patch.values.text.font,"variants[%d].patch.values.text.font",i)}
    for &s,i in d.style_infos {add(out,s.base,"style_infos[%d].base",i)}
    for &f,i in d.fonts {add(out,f.font,"fonts[%d].font",i)}
    for &an,i in d.anims {add(out,an.kind,"anims[%d].kind",i);add(out,an.first,"anims[%d].first",i);add(out,an.count,"anims[%d].count",i)}
    for &tr,i in d.tracks {add(out,tr.first_key,"tracks[%d].first_key",i);add(out,tr.key_count,"tracks[%d].key_count",i)}
    for &k,i in d.keys {add(out,k.time,"keys[%d].time",i)}
    for &p,i in d.parts {add(out,p,"parts[%d]",i)}
    for &set,i in d.anim_sets {
        for &state,s in (^[size_of(ui.Anim_Set)/size_of(ui.Anim)]ui.Anim)(&set) {add(out,state,"anim_sets[%d][%d]",i,s)}
    }
    for &tr,i in d.translations {add(out,tr.text.offset,"translations[%d].text.offset",i);add(out,tr.text.length,"translations[%d].text.length",i)}
}

// Rows and counts of the tables, which hold up to 8 rows, and around the
// limits of the text, of the fonts and of the integers.
@(private="file") UI_CHECK_ROWS :: [?]i64{-2,-1,0,1,2,3,4,5,6,7,8,9,65535,1<<31}
@(private="file") UI_CHECK_TEXT :: [?]i64{0,1,2,4,6,8,11,12,13,1<<31}
@(private="file") UI_CHECK_FONTS :: [?]i64{0,1,15,16,17,255}
@(private="file") UI_CHECK_TIMES :: [?]f32{-1,0,0.05,0.1,0.2,0.3,0.5,1}
@(private="file") UI_CHECK_KINDS :: [?]ui.Node_Kind{.Box,.Text,.Image,.Component,.Scroll,.List,.Tooltip}
@(private="file") UI_CHECK_ANIM_KINDS :: [?]ui.Anim_Kind{.Clip,.Sequence,.Parallel}
@(private="file") UI_CHECK_FIELDS :: [?]u32{0,1<<u32(ui.Node_Field.Text),1<<u32(ui.Node_Field.Style),1<<u32(ui.Node_Field.Layout),1<<u32(ui.Node_Field.Image),1<<u32(ui.Node_Field.Animations),0x3f,1<<20}
@(private="file") UI_CHECK_NAMES :: [?]string{"","label","icon","icon/pic","slot","card","badge","x"}

@(private="file")
ui_check_ints :: proc(link:Ui_Link) -> []i64 {
    rows,text,fonts:=UI_CHECK_ROWS,UI_CHECK_TEXT,UI_CHECK_FONTS
    if link.value.id==u8 {return slice.clone(fonts[:],context.temp_allocator)}
    if strings.contains(link.name,"text.") {return slice.clone(text[:],context.temp_allocator)}
    return slice.clone(rows[:],context.temp_allocator)
}

// How many values ui_check_set gives a field.
@(private="file")
ui_check_values :: proc(link:Ui_Link) -> int {
    switch link.value.id {
    case f32: return len(UI_CHECK_TIMES)+3
    case ui.Node_Kind: return len(UI_CHECK_KINDS)
    case ui.Anim_Kind: return len(UI_CHECK_ANIM_KINDS)
    case ui.Node_Fields: return len(UI_CHECK_FIELDS)
    case base.Asset_Id: return 2
    case [ui.TREE_NAME_CAPACITY]u8: return len(UI_CHECK_NAMES)+2
    }
    return len(ui_check_ints(link))
}

// Sets value number at of a field and says what it set.
@(private="file")
ui_check_set :: proc(link:Ui_Link,value:any,at:int) -> string {
    switch value.id {
    case f32:
        times:=UI_CHECK_TIMES
        extra:=[3]f32{math.inf_f32(1),math.inf_f32(-1),math.nan_f32()}
        v:=times[at] if at<len(times) else extra[at-len(times)]
        (^f32)(value.data)^=v
        return fmt.tprint(v)
    case ui.Node_Kind:
        kinds:=UI_CHECK_KINDS
        (^ui.Node_Kind)(value.data)^=kinds[at]
        return fmt.tprint(kinds[at])
    case ui.Anim_Kind:
        kinds:=UI_CHECK_ANIM_KINDS
        (^ui.Anim_Kind)(value.data)^=kinds[at]
        return fmt.tprint(kinds[at])
    case ui.Node_Fields:
        fields:=UI_CHECK_FIELDS
        (^u32)(value.data)^=fields[at]
        return fmt.tprintf("%#x",fields[at])
    case base.Asset_Id:
        (^base.Asset_Id)(value.data)^=at==0?{}:{7,7}
        return at==0?"none":"an id"
    case [ui.TREE_NAME_CAPACITY]u8:
        names:=UI_CHECK_NAMES
        field:=(^[ui.TREE_NAME_CAPACITY]u8)(value.data)
        switch at {
        case len(UI_CHECK_NAMES): // fills the field but its terminator
            ui.tree_text_set(field[:],strings.repeat("n",ui.TREE_NAME_CAPACITY-1,context.temp_allocator))
            return "63 bytes"
        case len(UI_CHECK_NAMES)+1:
            for &b in field {b='n'}
            return "64 bytes without terminator"
        }
        ui.tree_text_set(field[:],names[at])
        return fmt.tprintf("%q",names[at])
    }
    v:=ui_check_ints(link)[at]
    switch value.id {
    case i32: (^i32)(value.data)^=i32(v)
    case u32: (^u32)(value.data)^=u32(v)
    case u16: (^u16)(value.data)^=u16(v)
    case ui.Anim: (^ui.Anim)(value.data)^=ui.Anim(v)
    case u8: (^u8)(value.data)^=u8(v)
    case: panic("a link of a type ui_check_set does not know")
    }
    return fmt.tprint(v)
}

// Writes the records unchecked and expects asset.ui_check to say what
// ui.tree_load says of the records read back.
@(private="file")
ui_check_same :: proc(t:^testing.T,types:^asset.Types,data:ui.Tree_Data,what:string,expected:Maybe(bool)=nil) -> bool {
    doc:asset.Document
    asset.document_init(&doc,asset.KIND_UI,UI_CHECK_ID,context.temp_allocator)
    defer asset.document_destroy(&doc)
    doc.kind_version=asset.UI_VERSION
    if !testing.expectf(t,ui_tree_tables(&doc,types,data)==.None,"%s: the records do not write",what) {return false}
    bytes,error:=asset.document_bytes(&doc,context.temp_allocator)
    if !testing.expectf(t,error==.None,"%s: %v",what,error) {return false}
    a:asset.Asset
    if !testing.expectf(t,asset.asset_open(&a,bytes,context.temp_allocator)==.None,"%s: the file does not open",what) {return false}
    defer asset.asset_close(&a)
    checked:=asset.ui_check(&a,types)
    loaded:=false
    if view,view_error:=ui_tree_view(&a,types);view_error==.None {
        if linked,ok:=ui.tree_link(view,nil);ok {
            tree:ui.Widget_Tree
            resources:=ui.Tree_Resources{textures=make([]u32,len(linked.images),context.temp_allocator),fonts=make([]u8,len(linked.fonts),context.temp_allocator)}
            loaded=ui.tree_load(&tree,linked,resources,context.temp_allocator)
            if loaded {ui.tree_destroy(&tree)}
        }
    }
    if want,known:=expected.?;known && !testing.expectf(t,loaded==want,"%s: ui.tree_load says %v",what,loaded) {return false}
    return testing.expectf(t,checked==loaded,"%s: asset.ui_check says %v and ui.tree_load %v",what,checked,loaded)
}

// The records of a tree as a file and back: the same rows, table by table.
@(test)
ui_records_come_back_from_their_file_row_by_row :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    data:=ui_check_base()
    doc:asset.Document
    if !testing.expect_value(t,ui_tree_document(&doc,&types,UI_CHECK_ID,data,allocator=context.temp_allocator),asset.Error.None) {return}
    defer asset.document_destroy(&doc)
    bytes,error:=asset.document_bytes(&doc,context.temp_allocator)
    if !testing.expect_value(t,error,asset.Error.None) {return}
    a:asset.Asset
    if !testing.expect_value(t,asset.asset_open(&a,bytes,context.temp_allocator),asset.Error.None) {return}
    defer asset.asset_close(&a)
    testing.expect(t,asset.ui_check(&a,&types))
    view,view_error:=ui_tree_view(&a,&types)
    if !testing.expect_value(t,view_error,asset.Error.None) {return}
    same :: proc(t:^testing.T,a,b:[]$T,table:string) {
        testing.expectf(t,len(a)==len(b) && mem.compare(slice.to_bytes(a),slice.to_bytes(b))==0,"%s does not come back as it was written",table)
    }
    same(t,view.nodes,data.nodes,"nodes");same(t,view.styles,data.styles,"styles");same(t,view.variants,data.variants,"variants")
    same(t,view.components,data.components,"components")
    same(t,view.overrides,data.overrides,"overrides");same(t,view.images,data.images,"images");same(t,view.anims,data.anims,"anims")
    same(t,view.tracks,data.tracks,"tracks");same(t,view.keys,data.keys,"keys");same(t,view.parts,data.parts,"parts")
    same(t,view.anim_sets,data.anim_sets,"anim_sets");same(t,view.fonts,data.fonts,"fonts");same(t,view.style_infos,data.style_infos,"style_infos")
    same(t,view.translations,data.translations,"translations");same(t,view.grid_tracks,data.grid_tracks,"grid_tracks");same(t,view.text,data.text,"text")
}

// Every field that links rows, set to the values around its limits, one at a
// time, and every table cut short: the check of the file and the loader agree.
@(test)
ui_check_refuses_what_tree_load_refuses_case_by_case :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    base_data:=ui_check_base()
    if !ui_check_same(t,&types,base_data,"the tree as built",true) {return}
    links:=make([dynamic]Ui_Link,context.temp_allocator)
    ui_check_links(&base_data,&links)
    for link in links {
        for v in 0..<ui_check_values(link) {
            runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
            d:=ui_check_clone(base_data)
            what:=ui_check_set(link,ui_check_moved(&base_data,&d,link.value),v)
            ui_check_same(t,&types,d,fmt.tprintf("%s=%s",link.name,what))
        }
    }
    TABLES :: [?]string{"nodes","styles","variants","components","overrides","images","anims","tracks","keys","parts","anim_sets","fonts","style_infos","translations","grid_tracks","text"}
    for table,i in TABLES {
        for rows in 0..<64 {
            runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
            d:=ui_check_clone(base_data)
            cut :: proc(list:^[]$T,rows:int) -> bool {
                if rows>=len(list) {return false}
                list^=list[:rows]
                return true
            }
            cuts:bool
            switch i {
            case 0: cuts=cut(&d.nodes,rows)
            case 1: cuts=cut(&d.styles,rows)
            case 2: cuts=cut(&d.variants,rows)
            case 3: cuts=cut(&d.components,rows)
            case 4: cuts=cut(&d.overrides,rows)
            case 5: cuts=cut(&d.images,rows)
            case 6: cuts=cut(&d.anims,rows)
            case 7: cuts=cut(&d.tracks,rows)
            case 8: cuts=cut(&d.keys,rows)
            case 9: cuts=cut(&d.parts,rows)
            case 10: cuts=cut(&d.anim_sets,rows)
            case 11: cuts=cut(&d.fonts,rows)
            case 12: cuts=cut(&d.style_infos,rows)
            case 13: cuts=cut(&d.translations,rows)
            case 14: cuts=cut(&d.grid_tracks,rows)
            case 15: cuts=cut(&d.text,rows)
            }
            if !cuts {break}
            ui_check_same(t,&types,d,fmt.tprintf("%s cut to %d rows",table,rows))
        }
    }
}

// Chains of boxes around the depth a tree is built to.
@(test)
ui_check_refuses_what_tree_load_refuses_at_the_depth_limit :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    base_data:=ui_check_base()
    for boxes in ui.TREE_DEPTH-6..=ui.TREE_DEPTH+1 {
        runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
        // boxes nested in a chain, a text in the last one.
        d:=ui_check_clone(base_data)
        d.nodes=make([]ui.Tree_Node,boxes+1,context.temp_allocator)
        for &n,i in d.nodes {n.kind,n.parent=.Box,i32(i-1)}
        d.nodes[boxes].kind=.Text
        ui_check_same(t,&types,d,fmt.tprintf("%d boxes over a text",boxes))
        d.nodes=d.nodes[:boxes]
        ui_check_same(t,&types,d,fmt.tprintf("%d boxes",boxes),boxes<=ui.TREE_DEPTH)
    }
}

// A component is a use of the widget of another file: a file holds no other.
@(test)
a_ui_file_has_no_components_of_its_own :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    d:ui.Tree_Data
    d.styles=make([]ui.Node_Style,1,context.temp_allocator)
    d.nodes=make([]ui.Tree_Node,2,context.temp_allocator)
    d.nodes[0]={kind=.Box,parent=-1}
    d.nodes[1]={kind=.Component,parent=0,component=1}
    ui.tree_text_set(d.nodes[1].name[:],"card")
    d.component_nodes=make([]ui.Tree_Node,1,context.temp_allocator)
    d.component_nodes[0]={kind=.Box,parent=-1}
    d.components=make([]ui.Tree_Component,1,context.temp_allocator)
    d.components[0]=ui.tree_component_record("card",0,1)
    doc:asset.Document
    testing.expect_value(t,ui_tree_document(&doc,&types,UI_CHECK_ID,d,allocator=context.temp_allocator),asset.Error.Invalid)
    asset.document_init(&doc,asset.KIND_UI,UI_CHECK_ID,context.temp_allocator)
    defer asset.document_destroy(&doc)
    doc.kind_version=asset.UI_VERSION
    if !testing.expect_value(t,ui_tree_tables(&doc,&types,d),asset.Error.None) {return}
    bytes,error:=asset.document_bytes(&doc,context.temp_allocator)
    if !testing.expect_value(t,error,asset.Error.None) {return}
    a:asset.Asset
    if !testing.expect_value(t,asset.asset_open(&a,bytes,context.temp_allocator),asset.Error.None) {return}
    defer asset.asset_close(&a)
    testing.expect(t,!asset.ui_check(&a,&types),"the check of the file refuses it")
}
