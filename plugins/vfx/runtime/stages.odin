package vfx

import "mirai:core"
import erender "mirai:engine/render"

// The stages of the Vfx programs of a world: in each step, after the births
// and before update, stage k of every emitter whose program has one, k in
// order. A stage over particles goes over those of its emitter; a stage over
// a grid goes over the cells of its region. Neighbours are found through a
// grid: a stage over particles adds each to the words of its cell, and a later
// one reads the cells around. A stage runs
// iterations times, each reading what the one before left. One emitter at a time goes over a
// grid in its stages; another that does is a problem and its stages over it
// do not run. The stages of a sub effect do not run.

Stage_Kind :: enum u8 {None,Particles,Cells}

// A stage the program of an emitter declares.
Stage_Need :: struct {
    kind:Stage_Kind,
    over:u8,       // a stage over cells: the resource of its grid
    iterations:u8,
    writes:u32,    // the grid resources it writes besides its own, a bit each
}

// What the program of an emitter declares besides its parameters.
Program_Needs :: struct {
    resources:[RESOURCES]Resource_Need,
    stages:[erender.PROGRAM_STAGES]Stage_Need,
    cleared:u32, // the grid resources that start at zero each stage that writes them, a bit each
}

// shaders/particles.slang: Particle_Stage, after the resource rows of its emitter.
Gpu_Stage :: struct {
    kind,row,iterations:u32, // row: of the resource of its grid
    writes,clears:u32,       // the grid resources it writes besides its own, and those of them that start at zero
    pad:[3]u32,
}
#assert(size_of(Gpu_Stage)==32)

// What a stage index runs in a step across the emitters of the pool.
Stage_Plan :: struct {
    particles,cells:bool,
    iterations:u32, // the most among its stages
    writes:bool,    // a stage writes grids besides the one it goes over
}

// The stage rows of an emitter, which take the grids its stages go over:
// its first in Particle_Sync.stage_rows + 1, or 0 without stages.
@(private)
emitter_stages :: proc(sync:^Particle_Sync,needs:^Program_Needs,resources:u32,id:u64,e:core.Entity,problems:^core.Problems) -> u32 {
    if needs.stages[0].kind==.None {return 0}
    first:=u32(len(sync.stage_rows))+1
    for need in needs.stages {
        row:Gpu_Stage
        switch need.kind {
        case .None:
        case .Particles: row={kind=u32(Stage_Kind.Particles),iterations=u32(need.iterations),writes=need.writes,clears=need.writes&needs.cleared}
        case .Cells:
            if resources==0 {break}
            grid:=sync.resources[resources+u32(need.over)]
            if grid.kind!=.Grid || int(grid.first)>=len(sync.grids.entries) {break}
            entry:=&sync.grids.entries[grid.first]
            if entry.writer!=0 && entry.writer!=id {
                core.report(problems,e,"vfx.grid","another emitter goes over this grid in its stages: give each emitter its own grid")
                break
            }
            entry.writer=id
            row={kind=u32(Stage_Kind.Cells),row=1+u32(need.over),iterations=u32(need.iterations),writes=need.writes,clears=need.writes&needs.cleared}
        }
        append(&sync.stage_rows,row)
    }
    return first
}

// The stage modes of particle_stage.comp.slang.
STAGE_PARTICLES :: 0
STAGE_CELLS :: 1
STAGE_SWAP :: 2
STAGE_CLEAR :: 3
STAGE_PREPARE :: 4
STAGE_SWAP_PARTICLES :: 5

// The stages of a step, k in order, over the particles and over the cells.
@(private)
stages_step :: proc(sync:^Particle_Sync,pass:^erender.Pass,params:^Simulate_Params) {
    pool:=&sync.pool
    all:=Program_Span{count=u32(pool.order_count)}
    programs:=sync.pipelines.groups
    stage:=sync.pipelines.stage
    for k in 0..<pool.stage_count {
        plan:=pool.plan[k]
        params.stage=k
        if plan.particles {
            for iteration in 0..<max(plan.iterations,1) {
                params.iteration=iteration
                if plan.writes {particle_work(sync,pass,params,all,.Grid_Copy,stage,STAGE_PREPARE)}
                for group in programs {
                    if group.program==0 || group.stage==0 {continue}
                    particle_work(sync,pass,params,group.span,.Particles,group.stage,STAGE_PARTICLES)
                }
                if plan.writes {particle_work(sync,pass,params,all,.Swap_Particles,stage,STAGE_SWAP_PARTICLES)}
            }
        }
        if plan.cells {
            for iteration in 0..<plan.iterations {
                params.iteration=iteration
                if plan.writes {particle_work(sync,pass,params,all,.Grid_Copy,stage,STAGE_PREPARE)}
                for group in programs {
                    if group.program==0 || group.stage==0 {continue}
                    particle_work(sync,pass,params,group.span,.Cells,group.stage,STAGE_CELLS)
                }
                particle_work(sync,pass,params,all,.Swap_Cells,stage,STAGE_SWAP)
            }
        }
    }
    params.stage,params.iteration=0,0
}

// The world buffer of the frame: the areas of the surfaces it does not have
// yet, the grids zeroed when they were made again, and the cells that came
// into the regions that moved since the frame the GPU went over last.
// False when the device does not take it.
@(private)
world_prepare :: proc(sync:^Particle_Sync,pass:^erender.Pass,params:^Simulate_Params) -> bool {
    s:=&sync.surfaces
    world:=world_buffer(sync)
    bound,made:=erender.pass_buffer(pass,6,world)
    if !bound {return false}
    if made {
        for &entry in s.entries {entry.built=false}
        sync.grids.made=false
    }
    if made || sync.fields_dirty || sync.fields_origin!=pass.origin {
        fields:=fields_relative(sync.fields,pass.origin)
        if !erender.pass_buffer_write(pass,world,0,&fields,size_of(fields)) {return false}
        sync.fields_dirty=false
        sync.fields_origin=pass.origin
    }
    Surface_Params :: struct {mesh,first,count,pad:u32}
    for &entry in s.entries {
        if entry.built {continue}
        surface:=Surface_Params{u32(entry.mesh),entry.first+size_of(Gpu_Fields)/4,entry.count,0}
        erender.pass_pipeline(pass,sync.pipelines.surface)
        erender.pass_params(pass,&surface,size_of(surface))
        erender.pass_dispatch(pass,1)
        entry.built=true
    }
    g:=&sync.grids
    if len(g.entries)==0 {return true}
    if !g.made {
        erender.pass_buffer_fill(pass,world,u64(grids_base(sync)),u64(g.bytes))
        g.made=true
        for &entry in g.entries {entry.cleared,entry.loaded,entry.texture_dirty=entry.first,{},true}
        return true
    }
    grids_load(sync,pass)
    params.mode=STAGE_CLEAR
    erender.pass_pipeline(pass,sync.pipelines.stage)
    for &entry,at in g.entries {
        if entry.cleared==entry.first {continue}
        params.stage=sync.pool.grids_at+u32(at)*size_of(Gpu_Grid)
        if !erender.pass_params(pass,params,size_of(params^)) {return false}
        erender.pass_dispatch(pass,groups(grid_cells(entry.cells),64))
        entry.cleared=entry.first
        entry.texture_dirty=true
    }
    params.stage=0
    return true
}

// The world buffer: the areas of the surfaces, the grids, then the data channels.
@(private)
world_buffer :: proc "contextless" (sync:^Particle_Sync) -> erender.Buffer_Desc {
    return {"vfx world",u64(data_base(sync))+u64(sync.data.bytes)}
}

@(private)
grids_base :: proc "contextless" (sync:^Particle_Sync) -> u32 {return size_of(Gpu_Fields)+max(sync.surfaces.capacity,64)*4}
