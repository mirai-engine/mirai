package editor

import "base:runtime"
import "core:fmt"
import "core:mem"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/history"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import "mirai:editor/kit"
import "mirai:ui"

// The effects of the View_Volume of the selected entity: enable,
// disable, add, remove and reorder the materials whose program is a
// Postprocess one. The stack is scene data; the material keeps its
// parameters and opens in the material document.

POST_PROCESS_PICKER_WIDTH :: f32(320)
POST_PROCESS_PICKER_LIST :: f32(240)
POST_PROCESS_CHOICE_CAPACITY :: 256

@(storage)
Post_Process_Provider :: struct {provider:Inspector_Provider}

POST_PROCESS_PROVIDER_DEFAULT :: Post_Process_Provider{provider={array=post_process_array}}

Post_Process_Picker :: struct {
	open:bool,
	add:bool,      // true: add a layer; false: replace the material of layer
	after:bool,    // stage of a new layer
	layer:int,     // raw index for a replacement
	scroll:f32,
	filter:[64]u8,
	filter_length:int,
	choices:[POST_PROCESS_CHOICE_CAPACITY]Post_Process_Choice, // read once, when it opens
	choice_count:int,
}

Post_Process_Editor :: struct {
	picker:Post_Process_Picker,
	inspect_entity:core.Entity, // whose stack the viewport shows up to inspect_layer; NONE: all of it
	inspect_layer:int,
}

Post_Process_Choice :: struct {
	id:base.Asset_Id,
	program:[asset.MATERIAL_NAME_BYTES]u8,
}

Post_Process_Selection :: struct {
	world:core.World_Ref,
	table:^core.Table_Info,
	entity:core.Entity,
	post:^erender.View_Volume,
}

post_process_picker_id :: proc(g:^Editor_Ui) -> ui.Id {
	return shell_id(g,"post_process_picker")
}

// The table and the stack of the selected entity, if it has a Post Process
// component. The first entity with one decides the stack in the renderer.
post_process_selection :: proc(s:^Session) -> (sel:Post_Process_Selection,ok:bool) {
	w:=shown_world(s)
	e:=history.selection_active(s.selection)
	if w.info==nil || e==core.NONE {return}
	for &t in w.info.tables {
		if t.type!=erender.View_Volume {continue}
		table:=core.world_table_at(w,&t)
		value:=core.raw_find(table,t.info,e)
		if value==nil {return}
		sel={world=w,table=&t,entity=e,post=cast(^erender.View_Volume)value}
		return sel,true
	}
	return
}

post_process_count :: proc(
	layers:^[erender.POST_PROCESS_CAPACITY]erender.Post_Process_Layer) -> int {
	count:=0
	for i in 0..<erender.POST_PROCESS_CAPACITY {
		if layers[i].material!={} {count+=1}
	}
	return count
}

// Leaves the used layers first and clears the rest.
post_process_compact :: proc(
	layers:^[erender.POST_PROCESS_CAPACITY]erender.Post_Process_Layer) -> int {
	used:=0
	for i in 0..<erender.POST_PROCESS_CAPACITY {
		if layers[i].material=={} {continue}
		if used!=i {layers[used]=layers[i]}
		used+=1
	}
	for i in used..<erender.POST_PROCESS_CAPACITY {layers[i]={}}
	return used
}

post_process_write :: proc(s:^Session,sel:Post_Process_Selection,
	layers:^[erender.POST_PROCESS_CAPACITY]erender.Post_Process_Layer) {
	field_write(s,sel.table,[]core.Entity{sel.entity},
		int(offset_of(erender.View_Volume,layers)),mem.ptr_to_bytes(layers))
}

// Writes one field of one layer: offset is that of the field in Post_Process_Layer.
post_process_write_field :: proc(s:^Session,sel:Post_Process_Selection,index:int,
	offset:uintptr,bytes:[]u8) {
	if index<0 || index>=erender.POST_PROCESS_CAPACITY {return}
	at:=int(offset_of(erender.View_Volume,layers))+
		index*size_of(erender.Post_Process_Layer)+int(offset)
	field_write(s,sel.table,[]core.Entity{sel.entity},at,bytes)
}

post_process_write_enabled :: proc(s:^Session,sel:Post_Process_Selection,index:int,on:bool) {
	value:=on
	post_process_write_field(s,sel,index,offset_of(erender.Post_Process_Layer,enabled),
		mem.ptr_to_bytes(&value))
}

post_process_write_after :: proc(s:^Session,sel:Post_Process_Selection,index:int,after:bool) {
	value:=after
	post_process_write_field(s,sel,index,offset_of(erender.Post_Process_Layer,after_tonemap),
		mem.ptr_to_bytes(&value))
}

post_process_add :: proc(s:^Session,id:base.Asset_Id,after:bool) {
	sel,ok:=post_process_selection(s)
	if !ok || id=={} {return}
	next:=sel.post.layers
	used:=post_process_compact(&next)
	if used>=erender.POST_PROCESS_CAPACITY {return}
	at:=used
	for layer,i in next[:used] {
		if layer.after_tonemap==after {at=i+1}
	}
	if at<used {
		mem.copy(&next[at+1],&next[at],
			(used-at)*size_of(erender.Post_Process_Layer))
	}
	next[at]={material=id,after_tonemap=after,enabled=true}
	for i in used+1..<erender.POST_PROCESS_CAPACITY {next[i]={}}
	post_process_write(s,sel,&next)
}

post_process_remove :: proc(s:^Session,index:int) {
	sel,ok:=post_process_selection(s)
	if !ok || index<0 || index>=erender.POST_PROCESS_CAPACITY {return}
	next:=sel.post.layers
	if next[index].material=={} {return}
	next[index]={}
	post_process_compact(&next)
	post_process_write(s,sel,&next)
}

post_process_clear :: proc(s:^Session) {
	sel,ok:=post_process_selection(s)
	if !ok {return}
	next:[erender.POST_PROCESS_CAPACITY]erender.Post_Process_Layer
	post_process_write(s,sel,&next)
}

post_process_neighbor :: proc(layers:^[erender.POST_PROCESS_CAPACITY]erender.Post_Process_Layer,
	index,direction:int) -> int {
	if index<0 || index>=erender.POST_PROCESS_CAPACITY {return -1}
	after:=layers[index].after_tonemap
	for i:=index+direction; i>=0 && i<erender.POST_PROCESS_CAPACITY; i+=direction {
		if layers[i].material=={} || layers[i].after_tonemap!=after {continue}
		return i
	}
	return -1
}

post_process_move :: proc(s:^Session,index,direction:int) {
	sel,ok:=post_process_selection(s)
	if !ok {return}
	next:=sel.post.layers
	other:=post_process_neighbor(&next,index,direction)
	if other<0 {return}
	next[index],next[other]=next[other],next[index]
	post_process_write(s,sel,&next)
}

// The effects of each side of the tonemap that run up to layer and the one
// at layer, as the renderer gets them: the enabled and usable layers, before
// the tonemap first.
post_process_inspect_counts :: proc(layers:^[erender.POST_PROCESS_CAPACITY]erender.Post_Process_Layer,
	usable:[erender.POST_PROCESS_CAPACITY]bool,layer:int) -> (effects:[2]u8,ok:bool) {
	if layer<0 || layer>=erender.POST_PROCESS_CAPACITY {return}
	shown:=layers[layer]
	if shown.material=={} || !shown.enabled || !usable[layer] {return}
	for l,i in layers {
		if l.material=={} || !l.enabled || !usable[i] {continue}
		side:=1 if l.after_tonemap else 0
		if l.after_tonemap==shown.after_tonemap {
			if i<=layer {effects[side]+=1}
		} else if !l.after_tonemap {effects[0]+=1}
	}
	return effects,true
}

post_process_inspecting :: proc(s:^Session,sel:Post_Process_Selection,index:int) -> bool {
	e:=&s.inspector.post_process
	return e.inspect_entity==sel.entity && e.inspect_layer==index
}

// The viewport shows the image of the stack up to the layer the eye of the
// inspector chose, in the View_Volume it chose.
@(step="render",after="view_mode_render")
post_process_inspect_render :: proc(s:^Session,app:^host.App) {
	e:=&s.inspector.post_process
	if e.inspect_entity==core.NONE {return}
	if s.mode==.Play || document_is_prefab(s) {return}
	w:=shown_world(s)
	for &t in w.info.tables {
		if t.type!=erender.View_Volume {continue}
		table:=core.world_table_at(w,&t)
		if table==nil || table.on==0 {break}
		post:=cast(^erender.View_Volume)core.raw_find(table,t.info,e.inspect_entity)
		if post==nil {break}
		usable:[erender.POST_PROCESS_CAPACITY]bool
		for layer,i in post.layers {
			_,program:=post_process_material_info(s,layer.material)
			usable[i]=layer.material!={} && program!="" && program!="No Postprocess program"
		}
		effects,ok:=post_process_inspect_counts(&post.layers,usable,e.inspect_layer)
		if !ok {break}
		app.inspection.postprocess={limited=true,effects=effects}
		return
	}
	e.inspect_entity=core.NONE
}

post_process_material_info :: proc(s:^Session,id:base.Asset_Id) -> (name,program:string) {
	name=asset_label_of(s,id,"None")
	if id=={} {return}
	a:=s.app.assets
	if a==nil {return name,""}
	material:=host.assets_material(a,id)
	if material==nil || material.failed {return name,""}
	found:=host.assets_material_program(a,material,.Postprocess)
	if found==nil {return name,"No Postprocess program"}
	return name,found.name
}

// The registered materials with a Postprocess program, into the choices of
// the picker.
post_process_choices_read :: proc(s:^Session,p:^Post_Process_Picker) {
	p.choice_count=0
	a:=s.app.assets
	if a==nil {return}
	for &file in a.registry.files {
		if p.choice_count>=POST_PROCESS_CHOICE_CAPACITY {return}
		if file.state!=.Asset || file.kind!=asset.KIND_MATERIAL {continue}
		if !asset.registry_listed(&file) {continue}
		material:=host.assets_material(a,file.id)
		if material==nil || material.failed {continue}
		program:=host.assets_material_program(a,material,.Postprocess)
		if program==nil {continue}
		choice:=&p.choices[p.choice_count]
		choice.id=file.id
		base.text_set(choice.program[:],program.name)
		p.choice_count+=1
	}
}

post_process_picker_open :: proc(s:^Session,add:bool,layer:int,after:bool,anchor:ui.Rect) {
	p:=&s.inspector.post_process.picker
	p^={open=true,add=add,layer=layer,after=after}
	post_process_choices_read(s,p)
	ui.popup_open(s.gui.ctx,post_process_picker_id(s.gui),anchor)
}

post_process_pick :: proc(s:^Session,id:base.Asset_Id) {
	p:=&s.inspector.post_process.picker
	if id=={} {return}
	if p.add {
		post_process_add(s,id,p.after)
		return
	}
	sel,ok:=post_process_selection(s)
	if !ok || p.layer<0 || p.layer>=erender.POST_PROCESS_CAPACITY {return}
	next:=sel.post.layers
	if next[p.layer].material=={} {return}
	next[p.layer].material=id
	next[p.layer].enabled=true
	post_process_write(s,sel,&next)
}

post_process_row :: proc(s:^Session,index:int,layer:erender.Post_Process_Layer) {
	ctx:=s.gui.ctx
	sel,ok:=post_process_selection(s)
	if !ok {return}
	name,_:=post_process_material_info(s,layer.material)
	up:=post_process_neighbor(&sel.post.layers,index,-1)>=0
	down:=post_process_neighbor(&sel.post.layers,index,1)>=0
	if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=2,align_y=.Center}) {
		on:=layer.enabled
		if ui.checkbox(ctx,ui.id(ctx,"post_enabled",index+1),&on) {
			post_process_write_enabled(s,sel,index,on)
		}
		button:=ui.id(ctx,"post_material",index+1)
		if ui.button(ctx,button,{label=name,variant="field",width=-1,
			height=ui.metric(ctx,"row")-4,size=ui.metric(ctx,"font_small")}).clicked {
			if rect,found:=ui.widget_rect(ctx,button); found {
				post_process_picker_open(s,false,index,false,rect)
			}
		}
		inspecting:=post_process_inspecting(s,sel,index)
		if ui.button(ctx,ui.id(ctx,"post_inspect",index+1),
			{icon=.Eye,variant="ghost",width=22,height=22,icon_size=13,active=inspecting,
			 icon_color=ui.tone(ctx,"accent") if inspecting else ui.tone(ctx,"text_muted"),disabled=!layer.enabled}).clicked {
			e:=&s.inspector.post_process
			if inspecting {e.inspect_entity=core.NONE} else {e.inspect_entity,e.inspect_layer=sel.entity,index}
		}
		if ui.button(ctx,ui.id(ctx,"post_edit",index+1),
			{icon=.Edit,variant="ghost",width=22,height=22,icon_size=13,icon_color=ui.tone(ctx,"text_muted")}).clicked {
			asset_document_open(s,layer.material)
		}
		if ui.button(ctx,ui.id(ctx,"post_stage",index+1),
			{label=layer.after_tonemap?"LDR":"HDR",variant="ghost",width=32,
			 height=22,size=ui.metric(ctx,"font_small")}).clicked {
			post_process_write_after(s,sel,index,!layer.after_tonemap)
		}
		if ui.button(ctx,ui.id(ctx,"post_up",index+1),
			{icon=.Chevron_Up,variant="ghost",width=18,height=22,icon_size=12,
			 icon_color=ui.tone(ctx,"text_muted"),disabled=!up}).clicked {
			post_process_move(s,index,-1)
		}
		if ui.button(ctx,ui.id(ctx,"post_down",index+1),
			{icon=.Chevron_Down,variant="ghost",width=18,height=22,icon_size=12,
			 icon_color=ui.tone(ctx,"text_muted"),disabled=!down}).clicked {
			post_process_move(s,index,1)
		}
		if ui.button(ctx,ui.id(ctx,"post_remove",index+1),
			{icon=.Cross,variant="ghost",width=22,height=22,icon_size=12,icon_color=ui.tone(ctx,"text_muted")}).clicked {
			post_process_remove(s,index)
		}
	}
	post_process_fade_row(s,sel,index,layer)
}

// The fade of a layer under its row: a scrub is one undo step.
post_process_fade_row :: proc(s:^Session,sel:Post_Process_Selection,index:int,
	layer:erender.Post_Process_Layer) {
	ctx:=s.gui.ctx
	row_begin(ctx,"Fade")
	value:=f64(layer.fade)
	r:=kit.slider_field(ctx,ui.id(ctx,"post_fade",index+1),&value,
		{decimals=2,speed=0.005,min=0,max=1,has_min=true,has_max=true,height=22})
	key:=value_key(sel.entity,index,base.name_hash("Post_Process_Layer.fade"))
	gesture_follow(s,key,r,"Fade")
	if r.changed {
		fade:=f32(value)
		post_process_write_field(s,sel,index,offset_of(erender.Post_Process_Layer,fade),
			mem.ptr_to_bytes(&fade))
	}
	if r.ended {gesture_end(s,key)}
	row_end(ctx)
}

post_process_group :: proc(s:^Session,after:bool) {
	ctx:=s.gui.ctx
	sel,ok:=post_process_selection(s)
	if !ok {return}
	kit.section(ctx,after?"AFTER TONEMAP":"BEFORE TONEMAP")
	any:=false
	for layer,i in sel.post.layers {
		if layer.material=={} || layer.after_tonemap!=after {continue}
		post_process_row(s,i,layer)
		any=true
	}
	if !any {ui.label(ctx,"None",ui.metric(ctx,"font_small"),ui.tone(ctx,"text_faint"),0)}
}

// The layers of a View_Volume as a stack of effects.
post_process_array :: proc(c:^Inspect,info:^runtime.Type_Info,name,label:string,offset:uintptr) -> bool {
	if c.t==nil || c.t.type!=erender.View_Volume || name!="layers" || offset!=offset_of(erender.View_Volume,layers) {return false}
	s:=c.s
	ctx:=s.gui.ctx
	if len(c.entities)!=1 {return false}
	value:=core.raw_find(core.world_table_at(c.w,c.t),c.t.info,c.entities[0])
	if value==nil {return true}
	post:=cast(^erender.View_Volume)value
	used:=post_process_count(&post.layers)
	if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=6,align_y=.Center}) {
		ui.label(ctx,fmt.tprintf("%d / %d effects",used,
			erender.POST_PROCESS_CAPACITY),ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))
		ui.spacer(ctx)
		add:=ui.id(ctx,"post_process_add")
		if ui.button(ctx,add,{label="Add effect",icon=.Plus,variant="field",height=24,
			size=ui.metric(ctx,"font_small"),disabled=used>=erender.POST_PROCESS_CAPACITY}).clicked {
			if rect,found:=ui.widget_rect(ctx,add); found {
				post_process_picker_open(s,true,-1,false,rect)
			}
		}
		if ui.button(ctx,ui.id(ctx,"post_process_clear"),
			{label="Clear",variant="ghost",height=24,size=ui.metric(ctx,"font_small"),disabled=used==0}).clicked {
			post_process_clear(s)
		}
	}
	post_process_group(s,false)
	post_process_group(s,true)
	return true
}

post_process_picker_build :: proc(s:^Session) {
	p:=&s.inspector.post_process.picker
	if !p.open {return}
	ctx:=s.gui.ctx
	popup:=post_process_picker_id(s.gui)
	if !ui.popup_is_open(ctx,popup) {
		p^={}
		return
	}
	if !p.add {
		sel,ok:=post_process_selection(s)
		if !ok || p.layer<0 || p.layer>=erender.POST_PROCESS_CAPACITY ||
			sel.post.layers[p.layer].material=={} {
			p^={}
			ui.popup_close(ctx,popup)
			return
		}
	}
	filter:=string(p.filter[:p.filter_length])
	shown:=make([dynamic]int,context.temp_allocator)
	for &choice,i in p.choices[:p.choice_count] {
		if base.contains_fold(asset_label_of(s,choice.id,""),filter) ||
			base.contains_fold(base.text_get(choice.program[:]),filter) {
			append(&shown,i)
		}
	}
	if ui.popup(ctx,popup,{width=POST_PROCESS_PICKER_WIDTH,padding=12,gap=4}) {
		ui.id_push(ctx,popup)
		defer ui.id_pop(ctx)
		if p.add {
			ui.label(ctx,"Add effect",ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"),0)
			stage:=p.after?1:0
			if kit.tabs(ctx,ui.id(ctx,"post_picker_stage"),
				{"Before tonemap","After tonemap"},&stage,ui.fixed(240),24) {
				p.after=stage==1
			}
		} else {
			ui.label(ctx,"Choose material",ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"),0)
		}
		ui.text_field(ctx,ui.id(ctx,"post_picker_filter"),p.filter[:],
			&p.filter_length,{placeholder="Search",live=true,height=ui.metric(ctx,"row")})
		if len(shown)==0 {
			ui.label(ctx,"No Postprocess material",ui.metric(ctx,"font_small"),ui.tone(ctx,"text_faint"),0)
		} else {
			picked:=false
			first,last:=ui.list_begin(ctx,ui.id(ctx,"post_picker_list"),&p.scroll,
				len(shown),ui.metric(ctx,"row"),POST_PROCESS_PICKER_LIST)
			for i in first..<last {
				choice:=&p.choices[shown[i]]
				label:=fmt.tprintf("%s - %s",asset_label_of(s,choice.id,""),
					base.text_get(choice.program[:]))
				if ui.button(ctx,ui.id(ctx,"post_picker_item",i+1),
					{label=label,variant="ghost",width=-1,height=ui.metric(ctx,"row"),
					 size=ui.metric(ctx,"font_small")}).clicked {
					post_process_pick(s,choice.id)
					picked=true
					break
				}
			}
			ui.list_end(ctx,ui.id(ctx,"post_picker_list"),len(shown),last,ui.metric(ctx,"row"))
			if picked {
				ui.popup_close(ctx,popup)
				p^={}
			}
		}
	}
}
