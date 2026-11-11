package anim

@(require) import "base:runtime"
@(require) import "core:log"
@(require) import "core:testing"
@(require) import "core:time"
@(require) import "mirai:asset"
@(require) import "mirai:core"
@(require) import "mirai:std/jobs"
@(require) import mm "mirai:std/math"

when #config(MIRAI_BENCH,false) {
@(test)
bench_palette_jobs_64_bones :: proc(t:^testing.T) {
    BONES :: 64
    REPEATS :: #config(ANIM_PALETTE_BENCH_REPEATS,512)
    parents:[BONES]i32;rest,current:[BONES]mm.Transform;joints:[BONES]asset.Rig_Joint
    for i in 0..<BONES {
        parents[i]=i32(i-1);rest[i]=mm.TRANSFORM_IDENTITY;rest[i].position.y=.02
        current[i]=rest[i];current[i].rotation=mm.quat_axis_angle({0,1,0},.01)
        joints[i]={node=u32(i),inverse_bind=mm.MAT4_IDENTITY}
    }
    sink:f32
    for count in ([4]int{2,8,64,256}) {
        local:=make([]mm.Transform,count*BONES);world:=make([]mm.Transform,count*BONES);palette:=make([]mm.Mat4,count*BONES)
        works:=make([]Pose_Palette_Work,count)
        defer delete(local);defer delete(world);defer delete(palette);defer delete(works)
        for &work,i in works {work={parents=parents[:],previous=rest[:],current=current[:],local=local[i*BONES:][:BONES],world=world[i*BONES:][:BONES],joints=joints[:],palette=palette[i*BONES:][:BONES],basis=mm.TRANSFORM_IDENTITY,inverse=mm.MAT4_IDENTITY,alpha=.5,enabled=true}}
        workspace:Palette_Workspace;defer palette_workspace_free(&workspace)
        if !testing.expect(t,palette_workspace_prepare(&workspace,count)) {return}
        labels:=[4]string{"serial kernel","serial batch","2 job threads","automatic job threads"}
        times:[4]f64
        for label,mode in labels {
            system:jobs.Job_System
            if mode>0 && !testing.expect(t,jobs.system_init(&system,{threads=0 if mode==1 else 2 if mode==2 else jobs.THREADS_AUTO})) {return}
            if !testing.expect(t,pose_palette_batch(&system,works,&workspace,4)) {if mode>0 {jobs.system_destroy(&system)};return}
            workers:=jobs.worker_count(&system) if mode>0 else 1
            saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
            stable:=true;best:=max(time.Duration)
            for _ in 0..<5 {
                start:=time.tick_now()
                for repeat in 0..<REPEATS {
                    if mode==0 {for &work in works {work.ok=false;palette_work_evaluate(&work);stable &&=work.ok}} else {stable &&=pose_palette_batch(&system,works,&workspace,4)}
                    sink+=palette[(repeat%count)*BONES+BONES-1][0,0]
                }
                best=min(best,time.tick_since(start))
            }
            context=saved
            if mode>0 {jobs.system_destroy(&system)}
            testing.expect(t,stable)
            times[mode]=f64(time.duration_nanoseconds(best))/REPEATS
            log.infof("animation palette, %d rigs x %d bones, %s, %d workers, grain4: %.2f ns/batch / %.2f ns/rig (check %v)",count,BONES,label,workers,times[mode],times[mode]/f64(count),sink)
        }
        log.infof("animation palette ratios, %d rigs: serial preflight %.3fx kernel, 2 threads %.3fx serial, automatic %.3fx serial",count,times[1]/times[0],times[2]/times[1],times[3]/times[1])
    }
}

@(test)
bench_presentation_budget_unlimited_and_limited :: proc(t:^testing.T) {
    REPEATS :: #config(ANIM_BUDGET_BENCH_REPEATS,4096)
    sink:u64
    for count in ([4]int{2,8,64,256}) {
        budget:Budget_Runtime;defer budget_runtime_free(&budget)
        candidates:=make([]Budget_Candidate,count);defer delete(candidates)
        if !testing.expect(t,budget_prepare(&budget,count,nil)) {return}
        for &candidate,i in candidates {candidate={entity=core.entity_make(i+1,1),slot=u32(i),policy={period=1,significance=1}}}
        for limited in ([2]bool{false,true}) {
            config:=ANIMATION_BUDGET_CONFIG_DEFAULT
            if limited {config.max_palette_updates=u32(max(count/4,1))}
            frame:=u64(1)
            if !testing.expect(t,budget_select(&budget,candidates,frame,0,config,nil)) {return}
            saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
            stable:=true;best:=max(time.Duration)
            for _ in 0..<5 {
                start:=time.tick_now()
                for _ in 0..<REPEATS {frame+=1;stable &&=budget_select(&budget,candidates,frame,0,config,nil);sink+=budget.evaluated}
                best=min(best,time.tick_since(start))
            }
            context=saved
            testing.expect(t,stable)
            log.infof("animation budget, %d candidates, %s: %.2f ns/select (check %d)",count,"limited" if limited else "unlimited",f64(time.duration_nanoseconds(best))/REPEATS,sink)
        }
    }
}
}
