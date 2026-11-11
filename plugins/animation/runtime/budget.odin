package anim

import "core:math"
import "core:math/linalg"
import "core:mem"
import "mirai:asset"
import "mirai:core"
import inp "mirai:engine/input"
import "mirai:std/base"
import lib "mirai:std/anim"
import "mirai:std/jobs"
import mm "mirai:std/math"

// period: the fewest render frames between palette updates; 0: automatic, by how large the mesh
// shows in the view (BUDGET_SCREEN), every frame for the body a seat drives.
@(component,description="Controls skeletal presentation frequency and priority, automatically by how large the mesh shows or every period frames. Simulation clocks, events, root motion and constraints still run every fixed tick.")
Animation_Budget :: struct {period:u16 `mirai:"max=120"`,significance:f32 `mirai:"min=0,max=1000"`,enabled:bool}
ANIMATION_BUDGET_DEFAULT :: Animation_Budget{significance=1,enabled=true}
// Share of the height of the view, at its distance, that the bounds of a mesh cover above which its
// automatic period is 1, and 2; a smaller one gets 3.
BUDGET_SCREEN :: [2]f32{.98,.69}
@(storage,setting)
Animation_Budget_Config :: struct {max_palette_updates:u32 `mirai:"advanced"`,job_grain:u16 `mirai:"advanced"`,parallel:bool `mirai:"advanced"`}
ANIMATION_BUDGET_CONFIG_DEFAULT :: Animation_Budget_Config{job_grain=4,parallel=true}
Budget_State :: struct {entity:core.Entity,last_update:u64}
// screen: share of the height of the view its bounds cover (budget_screen); exempt: a seat drives
// it, or what it hangs from. Both choose an automatic period.
Budget_Candidate :: struct {entity:core.Entity,slot:u32,policy:Animation_Budget,screen:f32,exempt,force:bool}
@(storage,free="budget_runtime_free")
Budget_Runtime :: struct {
    states:[dynamic]Budget_State,
    selected:[dynamic]bool,
    keys,scratch:[dynamic]base.Sort_Key64,
    frame:u64,
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

// Chooses the palettes made in this frame. False, with every one made, for a
// candidate whose policy is out of range or that comes twice.
budget_select :: proc(runtime:^Budget_Runtime,candidates:[]Budget_Candidate,frame:u64,config:Animation_Budget_Config,problems:^core.Problems) -> bool {
    if runtime==nil || len(candidates)>len(runtime.selected) || len(candidates)>len(runtime.keys) || len(candidates)>len(runtime.scratch) {return false}
    if config.job_grain==0 {
        core.report(problems,core.NONE,"animation.budget_config","Animation_Budget_Config.job_grain is 0, so the budget is off and every skinned mesh is posed each frame; give it 1 or more")
        return false
    }
    for candidate in candidates {
        if candidate.entity==core.NONE || int(candidate.slot)>=len(runtime.states) || int(candidate.slot)>=len(runtime.keys) {budget_inconsistent(problems);return false}
        if candidate.policy.enabled && (candidate.policy.period>120 || !finite(candidate.policy.significance) || candidate.policy.significance<0 || candidate.policy.significance>1000) {
            core.report(problems,candidate.entity,"animation.budget_policy","Animation_Budget of this rig has period %d and significance %f; period goes from 0 (automatic) to 120 and significance from 0 to 1000; until it is fixed the budget is off and every skinned mesh is posed each frame",candidate.policy.period,candidate.policy.significance)
            return false
        }
    }
    for candidate in candidates {runtime.keys[candidate.slot].key=0}
    for candidate in candidates {
        if runtime.keys[candidate.slot].key!=0 {budget_inconsistent(problems);return false}
        runtime.keys[candidate.slot].key=1
    }
    if frame<runtime.frame {for &state in runtime.states {state.last_update=0}}
    runtime.frame=frame
    eligible,forced:=0,0
    for candidate,i in candidates {
        runtime.selected[i]=false
        state:=&runtime.states[candidate.slot]
        if state.entity!=candidate.entity {state^={entity=candidate.entity}}
        period:=budget_period(candidate)
        if candidate.force {runtime.selected[i]=true;forced+=1;continue}
        age:=frame-state.last_update if frame>=state.last_update else u64(0)
        if age<period {continue}
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
            period:=budget_period(candidate)
            significance:=candidate.policy.significance if candidate.policy.enabled else f32(1)
            score:=f32(f64(frame-state.last_update)/f64(period)*(1+f64(significance)))
            runtime.keys[count]={key=u64(~base.sort_key_f32(score))<<32|u64(core.entity_index(candidate.entity)),index=u32(i)}
            count+=1
        }
        if limit>0 {
            base.radix_sort64(runtime.keys[:count],runtime.scratch[:count])
            for item in runtime.keys[:limit] {runtime.selected[item.index]=true}
        }
    }
    for candidate,i in candidates {if runtime.selected[i] {runtime.states[candidate.slot].last_update=frame}}
    runtime.evaluated+=u64(forced+limit);runtime.throttled+=u64(len(candidates)-forced-limit)
    return true
}

// The period of a candidate: that of its policy, or the automatic one; disabled, the default.
budget_period :: proc "contextless" (candidate:Budget_Candidate) -> u64 {
    policy:=candidate.policy if candidate.policy.enabled else ANIMATION_BUDGET_DEFAULT
    if policy.period>0 {return u64(policy.period)}
    if candidate.exempt {return 1}
    for limit,i in BUDGET_SCREEN {if candidate.screen>=limit {return u64(i+1)}}
    return len(BUDGET_SCREEN)+1
}

// The share of the height the view sees at the distance of a sphere that the sphere covers.
budget_screen :: proc "contextless" (view:core.View,center:mm.Vec3,radius:f32) -> f32 {
    distance:=max(linalg.length(center-view.position),1e-3)
    switch view.projection {
    case .Orthographic: if view.height>0 {return 2*radius/view.height}
    case .Custom: return abs(view.custom[1,1])*radius/distance
    case .Perspective:
    }
    return radius/(distance*math.tan(.5*(view.fov if view.fov>0 else core.VIEW_DEFAULT.fov)))
}

// Whether a seat drives e or an entity it hangs from.
budget_seated :: proc(seats:^core.Table(inp.Seat,$A),parents:^core.Table(core.Parent,$B),e:core.Entity) -> bool {
    if seats==nil || core.count(seats)==0 {return false}
    at:=e
    for _ in 0..=(core.count(parents) if parents!=nil else 0) {
        for row in 0..<core.count(seats) {if core.at(seats,row).body==at {return true}}
        if parents==nil {break}
        parent,has:=core.get(parents,at)
        if !has || parent.entity==core.NONE {break}
        at=parent.entity
    }
    return false
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
