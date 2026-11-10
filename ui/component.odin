package ui

import "base:runtime"
import "core:strings"
import "mirai:std/base"
import "mirai:std/serial"

Tree_Component :: struct {
    name:[TREE_NAME_CAPACITY]u8 `mirai:"text"`,
    first,count:u32, // the range of component_nodes tree_link expanded it into; 0 in a file
    widget:base.Asset_Id, // the .ui whose one root is the widget; empty only once linked
}
Tree_Override :: struct {
    instance:u32, // row in nodes, whose kind is Component
    node:[TREE_NAME_CAPACITY]u8 `mirai:"text"`, // local name; nested instances use name/child
    fields:Node_Fields,
    values:Tree_Node,
}
Tree_Style_Variant :: struct {
    style:u16,
    variant:[TREE_NAME_CAPACITY]u8 `mirai:"text"`,
    states:Style_States,
    patch:Style_Patch,
    own:Style_Keys,       // what it sets itself; none: every value it has, unless inherited
    inherited:bool,       // kept for a style that extends the one it came from: tree_settle makes it again
    extends:Style_States, // the states of another rule of its style and variant it starts from
}
TREE_EXPANDED_NODES :: 65535

// What of its layout v gives over what node has: what v has as its own, or
// all of it when v does not say.
@(private)
tree_layout_patch :: proc "contextless" (node,v:^Tree_Node) {
    if v.layout_own=={} {
        node.layout=v.layout
        node.layout_own=LAYOUT_KEYS
        return
    }
    for key in v.layout_own&LAYOUT_KEYS {layout_key_copy(&node.layout,&v.layout,key)}
    node.layout_own+=v.layout_own&LAYOUT_KEYS
}

@(private)
tree_node_patch :: proc "contextless" (node:^Tree_Node,fields:Node_Fields,v:^Tree_Node) {
    if .Text in fields {node.text,node.fields=v.text,v.fields}
    if .Style in fields {node.style=v.style}
    if .Layout in fields {tree_layout_patch(node,v)}
    if .Float in fields {node.float=v.float}
    if .Image in fields {node.image=v.image}
    if .Animations in fields {node.anims=v.anims}
    if .Bindings in fields {
        node.bind_text=v.bind_text;node.bind_value=v.bind_value;node.bind_visible=v.bind_visible;node.bind_selected=v.bind_selected;node.bind_disabled=v.bind_disabled
        node.bind_items=v.bind_items;node.bind_image=v.bind_image;node.bind_tint=v.bind_tint;node.bind_variant=v.bind_variant
        node.data=v.data
    }
    if .Visibility in fields {node.selected=v.selected;node.disabled=v.disabled}
    if .Variant in fields {node.variant=v.variant}
    if .Layer in fields {node.layer=v.layer}
    if .Clip in fields {node.clip=v.clip}
    if .Block in fields {node.block=v.block}
    if .Values in fields {node.index,node.count,node.choice,node.range,node.limit,node.delay,node.particle,node.draw=v.index,v.count,v.choice,v.range,v.limit,v.delay,v.particle,v.draw}
    if .Action in fields {node.action=v.action;node.hold=v.hold}
    if .Focus in fields {node.nav=v.nav;node.order=v.order;node.flags=v.flags}
    if .Drag in fields {node.tag,node.accepts,node.ghost=v.tag,v.accepts,v.ghost}
}
@(private)
tree_path :: proc "contextless" (out:[]u8,prefix,name:string) -> (path:string,ok:bool) {
    length:=len(prefix)+len(name)+(1 if prefix!="" && name!="" else 0)
    if length>=len(out) {return "",false}
    copy(out,prefix)
    at:=len(prefix)
    if prefix!="" && name!="" {out[at]='/';at+=1}
    copy(out[at:],name)
    return string(out[:length]),true
}
// A path of a widget that starts with @ starts at the data its instance
// gives it: "@" is that data, "@hp" its field hp. Others stay; so does @
// without data, which then binds nothing the game has.
@(private)
tree_data_join :: proc(out:[]u8,path,data:string) -> (joined:string,ok:bool) {
    if len(path)==0 || path[0]!='@' || data=="" {return path,true}
    rest:=path[1:]
    length:=len(data)+len(rest)+(1 if rest!="" else 0)
    if length>=len(out) {return "",false}
    copy(out,data)
    if rest!="" {out[len(data)]='.';copy(out[len(data)+1:],rest)}
    return string(out[:length]),true
}

// The paths of a node of a widget, those of the fields of its text too, joined to data.
@(private)
tree_data_paths :: proc(node:^Tree_Node,data:string) -> bool {
    fields:=[?][]u8{node.bind_text[:],node.bind_value[:],node.bind_visible[:],node.bind_selected[:],node.bind_disabled[:],node.bind_items[:],node.bind_image[:],node.bind_tint[:],node.bind_variant[:],
        node.fields[0].path[:],node.fields[1].path[:],node.fields[2].path[:],node.fields[3].path[:]}
    for field in fields {
        buffer:[TREE_PATH_CAPACITY]u8
        joined:=tree_data_join(buffer[:],serial.text_field(field),data) or_return
        if len(joined)>=len(field) {return false}
        tree_text_set(field,joined)
    }
    return true
}

@(private)
Tree_Expansion :: struct {
    data:Tree_Data,
    output:[]Tree_Node,
    count:int,
    matched:[]bool,
    components:[TREE_DEPTH]u16,
    allocator:runtime.Allocator,
}
@(private)
tree_expand_range :: proc(e:^Tree_Expansion,nodes:[]Tree_Node,parent:i32,prefix,local_prefix:string,instance:i32,component_depth:int,root_patch:^Tree_Node=nil,inherited_variant:[TREE_NAME_CAPACITY]u8={},parent_depth:int=0,data:string="") -> (first:i32,ok:bool) {
    first=i32(e.count)
    maps,error:=make([]i32,len(nodes),e.allocator)
    if error!=nil {return -1,false}
    defer delete(maps,e.allocator)
    subtree,error2:=make([]i32,len(nodes),e.allocator)
    if error2!=nil {return -1,false}
    defer delete(subtree,e.allocator)
    depths,error3:=make([]int,len(nodes),e.allocator)
    if error3!=nil {return -1,false}
    defer delete(depths,e.allocator)
    for &source,at in nodes {
        if source.parent<-1 || int(source.parent)>=at {return -1,false}
        if source.parent>=0 && (!node_kind_holds(nodes[source.parent].kind) && nodes[source.parent].kind!=.Component || int(source.parent+subtree[source.parent])+1!=at) {return -1,false}
        for ancestor:=source.parent;ancestor>=0;ancestor=nodes[ancestor].parent {subtree[ancestor]+=1}
        source:=source
        for field in tree_node_texts(&source) {if len(serial.text_field(field))>=len(field) {return -1,false}}
        if (transmute(u32)source.component_fields)&NODE_FIELDS_UNKNOWN!=0 {return -1,false}
        depth:=depths[source.parent]+1 if source.parent>=0 else parent_depth
        if depth>=TREE_DEPTH {return -1,false}
        depths[at]=depth
        destination_parent:=maps[source.parent] if source.parent>=0 else parent
        name:=serial.text_field(source.name[:])
        path_buffer,local_buffer:[TREE_NAME_CAPACITY]u8
        path_name:=name if at!=0 || root_patch==nil else ""
        path,path_ok:=tree_path(path_buffer[:],prefix,path_name)
        local,local_ok:=tree_path(local_buffer[:],local_prefix,name)
        if !path_ok || !local_ok {return -1,false}
        if source.kind==.Component {
            if source.component==0 || int(source.component)>len(e.data.components) || name=="" || component_depth>=TREE_DEPTH || e.data.components[source.component-1].count==0 {return -1,false}
            for active in e.components[:component_depth] {if active==source.component {return -1,false}}
            e.components[component_depth]=source.component
            component:=e.data.components[source.component-1]
            top:=i32(at) if instance==-1 else instance
            next_local:=local if instance>=0 else ""
            next_variant:=source.variant if source.variant!={} else inherited_variant
            // What its widget reads with @: its data, itself read from the data around it.
            data_buffer:[TREE_PATH_CAPACITY]u8
            inner,inner_ok:=tree_data_join(data_buffer[:],serial.text_field(source.data[:]),data)
            if !inner_ok {return -1,false}
            root,expanded:=tree_expand_range(e,e.data.component_nodes[component.first:][:component.count],destination_parent,path,next_local,top,component_depth+1,&source,next_variant,depth,inner)
            if !expanded {return -1,false}
            maps[at]=root
            // What the instance holds goes in the Slot of its template, a node
            // left without one holds what no node can be.
            if e.output!=nil && at+1<len(nodes) && nodes[at+1].parent==i32(at) {
                slot:=-1
                for i in int(root)..<e.count {if .Slot in e.output[i].flags {slot=i}}
                if slot<0 {return -1,false}
                maps[at]=i32(slot)
            }
            continue
        }
        if source.component!=0 {return -1,false}
        node:=source
        if at==0 && root_patch!=nil {
            tree_node_patch(&node,root_patch.component_fields,root_patch)
            path=prefix
        }
        if node.variant=={} {node.variant=inherited_variant}
        if instance>=0 {
            for &override,i in e.data.overrides {
                if int(override.instance)!=int(instance) || serial.text_field(override.node[:])!=local {continue}
                tree_node_patch(&node,override.fields,&override.values)
                e.matched[i]=true
            }
        }
        if int(node.style)>=max(len(e.data.styles),1) || int(node.image)>len(e.data.images) || int(node.anims)>len(e.data.anim_sets) {return -1,false}
        if !tree_layout_finite(node.layout,node.float) || !tree_finite(node.layer.opacity,node.layer.radius,node.layer.backdrop_blur) {return -1,false}
        if e.count>=TREE_EXPANDED_NODES {return -1,false}
        if data!="" && !tree_data_paths(&node,data) {return -1,false}
        node.parent=destination_parent
        node.component,node.component_fields=0,{}
        tree_text_set(node.name[:],path if name!="" || at==0 && root_patch!=nil else "")
        maps[at]=i32(e.count)
        if e.output!=nil {e.output[e.count]=node}
        e.count+=1
    }
    return first,true
}

// The nodes of linked records (tree_link) with their components expanded, as
// tree_load builds them: row i is node i of the Widget_Tree, named by its path.
tree_expand :: proc(data:Tree_Data,allocator:runtime.Allocator) -> (nodes:[]Tree_Node,ok:bool) {
    if len(data.components)>=int(max(u16)) || len(data.nodes)>TREE_EXPANDED_NODES {return nil,false}
    for &component,i in data.components {
        // A widget names a file the records must be linked with first.
        if component.widget!={} || u64(component.first)+u64(component.count)>u64(len(data.component_nodes)) {return nil,false}
        name:=serial.text_field(component.name[:])
        if name=="" || len(name)>=len(component.name) {return nil,false}
        for &earlier in data.components[:i] {if serial.text_field(earlier.name[:])==name {return nil,false}}
        if component.count==0 {continue}
        range:=data.component_nodes[component.first:][:component.count]
        if range[0].kind==.Component || range[0].parent!=-1 {return nil,false}
        for node,at in range {if at>0 && node.parent<0 {return nil,false}}
    }
    for &override in data.overrides {
        if int(override.instance)>=len(data.nodes) || data.nodes[override.instance].kind!=.Component || (transmute(u32)override.fields)&NODE_FIELDS_UNKNOWN!=0 {return nil,false}
        name:=serial.text_field(override.node[:])
        if name=="" || len(name)>=len(override.node) {return nil,false}
    }
    matched,error:=make([]bool,len(data.overrides),allocator)
    if error!=nil {return nil,false}
    defer delete(matched,allocator)
    e:=Tree_Expansion{data=data,matched=matched,allocator=allocator}
    // Unused templates are validated too, including recursion cycles.
    for &component,i in data.components {
        if component.count==0 {continue}
        e.count=0;e.components[0]=u16(i+1)
        _,valid:=tree_expand_range(&e,data.component_nodes[component.first:][:component.count],-1,"","",-2,1)
        if !valid {return nil,false}
    }
    e.count=0
    _,valid:=tree_expand_range(&e,data.nodes,-1,"","",-1,0)
    if !valid {return nil,false}
    for found in matched {if !found {return nil,false}}
    nodes,error=make([]Tree_Node,e.count,allocator)
    if error!=nil {return nil,false}
    e.output,e.count=nodes,0
    _,valid=tree_expand_range(&e,data.nodes,-1,"","",-1,0)
    if !valid {delete(nodes,allocator);return nil,false}
    return nodes,true
}

// Names remain local in a template; each instance exposes its own namespace.
tree_component_record :: proc(name:string,first,count:u32) -> (component:Tree_Component) {
    component.first,component.count=first,count
    tree_text_set(component.name[:],name)
    return
}
tree_override_record :: proc(text:^[dynamic]u8,instance:u32,node:string,fields:Node_Fields,values:Node_Desc) -> (override:Tree_Override) {
    // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
    override.instance=instance
    override.fields=fields
    override.values=tree_node_record(text,-1,values)
    tree_text_set(override.node[:],node)
    return
}
tree_variant_record :: proc(style:u16,variant:string,states:Style_States,patch:Style_Patch) -> (rule:Tree_Style_Variant) {
    // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
    rule.style=style
    rule.states=states
    rule.patch=patch
    tree_text_set(rule.variant[:],variant)
    return
}
