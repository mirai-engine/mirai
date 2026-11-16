package profiler_editor

import "core:fmt"
import "core:hash"
import "mirai:editor/kit"
import "mirai:core"
import "mirai:editor"
import "mirai:host"
import mm "mirai:std/math"
import "mirai:ui"

// A panel of the editor, under View > Profiler, that records frames into the
// captures of the profile.* methods and shows the last one: the time of each
// frame, then a tab per track: the zones of the threads of the frame chosen
// and the zones that took most; its GPU passes where they ran and the passes
// that took most; the memory over the frames. An agent and the panel see the
// same captures.

@(storage)
Profiler_Api :: struct {provider:editor.Api_Provider}

PROFILER_API_DEFAULT :: Profiler_Api{provider={register=api_register}}

@(private)
panel_of :: proc(s:^editor.Session) -> ^Profiler_Panel {
	if s.info==nil || s.editor_world==nil {return nil}
	return core.world_storage_of(core.world_ref(s.editor_world,s.info,.Editor),Profiler_Panel)
}

@(private)
api_register :: proc(s:^editor.Session) {
	editor.command_bind(s,{name="profiler",label="Profiler",icon=.History,menu=.View,group=editor.MENU_GROUP_PLUGINS,state=panel_state,
		view=proc(s:^editor.Session) {if p:=panel_of(s);p!=nil {p.open=!p.open}},
	})
}

@(private)
panel_state :: proc(s:^editor.Session,b:^editor.Binding) -> editor.Command_State {
	p:=panel_of(s)
	return {checked=p!=nil && p.open,disabled=p==nil}
}

PANEL_SCOPE :: ui.Id(0x70726f66)
TOP_ZONES :: 8
FRAMES_DEFAULT :: 120
ROW :: f32(16)     // of a row of the timeline, in points
GRAPH :: f32(72)   // height of the graph of the frames

TABS :: [?]string{"CPU","GPU","Memory"}
Tab :: enum int {Cpu,Gpu,Memory}
TAB_GAP :: f32(8)

Top_Pass :: struct {
	name: int, // into the pass names of the capture
	ms:   f64, // per measured frame
}

Top_Zone :: struct {
	name:   int, // into the names of the capture
	worker: bool,
	ms:     f64, // per frame, of the frames it was in
	calls:  f64, // per frame
}

@(storage)
Profiler_Panel :: struct {
	open:    bool,
	frames:  f64, // frames a recording takes
	shown:   int, // id of the capture the panel shows; 0: none
	frame:   int, // of that capture, the one the timeline shows
	workers: int, // first zone of the other threads in the capture
	depth:   int, // rows of the main thread
	threads: [64]u8, // the other threads that ran jobs in the capture
	thread_count: int,
	graph_ms: f64, // the top of the graph: above it a frame is cut and marked
	top:     [TOP_ZONES]Top_Zone,
	top_count: int,
	passes:  [TOP_ZONES]Top_Pass,
	pass_count: int,
	tab:     int,
	memory_range: [3][2]f64, // of the World, the private memory and the GPU, in MB: the lowest and highest of the capture
	error:   [128]u8,
	error_length: int,
	capture: ^editor.Profile_Capture, // the one shown, for the drawings of this frame
}

@(step="ui",after="editor_panels")
profiler_panel :: proc(s:^editor.Session,p:^Profiler_Panel,app:^host.App) {
	g:=s.gui
	if !g.begun {return}
	ctx:=g.ctx
	if !p.open || s.viewport.pick.active {return}
	if p.frames<=0 {p.frames=FRAMES_DEFAULT}
	editor.profile_collect(s)
	p.capture=editor.profile_find(s,0)
	if p.capture!=nil && p.capture.id!=p.shown {profiler_show(p,p.capture)}
	if p.capture==nil {p.shown=0}

	id:=ui.id_derive(ctx,PANEL_SCOPE,"panel")
	width:=clamp(ctx.size.x*0.62,520,1120)
	bottom:=ui.metric(ctx,"margin")
	if r:=g.rects.bottom;r.h>0 {bottom+=ctx.size.y-r.y}
	if ui.panel(ctx,id,{width=ui.fixed(width),height=ui.FIT,padding=ui.padding_all(12),gap=8,anchor=.Bottom_Center,pivot=.Bottom_Center,offset={0,-bottom}}) {
		ui.id_push(ctx,id)
		defer ui.id_pop(ctx)
		profiler_header(s,p,app)
		if p.capture==nil {return}
		c:=p.capture
		ui.label(ctx,profiler_summary(p,c),ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))
		graph:=editor.drawing(g,ui.id(ctx,"frames"),ui.GROW,ui.fixed(GRAPH),frames_draw,p)
		if graph.pressed || graph.active {
			if r,found:=ui.widget_rect(ctx,ui.id(ctx,"frames"));found && len(c.frames)>0 {
				p.frame=clamp(int((ctx.pointer.x-r.x)/r.w*f32(len(c.frames))),0,len(c.frames)-1)
			}
		}
		titles:=TABS
		kit.tabs(ctx,ui.id(ctx,"tracks"),titles[:],&p.tab,ui.fixed(240),28)
		small:=ui.metric(ctx,"font_small")
		switch Tab(p.tab) {
		case .Cpu: ui.label(ctx,profiler_frame_text(p,c),small,ui.tone(ctx,"text"))
		case .Gpu: ui.label(ctx,gpu_frame_text(p,c),small,ui.tone(ctx,"text"))
		case .Memory:
			if c.memory {ui.label(ctx,memory_frame_text(p,c),small,ui.tone(ctx,"text"))} else {ui.label(ctx,"This capture did not sample the memory",small,ui.tone(ctx,"text_muted"))}
		}
		// Every tab is as tall as the tallest, the others keeping their place empty: the panel,
		// held by its bottom, keeps its tabs under the pointer.
		if ui.box(ctx,{width=ui.GROW,direction=.Stack}) {
			for tab in Tab {
				drawn:=tab==Tab(p.tab) && (tab!=.Memory || c.memory)
				if ui.box(ctx,{width=ui.GROW,direction=.Column,gap=TAB_GAP}) {
					for part in tab_parts(p,tab) {
						if part.height==0 {continue}
						if drawn {editor.drawing(g,ui.id(ctx,part.id),ui.GROW,ui.fixed(part.height),part.draw,p)} else if ui.box(ctx,{width=ui.GROW,height=ui.fixed(part.height)}) {}
					}
				}
			}
		}
	}
}

@(private="file")
Tab_Part :: struct {id:string,height:f32,draw:editor.Drawing_Proc}

// The drawings of a tab, one over the other.
@(private="file")
tab_parts :: proc(p:^Profiler_Panel,tab:Tab) -> [2]Tab_Part {
	switch tab {
	case .Cpu: return {{"timeline",f32(p.depth+p.thread_count)*(ROW+2)+ROW,timeline_draw},{"zones",f32(p.top_count)*ROW+ROW,zones_draw}}
	case .Gpu: return {{"gpu_timeline",ROW+2+ROW,timeline_draw},{"passes",f32(p.pass_count)*ROW+ROW,passes_draw}}
	case .Memory: return {{"memory",GRAPH,memory_draw},{}}
	}
	return {}
}

@(private="file")
profiler_header :: proc(s:^editor.Session,p:^Profiler_Panel,app:^host.App) {
	ctx:=s.gui.ctx
	if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=8,align_y=.Center}) {
		ui.label(ctx,"Profiler",ui.metric(ctx,"font"),ui.tone(ctx,"text"),font=ui.FONT_SEMIBOLD)
		ui.spacer(ctx)
		recording:=s.profiles.recording!=0
		if recording {
			ui.label(ctx,fmt.tprintf("Recording %d/%d",len(host.profile_recording(app).frames),int(p.frames)),ui.metric(ctx,"font_small"),ui.tone(ctx,"accent"))
		} else if p.error_length>0 {
			ui.label(ctx,string(p.error[:p.error_length]),ui.metric(ctx,"font_small"),ui.tone(ctx,"danger"))
		}
		ui.number_field(ctx,ui.id(ctx,"frames_asked"),&p.frames,{width=ui.fixed(72),decimals=0,speed=1,has_min=true,min=2,has_max=true,max=f64(host.PROFILE_FRAMES_MAX),disabled=recording})
		if ui.button(ctx,ui.id(ctx,"record"),{label="Record",variant="accent",size=ui.metric(ctx,"font_small"),disabled=recording}).clicked {
			p.error_length=0
			if _,error:=editor.profile_begin(s,int(p.frames),"profiler panel",memory=Tab(p.tab)==.Memory);error!="" {p.error_length=copy(p.error[:],error)}
		}
	}
}

// What the panel keeps of a capture when it starts showing it: where the
// other threads begin, the rows of the timeline, the top of the graph, the
// zones that took most, and the frame nearest the median as the one chosen.
@(private="file")
profiler_show :: proc(p:^Profiler_Panel,c:^editor.Profile_Capture) {
	p.shown,p.frame,p.workers,p.depth,p.thread_count,p.top_count,p.pass_count=c.id,0,0,1,0,0,0
	p.memory_range={{max(f64),0},{max(f64),0},{max(f64),0}}
	for f in c.frames {
		for value,k in memory_values(f) {p.memory_range[k]={min(p.memory_range[k][0],value),max(p.memory_range[k][1],value)}}
	}
	for values,name in editor.profile_passes_by_name(c) {
		total:f64
		for ms in values {total+=ms}
		entry:=Top_Pass{name,total/f64(max(len(values),1))}
		at:=p.pass_count
		for at>0 && p.passes[at-1].ms<entry.ms {
			if at<TOP_ZONES {p.passes[at]=p.passes[at-1]}
			at-=1
		}
		if at<TOP_ZONES {
			p.passes[at]=entry
			p.pass_count=min(p.pass_count+1,TOP_ZONES)
		}
	}
	frame:=make([]f64,len(c.frames),context.temp_allocator)
	for f,i in c.frames {
		p.workers+=f.zone_count
		frame[i]=editor.profile_frame_ms(f)
	}
	spread,gpu_spread:=editor.profile_spread(frame),editor.profile_spread(editor.profile_gpu_ms(c))
	p.graph_ms=max(spread.p95,gpu_spread.p95,0.001)*1.5
	nearest:=max(f64)
	for ms,i in frame {
		if d:=abs(ms-spread.p50);d<nearest {nearest,p.frame=d,i}
	}
	for zone in c.zones[:p.workers] {p.depth=max(p.depth,zone.depth)}
	used:[256]bool
	for zone in c.zones[p.workers:] {
		if zone.depth==0 && zone.thread>0 && zone.thread<len(used) {used[zone.thread]=true}
	}
	for thread in 1..<len(used) {
		if used[thread] && p.thread_count<len(p.threads) {
			p.threads[p.thread_count]=u8(thread)
			p.thread_count+=1
		}
	}
	aggregates:=editor.profile_aggregate(c)
	for a in aggregates {
		if editor.profile_is_part(c.names[a.name]) {continue}
		total:f64
		for ms in a.total {total+=ms}
		entry:=Top_Zone{name=a.name,worker=a.worker,ms=total/f64(max(len(c.frames),1)),calls=f64(a.calls)/f64(max(len(c.frames),1))}
		at:=p.top_count
		for at>0 && p.top[at-1].ms<entry.ms {
			if at<TOP_ZONES {p.top[at]=p.top[at-1]}
			at-=1
		}
		if at<TOP_ZONES {
			p.top[at]=entry
			p.top_count=min(p.top_count+1,TOP_ZONES)
		}
	}
}

@(private="file")
profiler_summary :: proc(p:^Profiler_Panel,c:^editor.Profile_Capture) -> string {
	frame:=make([]f64,len(c.frames),context.temp_allocator)
	for f,i in c.frames {frame[i]=editor.profile_frame_ms(f)}
	spread,gpu_spread:=editor.profile_spread(frame),editor.profile_spread(editor.profile_gpu_ms(c))
	return fmt.tprintf("Capture %d  ·  %d frames  ·  frame %.2f ms mean, %.2f ms p95  ·  GPU %.2f ms  ·  %s %s",
		c.id,len(c.frames),spread.mean,spread.p95,gpu_spread.mean,c.conditions.backend,c.conditions.device)
}

@(private="file")
profiler_frame_text :: proc(p:^Profiler_Panel,c:^editor.Profile_Capture) -> string {
	if p.frame>=len(c.frames) {return ""}
	f:=c.frames[p.frame]
	bounds:=[editor.Profile_Bound]string{.Cpu="CPU",.Gpu="GPU",.Paced="pacing"}
	return fmt.tprintf("Frame %d  ·  %.2f ms  ·  CPU %.2f ms  ·  waits for %s",
		p.frame+1,editor.profile_frame_ms(f),editor.profile_frame_cpu_ms(f),bounds[editor.profile_frame_bound(f)])
}

@(private="file")
gpu_frame_text :: proc(p:^Profiler_Panel,c:^editor.Profile_Capture) -> string {
	if p.frame>=len(c.frames) {return ""}
	f:=c.frames[p.frame]
	if !f.gpu_measured {return fmt.tprintf("Frame %d  ·  GPU not measured: a submission of the frame did not come back",p.frame+1)}
	return fmt.tprintf("Frame %d  ·  GPU %.2f ms  ·  %d passes",p.frame+1,f.gpu_ms,f.pass_count)
}

@(private="file")
memory_frame_text :: proc(p:^Profiler_Panel,c:^editor.Profile_Capture) -> string {
	if p.frame>=len(c.frames) {return ""}
	m:=c.frames[p.frame].memory
	return fmt.tprintf("Frame %d  ·  World %.1f MB  ·  process private %.1f MB, resident %.1f MB  ·  GPU %.1f MB",
		p.frame+1,mb(m.world),mb(i64(m.process.private)),mb(i64(m.process.resident)),mb(i64(m.gpu)))
}

@(private="file")
mb :: proc(bytes:i64) -> f64 {return f64(bytes)/(1<<20)}

// A color of its own for each name, among muted hues.
@(private="file")
zone_color :: proc(name:string) -> ui.Color {
	return ui.rgb_color(mm.hsv_to_rgb({f32(hash.fnv32a(transmute([]u8)name)%360)/360,0.45,0.78}))
}

// One bar per frame: the frame's time, colored by what it waited for, with
// the GPU time over it as a line; a frame above the top of the graph is cut
// and capped with a mark, and the frame chosen is outlined.
@(private="file")
frames_draw :: proc(ctx:^ui.Context,rect:ui.Rect,user:rawptr) {
	p:=(^Profiler_Panel)(user)
	c:=p.capture
	ui.draw_rounded(ctx,rect,ui.metric(ctx,"radius_control"),ui.tone(ctx,"field"))
	if c==nil || len(c.frames)==0 {return}
	top:=p.graph_ms
	step:=rect.w/f32(len(c.frames))
	for f,i in c.frames {
		ms:=editor.profile_frame_ms(f)
		h:=f32(min(ms/top,1))*(rect.h-4)
		color:=ui.tone(ctx,"accent")
		switch editor.profile_frame_bound(f) {
		case .Gpu:   color=ui.Color{214,150,74,255}
		case .Paced: color=ui.tone(ctx,"text_faint")
		case .Cpu:
		}
		x:=rect.x+f32(i)*step
		ui.draw_rect(ctx,{x+step*0.12,rect.y+rect.h-2-h,max(step*0.76,1),h},color)
		if ms>top {ui.draw_rect(ctx,{x,rect.y+2,step,3},ui.tone(ctx,"danger"))}
		if !f.gpu_measured {continue}
		gpu:=f32(min(f64(f.gpu_ms)/top,1))*(rect.h-4)
		ui.draw_rect(ctx,{x,rect.y+rect.h-2-gpu,step,1.5},ui.tone(ctx,"text"))
	}
	if p.frame<len(c.frames) {
		ui.draw_rect_lines(ctx,{rect.x+f32(p.frame)*step,rect.y+1,max(step,2),rect.h-2},1,ui.tone(ctx,"text"))
	}
	text:=fmt.tprintf("%.1f ms",top)
	ui.draw_text(ctx,text,rect.x+rect.w-ui.text_width(&ctx.font,text,ui.metric(ctx,"font_small"))-6,rect.y+6,ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))
}

// The frame chosen on one time axis, that of its CPU frame and what ran
// after it: in the CPU tab the zones of the main thread by depth and those
// of the other threads; in the GPU tab its passes where they ran.
@(private="file")
timeline_draw :: proc(ctx:^ui.Context,rect:ui.Rect,user:rawptr) {
	p:=(^Profiler_Panel)(user)
	c:=p.capture
	if c==nil || p.frame>=len(c.frames) {return}
	f:=c.frames[p.frame]
	passes:=c.passes[f.pass_first:][:f.pass_count]
	span:=max(f.ns+f.between_ns,1)
	for pass in passes {span=max(span,pass.start_ns+pass.ns-f.start_ns)}
	label:=f32(64)
	x0:=rect.x+label
	w:=rect.w-label
	scale:=w/f32(span)
	ui.draw_rounded(ctx,{x0,rect.y,w,rect.h},ui.metric(ctx,"radius_control"),ui.tone(ctx,"field"))
	bar :: proc(ctx:^ui.Context,x,y,w:f32,name:string,ms:f64) {
		r:=ui.Rect{x,y,max(w,1),ROW}
		ui.draw_rect(ctx,r,zone_color(name))
		text:=w>90?fmt.tprintf("%s %.2f",name,ms):name
		if ui.text_width(&ctx.font,text,ui.metric(ctx,"font_small"))+6<w {ui.draw_text(ctx,text,x+3,y+2,ui.metric(ctx,"font_small"),ui.Color{20,22,26,255})}
	}
	row_y:=rect.y+2
	if Tab(p.tab)==.Gpu {
		ui.draw_text(ctx,"GPU",rect.x,row_y+2,ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))
		for pass in passes {
			bar(ctx,x0+f32(max(pass.start_ns-f.start_ns,0))*scale,row_y,f32(pass.ns)*scale,c.pass_names[pass.name],f64(pass.ns)/1e6)
		}
		if !f.gpu_measured {ui.draw_text(ctx,"not measured",x0+4,row_y+2,ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))}
		ruler(ctx,rect,x0,w,row_y+ROW+4,span)
		return
	}
	ui.draw_text(ctx,"main",rect.x,row_y+2,ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))
	for zone in c.zones[f.zone_first:][:f.zone_count] {
		y:=row_y+f32(zone.depth-1)*(ROW+2)
		bar(ctx,x0+f32(zone.start_ns-f.start_ns)*scale,y,f32(zone.ns)*scale,c.names[zone.name],f64(zone.ns)/1e6)
	}
	row_y+=f32(p.depth)*(ROW+2)
	for thread in p.threads[:p.thread_count] {
		ui.draw_text(ctx,fmt.tprintf("worker %d",thread),rect.x,row_y+2,ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))
		for zone in c.zones[p.workers:] {
			if zone.frame!=p.frame || zone.thread!=int(thread) || zone.depth!=0 {continue}
			bar(ctx,x0+f32(zone.start_ns-f.start_ns)*scale,row_y,f32(zone.ns)*scale,c.names[zone.name],f64(zone.ns)/1e6)
		}
		row_y+=ROW+2
	}
	ruler(ctx,rect,x0,w,row_y+2,span)
}

@(private="file")
ruler :: proc(ctx:^ui.Context,rect:ui.Rect,x0,w,y:f32,span:i64) {
	for i in 0..=4 {
		x:=x0+w*f32(i)/4
		ui.draw_rect(ctx,{x,rect.y,1,y-rect.y},ui.color_alpha(ui.tone(ctx,"text_faint"),60))
		ui.draw_text(ctx,fmt.tprintf("%.1f ms",f64(span)*f64(i)/4/1e6),min(x+3,rect.x+rect.w-48),y,ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))
	}
}

// The passes that took most per measured frame over the capture.
@(private="file")
passes_draw :: proc(ctx:^ui.Context,rect:ui.Rect,user:rawptr) {
	p:=(^Profiler_Panel)(user)
	c:=p.capture
	if c==nil || p.pass_count==0 {return}
	small:=ui.metric(ctx,"font_small")
	ui.draw_text(ctx,"Pass",rect.x,rect.y,small,ui.tone(ctx,"text_muted"))
	ui.draw_text(ctx,"ms / frame",rect.x+rect.w*0.55,rect.y,small,ui.tone(ctx,"text_muted"))
	most:=max(p.passes[0].ms,0.001)
	for top,i in p.passes[:p.pass_count] {
		y:=rect.y+ROW*f32(i+1)
		name:=c.pass_names[top.name]
		ui.draw_rect(ctx,{rect.x,y+3,rect.w*0.5*f32(top.ms/most),ROW-6},ui.color_alpha(zone_color(name),110))
		ui.draw_text(ctx,name,rect.x+4,y+1,small,ui.tone(ctx,"text"))
		ui.draw_text(ctx,fmt.tprintf("%.3f",top.ms),rect.x+rect.w*0.55,y+1,small,ui.tone(ctx,"text"))
	}
}

// The memory at the end of each frame, a band each for the World, the
// private memory of the process and the GPU, each from its lowest to its
// highest in the capture; the frame chosen is marked.
@(private="file")
memory_draw :: proc(ctx:^ui.Context,rect:ui.Rect,user:rawptr) {
	p:=(^Profiler_Panel)(user)
	c:=p.capture
	ui.draw_rounded(ctx,rect,ui.metric(ctx,"radius_control"),ui.tone(ctx,"field"))
	if c==nil || len(c.frames)==0 {return}
	small:=ui.metric(ctx,"font_small")
	names:=[3]string{"World","Private","GPU"}
	texts:[3]string
	label:f32
	for name,k in names {
		texts[k]=fmt.tprintf("%s %.1f-%.1f MB",name,p.memory_range[k][0],p.memory_range[k][1])
		label=max(label,ui.text_width(&ctx.font,texts[k],small)+12)
	}
	x0,w:=rect.x+label,rect.w-label
	band:=rect.h/3
	step:=w/f32(len(c.frames))
	for text,k in texts {
		top:=rect.y+band*f32(k)
		low,high:=p.memory_range[k][0],p.memory_range[k][1]
		ui.draw_text(ctx,text,rect.x+6,top+band/2-small/2,small,ui.tone(ctx,"text_muted"))
		if k>0 {ui.draw_rect(ctx,{rect.x,top,rect.w,1},ui.color_alpha(ui.tone(ctx,"text_faint"),60))}
		for f,i in c.frames {
			at:=0.5 if high<=low else (memory_values(f)[k]-low)/(high-low)
			y:=top+band-4-f32(at)*(band-8)
			ui.draw_rect(ctx,{x0+f32(i)*step,y,max(step,1),1.5},ui.tone(ctx,"accent"))
		}
	}
	ui.draw_rect(ctx,{x0+f32(p.frame)*step,rect.y,1,rect.h},ui.color_alpha(ui.tone(ctx,"text_faint"),120))
}

@(private="file")
memory_values :: proc(f:editor.Profile_Frame_Record) -> [3]f64 {
	return {mb(f.memory.world),mb(i64(f.memory.process.private)),mb(i64(f.memory.gpu))}
}

// The zones that took most per frame over the capture, the parts of the frame left out.
@(private="file")
zones_draw :: proc(ctx:^ui.Context,rect:ui.Rect,user:rawptr) {
	p:=(^Profiler_Panel)(user)
	c:=p.capture
	if c==nil || p.top_count==0 {return}
	ui.draw_text(ctx,"Zone",rect.x,rect.y,ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))
	ui.draw_text(ctx,"ms / frame",rect.x+rect.w*0.55,rect.y,ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))
	ui.draw_text(ctx,"calls / frame",rect.x+rect.w*0.78,rect.y,ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))
	most:=max(p.top[0].ms,0.001)
	for top,i in p.top[:p.top_count] {
		y:=rect.y+ROW*f32(i+1)
		name:=c.names[top.name]
		ui.draw_rect(ctx,{rect.x,y+3,rect.w*0.5*f32(top.ms/most),ROW-6},ui.color_alpha(zone_color(name),110))
		ui.draw_text(ctx,top.worker?fmt.tprintf("%s (worker)",name):name,rect.x+4,y+1,ui.metric(ctx,"font_small"),ui.tone(ctx,"text"))
		ui.draw_text(ctx,fmt.tprintf("%.3f",top.ms),rect.x+rect.w*0.55,y+1,ui.metric(ctx,"font_small"),ui.tone(ctx,"text"))
		ui.draw_text(ctx,fmt.tprintf("%.1f",top.calls),rect.x+rect.w*0.78,y+1,ui.metric(ctx,"font_small"),ui.tone(ctx,"text"))
	}
}
