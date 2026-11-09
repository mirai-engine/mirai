package profiler_editor

import "core:fmt"
import "core:hash"
import "core:math"
import "mirai:editor"
import "mirai:host"
import "mirai:ui"

// A panel of the editor, under View > Profiler, that records frames into the
// captures of the profile.* methods and shows the last one: the time of each
// frame, then a tab per track: the zones of the threads of the frame chosen
// and those that took most (CPU); its GPU passes where they ran and the passes
// that took most (GPU); what the process and the GPU held frame by frame
// (Memory). An agent and the panel see the same captures.

PANEL_SCOPE :: ui.Id(0x70726f66)
TOP_ZONES :: 8
FRAMES_DEFAULT :: 120
ROW :: f32(16)     // of a row of the timeline, in points
GRAPH :: f32(72)   // height of the graph of the frames
TABS :: [?]string{"CPU","GPU","Memory"}
GPU_COLOR :: ui.Color{214,150,74,255} // what the GPU took or holds, and frames that waited for it
BAR_TEXT :: ui.Color{20,22,26,255}    // over the colors of the bars

Tab :: enum int {Cpu,Gpu,Memory}

Top_Zone :: struct {
	name:   int, // into the names of the capture
	worker: bool,
	ms:     f64, // per frame, of the frames it was in
	calls:  f64, // per frame
}

Top_Pass :: struct {
	name: int, // into the pass names of the capture
	ms:   f64, // mean per frame whose GPU times came back
}

@(storage)
Profiler_Panel :: struct {
	open:    bool,
	tab:     int,
	frames:  f64, // frames a recording takes
	shown:   int, // id of the capture the panel shows; 0: none
	frame:   int, // of that capture, the one the tabs show
	workers: int, // first zone of the other threads in the capture
	depth:   int, // rows of the main thread
	threads: [64]u8, // the other threads that ran jobs in the capture
	thread_count: int,
	graph_ms: f64, // the top of the graph: above it a frame is cut and marked
	top:     [TOP_ZONES]Top_Zone,
	top_count: int,
	passes:  [TOP_ZONES]Top_Pass,
	pass_count: int,
	memory_mb: f64, // the top of the memory graph
	error:   [128]u8,
	error_length: int,
	capture: ^editor.Profile_Capture, // the one shown, for the drawings of this frame
}

@(step="ui",after="editor_panels")
profiler_panel :: proc(s:^editor.Session,p:^Profiler_Panel,app:^host.App) {
	g:=s.gui
	if !g.begun {return}
	ctx:=g.ctx
	if editor.view_toggle(g,ui.id_derive(ctx,PANEL_SCOPE,"view"),"Profiler",p.open) {p.open=!p.open}
	if !p.open || s.viewport.pick.active {return}
	if p.frames<=0 {p.frames=FRAMES_DEFAULT}
	editor.profile_collect(s)
	p.capture=editor.profile_find(s,0)
	if p.capture!=nil && p.capture.id!=p.shown {profiler_show(p,p.capture)}
	if p.capture==nil {p.shown=0}

	th:=&ctx.theme
	id:=ui.id_derive(ctx,PANEL_SCOPE,"panel")
	width:=clamp(ctx.size.x*0.62,520,1120)
	bottom:=th.margin
	if r:=g.rects.bottom;r.h>0 {bottom+=ctx.size.y-r.y}
	if ui.panel(ctx,id,{width=ui.fixed(width),height=ui.FIT,padding=ui.padding_all(12),gap=8,anchor=.Bottom_Center,pivot=.Bottom_Center,offset={0,-bottom}}) {
		ui.id_push(ctx,id)
		defer ui.id_pop(ctx)
		profiler_header(s,p,app)
		if p.capture==nil {return}
		c:=p.capture
		ui.label(ctx,profiler_summary(c),th.font_small,th.text_muted)
		graph:=editor.drawing(g,ui.id(ctx,"frames"),ui.GROW,ui.fixed(GRAPH),frames_draw,p)
		if graph.pressed || graph.active {
			if r,found:=ui.widget_rect(ctx,ui.id(ctx,"frames"));found && len(c.frames)>0 {
				p.frame=clamp(int((ctx.pointer.x-r.x)/r.w*f32(len(c.frames))),0,len(c.frames)-1)
			}
		}
		titles:=TABS
		ui.tabs(ctx,ui.id(ctx,"tracks"),titles[:],&p.tab,ui.fixed(240),28)
		switch Tab(p.tab) {
		case .Cpu:
			ui.label(ctx,cpu_frame_text(p,c),th.font_small,th.text)
			rows:=f32(p.depth+p.thread_count)
			editor.drawing(g,ui.id(ctx,"timeline"),ui.GROW,ui.fixed(rows*(ROW+2)+ROW),timeline_draw,p)
			editor.drawing(g,ui.id(ctx,"zones"),ui.GROW,ui.fixed(f32(p.top_count)*ROW+ROW),zones_draw,p)
		case .Gpu:
			if .Gpu not_in c.tracks {ui.label(ctx,"This capture did not record the GPU track",th.font_small,th.text_muted);break}
			ui.label(ctx,gpu_frame_text(p,c),th.font_small,th.text)
			editor.drawing(g,ui.id(ctx,"gpu_timeline"),ui.GROW,ui.fixed(ROW+ROW+4),gpu_timeline_draw,p)
			editor.drawing(g,ui.id(ctx,"passes"),ui.GROW,ui.fixed(f32(p.pass_count)*ROW+ROW),passes_draw,p)
		case .Memory:
			if .Memory not_in c.tracks || len(c.memory)==0 {ui.label(ctx,"This capture did not record the memory track",th.font_small,th.text_muted);break}
			ui.label(ctx,memory_frame_text(p,c),th.font_small,th.text)
			editor.drawing(g,ui.id(ctx,"memory"),ui.GROW,ui.fixed(GRAPH+ROW),memory_draw,p)
			ui.label(ctx,memory_capture_text(c),th.font_small,th.text_muted)
		}
	}
}

@(private="file")
profiler_header :: proc(s:^editor.Session,p:^Profiler_Panel,app:^host.App) {
	ctx:=s.gui.ctx
	th:=&ctx.theme
	if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.row),gap=8,align_y=.Center}) {
		ui.label(ctx,"Profiler",th.font,th.text,font=ui.FONT_SEMIBOLD)
		ui.spacer(ctx)
		recording:=s.profiles.recording!=0
		if recording {
			ui.label(ctx,fmt.tprintf("Recording %d/%d",len(host.profile_recording(app).frames),int(p.frames)),th.font_small,th.accent)
		} else if p.error_length>0 {
			ui.label(ctx,string(p.error[:p.error_length]),th.font_small,th.danger)
		}
		ui.number_field(ctx,ui.id(ctx,"frames_asked"),&p.frames,{width=ui.fixed(72),decimals=0,speed=1,has_min=true,min=2,has_max=true,max=f64(host.PROFILE_FRAMES_MAX),disabled=recording})
		if ui.button(ctx,ui.id(ctx,"record"),{label="Record",style=.Accent,size=th.font_small,disabled=recording}).clicked {
			p.error_length=0
			if _,error:=editor.profile_begin(s,int(p.frames),"profiler panel");error!="" {p.error_length=copy(p.error[:],error)}
		}
	}
}

// What the panel keeps of a capture when it starts showing it: where the
// other threads begin, the rows of the timeline, the tops of the graphs, the
// zones and the passes that took most, and the frame nearest the median as
// the one chosen.
@(private="file")
profiler_show :: proc(p:^Profiler_Panel,c:^editor.Profile_Capture) {
	p.shown,p.frame,p.workers,p.depth,p.thread_count,p.top_count,p.pass_count=c.id,0,0,1,0,0,0
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
	for zone in c.cpu.zones[:p.workers] {p.depth=max(p.depth,zone.depth)}
	used:[256]bool
	for zone in c.cpu.zones[p.workers:] {
		if zone.depth==0 && zone.thread>0 && zone.thread<len(used) {used[zone.thread]=true}
	}
	for thread in 1..<len(used) {
		if used[thread] && p.thread_count<len(p.threads) {
			p.threads[p.thread_count]=u8(thread)
			p.thread_count+=1
		}
	}
	for a in editor.profile_aggregate(c) {
		if editor.profile_is_part(c.cpu.names[a.name]) {continue}
		total:f64
		for ms in a.total {total+=ms}
		insert(p.top[:],&p.top_count,Top_Zone{name=a.name,worker=a.worker,ms=total/f64(max(len(c.frames),1)),calls=f64(a.calls)/f64(max(len(c.frames),1))})
	}
	for values,name in editor.profile_passes_by_name(c) {
		insert(p.passes[:],&p.pass_count,Top_Pass{name=name,ms=editor.profile_spread(values).mean})
	}
	p.memory_mb=0
	for m in c.memory {
		for counter in editor.Profile_Memory_Counter {
			p.memory_mb=max(p.memory_mb,f64(editor.profile_memory_value(m,counter))/(1<<20))
		}
	}
	p.memory_mb=max(p.memory_mb*1.1,1)
}

// Keeps the largest by ms, largest first.
@(private="file")
insert :: proc(list:[]$T,count:^int,entry:T) {
	at:=count^
	for at>0 && list[at-1].ms<entry.ms {
		if at<len(list) {list[at]=list[at-1]}
		at-=1
	}
	if at<len(list) {
		list[at]=entry
		count^=min(count^+1,len(list))
	}
}

@(private="file")
profiler_summary :: proc(c:^editor.Profile_Capture) -> string {
	frame:=make([]f64,len(c.frames),context.temp_allocator)
	for f,i in c.frames {frame[i]=editor.profile_frame_ms(f)}
	spread:=editor.profile_spread(frame)
	gpu:="no GPU track"
	if .Gpu in c.tracks {gpu=fmt.tprintf("GPU %.2f ms",editor.profile_spread(editor.profile_gpu_ms(c)).mean)}
	return fmt.tprintf("Capture %d  ·  %d frames  ·  frame %.2f ms mean, %.2f ms p95  ·  %s  ·  %s %s",
		c.id,len(c.frames),spread.mean,spread.p95,gpu,c.conditions.backend,c.conditions.device)
}

@(private="file")
cpu_frame_text :: proc(p:^Profiler_Panel,c:^editor.Profile_Capture) -> string {
	if p.frame>=len(c.frames) {return ""}
	f:=c.frames[p.frame]
	bounds:=[editor.Profile_Bound]string{.Cpu="CPU",.Gpu="GPU",.Paced="pacing"}
	return fmt.tprintf("Frame %d  ·  %.2f ms  ·  CPU %.2f ms  ·  wait %.2f ms  ·  workers %.2f ms in %d jobs  ·  waits for %s",
		p.frame+1,editor.profile_frame_ms(f),editor.profile_frame_cpu_ms(f),f.wait_ms,f64(f.worker_ns)/1e6,f.jobs,bounds[editor.profile_frame_bound(f)])
}

@(private="file")
gpu_frame_text :: proc(p:^Profiler_Panel,c:^editor.Profile_Capture) -> string {
	if p.frame>=len(c.gpu.frames) {return ""}
	g:=c.gpu.frames[p.frame]
	if !g.measured {return fmt.tprintf("Frame %d  ·  its GPU times did not come back",p.frame+1)}
	return fmt.tprintf("Frame %d  ·  GPU %.2f ms in %d passes",p.frame+1,g.ms,g.pass_count)
}

@(private="file")
memory_frame_text :: proc(p:^Profiler_Panel,c:^editor.Profile_Capture) -> string {
	if p.frame>=len(c.memory) {return ""}
	m:=c.memory[p.frame]
	mb :: proc(bytes:u64) -> f64 {return f64(bytes)/(1<<20)}
	return fmt.tprintf("Frame %d  ·  private %.1f MB  ·  resident %.1f MB  ·  GPU %.1f of %.1f MB  ·  textures %.1f MB  ·  geometry %.1f MB",
		p.frame+1,mb(m.process.private),mb(m.process.resident),mb(m.gpu_used),mb(m.gpu_budget),mb(m.textures),mb(m.geometry))
}

@(private="file")
memory_capture_text :: proc(c:^editor.Profile_Capture) -> string {
	private:=editor.profile_memory_series(c,.Process_Private)
	gpu:=editor.profile_memory_series(c,.Gpu_Used)
	return fmt.tprintf("Over the capture: private %+.2f MB, up in %d frames  ·  GPU %+.2f MB",
		(f64(private.last)-f64(private.first))/(1<<20),private.rises,(f64(gpu.last)-f64(gpu.first))/(1<<20))
}

// A color of its own for each name, among muted hues.
@(private="file")
zone_color :: proc(name:string) -> ui.Color {
	h:=f32(hash.fnv32a(transmute([]u8)name)%360)
	return hsv(h,0.45,0.78)
}

@(private="file")
hsv :: proc(h,s,v:f32) -> ui.Color {
	c:=v*s
	x:=c*(1-abs(math.mod(h/60,2)-1))
	r,g,b:f32
	switch {
	case h<60:  r,g,b=c,x,0
	case h<120: r,g,b=x,c,0
	case h<180: r,g,b=0,c,x
	case h<240: r,g,b=0,x,c
	case h<300: r,g,b=x,0,c
	case:       r,g,b=c,0,x
	}
	m:=v-c
	return {u8((r+m)*255),u8((g+m)*255),u8((b+m)*255),255}
}

@(private="file")
bar :: proc(ctx:^ui.Context,x,y,w:f32,name:string,ms:f64) {
	th:=&ctx.theme
	r:=ui.Rect{x,y,max(w,1),ROW}
	ui.draw_rect(ctx,r,zone_color(name))
	text:=w>90?fmt.tprintf("%s %.2f",name,ms):name
	if ui.text_width(&ctx.font,text,th.font_small)+6<w {ui.draw_text(ctx,text,x+3,y+2,th.font_small,BAR_TEXT)}
}

// Four marks of time under a timeline, from 0 to span.
@(private="file")
ruler :: proc(ctx:^ui.Context,rect:ui.Rect,x0,w,y:f32,span:i64) {
	th:=&ctx.theme
	for i in 0..=4 {
		x:=x0+w*f32(i)/4
		ui.draw_rect(ctx,{x,rect.y,1,y-rect.y},ui.color_alpha(th.text_faint,60))
		ui.draw_text(ctx,fmt.tprintf("%.1f ms",f64(span)*f64(i)/4/1e6),min(x+3,rect.x+rect.w-48),y,th.font_small,th.text_muted)
	}
}

// One bar per frame: the frame's time, colored by what it waited for, with
// the GPU time over it as a line when it came back; a frame above the top of
// the graph is cut and capped with a mark, and the frame chosen is outlined.
@(private="file")
frames_draw :: proc(ctx:^ui.Context,rect:ui.Rect,user:rawptr) {
	p:=(^Profiler_Panel)(user)
	c:=p.capture
	th:=&ctx.theme
	ui.draw_rounded(ctx,rect,th.radius_control,th.field)
	if c==nil || len(c.frames)==0 {return}
	top:=p.graph_ms
	step:=rect.w/f32(len(c.frames))
	for f,i in c.frames {
		ms:=editor.profile_frame_ms(f)
		h:=f32(min(ms/top,1))*(rect.h-4)
		color:=th.accent
		switch editor.profile_frame_bound(f) {
		case .Gpu:   color=GPU_COLOR
		case .Paced: color=th.text_faint
		case .Cpu:
		}
		x:=rect.x+f32(i)*step
		ui.draw_rect(ctx,{x+step*0.12,rect.y+rect.h-2-h,max(step*0.76,1),h},color)
		if ms>top {ui.draw_rect(ctx,{x,rect.y+2,step,3},th.danger)}
		if i<len(c.gpu.frames) && c.gpu.frames[i].measured {
			gpu:=f32(min(f64(c.gpu.frames[i].ms)/top,1))*(rect.h-4)
			ui.draw_rect(ctx,{x,rect.y+rect.h-2-gpu,step,1.5},th.text)
		}
	}
	if p.frame<len(c.frames) {
		ui.draw_rect_lines(ctx,{rect.x+f32(p.frame)*step,rect.y+1,max(step,2),rect.h-2},1,th.text)
	}
	text:=fmt.tprintf("%.1f ms",top)
	ui.draw_text(ctx,text,rect.x+rect.w-ui.text_width(&ctx.font,text,th.font_small)-6,rect.y+6,th.font_small,th.text_muted)
}

// The frame chosen on the CPU: the zones of the main thread by depth and the
// jobs of the other threads, on one time axis from the start of the frame.
@(private="file")
timeline_draw :: proc(ctx:^ui.Context,rect:ui.Rect,user:rawptr) {
	p:=(^Profiler_Panel)(user)
	c:=p.capture
	th:=&ctx.theme
	if c==nil || p.frame>=len(c.frames) {return}
	f:=c.frames[p.frame]
	span:=max(f.ns+f.between_ns,1)
	label:=f32(64)
	x0:=rect.x+label
	w:=rect.w-label
	scale:=w/f32(span)
	ui.draw_rounded(ctx,{x0,rect.y,w,rect.h},th.radius_control,th.field)
	row_y:=rect.y+2
	ui.draw_text(ctx,"main",rect.x,row_y+2,th.font_small,th.text_muted)
	for zone in c.cpu.zones[f.zone_first:][:f.zone_count] {
		y:=row_y+f32(zone.depth-1)*(ROW+2)
		bar(ctx,x0+f32(zone.start_ns-f.start_ns)*scale,y,f32(zone.ns)*scale,c.cpu.names[zone.name],f64(zone.ns)/1e6)
	}
	row_y+=f32(p.depth)*(ROW+2)
	for thread in p.threads[:p.thread_count] {
		ui.draw_text(ctx,fmt.tprintf("worker %d",thread),rect.x,row_y+2,th.font_small,th.text_muted)
		for zone in c.cpu.zones[p.workers:] {
			if zone.frame!=p.frame || zone.thread!=int(thread) || zone.depth!=0 {continue}
			bar(ctx,x0+f32(zone.start_ns-f.start_ns)*scale,row_y,f32(zone.ns)*scale,c.cpu.names[zone.name],f64(zone.ns)/1e6)
		}
		row_y+=ROW+2
	}
	ruler(ctx,rect,x0,w,row_y+2,span)
}

// The GPU passes of what the frame chosen submitted, where they ran, from the
// start of the first one.
@(private="file")
gpu_timeline_draw :: proc(ctx:^ui.Context,rect:ui.Rect,user:rawptr) {
	p:=(^Profiler_Panel)(user)
	c:=p.capture
	th:=&ctx.theme
	if c==nil || p.frame>=len(c.gpu.frames) {return}
	g:=c.gpu.frames[p.frame]
	passes:=c.gpu.passes[g.pass_first:][:g.pass_count]
	label:=f32(64)
	x0:=rect.x+label
	w:=rect.w-label
	ui.draw_rounded(ctx,{x0,rect.y,w,ROW+4},th.radius_control,th.field)
	ui.draw_text(ctx,"GPU",rect.x,rect.y+4,th.font_small,th.text_muted)
	if len(passes)==0 {return}
	first,last:=passes[0].start_ns,passes[0].start_ns+passes[0].ns
	for pass in passes {first,last=min(first,pass.start_ns),max(last,pass.start_ns+pass.ns)}
	span:=max(last-first,1)
	scale:=w/f32(span)
	for pass in passes {
		bar(ctx,x0+f32(pass.start_ns-first)*scale,rect.y+2,f32(pass.ns)*scale,c.gpu.pass_names[pass.name],f64(pass.ns)/1e6)
	}
	ruler(ctx,rect,x0,w,rect.y+ROW+4,span)
}

// The process private and resident memory and the GPU memory, one point per
// frame, with the frame chosen marked.
@(private="file")
memory_draw :: proc(ctx:^ui.Context,rect:ui.Rect,user:rawptr) {
	p:=(^Profiler_Panel)(user)
	c:=p.capture
	th:=&ctx.theme
	graph:=ui.Rect{rect.x,rect.y,rect.w,rect.h-ROW}
	ui.draw_rounded(ctx,graph,th.radius_control,th.field)
	if c==nil || len(c.memory)==0 {return}
	Line :: struct {counter:editor.Profile_Memory_Counter,name:string,color:ui.Color}
	lines:=[3]Line{{.Process_Private,"private",th.accent},{.Process_Resident,"resident",th.text_muted},{.Gpu_Used,"GPU",GPU_COLOR}}
	step:=graph.w/f32(len(c.memory))
	for line in lines {
		for m,i in c.memory {
			mb:=f64(editor.profile_memory_value(m,line.counter))/(1<<20)
			y:=graph.y+graph.h-2-f32(min(mb/p.memory_mb,1))*(graph.h-4)
			ui.draw_rect(ctx,{graph.x+f32(i)*step,y,max(step,1),1.5},line.color)
		}
	}
	if p.frame<len(c.memory) {
		ui.draw_rect(ctx,{graph.x+f32(p.frame)*step,graph.y+1,1,graph.h-2},th.text)
	}
	text:=fmt.tprintf("%.0f MB",p.memory_mb)
	ui.draw_text(ctx,text,graph.x+graph.w-ui.text_width(&ctx.font,text,th.font_small)-6,graph.y+6,th.font_small,th.text_muted)
	x:=rect.x
	for line in lines {
		ui.draw_rect(ctx,{x,rect.y+rect.h-ROW+6,10,3},line.color)
		ui.draw_text(ctx,line.name,x+14,rect.y+rect.h-ROW+1,th.font_small,th.text_muted)
		x+=ui.text_width(&ctx.font,line.name,th.font_small)+30
	}
}

// The zones that took most per frame over the capture, the parts of the frame left out.
@(private="file")
zones_draw :: proc(ctx:^ui.Context,rect:ui.Rect,user:rawptr) {
	p:=(^Profiler_Panel)(user)
	c:=p.capture
	th:=&ctx.theme
	if c==nil || p.top_count==0 {return}
	ui.draw_text(ctx,"Zone",rect.x,rect.y,th.font_small,th.text_muted)
	ui.draw_text(ctx,"ms / frame",rect.x+rect.w*0.55,rect.y,th.font_small,th.text_muted)
	ui.draw_text(ctx,"calls / frame",rect.x+rect.w*0.78,rect.y,th.font_small,th.text_muted)
	most:=max(p.top[0].ms,0.001)
	for top,i in p.top[:p.top_count] {
		y:=rect.y+ROW*f32(i+1)
		name:=c.cpu.names[top.name]
		ui.draw_rect(ctx,{rect.x,y+3,rect.w*0.5*f32(top.ms/most),ROW-6},ui.color_alpha(zone_color(name),110))
		ui.draw_text(ctx,top.worker?fmt.tprintf("%s (worker)",name):name,rect.x+4,y+1,th.font_small,th.text)
		ui.draw_text(ctx,fmt.tprintf("%.3f",top.ms),rect.x+rect.w*0.55,y+1,th.font_small,th.text)
		ui.draw_text(ctx,fmt.tprintf("%.1f",top.calls),rect.x+rect.w*0.78,y+1,th.font_small,th.text)
	}
}

// The GPU passes that took most per frame whose GPU times came back.
@(private="file")
passes_draw :: proc(ctx:^ui.Context,rect:ui.Rect,user:rawptr) {
	p:=(^Profiler_Panel)(user)
	c:=p.capture
	th:=&ctx.theme
	if c==nil || p.pass_count==0 {return}
	ui.draw_text(ctx,"Pass",rect.x,rect.y,th.font_small,th.text_muted)
	ui.draw_text(ctx,"ms / frame",rect.x+rect.w*0.55,rect.y,th.font_small,th.text_muted)
	most:=max(p.passes[0].ms,0.001)
	for pass,i in p.passes[:p.pass_count] {
		y:=rect.y+ROW*f32(i+1)
		name:=c.gpu.pass_names[pass.name]
		ui.draw_rect(ctx,{rect.x,y+3,rect.w*0.5*f32(pass.ms/most),ROW-6},ui.color_alpha(zone_color(name),110))
		ui.draw_text(ctx,name,rect.x+4,y+1,th.font_small,th.text)
		ui.draw_text(ctx,fmt.tprintf("%.3f",pass.ms),rect.x+rect.w*0.55,y+1,th.font_small,th.text)
	}
}
