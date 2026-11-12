package anim

import "base:runtime"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import lib "mirai:std/anim"
import "mirai:std/jobs"
import mm "mirai:std/math"

@(test)
presentation_budget_respects_period_priority_capacity_force_and_snapshot_state_without_allocations :: proc(t:^testing.T) {
    budget:Budget_Runtime;defer budget_runtime_free(&budget)
    if !testing.expect(t,budget_prepare(&budget,3,nil)) {return}
    candidates:=[3]Budget_Candidate{}
    for &candidate,i in candidates {candidate={entity=core.entity_make(i+1,1),slot=u32(i),policy={period=1,significance=1}}}
    config:=ANIMATION_BUDGET_CONFIG_DEFAULT;config.max_palette_updates=1
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    stable:=true;chosen:[4]int
    for frame in 1..=4 {
        stable &&=budget_select(&budget,candidates[:],u64(frame),0,config,nil)
        selected:=0
        for value,i in budget.selected[:3] {if value {chosen[frame-1]=i;selected+=1}}
        stable &&=selected==1
    }
    candidates[1].force,candidates[2].force=true,true
    stable &&=budget_select(&budget,candidates[:],5,0,config,nil)
    forced:=budget.selected[1] && budget.selected[2] && !budget.selected[0]
    candidates[1].force,candidates[2].force=false,false
    candidates[0].policy.period=4;candidates[1].policy.period=4;candidates[2].policy.period=4
    stable &&=budget_select(&budget,candidates[:],6,0,config,nil)
    period_blocked:=!budget.selected[0] && !budget.selected[1] && !budget.selected[2]
    context=saved
    testing.expect(t,stable && chosen==[4]int{0,1,2,0} && forced && period_blocked)
    copied:Budget_Runtime;core.value_copy(&copied,&budget,type_info_of(Budget_Runtime));defer budget_runtime_free(&copied)
    testing.expect(t,budget_select(&copied,candidates[:],9,0,config,nil))
    testing.expect(t,budget.states[0].last_update==4 && copied.states[0].last_update==9)
    candidates[1].slot=0;testing.expect(t,!budget_select(&budget,candidates[:],7,0,config,nil));candidates[1].slot=1
    candidates[0].policy.period=121;testing.expect(t,!budget_select(&budget,candidates[:],7,0,config,nil));candidates[0].policy.period=1
    candidates[0].policy.significance=f32(0h7fc00000);testing.expect(t,!budget_select(&budget,candidates[:],7,0,config,nil));candidates[0].policy.significance=1
    testing.expect(t,budget_select(&budget,candidates[:],1,0,config,nil) && budget.states[0].last_update==1)
}

@(test)
palette_jobs_evaluate_identical_poses_and_palettes_with_zero_and_two_workers_using_exclusive_buffers :: proc(t:^testing.T) {
    COUNT :: 24
    parents:=[3]i32{-1,0,1}
    rest:=[3]mm.Transform{mm.TRANSFORM_IDENTITY,mm.TRANSFORM_IDENTITY,mm.TRANSFORM_IDENTITY};rest[1].position.y=1;rest[2].position.y=1
    joints:=[2]asset.Rig_Joint{{node=1,inverse_bind=mm.MAT4_IDENTITY},{node=2,inverse_bind=mm.MAT4_IDENTITY}}
    previous,current:[COUNT][3]mm.Transform
    for &values,i in previous {values=rest;current[i]=rest;current[i][0].position.x=f32(i);current[i][1].rotation=mm.quat_axis_angle({0,0,1},.5)}
    local,world:[2][COUNT][3]mm.Transform;palettes:[2][COUNT][2]mm.Mat4
    works:[2][COUNT]Pose_Palette_Work
    workspace:Palette_Workspace;defer palette_workspace_free(&workspace)
    if !testing.expect(t,palette_workspace_prepare(&workspace,COUNT)) {return}
    for &pass,p in works {for &work,i in pass {work={parents=parents[:],previous=previous[i][:],current=current[i][:],local=local[p][i][:],world=world[p][i][:],joints=joints[:],palette=palettes[p][i][:],basis=mm.TRANSFORM_IDENTITY,inverse=mm.MAT4_IDENTITY,alpha=.3,enabled=true}}}
    saved:=context;all_ok:=true
    for &pass,p in works {
        system:jobs.Job_System
        if !jobs.system_init(&system,{threads=0 if p==0 else 2}) {all_ok=false;break}
        context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
        for _ in 0..<12 {all_ok &&=pose_palette_batch(&system,pass[:],&workspace,1)}
        for &work,i in pass {work.enabled=i%4==2}
        sparse_before:=jobs.system_stats(&system)
        all_ok &&=pose_palette_batch(&system,pass[:],&workspace,4)
        sparse_after:=jobs.system_stats(&system)
        if p==1 {all_ok &&=sparse_after.executed-sparse_before.executed==3} else {all_ok &&=sparse_after.executed==sparse_before.executed}
        for &work,i in pass {work.enabled=i==10}
        before:=jobs.system_stats(&system)
        all_ok &&=pose_palette_batch(&system,pass[:],&workspace,4)
        for &work in pass {work.enabled=false}
        all_ok &&=pose_palette_batch(&system,pass[:],&workspace,4)
        after:=jobs.system_stats(&system);all_ok &&=before.executed==after.executed
        context=saved;jobs.system_destroy(&system)
    }
    testing.expect(t,all_ok && local[0]==local[1] && world[0]==world[1] && palettes[0]==palettes[1])
    testing.expect(t,abs(local[0][10][0].position.x-3)<1e-6 && world[0][10][2].position!=rest[2].position)
}

@(test)
palette_jobs_reject_shared_writes_read_write_aliases_invalid_joints_and_nonfinite_inputs :: proc(t:^testing.T) {
    parents:=[1]i32{-1};rest:=[1]mm.Transform{mm.TRANSFORM_IDENTITY}
    local,world:[2][1]mm.Transform;palettes:[2][1]mm.Mat4
    joints:=[1]asset.Rig_Joint{{inverse_bind=mm.MAT4_IDENTITY}}
    works:[2]Pose_Palette_Work
    for &work,i in works {work={parents=parents[:],previous=rest[:],current=rest[:],local=local[i][:],world=world[i][:],joints=joints[:],palette=palettes[i][:],basis=mm.TRANSFORM_IDENTITY,inverse=mm.MAT4_IDENTITY,alpha=1,enabled=true}}
    workspace:Palette_Workspace;defer palette_workspace_free(&workspace);testing.expect(t,palette_workspace_prepare(&workspace,2))
    baseline:=works[1]
    works[1].world=works[0].world;testing.expect(t,!pose_palette_batch(nil,works[:],&workspace));works[1]=baseline
    works[1].current=works[0].local;testing.expect(t,!pose_palette_batch(nil,works[:],&workspace));works[1]=baseline
    works[0].palette=palettes[0][:0];testing.expect(t,!pose_palette_batch(nil,works[:],&workspace));works[0].palette=palettes[0][:]
    works[0].bone_offset=max(u32);testing.expect(t,!pose_palette_batch(nil,works[:],&workspace));works[0].bone_offset=0
    works[0].alpha=f32(0h7fc00000);testing.expect(t,!pose_palette_batch(nil,works[:],&workspace));works[0].alpha=1
    works[0].basis.rotation=0;testing.expect(t,!pose_palette_batch(nil,works[:],&workspace));works[0].basis=mm.TRANSFORM_IDENTITY
    testing.expect(t,pose_palette_batch(nil,works[:],&workspace))
    testing.expect(t,!pose_palette_batch(nil,works[:],&workspace,0) && !works[0].ok && !works[1].ok && workspace.checked_count==-1)
    testing.expect(t,pose_palette_batch(nil,works[:],&workspace))
    previous_count:=workspace.checked_count
    testing.expect(t,!palette_workspace_prepare(&workspace,4,runtime.nil_allocator()) && workspace.checked_count==previous_count)
    testing.expect(t,pose_palette_batch(nil,works[:],&workspace))
    works[1].world=works[0].world
    testing.expect(t,!pose_palette_batch(nil,works[:],&workspace) && !works[0].ok && !works[1].ok && workspace.checked_count==-1)
    works[1]=baseline
    testing.expect(t,pose_palette_batch(nil,works[:],&workspace))
    parents[0]=0;testing.expect(t,!pose_palette_batch(nil,works[:],&workspace));parents[0]=-1
    rest[0].position.x=f32(0h7fc00000);testing.expect(t,!pose_palette_batch(nil,works[:],&workspace));rest[0].position.x=0
    works[0].inverse[0,0]=f32(0h7fc00000);testing.expect(t,!pose_palette_batch(nil,works[:],&workspace));works[0].inverse=mm.MAT4_IDENTITY
    joints[0].inverse_bind[1,1]=f32(0h7fc00000);testing.expect(t,!pose_palette_batch(nil,works[:],&workspace));joints[0].inverse_bind=mm.MAT4_IDENTITY
    joints[0].node=1;testing.expect(t,!pose_palette_batch(nil,works[:],&workspace) && workspace.checked_count==-1);joints[0].node=0
    testing.expect(t,pose_palette_batch(nil,works[:],&workspace))
}

@(test)
unlimited_presentation_selects_only_eligible_slots_and_preserves_state_on_invalid_candidates :: proc(t:^testing.T) {
    budget:Budget_Runtime;defer budget_runtime_free(&budget)
    if !testing.expect(t,budget_prepare(&budget,4,nil)) {return}
    candidates:=[3]Budget_Candidate{
        {entity=core.entity_make(4,1),slot=3,policy={period=2,significance=0}},
        {entity=core.entity_make(2,1),slot=1,policy={period=1,significance=1}},
        {entity=core.entity_make(1,1),slot=0,policy={period=1,significance=1}},
    }
    config:=ANIMATION_BUDGET_CONFIG_DEFAULT
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    ok:=budget_select(&budget,candidates[:],1,0,config,nil) && !budget.selected[0] && budget.selected[1] && budget.selected[2]
    ok &&=budget_select(&budget,candidates[:],2,0,config,nil) && budget.selected[0] && budget.selected[1] && budget.selected[2]
    config.max_palette_updates=3
    ok &&=budget_select(&budget,candidates[:],3,0,config,nil) && !budget.selected[0] && budget.selected[1] && budget.selected[2]
    candidates[2].force=true;config.max_palette_updates=1
    ok &&=budget_select(&budget,candidates[:],4,0,config,nil) && !budget.selected[0] && !budget.selected[1] && budget.selected[2]
    previous:=budget.states[3];candidates[1].slot=3
    ok &&=!budget_select(&budget,candidates[:],5,0,config,nil) && budget.states[3]==previous && budget.frame==4
    candidates[1].slot=1;key_count:=len(budget.keys);resize(&budget.keys,3)
    ok &&=!budget_select(&budget,candidates[:],5,0,config,nil) && budget.states[3]==previous
    resize(&budget.keys,key_count)
    context=saved
    testing.expect(t,ok)
}

// An automatic palette waits by the size of its mesh on screen, in seconds: a near rig is made
// every frame, a far one less often at 60 frames a second and every frame at 20, never later than
// its interval; an authored period counts frames.
@(test)
automatic_period_waits_by_size_on_screen_in_seconds_at_any_frame_rate :: proc(t:^testing.T) {
    view:=core.VIEW_DEFAULT;view.position={};view.size={1920,1080}
    near,far:=budget_pixels(view,{0,0,-3},1),budget_pixels(view,{0,0,-200},1)
    interval:=f64(budget_interval(far))
    testing.expect(t,budget_interval(near)<1.0/240 && interval>1.0/60 && interval<BUDGET_LONGEST)
    for rate in ([2]int{60,20}) {
        candidates:=[3]Budget_Candidate{
            {entity=core.entity_make(1,1),slot=0,policy=ANIMATION_BUDGET_DEFAULT,pixels=near},
            {entity=core.entity_make(2,1),slot=1,policy=ANIMATION_BUDGET_DEFAULT,pixels=far},
            {entity=core.entity_make(3,1),slot=2,policy={period=2,significance=1},pixels=far},
        }
        budget:Budget_Runtime;defer budget_runtime_free(&budget)
        if !testing.expect(t,budget_prepare(&budget,len(candidates),nil)) {return}
        made:[3]int;last,gap:f64
        for frame in 1..=2*rate {
            if !testing.expect(t,budget_select(&budget,candidates[:],u64(frame),1/f32(rate),ANIMATION_BUDGET_CONFIG_DEFAULT,nil)) {return}
            for chosen,i in budget.selected[:len(candidates)] {if chosen {made[i]+=1}}
            if budget.selected[1] {gap=max(gap,budget.clock-last);last=budget.clock}
        }
        testing.expectf(t,made[0]==2*rate && made[2]==rate && (made[1]<made[0] if rate==60 else made[1]==made[0]) && gap<=interval+1e-9,"%d frames a second: made %v, longest wait %v of %v",rate,made,gap,interval)
    }
}
