package ui_inspector_editor

import "core:fmt"
import "mirai:cook/author"
import "mirai:editor"
import "mirai:host"
import std_anim "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"
import "mirai:ui"

// The animations of the file (clips of tracks of keys, and sequences and
// parallels of other animations), which nodes play in the events of their
// Events card, and the component a node is an instance of, with its overrides.

// The names of the animations of the file, after "None".
@(private)
anim_names :: proc(r:^author.Records) -> []string {
    names:=make([]string,len(r.anims)+1,context.temp_allocator)
    names[0]="None"
    for &a,i in r.anims {
        name:=serial.text_field(a.name[:])
        names[i+1]=name if name!="" else fmt.tprintf("Animation %d",i+1)
    }
    return names
}

@(private) Key_Pair :: struct {value:[2]f32 `mirai:"axes=X Y"`}
@(private) Key_Angle :: struct {value:f32 `mirai:"unit=rad"`}
@(private) Key_Number :: struct {value:f32}

// The value of a key, as what its property means: an offset or a scale in
// x and y, an angle, an opacity, a color that multiplies, a size, a value, a
// frame or the part of the text shown.
@(private)
key_row :: proc(p:^Pane,property:ui.Anim_Property,key:^std_anim.Keyframe) -> (changed:bool) {
    v:=&key.value
    d:=author.property_default(property)
    pair :: proc(p:^Pane,label:string,v:^[4]f32,d:[4]f32,about:string) -> bool {
        value:=[2]f32{v[0],v[1]}
        if !value_row(p,label,Key_Pair,&value,[2]f32{d[0],d[1]},about) {return false}
        v[0],v[1]=value[0],value[1]
        return true
    }
    one :: proc(p:^Pane,label:string,$H:typeid,v:^[4]f32,d:[4]f32,about:string) -> bool {
        return value_row(p,label,H,&v[0],d[0],about)
    }
    switch property {
    case .Offset:   changed=pair(p,"Offset",v,d,"How far it is drawn from its place, in units of the layout")
    case .Scale:    changed=pair(p,"Scale",v,d,"How large it is drawn around its center; 1 is its size")
    case .Rotation: changed=one(p,"Rotation",Key_Angle,v,d,"How far it turns clockwise, in radians")
    case .Opacity:  changed=one(p,"Opacity",Unit_Value,v,d,"0: it does not show; 1: as it is")
    case .Color:    changed=value_row(p,"Color",Color_Value,v,d,"What its colors are multiplied by; white leaves them")
    case .Width:    changed=one(p,"Width",Positive_Value,v,d,"Its width, which the layout around it follows")
    case .Height:   changed=one(p,"Height",Positive_Value,v,d,"Its height, which the layout around it follows")
    case .Value:    changed=one(p,"Value",Key_Number,v,d,"What a Progress, a Slider or a Number shows in place of its value")
    case .Frame:    changed=one(p,"Frame",Positive_Value,v,d,"The frame of the sheet of sprites of its image")
    case .Reveal:   changed=one(p,"Reveal",Unit_Value,v,d,"The part of the characters of its text shown, 0 to 1")
    }
    return
}

@(private)
section_animations :: proc(p:^Pane,n:^ui.Tree_Node) {
    ctx:=p.s.gui.ctx
    u:=p.u
    th:=&ctx.theme
    r:=&u.records
    names:=anim_names(r)
    // The list and what removes one on a line; what makes one under it, to
    // fit the width of the panel.
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=4,align_y=.Center}) {
        chosen:=u.anim+1
        if ui.dropdown(ctx,ui.id(ctx,"anim"),{list=names},&chosen,{width=-1}) {u.anim=chosen-1}
        if ui.button(ctx,ui.id(ctx,"anim_remove"),{icon=ui.icon_user(u8(editor.User_Icon.Trash)),icon_size=13,icon_color=th.text_muted,tip="Delete",style=.Ghost,width=th.row,height=th.row,disabled=u.anim<0 || u.anim>=len(r.anims)}).clicked {
            author.records_anim_remove(r,u.anim)
            u.anim=min(u.anim,len(r.anims)-1)
            changed(u,"Delete animation")
        }
    }
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=4,align_y=.Center}) {
        if add_button(p,"clip_add","New clip") {
            u.anim=author.records_clip(r,fmt.tprintf("fade%d",len(r.anims)+1),.Opacity,{0,0,0,0},{1,0,0,0},0.25)
            changed(u,"New animation")
        }
        if add_button(p,"group_add","New group") {
            a:=ui.Tree_Anim{kind=.Sequence,first=u32(len(r.parts))}
            ui.tree_text_set(a.name[:],fmt.tprintf("group%d",len(r.anims)+1))
            append(&r.anims,a)
            u.anim=len(r.anims)-1
            changed(u,"New animation")
        }
    }
    if u.anim<0 || u.anim>=len(r.anims) {return}
    a:=&r.anims[u.anim]
    edit(u,"Animation",value_row(p,"Name",Name_Value,&a.name,a.name,"What the game names to play it on a node"))
    edit(u,"Animation",value_row(p,"Loop",Enum_Value(std_anim.Loop),&a.loop,std_anim.Loop.Once))
    if a.kind==.Clip {
        removed_track:=-1
        for t in 0..<int(a.count) {
            track_row:=int(a.first)+t
            track:=&r.tracks[track_row]
            ui.id_push(ctx,ui.id(ctx,"track",track_row+1))
            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=4,align_y=.Center}) {
                if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column}) {
                    property:=track.property
                    if value_row(p,fmt.tprintf("Track %d",t+1),Enum_Value(ui.Anim_Property),&property,track.property,"What it changes: Width and Height move the layout around it, the others only how it is drawn") {
                        // Keys of another property start from what that property holds alone.
                        if property!=track.property {
                            for &key in r.keys[track.first_key:][:track.key_count] {key.value=author.property_default(property)}
                        }
                        track.property=property
                        changed(u,"Animation")
                    }
                }
                if ui.button(ctx,ui.id(ctx,"remove"),{icon=.Cross,tip="Remove track",style=.Ghost,width=th.row,height=th.row,disabled=a.count<=1}).clicked {removed_track=t}
            }
            removed_key:=-1
            for k in 0..<int(track.key_count) {
                key:=&r.keys[int(track.first_key)+k]
                ui.id_push(ctx,ui.id(ctx,"key",k+1))
                edit(u,"Animation",value_row(p,"Time",Seconds_Value,&key.time,key.time))
                edit(u,"Animation",key_row(p,track.property,key))
                if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=4,align_y=.Center}) {
                    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column}) {
                        edit(u,"Animation",value_row(p,"Ease",Enum_Value(mm.Ease),&key.ease,mm.Ease.Linear))
                        edit(u,"Animation",value_row(p,"Interpolation",Enum_Value(std_anim.Interpolation),&key.interpolation,std_anim.Interpolation.Linear))
                    }
                    if ui.button(ctx,ui.id(ctx,"remove"),{icon=.Cross,tip="Remove key",style=.Ghost,width=th.row,height=th.row,disabled=track.key_count<=1}).clicked {removed_key=k}
                }
                ui.id_pop(ctx)
            }
            if removed_key>=0 {author.records_key_remove(r,track_row,removed_key);changed(u,"Remove key")}
            if add_button(p,"key_add","Add key") {author.records_key_add(r,track_row);changed(u,"Add key")}
            ui.id_pop(ctx)
        }
        if removed_track>=0 {author.records_track_remove(r,u.anim,removed_track);changed(u,"Remove track")}
        if add_button(p,"track_add","Add track",a.count>=ui.TREE_CLIP_TRACKS) {
            if author.records_track_add(r,u.anim,.Scale) {changed(u,"Add track")}
        }
        return
    }
    // A group plays animations of earlier rows.
    together:=1 if a.kind==.Parallel else 0
    if list_row(p,"Plays them",&together,{"In sequence","Together"}) {
        a.kind=.Parallel if together==1 else .Sequence
        changed(u,"Animation")
    }
    earlier:=names[:u.anim+1]
    removed:=-1
    for part in 0..<int(a.count) {
        at:=int(a.first)+part
        chosen:=r.parts[at]
        ui.id_push(ctx,ui.id(ctx,"part",part+1))
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=4,align_y=.Center}) {
            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column}) {
                if list_row(p,fmt.tprintf("Part %d",part+1),&chosen,earlier) && chosen>0 {r.parts[at]=chosen;changed(u,"Animation")}
            }
            if ui.button(ctx,ui.id(ctx,"remove"),{icon=.Cross,tip="Remove part",style=.Ghost,width=th.row,height=th.row}).clicked {removed=part}
        }
        ui.id_pop(ctx)
    }
    if removed>=0 {author.records_part_remove(r,u.anim,removed);changed(u,"Remove part")}
    if add_button(p,"part_add","Add part",u.anim==0) {
        if author.records_part_add(r,u.anim,ui.Anim(1)) {changed(u,"Animation")}
    }
}

// ---------------------------------------------------------------- components

// The fields of a node an instance or an override can set, as their rows say them.
@(private)
NODE_FIELD_NAMES :: [ui.Node_Field]string{.Text="text",.Style="style",.Layout="layout",.Float="floating",.Image="image",.Animations="animations",.Bindings="bindings",
    .Visibility="selected and disabled",.Variant="variant",.Layer="layer",.Clip="clip",.Block="pointer",.Values="values",.Action="action",.Focus="focus",.Drag="drag"}

// What of an instance replaces the root of its widget, in Advanced: of the
// fields its own rows show, its layout and where it floats, as Make widget
// leaves them, is what most need.
@(private)
component_fields_rows :: proc(p:^Pane,n:^ui.Tree_Node) {
    u:=p.u
    names:=NODE_FIELD_NAMES
    own:=bit_set[ui.Node_Field]{.Layout,.Float,.Bindings}
    for field in ui.Node_Field {
        on:=field in n.component_fields
        if !on && field not_in own {continue}
        if value_row(p,fmt.tprintf("Own %s",names[field]),Flag_Value,&on,false,"Its own value takes the place of the one the root of its widget has") {
            if on {n.component_fields+={field}} else {n.component_fields-={field}}
            changed(u,"Component")
        }
    }
}

@(private)
section_component :: proc(p:^Pane,a:^host.Assets,n:^ui.Tree_Node) {
    s:=p.s
    u:=p.u
    ctx:=s.gui.ctx
    th:=&ctx.theme
    r:=&u.records
    // The widgets it can be a use of: a file it uses for its styles has no one root.
    names:=make([dynamic]string,context.temp_allocator)
    rows:=make([dynamic]int,context.temp_allocator)
    for &component,i in r.components {
        if !widget_one_root(u,a,component.widget) {continue}
        append(&names,editor.asset_name_of(a,component.widget,"missing"));append(&rows,i)
    }
    picked:=-1
    for row,i in rows {if row==int(n.component)-1 {picked=i}}
    if row(p,"Of") {
        if ui.dropdown(ctx,ui.id(ctx,"component"),{list=names[:]},&picked,{width=-1}) {n.component=u16(rows[picked]+1);changed(u,"Component")}
    }
    if picked<0 {return}
    chosen:=rows[picked]
    if !p.readonly {param_rows(p,a,n,chosen)}
    if advanced(p) {component_fields_rows(p,n)}
    component:=&r.components[chosen]
    bind_only(p,"Data",n.data[:],.Data,"What the paths of its widget that start with @ read: a struct or an entity of the game, so one widget shows the health of the player in one place and of an enemy in another")
    if ui.button(ctx,ui.id(ctx,"open"),{label=fmt.tprintf("Open %s",editor.asset_name_of(a,component.widget,"missing")),style=.Ghost,height=th.row}).clicked {
        editor.asset_document_open(s,component.widget)
    }
    if p.readonly {return}
    open:=!u.overrides_closed
    defer u.overrides_closed=!open
    if !subsection(p,ui.id(ctx,"overrides"),"Overrides",&open) {return}
    // The names an override can reach: the nodes of its widget.
    targets:=override_targets(u,a,u.selected)
    removed:=-1
    for row in author.records_overrides(r,u.selected) {
        o:=&r.overrides[row]
        ui.id_push(ctx,ui.id(ctx,"override",row+1))
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=4,align_y=.Center}) {
            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column}) {edit(u,"Override",value_row(p,"Node",Name_Value,&o.node,o.node,"The node of the widget it changes, by its name; one inside a widget of the widget, by both names: outer/inner"))}
            if ui.button(ctx,ui.id(ctx,"remove"),{icon=.Cross,tip="Remove override",style=.Ghost,width=th.row,height=th.row}).clicked {removed=row}
        }
        field_names:=NODE_FIELD_NAMES
        // What an instance usually changes of a widget; the rest in Advanced, or once it is set.
        usual:=bit_set[ui.Node_Field]{.Text,.Style,.Image,.Visibility,.Variant,.Action,.Layout}
        rest:=false
        for pass in 0..<2 {
            if pass==1 {
                rest=advanced(p)
                if !rest {break}
            }
            for field in ui.Node_Field {
                on:=field in o.fields
                if (pass==0)!=(on || field in usual) {continue}
                if value_row(p,fmt.tprintf("Sets %s",field_names[field]),Flag_Value,&on,false,"The node takes this from the override instead of from its widget") {
                    override_field_set(u,a,row,field,on)
                    changed(u,"Override")
                }
                if on {override_rows(p,a,o,field)}
            }
        }
        ui.id_pop(ctx)
    }
    if removed>=0 {ordered_remove(&r.overrides,removed);changed(u,"Remove override")}
    added:=-1
    if ui.dropdown(ctx,ui.id(ctx,"override_add"),{list=targets},&added,{width=-1,empty="Override a node",disabled=len(targets)==0}) {
        author.records_override(r,u.selected,targets[added],{})
        changed(u,"Add override")
    }
}

// The parameters of the widget a use says by name, each a row with what it
// gives: changing one writes where the widget says it goes.
@(private)
param_rows :: proc(p:^Pane,a:^host.Assets,n:^ui.Tree_Node,component:int) {
    u:=p.u
    r:=&u.records
    data:=author.records_data(r)
    imports,_:=imports_cached(&u.imports,a,data,u.allocator)
    if component>=len(imports) {return}
    linked:=imports[component]
    name:=editor.asset_name_of(a,r.components[component].widget,"missing")
    for &param in linked.params {
        label:=serial.text_field(param.name[:])
        w:=author.Doc_Write{r=r,list=r.nodes[:]}
        current,_:=author.doc_param_value(&w,u.selected,&param)
        buffer,zero:[TEXT_EDIT]u8
        ui.tree_text_set(buffer[:],current)
        if !value_row(p,label,Text_Value,&buffer,zero,fmt.tprintf("A parameter of %s: it goes to %s",name,serial.text_field(param.node[:]))) {continue}
        // What the widget has at the node it goes to, with the rows it names copied here.
        node:ui.Tree_Node
        source:=new(author.Records,context.temp_allocator)
        author.records_load(source,linked,context.temp_allocator)
        expanded,expanded_ok:=ui.tree_expand(linked,context.temp_allocator)
        if expanded_ok {for &e in expanded {if serial.text_field(e.name[:])==serial.text_field(param.node[:]) {node=e;break}}}
        if author.records_param_give(author.assets_of(a),r,u.selected,&param,serial.text_field(buffer[:]),source,node) {changed(u,"Parameter")}
    }
}

// What a widget a person edits says of what its uses take: a row per
// parameter, with its name, the node it goes to and which field of that
// node, and which node takes what a use holds.
@(private)
section_parameters :: proc(p:^Pane,a:^host.Assets,n:^ui.Tree_Node) {
    s:=p.s
    u:=p.u
    ctx:=s.gui.ctx
    th:=&ctx.theme
    r:=&u.records
    fields:=author.DOC_PARAM_FIELDS
    slot:=.Slot in n.flags
    if !p.readonly && value_row(p,"Slot",Flag_Value,&slot,false,"This node takes what a use of the widget holds") {
        if why:=author.records_slot_set(r,u.selected,slot);why!="" {editor.notify(s,why)} else {changed(u,"Slot")}
    }
    nodes:=make([dynamic]string,context.temp_allocator)
    append(&nodes,"Root")
    for &each in r.nodes[1:] {if name:=serial.text_field(each.name[:]);name!="" {append(&nodes,name)}}
    removed:=-1
    for &param,i in r.params {
        ui.id_push(ctx,ui.id(ctx,"param",i+1))
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=4,align_y=.Center}) {
            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column}) {
                before:=param.name
                if value_row(p,"Name",Name_Value,&param.name,before,"What a use says by name") {
                    if why:=author.records_param_valid_name(r,i);why!="" {param.name=before;editor.notify(s,why)} else {changed(u,"Parameter")}
                }
            }
            if !p.readonly && ui.button(ctx,ui.id(ctx,"remove"),{icon=.Cross,tip="Remove parameter",style=.Ghost,width=th.row,height=th.row}).clicked {removed=i}
        }
        node_name:=serial.text_field(param.node[:])
        chosen:=0
        for name,j in nodes {if name==node_name {chosen=j}}
        if row(p,"Node","The node it goes to; Root: the root of the widget") {
            if ui.dropdown(ctx,ui.id(ctx,"node"),{list=nodes[:]},&chosen,{width=-1}) {
                author.records_param_target(r,i,nodes[chosen] if chosen>0 else "",ui.Tree_Param_Field.Text,"")
                changed(u,"Parameter")
            }
        }
        // A use it goes to offers the parameters of its widget beside the fields of a node.
        names:=make([dynamic]string,context.temp_allocator)
        for f in ui.Tree_Param_Field {append(&names,fields[f])}
        field_count:=len(names)
        if target:=author.records_node_named(r,serial.text_field(param.node[:]));target!=nil && target.kind==.Component {
            data:=author.records_data(r)
            imports,_:=imports_cached(&u.imports,a,data,u.allocator)
            if c:=int(target.component)-1;c>=0 && c<len(imports) {
                for &inner in imports[c].params {append(&names,serial.text_field(inner.name[:]))}
            }
        }
        picked:=int(param.field)
        if name:=serial.text_field(param.param[:]);name!="" {for option,j in names {if j>=field_count && option==name {picked=j}}}
        if row(p,"Field","Which field of the node it gives, or a parameter of the widget that node uses") {
            if ui.dropdown(ctx,ui.id(ctx,"field"),{list=names[:]},&picked,{width=-1}) {
                if picked<field_count {
                    author.records_param_target(r,i,serial.text_field(param.node[:]),ui.Tree_Param_Field(picked),"")
                } else {
                    author.records_param_target(r,i,serial.text_field(param.node[:]),ui.Tree_Param_Field.Text,names[picked])
                }
                changed(u,"Parameter")
            }
        }
        ui.id_pop(ctx)
    }
    if removed>=0 {ordered_remove(&r.params,removed);changed(u,"Remove parameter")}
    if !p.readonly && ui.button(ctx,ui.id(ctx,"param_add"),{label="Add parameter",icon=.Plus,style=.Ghost,height=th.row}).clicked {
        author.records_param_add(r)
        changed(u,"Add parameter")
    }
}

// The rows of a field an override sets.
@(private)
override_rows :: proc(p:^Pane,a:^host.Assets,o:^ui.Tree_Override,field:ui.Node_Field) {
    u:=p.u
    ctx:=p.s.gui.ctx
    r:=&u.records
    v:=&o.values
    d:=author.node_default(v.kind)
    ui.id_push(ctx,ui.id(ctx,"sets",int(field)+1))
    defer ui.id_pop(ctx)
    switch field {
    case .Text:
        edit(u,"Override",string_row(p,"Text",&v.text,"","The text it shows instead of that of its widget"))
    case .Style:
        // A style with a name, or the look of a row without one.
        names:=make([dynamic]string,context.temp_allocator)
        rows:=make([dynamic]int,context.temp_allocator)
        chosen:=-1
        for i in 0..<len(r.styles) {
            if author.records_style_base(r,i)>=0 || !author.records_style_named(r,i) && i!=int(v.style) {continue}
            if i==int(v.style) {chosen=len(names)}
            append(&names,author.records_style_name(r,i));append(&rows,i)
        }
        if row(p,"Style","A style of this file the node takes instead of its own") {
            if ui.dropdown(ctx,ui.id(ctx,"style"),{list=names[:]},&chosen,{width=-1,empty="Choose a style"}) {v.style=u16(rows[chosen]);changed(u,"Override")}
        }
    case .Layout:
        edit(u,"Override",size_row(p,"Width",&v.layout.width,d.layout.width))
        edit(u,"Override",size_row(p,"Height",&v.layout.height,d.layout.height))
        edit(u,"Override",value_row(p,"Direction",Enum_Value(ui.Direction),&v.layout.direction,d.layout.direction))
        edit(u,"Override",value_row(p,"Align X",Align_X_Value,&v.layout.align_x,d.layout.align_x))
        edit(u,"Override",value_row(p,"Align Y",Align_Y_Value,&v.layout.align_y,d.layout.align_y))
        edit(u,"Override",value_row(p,"Gap",Positive_Value,&v.layout.gap,d.layout.gap))
        edit(u,"Override",value_row(p,"Padding",Sides_Value,&v.layout.padding,d.layout.padding))
    case .Float:
        section_floating(p,v)
    case .Image:
        names:=make([dynamic]string,context.temp_allocator)
        append(&names,"None")
        for image,i in r.images {
            title:=editor.asset_name_of(a,image.texture,"missing")
            append(&names,fmt.tprintf("Image %d: %s",i+1,title) if title!="" else fmt.tprintf("Image %d",i+1))
        }
        chosen:=int(v.image)
        if row(p,"Image","An image of this file it shows instead") {
            if ui.dropdown(ctx,ui.id(ctx,"image"),{list=names[:]},&chosen,{width=-1}) {v.image=u16(chosen);changed(u,"Override")}
        }
    case .Animations:
        anims:=anim_names(r)
        names:=make([dynamic]string,context.temp_allocator)
        append(&names,"None")
        for set,i in r.anim_sets {
            shown:=anims[set.shown] if int(set.shown)<len(anims) else ""
            append(&names,fmt.tprintf("Set %d: shows %s",i+1,shown) if set.shown!=0 else fmt.tprintf("Set %d",i+1))
        }
        chosen:=int(v.anims)
        if row(p,"Animations","The animations of this file it plays in its events instead") {
            if ui.dropdown(ctx,ui.id(ctx,"anims"),{list=names[:]},&chosen,{width=-1}) {v.anims=u16(chosen);changed(u,"Override")}
        }
    case .Bindings:
        edit(u,"Override",binding_row(p,"Text field",&v.bind_text,"Shows it as its text"))
        edit(u,"Override",binding_row(p,"Value field",&v.bind_value,"The value of the node"))
        edit(u,"Override",binding_row(p,"Visible field",&v.bind_visible,"A bool: it is built only while it is true"))
        edit(u,"Override",binding_row(p,"Selected field",&v.bind_selected,"A bool: it is in the Selected state while it is true"))
        edit(u,"Override",binding_row(p,"Disabled field",&v.bind_disabled,"A bool: it takes no input while it is true"))
        edit(u,"Override",binding_row(p,"Items field",&v.bind_items,"An array a List builds its node for"))
        edit(u,"Override",binding_row(p,"Image field",&v.bind_image,"An asset id of a texture it shows"))
        edit(u,"Override",binding_row(p,"Tint field",&v.bind_tint,"A color in place of its fill"))
        edit(u,"Override",binding_row(p,"Variant field",&v.bind_variant,"A text or an enum that names its variant"))
        edit(u,"Override",binding_row(p,"Data",&v.data,"What the paths of a widget inside it that start with @ read"))
    case .Visibility:
        edit(u,"Override",value_row(p,"Selected",Flag_Value,&v.selected,false))
        edit(u,"Override",value_row(p,"Disabled",Flag_Value,&v.disabled,false))
    case .Variant:
        edit(u,"Override",value_row(p,"Variant",Name_Value,&v.variant,[ui.TREE_NAME_CAPACITY]u8{},"The variant of its style it shows"))
    case .Layer:
        layer_rows(p,u,&v.layer,d.layer)
    case .Clip:
        edit(u,"Override",value_row(p,"Clip",Flag_Value,&v.clip,false,"What it holds is cut at its edges"))
    case .Block:
        edit(u,"Override",value_row(p,"Blocks pointer",Flag_Value,&v.block,false,"The pointer over it does not reach what is behind it"))
    case .Values:
        edit(u,"Override",value_row(p,"Index",Count_Value,&v.index,d.index,"What a Switcher or a Tabs shows"))
        edit(u,"Override",value_row(p,"Elements",Count_Value,&v.count,d.count,"How many times a List builds its node"))
        edit(u,"Override",value_row(p,"Writes",Count_Value,&v.choice,d.choice,"What a Radio writes"))
        edit(u,"Override",value_row(p,"Range",Range_Value,&v.range,d.range,"Of a Slider or a Number: least, most and step"))
        edit(u,"Override",value_row(p,"Limit",Count_Value,&v.limit,d.limit,"The bytes a Field takes"))
        edit(u,"Override",value_row(p,"Delay",Seconds_Value,&v.delay,d.delay,"What a Tooltip waits"))
        if shown(p,"Effect") {
            values:=Particle_Pick{v.particle}
            none:Particle_Pick
            if editor.held_field_row(p.s,{key=base.hash_combine(u64(0x6f7061727469636c),u64(uintptr(o)))|1,info=type_info_of(Particle_Pick),value=&values,defaults=&none,width=p.width},"particle","Effect","The .particle a Particles plays") {
                v.particle=values.particle
                changed(u,"Override")
            }
        }
    case .Action:
        edit(u,"Override",action_row(p,"Action",v.action[:]))
        edit(u,"Override",value_row(p,"Hold",Seconds_Value,&v.hold,v.hold))
    case .Focus:
        edit(u,"Override",flag_row(p,"Focused first",&v.flags,.Focus_First,{},"It has the focus when the interface shows"))
        edit(u,"Override",flag_row(p,"Skipped",&v.flags,.Skip,{},"Navigation goes past it"))
        sides:=[4]string{"Up","Right","Down","Left"}
        for side,i in sides {edit(u,"Override",value_row(p,fmt.tprintf("Focus %s",side),Name_Value,&v.nav[i],[ui.TREE_NAME_CAPACITY]u8{},"The node the focus goes to that way"))}
        edit(u,"Override",value_row(p,"Tab order",Order_Value,&v.order,0,"Where Tab takes the focus"))
    case .Drag:
        edit(u,"Override",value_row(p,"Carries",Name_Value,&v.tag,[ui.TREE_NAME_CAPACITY]u8{},"What a Draggable carries"))
        edit(u,"Override",value_row(p,"Takes",Name_Value,&v.accepts,[ui.TREE_NAME_CAPACITY]u8{},"What a Drop takes; empty: anything"))
        edit(u,"Override",value_row(p,"Under pointer",Name_Value,&v.ghost,[ui.TREE_NAME_CAPACITY]u8{},"The node built under the pointer while it is dragged; empty: a copy"))
    }
}
