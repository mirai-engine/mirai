package anim

import "core:math"
import "core:math/linalg"
import "core:mem"
import "mirai:asset"
import "mirai:core"
import "mirai:std/base"
import lib "mirai:std/anim"
import "mirai:std/jobs"
import mm "mirai:std/math"

// period: the fewest render frames between palette updates; 0: automatic, as often as its size on
// screen needs (budget_interval).
@(component,description="Controls skeletal presentation frequency and priority: automatically, as often as the size of the mesh on screen needs, or every period frames. Simulation clocks, events, root motion and constraints still run every fixed tick.")
Animation_Budget :: struct {period:u16 `mirai:"max=120"`,significance:f32 `mirai:"min=0,max=1000"`}
ANIMATION_BUDGET_DEFAULT :: Animation_Budget{significance=1}
// An automatic palette waits while its pose moves less on screen than the eye tells from a
// continuous motion: BUDGET_STEP pixels, for limbs that cross BUDGET_SPEED times the height of
// the mesh a second, as in a run. A mesh of a few pixels waits at most BUDGET_LONGEST seconds.
BUDGET_STEP :: 1
BUDGET_SPEED :: 2
BUDGET_LONGEST :: .25
@(storage,setting)
Animation_Budget_Config :: struct {max_palette_updates:u32 `mirai:"advanced"`,job_grain:u16 `mirai:"advanced"`,parallel:bool `mirai:"advanced"`}
ANIMATION_BUDGET_CONFIG_DEFAULT :: Animation_Budget_Config{job_grain=4,parallel=true}
Budget_State :: struct {entity:core.Entity,last_update:u64,last_clock:f64}
// pixels: the height its bounds cover on screen (budget_pixels), which sets an automatic period.
Budget_Candidate :: struct {entity:core.Entity,slot:u32,policy:Animation_Budget,pixels:f32,force:bool}
@(storage,free="budget_runtime_free")
Budget_Runtime :: struct {
    states:[dynamic]Budget_State,
    selected:[dynamic]bool,
    keys,scratch:[dynamic]base.Sort_Key64,
    frame:u64,
    clock:f64, // seconds of the frames it chose for, since the start
    evaluated,throttled:u64, // palettes made and left for a later frame, since the start
}
budget_runtime_free :: proc(runtime:^Budget_Runtime) {if runtime!=nil {delete(runtime.states);delete(runtime.selected);delete(runtime.keys);delete(runtime.scratch);runtime^={}}}

budget_prepare :: proc(runtime:^Budget_Runtime,count:int,problems:^core.Problems) -> bool {
    if runtime==nil || count<0 || count>int(max(u32)) {return false}
    if len(runtime.states)>=count && len(runtime.selected)>=count && len(runtime.keys)>=count && len(runtime.scratch)>=count {return true}
    if resize(&runtime.states,count)!=nil || resize(&runtime.selected,count)!=nil || resize(&runtime.keys,count)!=nil || resize(&runtime.scratch,count)!=nil {
        memory_problem(problems,core.NONE,"the animation budget, so every skinned mesh is posed in this frame")
        return false
    }
    return true
}

// Chooses the palettes made in this frame, which lasts dt seconds. False, with every one made, for
// a candidate whose policy is out of range or that comes twice.
budget_select :: proc(runtime:^Budget_Runtime,candidates:[]Budget_Candidate,frame:u64,dt:f32,config:Animation_Budget_Config,problems:^core.Problems) -> bool {
    if runtime==nil || len(candidates)>len(runtime.selected) || len(candidates)>len(runtime.keys) || len(candidates)>len(runtime.scratch) {return false}
    if config.job_grain==0 {
        core.report(problems,core.NONE,"animation.budget_config","Animation_Budget_Config.job_grain is 0, so the budget is off and every skinned mesh is posed each frame; give it 1 or more")
        return false
    }
    for candidate in candidates {
        if candidate.entity==core.NONE || int(candidate.slot)>=len(runtime.states) || int(candidate.slot)>=len(runtime.keys) {budget_inconsistent(problems);return false}
        if candidate.policy.period>120 || !finite(candidate.policy.significance) || candidate.policy.significance<0 || candidate.policy.significance>1000 {
            core.report(problems,candidate.entity,"animation.budget_policy","Animation_Budget of this rig has period %d and significance %f; period goes from 0 (automatic) to 120 and significance from 0 to 1000; until it is fixed the budget is off and every skinned mesh is posed each frame",candidate.policy.period,candidate.policy.significance)
            return false
        }
    }
    for candidate in candidates {runtime.keys[candidate.slot].key=0}
    for candidate in candidates {
        if runtime.keys[candidate.slot].key!=0 {budget_inconsistent(problems);return false}
        runtime.keys[candidate.slot].key=1
    }
    if frame<runtime.frame {for &state in runtime.states {state.last_update,state.last_clock=0,0}}
    runtime.frame=frame
    step:=f64(dt) if finite(dt) && dt>0 else 0
    runtime.clock+=step
    eligible,forced:=0,0
    for candidate,i in candidates {
        runtime.selected[i]=false
        state:=&runtime.states[candidate.slot]
        if state.entity!=candidate.entity {state^={entity=candidate.entity}}
        if candidate.force {runtime.selected[i]=true;forced+=1;continue}
        if !budget_due(state^,candidate,frame,runtime.clock,step) {continue}
        runtime.selected[i]=true
        eligible+=1
    }
    limit:=eligible
    if config.max_palette_updates>0 {limit=min(eligible,max(int(config.max_palette_updates)-forced,0))}
    if limit<eligible {
        count:=0
        for candidate,i in candidates {
            if candidate.force || !runtime.selected[i] {continue}
            runtime.selected[i]=false
            if limit==0 {continue}
            state:=&runtime.states[candidate.slot]
            score:=f32(budget_waited(state^,candidate,frame,runtime.clock)*(1+f64(candidate.policy.significance)))
            runtime.keys[count]={key=u64(~base.sort_key_f32(score))<<32|u64(core.entity_index(candidate.entity)),index=u32(i)}
            count+=1
        }
        if limit>0 {
            base.radix_sort64(runtime.keys[:count],runtime.scratch[:count])
            for item in runtime.keys[:limit] {runtime.selected[item.index]=true}
        }
    }
    for candidate,i in candidates {if runtime.selected[i] {state:=&runtime.states[candidate.slot];state.last_update,state.last_clock=frame,runtime.clock}}
    runtime.evaluated+=u64(forced+limit);runtime.throttled+=u64(len(candidates)-forced-limit)
    return true
}

// Seconds an automatic palette may wait for a mesh whose bounds cover pixels of the screen
// height: until its pose moves BUDGET_STEP pixels.
budget_interval :: proc "contextless" (pixels:f32) -> f32 {
    if !(pixels>0) {return BUDGET_LONGEST}
    return min(BUDGET_STEP/(BUDGET_SPEED*pixels),BUDGET_LONGEST)
}

// Whether a candidate waited enough: its period in frames or, automatic, a frame and as long as the
// next frame, step seconds later, would pass budget_interval: fewer frames a second never make it
// wait longer than that.
@(private)
budget_due :: proc "contextless" (state:Budget_State,candidate:Budget_Candidate,frame:u64,clock,step:f64) -> bool {
    age:=frame-state.last_update if frame>=state.last_update else 0
    if candidate.policy.period>0 {return age>=u64(candidate.policy.period)}
    return age>=1 && clock-state.last_clock+step>f64(budget_interval(candidate.pixels))
}

// How many of its waits a candidate has waited.
@(private)
budget_waited :: proc "contextless" (state:Budget_State,candidate:Budget_Candidate,frame:u64,clock:f64) -> f64 {
    if candidate.policy.period>0 {return f64(frame-state.last_update if frame>=state.last_update else 0)/f64(candidate.policy.period)}
    return (clock-state.last_clock)/f64(max(budget_interval(candidate.pixels),1e-3))
}

// The height in pixels of the view that a sphere covers; without a size, as large as it gets.
budget_pixels :: proc "contextless" (view:core.View,center:mm.Vec3,radius:f32) -> f32 {
    if !(view.size.y>0) {return math.INF_F32}
    distance:=max(linalg.length(center-view.position),1e-3)
    switch view.projection {
    case .Orthographic: if view.height>0 {return 2*radius/view.height*view.size.y}
    case .Custom: return abs(view.custom[1,1])*radius/distance*view.size.y
    case .Perspective:
    }
    return radius/(distance*math.tan(.5*(view.fov if view.fov>0 else core.VIEW_DEFAULT.fov)))*view.size.y
}

@(private)
budget_inconsistent :: proc(problems:^core.Problems) {
    core.report(problems,core.NONE,"animation.budget_state","the animation budget got a skinned mesh twice or out of its slots, a bug of the engine; every skinned mesh is posed in this frame; report the scene")
}

Pose_Palette_Work :: struct {
    parents:[]i32,
    previous,current:[]mm.Transform,
    local,world:[]mm.Transform,
    joints:[]asset.Rig_Joint,
    palette:[]mm.Mat4,
    basis:mm.Transform,
    inverse:mm.Mat4,
    alpha:f32,
    bone_offset:u32,
    enabled,ok:bool,
}
Palette_Range :: struct {start,end:uintptr,writes:bool}
Palette_Workspace :: struct {ranges:[]Palette_Range,keys,scratch:[]base.Sort_Key64,allocator:mem.Allocator,checked_count:int}
palette_workspace_free :: proc(workspace:^Palette_Workspace) {
    if workspace==nil {return}
    delete(workspace.ranges,workspace.allocator);delete(workspace.keys,workspace.allocator);delete(workspace.scratch,workspace.allocator);workspace^={}
}
palette_workspace_prepare :: proc(workspace:^Palette_Workspace,count:int,allocator:=context.allocator) -> bool {
    if workspace==nil || count<0 || count>int(max(u32))/7 {return false}
    count:=count*7
    if len(workspace.ranges)>=count && len(workspace.keys)>=count && len(workspace.scratch)>=count {return true}
    ranges,e1:=make([]Palette_Range,count,allocator);keys,e2:=make([]base.Sort_Key64,count,allocator);scratch,e3:=make([]base.Sort_Key64,count,allocator)
    if e1!=nil || e2!=nil || e3!=nil {delete(ranges,allocator);delete(keys,allocator);delete(scratch,allocator);return false}
    palette_workspace_free(workspace);workspace^={ranges=ranges,keys=keys,scratch=scratch,allocator=allocator,checked_count=-1};return true
}

@(private)
palette_range_add :: proc(workspace:^Palette_Workspace,count:^int,changed:^bool,values:[]$T,writes:bool) -> bool {
    if len(values)==0 {return true}
    if count^>=len(workspace.ranges) || len(values)>int(max(uintptr)/uintptr(size_of(T))) || raw_data(values)==nil {return false}
    start:=uintptr(raw_data(values));size:=uintptr(len(values))*size_of(T)
    if start>max(uintptr)-size {return false}
    range:=Palette_Range{start,start+size,writes}
    changed^ ||= workspace.ranges[count^]!=range
    workspace.ranges[count^]=range;count^+=1
    return true
}

@(private)
palette_work_validate :: proc(works:[]Pose_Palette_Work,workspace:^Palette_Workspace) -> (active:int,ok:bool) {
    for &work in works {work.ok=false}
    if workspace==nil {return 0,false}
    previous_count:=workspace.checked_count;workspace.checked_count=-1
    if len(works)>len(workspace.ranges)/7 || len(workspace.keys)<len(workspace.ranges) || len(workspace.scratch)<len(workspace.ranges) {return 0,false}
    count:=0;changed:=false
    for &work in works {
        if !work.enabled {continue}
        if len(work.current)==0 || len(work.parents)!=len(work.current) || len(work.previous)!=len(work.current) || len(work.local)!=len(work.current) || len(work.world)!=len(work.current) || len(work.palette)!=len(work.joints) || !finite(work.alpha) || work.alpha<0 || work.alpha>1 {return 0,false}
        for joint in work.joints {if u64(joint.node)+u64(work.bone_offset)>=u64(len(work.world)) {return 0,false}}
        if !palette_range_add(workspace,&count,&changed,work.parents,false) || !palette_range_add(workspace,&count,&changed,work.previous,false) || !palette_range_add(workspace,&count,&changed,work.current,false) || !palette_range_add(workspace,&count,&changed,work.joints,false) || !palette_range_add(workspace,&count,&changed,work.local,true) || !palette_range_add(workspace,&count,&changed,work.world,true) || !palette_range_add(workspace,&count,&changed,work.palette,true) {return 0,false}
        active+=1
    }
    if active==0 {workspace.checked_count=previous_count;return 0,true}
    if changed || count!=previous_count {
        for range,i in workspace.ranges[:count] {workspace.keys[i]={key=u64(range.start),index=u32(i)}}
        base.radix_sort64(workspace.keys[:count],workspace.scratch[:count])
        read_end,write_end:=uintptr(0),uintptr(0)
        for key in workspace.keys[:count] {
            range:=workspace.ranges[key.index]
            if range.start<write_end || range.writes && range.start<read_end {return 0,false}
            if range.writes {write_end=max(write_end,range.end)} else {read_end=max(read_end,range.end)}
        }
    }
    workspace.checked_count=count
    return active,true
}

@(private)
palette_work_evaluate :: proc(work:^Pose_Palette_Work) {
    if !work.enabled {work.ok=true;return}
    if work.alpha>=1 {copy(work.local,work.current)} else if work.alpha<=0 {copy(work.local,work.previous)} else {
        for value,i in work.current {previous:=work.previous[i];work.local[i]=value if value==previous else mm.transform_interpolate(previous,value,work.alpha)}
    }
    if !lib.pose_world(work.parents,work.local,work.world,work.basis) {return}
    for joint,i in work.joints {
        value:=work.inverse*mm.transform_matrix(work.world[u64(joint.node)+u64(work.bone_offset)])*joint.inverse_bind
        for row in 0..<4 {for column in 0..<4 {if !finite(value[row,column]) {return}}}
        work.palette[i]=value
    }
    work.ok=true
}
@(private)
Palette_Batch :: struct {works:[]Pose_Palette_Work,indices:[]base.Sort_Key64}
@(private)
palette_range_evaluate :: proc(batch:^Palette_Batch,first,last,worker:int) {
    if len(batch.indices)>0 {for index in batch.indices[first:last] {palette_work_evaluate(&batch.works[index.index])}} else {
        for &work in batch.works[first:last] {palette_work_evaluate(&work)}
    }
}

pose_palette_batch :: proc(system:^jobs.Job_System,works:[]Pose_Palette_Work,workspace:^Palette_Workspace,grain:int=4) -> bool {
    if grain<=0 {for &work in works {work.ok=false};if workspace!=nil {workspace.checked_count=-1};return false}
    active,ready:=palette_work_validate(works,workspace)
    if !ready {return false}
    if active==0 {for &work in works {work.ok=true};return true}
    batch:=Palette_Batch{works=works}
    if active>grain && system!=nil && jobs.worker_count(system)>1 {
        if active<len(works) {
            count:=0
            for &work,i in works {if work.enabled {workspace.keys[count].index=u32(i);count+=1} else {work.ok=true}}
            batch.indices=workspace.keys[:active]
        }
        jobs.parallel_for(system,jobs.OWNER,active,grain,palette_range_evaluate,&batch)
    } else {palette_range_evaluate(&batch,0,len(works),jobs.OWNER)}
    for work in works {if !work.ok {workspace.checked_count=-1;return false}}
    return true
}
