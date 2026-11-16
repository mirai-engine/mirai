package author

import "core:strings"
import "mirai:asset"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// What the uses of a widget give follows where its parameters go: when a
// widget is written with other parameters, the .ui of the project that use it
// are written again, by the editor as steps of their history and by mirai ui
// write as their files.

// A parameter of a widget that went somewhere else, or went: after is empty.
Param_Change :: struct {before,after:ui.Tree_Param}

// What changed between two versions of the flat parameters of a widget. One
// that has another name now and goes to the same place changed nothing: a use
// says it by its name, read from the widget.
params_changes :: proc(before,after:[]ui.Tree_Param) -> []Param_Change {
    changes:=make([dynamic]Param_Change,context.temp_allocator)
    for &old in before {
        now:^ui.Tree_Param
        same_place:=false
        for &p in after {
            if p.name==old.name {now=&p;break}
            if p.node==old.node && p.field==old.field {same_place=true}
        }
        if now==nil {
            if !same_place {append(&changes,Param_Change{before=old})}
            continue
        }
        if now.node!=old.node || now.field!=old.field {append(&changes,Param_Change{before=old,after=now^})}
    }
    return changes[:]
}

// What the uses of a widget gave follows where its parameters go now, in the
// .ui of the project and, past a parameter of a widget that goes to the use,
// the uses of that one. write puts the records of each file that changes, and
// says whether it could; changed counts them.
widget_params_follow :: proc(a:Assets,id:base.Asset_Id,changes:[]Param_Change,write:proc(user:rawptr,id:base.Asset_Id,records:^Records) -> bool,user:rawptr,depth:=0) -> (changed:int) {
    if len(changes)==0 || depth>=ui.TREE_DEPTH {return}
    ids:=make([dynamic]base.Asset_Id,context.temp_allocator)
    for &file in a.registry.files {
        if file.kind==asset.KIND_UI && file.id!={} && file.id!=id {append(&ids,file.id)}
    }
    for file_id in ids {
        file:=struct{id:base.Asset_Id}{file_id}
        records:Records
        if !records_read(a,file.id,&records,context.temp_allocator) {continue}
        derived:=records_params_follow(a,&records,id,changes)
        if !derived.changed {continue}
        // A write may move the files of the registry: the next one is found again.
        followed:=file.id
        if !write(user,followed,&records) {continue}
        changed+=1+widget_params_follow(a,followed,derived.through[:],write,user,depth+1)
    }
    return
}

// What a file does when the parameters of a widget it uses change.
Param_Follow :: struct {
    changed:bool,
    through:[dynamic]Param_Change, // of its own parameters, the ones that go to those uses
}

// Moves what the uses of widget in records give; gone, it is taken away.
records_params_follow :: proc(a:Assets,records:^Records,widget:base.Asset_Id,changes:[]Param_Change) -> (follow:Param_Follow) {
    follow.through=make([dynamic]Param_Change,context.temp_allocator)
    lib,lib_ok:=doc_lib_read(a,widget,context.temp_allocator)
    if !lib_ok {return}
    node_at :: proc(lib:^Doc_Lib,path:string) -> (node:ui.Tree_Node,source:^Records) {
        source=new(Records,context.temp_allocator)
        records_load(source,lib.linked,context.temp_allocator)
        expanded,ok:=ui.tree_expand(lib.linked,context.temp_allocator)
        if ok {for &e in expanded {if serial.text_field(e.name[:])==path {return e,source}}}
        return {},source
    }
    w:=Doc_Write{r=records,list=records.nodes[:]}
    for &n,row in records.nodes {
        if n.kind!=.Component || int(n.component)==0 || int(n.component)>len(records.components) || records.components[n.component-1].widget!=widget {continue}
        name:=serial.text_field(n.name[:])
        for &c in changes {
            if value,has:=doc_param_value(&w,row,&c.before);has {
                follow.changed=true
                records_param_clear(records,row,&c.before,lib.linked.params)
                if c.after.name!={} {
                    node,source:=node_at(&lib,serial.text_field(c.after.node[:]))
                    records_param_give(a,records,row,&c.after,value,source,node)
                }
            }
            // A parameter of this file that goes to this one, through this use.
            for &p in records.params {
                if serial.text_field(p.node[:])!=name || serial.text_field(p.param[:])!=serial.text_field(c.before.name[:]) {continue}
                outer:=Param_Change{before=p}
                flatten :: proc(flat:^ui.Tree_Param,use:string,inner:^ui.Tree_Param) {
                    flat.param,flat.field={},inner.field
                    ui.tree_text_set(flat.node[:],strings.join({use,serial.text_field(inner.node[:])},"/",context.temp_allocator) if inner.node[0]!=0 else use)
                }
                flatten(&outer.before,name,&c.before)
                if c.after.name!={} {
                    outer.after=p
                    flatten(&outer.after,name,&c.after)
                }
                append(&follow.through,outer)
            }
        }
    }
    return
}

// Takes away of the use at row the value a parameter gave, unless another
// parameter of the widget goes to the same part of the same node.
records_param_clear :: proc(r:^Records,row:int,p:^ui.Tree_Param,all:[]ui.Tree_Param) {
    group:=doc_param_group(p.field)
    keep:=false
    for &other in all {if other.name!=p.name && other.node==p.node && doc_param_group(other.field)==group {keep=true}}
    node:=serial.text_field(p.node[:])
    if node=="" {
        if !keep {r.nodes[row].component_fields-={group}} else if slot:=doc_param_slot(&r.nodes[row],p.field);slot!=nil {ui.tree_text_set(slot,"")}
        return
    }
    for i:=len(r.overrides)-1;i>=0;i-=1 {
        o:=&r.overrides[i]
        if int(o.instance)!=row || serial.text_field(o.node[:])!=node || group not_in o.fields {continue}
        if keep {
            if slot:=doc_param_slot(&o.values,p.field);slot!=nil {ui.tree_text_set(slot,"")}
        } else {
            o.fields-={group}
            if o.fields=={} {ordered_remove(&r.overrides,i)}
        }
    }
}
