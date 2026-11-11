package ui

import "mirai:std/base"
import "mirai:std/serial"

// A tree whose components name other .ui files (Tree_Component.widget) as
// one set of records, the form tree_load takes: the template of each of those components is the tree
// of its file, with its own components and overrides expanded, and the
// styles, variants, images, fonts and animations of the file join those of the
// tree. Overrides of an instance reach the nodes of the file by their names
// in it ("slot/icon"). A widget gives its root to the instance and keeps the
// bindings it declares: they read the fields of what the tree binds. A style
// a row of the tree names by Tree_Style_Info.from is that style of the file,
// with its variants; a file no node uses lends only those.

// imports: by row of components, the records of the file of each widget,
// linked already; nothing for the components of the tree itself. Returns the
// records unchanged when no component names a file. A transaction: false
// when an import is missing, does not load or has more than one root, or
// memory runs out.
tree_link :: proc(data:Tree_Data,imports:[]Tree_Data,allocator:=context.temp_allocator) -> (linked:Tree_Data,ok:bool) {
    widgets:=false
    for component in data.components {widgets|=component.widget!={}}
    if !widgets {return data,true}
    if len(imports)!=len(data.components) {return}
    components,components_error:=make([dynamic]Tree_Component,0,len(data.components),allocator)
    if components_error!=nil {return}
    component_nodes:=make([dynamic]Tree_Node,allocator)
    styles:=make([dynamic]Node_Style,allocator)
    variants:=make([dynamic]Tree_Style_Variant,allocator)
    images:=make([dynamic]Tree_Image,allocator)
    fonts:=make([dynamic]Tree_Font,allocator)
    anims:=make([dynamic]Tree_Anim,allocator)
    tracks:=make([dynamic]Tree_Track,allocator)
    keys:=make([dynamic]Keyframe,allocator)
    parts:=make([dynamic]Anim,allocator)
    anim_sets:=make([dynamic]Anim_Set,allocator)
    translations:=make([dynamic]Tree_Translation,allocator)
    grid_tracks:=make([dynamic]Grid_Tracks,allocator)
    text:=make([dynamic]u8,allocator)
    grow :: proc(list:^[dynamic]$T,rows:[]T) -> bool {
        _,error:=append(list,..rows)
        return error==nil
    }
    ok=grow(&components,data.components) && grow(&component_nodes,data.component_nodes) && grow(&styles,data.styles) && grow(&variants,data.variants) &&
        grow(&images,data.images) && grow(&fonts,data.fonts) && grow(&anims,data.anims) && grow(&tracks,data.tracks) && grow(&keys,data.keys) && grow(&parts,data.parts) && grow(&anim_sets,data.anim_sets) && grow(&translations,data.translations) &&
        grow(&grid_tracks,data.grid_tracks) && grow(&text,data.text)
    if !ok {return}
    // Style 0 of a tree is what its nodes without a style use: a tree without
    // styles still has it, empty.
    if len(styles)==0 {append(&styles,Node_Style{})}
    // What a file adds to the tables goes in once, however many components name it.
    Joined :: struct {
        id:base.Asset_Id,
        style,image,set:u16,
        font:u8,
        anim:Anim,
        track,key,part,text:u32,
        tracks:u16,
    }
    joined:=make([dynamic]Joined,allocator)
    join :: proc(file:^Tree_Data,id:base.Asset_Id,joined:^[dynamic]Joined,styles:^[dynamic]Node_Style,variants:^[dynamic]Tree_Style_Variant,images:^[dynamic]Tree_Image,fonts:^[dynamic]Tree_Font,anims:^[dynamic]Tree_Anim,tracks:^[dynamic]Tree_Track,keys:^[dynamic]Keyframe,parts:^[dynamic]Anim,anim_sets:^[dynamic]Anim_Set,translations:^[dynamic]Tree_Translation,grid_tracks:^[dynamic]Grid_Tracks,text:^[dynamic]u8) -> (at:Joined,ok:bool) {
        for &j in joined {if j.id==id {return j,true}}
        at={id=id,style=u16(len(styles)),image=u16(len(images)),set=u16(len(anim_sets)),font=u8(len(fonts)),anim=Anim(len(anims)),track=u32(len(tracks)),key=u32(len(keys)),part=u32(len(parts)),text=u32(len(text)),tracks=u16(len(grid_tracks))}
        grow :: proc(list:^[dynamic]$T,rows:[]T) -> bool {
            _,error:=append(list,..rows)
            return error==nil
        }
        if len(styles)+max(len(file.styles),1)>int(max(u16)) || len(images)+len(file.images)>int(max(u16)) || len(anim_sets)+len(file.anim_sets)>int(max(u16)) || len(anims)+len(file.anims)>=int(max(u16)) || FONT_TREE+len(fonts)+len(file.fonts)>int(max(u8)) {return}
        // The texts of a widget keep their ids: every instance of it shows the same translations.
        ok=grow(styles,file.styles) && grow(images,file.images) && grow(fonts,file.fonts) && grow(keys,file.keys) && grow(text,file.text) && grow(grid_tracks,file.grid_tracks)
        if !ok || len(text)>int(max(u32)) || len(grid_tracks)>int(max(u16)) {return {},false}
        for t in file.translations {
            moved:=t
            moved.text.offset+=at.text
            _,error:=append(translations,moved);ok&=error==nil
        }
        if len(file.styles)==0 {_,error:=append(styles,Node_Style{});ok&=error==nil}
        // The fonts of the file are rows after those already joined.
        for &style in styles[min(int(at.style),len(styles)):] {if style.text.font>=FONT_TREE {style.text.font+=at.font}}
        for variant in file.variants {
            moved:=variant
            moved.style+=at.style
            if moved.patch.values.text.font>=FONT_TREE {moved.patch.values.text.font+=at.font}
            _,error:=append(variants,moved);ok&=error==nil
        }
        for a in file.anims {
            moved:=a
            moved.first+=at.track if a.kind==.Clip else at.part
            _,error:=append(anims,moved);ok&=error==nil
        }
        for track in file.tracks {
            moved:=track
            moved.first_key+=at.key
            _,error:=append(tracks,moved);ok&=error==nil
        }
        for part in file.parts {
            _,error:=append(parts,part+at.anim if part!=0 else 0);ok&=error==nil
        }
        for set in file.anim_sets {
            moved:=set
            for &played in (^[size_of(Anim_Set)/size_of(Anim)]Anim)(&moved) {if played!=0 {played+=at.anim}}
            _,error:=append(anim_sets,moved);ok&=error==nil
        }
        _,error:=append(joined,at);ok&=error==nil
        return
    }
    used,used_error:=make([]bool,len(components),allocator)
    if used_error!=nil {return {},false}
    for &node in data.nodes {if node.kind==.Component && node.component>0 && int(node.component)<=len(used) {used[node.component-1]=true}}
    for &component,row in components {
        if component.widget=={} {continue}
        widget:=imports[row]
        at,joined_ok:=join(&widget,component.widget,&joined,&styles,&variants,&images,&fonts,&anims,&tracks,&keys,&parts,&anim_sets,&translations,&grid_tracks,&text)
        if !joined_ok {return {},false}
        if !used[row] {
            component.widget={}
            continue
        }
        expanded,expanded_ok:=tree_expand(widget,allocator)
        if !expanded_ok || len(expanded)==0 || expanded[0].parent!=-1 {return {},false}
        for node in expanded[1:] {if node.parent<0 {return {},false}}
        first:=u32(len(component_nodes))
        for node in expanded {
            moved:=node
            // Its layout from the styles of its file, which this table of styles does not hold by row.
            if int(moved.style)<len(widget.style_infos) {tree_node_take_style(&moved,&widget.style_infos[moved.style])}
            moved.layout_own=LAYOUT_KEYS
            moved.style+=at.style
            if moved.image!=0 {moved.image+=at.image}
            if moved.anims!=0 {moved.anims+=at.set}
            if moved.layout.tracks!=0 {moved.layout.tracks+=at.tracks}
            moved.text.offset+=at.text
            _,error:=append(&component_nodes,moved);ok&=error==nil
        }
        if !ok {return {},false}
        component.first,component.count,component.widget=first,u32(len(expanded)),{}
    }
    // A style that names a file takes what that style is there.
    style_infos,infos_error:=make([dynamic]Tree_Style_Info,len(data.style_infos),max(len(styles),len(data.style_infos)),allocator)
    if infos_error!=nil {return {},false}
    copy(style_infos[:],data.style_infos)
    for &info,row in style_infos[:] {
        if info.from==0 {continue}
        if int(info.from)>len(data.components) || row>=len(data.styles) || data.components[info.from-1].widget=={} {return {},false}
        file:=imports[info.from-1]
        at:Joined
        for &j in joined {if j.id==data.components[info.from-1].widget {at=j;break}}
        wanted:=serial.text_field(info.name[:])
        found:=-1
        for &other,i in file.style_infos {if serial.text_field(other.name[:])==wanted {found=i;break}}
        if found<0 || found>=len(file.styles) {return {},false}
        styles[row]=styles[int(at.style)+found]
        had:=file.style_infos[found]
        info.layout=had.layout
        info.layout_keys=had.layout_keys
        info.blur=had.blur
        for i:=len(variants)-1;i>=0;i-=1 {if int(variants[i].style)==row {ordered_remove(&variants,i)}}
        for variant in file.variants {
            if int(variant.style)!=found {continue}
            moved:=variant
            moved.style=u16(row)
            if moved.patch.values.text.font>=FONT_TREE {moved.patch.values.text.font+=at.font}
            _,error:=append(&variants,moved);ok&=error==nil
        }
        info.from=0
    }
    if !ok {return {},false}
    // What a style of this file names in a file it links resolves here: the
    // styles and tokens of the file join those of the tree under their names,
    // after those of the tree.
    tokens:=make([dynamic]Tree_Token,allocator)
    append(&tokens,..data.tokens)
    if resize(&style_infos,len(styles))!=nil {return {},false}
    for j in joined {
        component:=-1
        for &c,i in data.components {if c.widget==j.id {component=i;break}}
        if component<0 {continue}
        file:=imports[component]
        for info,row in file.style_infos {
            at:=int(j.style)+row
            if at<len(style_infos) && style_infos[at].name[0]==0 {
                style_infos[at]=info
                style_infos[at].from=0 // a row the tree knows by name, already linked
            }
        }
        append(&tokens,..file.tokens)
    }
    tree_settle(styles[:],style_infos[:],&variants,tokens[:],data.token_uses)
    // A parameter that goes past a use is flat from here on: where the
    // parameter of its widget goes, under the name of the use. One that
    // resolves to nothing is for ui.check to say.
    params,params_error:=make([dynamic]Tree_Param,0,len(data.params),allocator)
    if params_error!=nil {return {},false}
    for &p in data.params {
        param:=serial.text_field(p.param[:])
        if param=="" {append(&params,p);continue}
        at:=-1
        for &n,row in data.nodes {if n.kind==.Component && serial.text_field(n.name[:])==serial.text_field(p.node[:]) {at=row;break}}
        if at<0 || int(data.nodes[at].component)==0 || int(data.nodes[at].component)>len(imports) {continue}
        for &inner in imports[data.nodes[at].component-1].params {
            if serial.text_field(inner.name[:])!=param {continue}
            buffer:[TREE_NAME_CAPACITY]u8
            path,fits:=tree_path(buffer[:],serial.text_field(p.node[:]),serial.text_field(inner.node[:]))
            if !fits {break}
            flat:=p
            flat.field,flat.param=inner.field,{}
            tree_text_set(flat.node[:],path)
            append(&params,flat)
            break
        }
    }
    linked=data
    linked.params=params[:]
    linked.style_infos=style_infos[:]
    linked.components,linked.component_nodes,linked.styles,linked.variants=components[:],component_nodes[:],styles[:],variants[:]
    linked.images,linked.fonts,linked.anims,linked.tracks,linked.keys,linked.parts,linked.anim_sets=images[:],fonts[:],anims[:],tracks[:],keys[:],parts[:],anim_sets[:]
    linked.translations,linked.grid_tracks,linked.text=translations[:],grid_tracks[:],text[:]
    linked.tokens=tokens[:]
    return linked,true
}
