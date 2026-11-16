package tracy

import "base:runtime"
import "core:log"
import "core:os"
import "core:slice"
import "core:strconv"
import "mirai:host"
import "mirai:std/base"
import erender "mirai:engine/render"

// The application as the Tracy profiler sees it: frame marks, the zones of
// every thread that host records (the parts of the frame, the functions of
// the loops, the jobs) and the GPU time of each pass. Off unless MIRAI_TRACY
// is set: MIRAI_TRACY=1 listens on MIRAI_TRACY_PORT (8086 and the next free
// ones) of the loopback interface, of every interface with MIRAI_TRACY_ANY=1,
// under the name MIRAI_TRACY_NAME. Zones are recorded only while a profiler
// is connected.

TRACY_PENDING :: 2 * host.PROFILE_RING // zones of a thread waiting for the outermost one around them to end

@(storage,host,free="tracy_free")
Tracy :: struct {
	started:  bool, // MIRAI_TRACY was read
	on:       bool,
	allocator: runtime.Allocator,
	profiler: Profiler,
	gpu:      Gpu_Context,
	frame:    u64, // host.App_Stats.frames of the last frame sent
	gpu_end:  i64, // end of the last GPU interval sent
	session:  u32, // of the client, when the rings were read last
	threads:  []Tracy_Thread,
	read:     []base.Profile_Zone, // what one read of a ring brings
	events:   []Zone_Event,
}

Tracy_Thread :: struct {
	cursor:  u64,
	pending: []base.Profile_Zone, // finished zones whose outermost zone is still open, in the order they ended
	count:   int,
}

// A begin or an end of a zone, in the order the server takes them.
Zone_Event :: struct {
	time:  i64, // nanoseconds since the epoch of the zones
	name:  string,
	begin: bool,
}

@(step="render",loops="game editor")
tracy_frame :: proc(t:^Tracy,app:^host.App) {
	if !t.started {tracy_start(t,app)}
	if !t.on || app.stats.frames==t.frame && t.frame!=0 {return}
	t.frame=app.stats.frames
	profiler_frame_mark(&t.profiler)
	if !profiler_session_ready(&t.profiler) || !host.profile_request(app) {return}
	if t.session!=t.profiler.client.session && !tracy_session_begin(t,app) {return}
	tracy_gpu_send(t,app.renderer)
	epoch:=host.profile_epoch_ns(app)
	for &thread,index in t.threads {
		count,next,_:=host.profile_read(app,index,thread.cursor,t.read)
		thread.cursor=next
		tracy_cpu_send(t,&thread,u32(index+1),t.read[:count],epoch)
	}
}

@(private="file")
tracy_start :: proc(t:^Tracy,app:^host.App) {
	t.started=true
	value:=os.get_env("MIRAI_TRACY",context.temp_allocator)
	if value=="" || value=="0" || value=="off" {return}
	port:=SERVER_PORT
	if parsed,ok:=strconv.parse_int(os.get_env("MIRAI_TRACY_PORT",context.temp_allocator));ok && parsed>0 && parsed<65536 {port=parsed}
	name:=os.get_env("MIRAI_TRACY_NAME",context.temp_allocator)
	if name=="" {name="Mirai"}
	if !profiler_init(&t.profiler,port,name,os.get_env("MIRAI_TRACY_ANY",context.temp_allocator)=="1",app.allocator) {
		log.warnf("tracy: no port from %d to %d is free; the profiler is off",port,port+TRACY_PORTS-1)
		return
	}
	if backend,ok:=erender.gpu_backend(app);ok {
		t.gpu,_=profiler_gpu_context(&t.profiler,backend==.Metal?.Metal:.Vulkan,"GPU")
	}
	t.on=true
	log.infof("tracy: waiting for the profiler on port %d",profiler_port(&t.profiler))
}

// The rings are read from where they are when a session starts: what ended
// before belongs to no session.
@(private="file")
tracy_session_begin :: proc(t:^Tracy,app:^host.App) -> bool {
	if len(t.threads)==0 {
		t.allocator=app.allocator
		count:=host.profile_threads(app)
		error:runtime.Allocator_Error
		if t.threads,error=make([]Tracy_Thread,count,app.allocator);error!=nil {return false}
		for &thread in t.threads {
			if thread.pending,error=make([]base.Profile_Zone,TRACY_PENDING,app.allocator);error!=nil {return false}
		}
		if t.read,error=make([]base.Profile_Zone,host.PROFILE_RING,app.allocator);error!=nil {return false}
		if t.events,error=make([]Zone_Event,2*TRACY_PENDING,app.allocator);error!=nil {return false}
	}
	for &thread,index in t.threads {
		_,thread.cursor,_=host.profile_read(app,index,0,t.read[:0])
		thread.count=0
	}
	t.gpu_end=0
	t.session=t.profiler.client.session
	return true
}

@(private="file")
tracy_gpu_send :: proc(t:^Tracy,renderer:^erender.Renderer) {
	for timing in erender.gpu_timings(renderer) {
		if timing.end_ns<=t.gpu_end {continue}
		if !profiler_gpu_timing(&t.profiler,t.gpu,timing.name,max(timing.start_ns,t.gpu_end),timing.end_ns) {break}
		t.gpu_end=timing.end_ns
	}
}

// Sends the trees of zones of a thread whose outermost zone ended; the rest
// waits for it. A tree that does not fit in the queue is dropped whole.
@(private="file")
tracy_cpu_send :: proc(t:^Tracy,thread:^Tracy_Thread,id:u32,read:[]base.Profile_Zone,epoch:i64) {
	if thread.count+len(read)>len(thread.pending) {thread.count=0}
	if len(read)>len(thread.pending) {return}
	copy(thread.pending[thread.count:],read)
	thread.count+=len(read)
	complete:=0
	for zone,i in thread.pending[:thread.count] {
		if zone.depth==0 {complete=i+1}
	}
	if complete==0 {return}
	events:=zone_events(thread.pending[:complete],t.events)
	if profiler_reserve(&t.profiler,THREAD_CONTEXT_BYTES+len(events)*CPU_ZONE_BEGIN_BYTES) && profiler_thread_context(&t.profiler,id) {
		for event in events {
			sent:=event.begin?profiler_cpu_zone_begin(&t.profiler,id,event.name,epoch+event.time):profiler_cpu_zone_end(&t.profiler,id,epoch+event.time)
			if !sent {break}
		}
	}
	copy(thread.pending,thread.pending[complete:thread.count])
	thread.count-=complete
}

// The begins and the ends of finished zones in the order a stack of zones
// takes them: by start, the outer one first, and each zone closed before the
// next one at its depth or above begins, so a zone that lasted nothing still
// begins before it ends. Sorts zones; out holds two events per zone.
zone_events :: proc(zones:[]base.Profile_Zone,out:[]Zone_Event) -> []Zone_Event {
	slice.sort_by(zones,proc(a,b:base.Profile_Zone) -> bool {
		if a.start!=b.start {return a.start<b.start}
		if a.depth!=b.depth {return a.depth<b.depth}
		return a.duration<b.duration // of two siblings that start together, the one that ended first
	})
	stack:[64]base.Profile_Zone
	depth,n:=0,0
	for zone in zones[:min(len(zones),len(out)/2)] {
		for depth>0 && stack[depth-1].depth>=zone.depth {
			depth-=1
			out[n]={time=stack[depth].start+stack[depth].duration}
			n+=1
		}
		out[n]={time=zone.start,name=zone.name,begin=true}
		n+=1
		if depth<len(stack) {
			stack[depth]=zone
			depth+=1
		} else {
			out[n]={time=zone.start+zone.duration}
			n+=1
		}
	}
	for depth>0 {
		depth-=1
		out[n]={time=stack[depth].start+stack[depth].duration}
		n+=1
	}
	return out[:n]
}

tracy_free :: proc(t:^Tracy) {
	if t.on {profiler_shutdown(&t.profiler)}
	allocator:=t.allocator
	for thread in t.threads {delete(thread.pending,allocator)}
	delete(t.threads,allocator)
	delete(t.read,allocator)
	delete(t.events,allocator)
	t^={}
}
