package install

import "core:mem/virtual"
import "core:strings"
import csync "core:sync"
import "core:thread"
import "mirai:std/base"

// Steps of install run one after the other on a thread of their own, for a
// program that must not stop while git clones: the editor and its launcher.

Step_Kind :: enum u8 {
    Add,     // text: the address of the repository; ref: what to check out, empty: its default branch
    Install, // text: the name of a plugin of the catalog, at the commit it lists
    Update,  // text: the name of the plugin; ref as update takes it
    Remove,  // text: the name of the plugin
    Sync,    // every plugin from git at the commit of the project
    Catalog, // the checkout of the catalog to what its repository has now
}

Step :: struct {
    kind:Step_Kind,
    text,ref:string,
}

Job :: struct {
    arena:virtual.Arena,
    root,engine_root:string,
    steps:[]Step,
    worker:^thread.Thread,
    done:bool,
    // Once done:
    ok:bool,      // every step did what it was asked
    changed:bool, // a plugin of the project was added, moved or taken out: its build is another
    message:string, // what each step said, a line or more each
}

// Starts the steps on a project and returns at once: job_poll says when they
// are over. What it is given is copied.
job_start :: proc(root,engine_root:string,steps:[]Step,allocator:=context.allocator) -> ^Job {
    job:=new(Job,allocator)
    _=virtual.arena_init_growing(&job.arena)
    a:=virtual.arena_allocator(&job.arena)
    job.root,job.engine_root=strings.clone(root,a),strings.clone(engine_root,a)
    job.steps=make([]Step,len(steps),a)
    for step,i in steps {job.steps[i]={step.kind,strings.clone(step.text,a),strings.clone(step.ref,a)}}
    job.worker=thread.create_and_start_with_poly_data(job,job_work)
    if job.worker==nil {
        job.message="The thread of the plugins could not be started"
        csync.atomic_store(&job.done,true)
    }
    return job
}

// True once the steps are over: the job has how. Does not block.
job_poll :: proc(job:^Job) -> bool {
    if !csync.atomic_load(&job.done) {return false}
    if job.worker!=nil {
        thread.join(job.worker)
        thread.destroy(job.worker)
        job.worker=nil
    }
    return true
}

// Waits for the steps and frees the job.
job_destroy :: proc(job:^Job) {
    if job==nil {return}
    for !job_poll(job) {thread.yield()}
    virtual.arena_destroy(&job.arena)
    free(job)
}

@(private="file")
job_work :: proc(job:^Job) {
    a:=virtual.arena_allocator(&job.arena)
    lines:=make([dynamic]string,a)
    job.ok=true
    for step in job.steps {
        result:Result
        switch step.kind {
        case .Add:     result=add(job.root,job.engine_root,step.text,step.ref,a)
        case .Install: result=add_from_catalog(job.root,job.engine_root,step.text,a)
        case .Update:
            old,_:=head_read(project_plugin(job.root,step.text))
            old=strings.clone(old,a)
            result=update(job.root,job.engine_root,step.text,step.ref,a)
            if result.ok && base.text_get(result.commit[:])!=old {job.changed=true}
        case .Remove: result=remove(job.root,job.engine_root,step.text,a)
        case .Sync:
            changed,message:=sync(job.root,a)
            result={ok=message=="",message=message}
            if changed>0 {job.changed=true}
        case .Catalog:
            message:=catalog_refresh(job.engine_root,a)
            result={ok=message=="",message=message}
        }
        if result.ok && (step.kind==.Add || step.kind==.Install || step.kind==.Remove) {job.changed=true}
        if !result.ok {job.ok=false}
        if result.message!="" {append(&lines,result.message)}
        free_all(context.temp_allocator)
    }
    job.message=strings.join(lines[:],"\n",a)
    csync.atomic_store(&job.done,true)
}

@(private="file")
project_plugin :: proc(root,name:string) -> string {
    return strings.concatenate({root,"/plugins/",name},context.temp_allocator)
}
