package editor

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "mirai:project"
import "mirai:std/serial"

// What profile.compare reads of a capture, and what a baseline keeps of one
// in the project: profile.audit saves it by name, and a later session compares
// against it after the captures of this one are gone.

PROFILE_BASELINE_NAME_BYTES :: 32
PROFILE_BASELINES :: "baselines" // folder of the baselines in the profiles folder of the project

Profile_Digest_Zone :: struct {name:string,worker:bool,self_ms:f64}
Profile_Digest_Pass :: struct {name:string,ms:f64}
Profile_Digest_Memory :: struct {name:string,high_mb:f64}

Profile_Digest :: struct {
    id:int,           // of the capture; 0 for a baseline
    baseline:string,  // its name; empty for a capture
    saved:string,     // when the baseline was saved, RFC 3339
    conditions:Profile_Conditions,
    gpu,memory:bool,  // it recorded those tracks
    frames:int,
    mean_ms,p95_ms,cpu_ms,gpu_ms:f64,
    zones:[]Profile_Digest_Zone,     // own time per frame
    passes:[]Profile_Digest_Pass,    // per frame that measured them
    counters:[]Profile_Digest_Memory,
}

// The digest of a capture, in the temp allocator.
profile_digest :: proc(c:^Profile_Capture) -> (d:Profile_Digest) {
    context.allocator=context.temp_allocator
    d.id,d.conditions,d.frames=c.id,c.conditions,len(c.frames)
    d.gpu,d.memory=.Gpu in c.tracks,.Memory in c.tracks && len(c.memory)>0
    totals,cpu:=make([]f64,len(c.frames)),make([]f64,len(c.frames))
    for f,i in c.frames {totals[i],cpu[i]=profile_frame_ms(f),profile_frame_cpu_ms(f)}
    frame:=profile_spread(totals)
    d.mean_ms,d.p95_ms,d.cpu_ms=frame.mean,frame.p95,profile_spread(cpu).mean
    if d.gpu {d.gpu_ms=profile_spread(profile_gpu_ms(c)).mean}
    aggregates:=profile_aggregate(c)
    zones:=make([]Profile_Digest_Zone,len(aggregates))
    for a,i in aggregates {zones[i]={c.cpu.names[a.name],a.worker,profile_spread(a.self).mean}}
    d.zones=zones
    by_name:=profile_passes_by_name(c)
    passes:=make([]Profile_Digest_Pass,len(by_name))
    for values,i in by_name {passes[i]={c.gpu.pass_names[i],profile_spread(values).mean}}
    d.passes=passes
    if d.memory {
        names:=PROFILE_MEMORY_NAMES
        counters:=make([]Profile_Digest_Memory,len(Profile_Memory_Counter))
        for counter,i in Profile_Memory_Counter {counters[i]={names[counter],f64(profile_memory_series(c,counter).high)/(1<<20)}}
        d.counters=counters
    }
    return
}

// A name a baseline may take: what fits a file name everywhere.
profile_baseline_name_valid :: proc(name:string) -> bool {
    if name=="" || len(name)>=PROFILE_BASELINE_NAME_BYTES {return false}
    for c in transmute([]u8)name {
        if !(c>='a' && c<='z' || c>='A' && c<='Z' || c>='0' && c<='9' || c=='_' || c=='-') {return false}
    }
    return true
}

profile_baseline_path :: proc(project_root,name:string) -> string {
    folder:=project.path(project.folder_path(project_root,.Generated,context.temp_allocator),"profiles",PROFILE_BASELINES,allocator=context.temp_allocator)
    return project.path(folder,fmt.tprintf("%s.json",name),allocator=context.temp_allocator)
}

// Writes the digest of a capture as the baseline name of the project; the
// path it wrote, or the error.
profile_baseline_save :: proc(project_root,name:string,d:Profile_Digest) -> (path,error:string) {
    if !profile_baseline_name_valid(name) {return "",fmt.tprintf("%q is not a baseline name: up to %d letters, digits, '_' and '-'",name,PROFILE_BASELINE_NAME_BYTES-1)}
    path=profile_baseline_path(project_root,name)
    folder,_:=os.split_path(path)
    if os.make_directory_all(folder)!=nil && !os.is_dir(folder) {return "",fmt.tprintf("%s could not be made",folder)}
    saved:=d
    saved.id,saved.baseline=0,name
    saved.saved,_=time.time_to_rfc3339(time.now(),0,true,context.temp_allocator)
    bytes,marshaled:=json.marshal(saved,{pretty=true},context.temp_allocator)
    if marshaled!=nil {return "","The baseline could not be serialized"}
    if serial.file_write_atomic(path,bytes)!=.None {return "",fmt.tprintf("%s could not be written",path)}
    return path,""
}

// The baseline name of the project, in allocator: a caller that runs frames
// before it reads the baseline does not pass the temp allocator, which a frame frees.
profile_baseline_load :: proc(project_root,name:string,allocator:=context.temp_allocator) -> (d:Profile_Digest,error:string) {
    if !profile_baseline_name_valid(name) {return {},fmt.tprintf("%q is not a baseline name: up to %d letters, digits, '_' and '-'",name,PROFILE_BASELINE_NAME_BYTES-1)}
    path:=profile_baseline_path(project_root,name)
    bytes,read:=os.read_entire_file(path,context.temp_allocator)
    if read!=nil {return {},fmt.tprintf("No baseline %q (%s): profile.audit with save writes one; profile.list names the saved ones",name,path)}
    if json.unmarshal(bytes,&d,allocator=allocator)!=nil {return {},fmt.tprintf("%s is not a baseline: save it again with profile.audit",path)}
    d.id,d.baseline=0,strings.clone(name,allocator)
    return d,""
}

// The names of the baselines the project saved, sorted, in the temp allocator.
profile_baselines :: proc(project_root:string) -> []string {
    folder,_:=os.split_path(profile_baseline_path(project_root,"x"))
    entries,error:=os.read_all_directory_by_path(folder,context.temp_allocator)
    if error!=nil {return nil}
    names:=make([dynamic]string,context.temp_allocator)
    for entry in entries {
        stem,ext:=os.split_filename(entry.name)
        if ext=="json" && profile_baseline_name_valid(stem) {append(&names,stem)}
    }
    slice.sort(names[:])
    return names[:]
}
