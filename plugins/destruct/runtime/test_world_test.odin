package destruct

import "mirai:core"
import render "mirai:engine/render"
import "mirai:host"
import phys "plugins:physics/runtime"

// The tables and the storages of a World that destruct steps on. The test
// world of a library that uses destruct holds them after its header with
// `using`, gives destruct.test_types to core.test_world_init or
// core.test_info, and steps with destruct.test_step. The test makes the
// simulation of physics itself, with the capacities it needs.
Test_Destruct :: struct {
    configs:core.Table(Destructible),
    colliders:core.Table(phys.Collider),
    states:core.Table(Destructible_State),
    groups:core.Table(Destructible_Group),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    meshes:core.Table(render.Mesh_Renderer),
    tints:core.Table(render.Tint),
    elsewhere:core.Table(render.Drawn_Elsewhere),
    ids:core.Table(core.Id),
    physics:phys.Physics_State,
    requests:Destruct_Requests,
    events:Destruct_Events,
    authority:core.Network,
}

// What a step of destruct takes that the World does not hold: what the
// application holds for it. The test makes and destroys its assets and jobs,
// and the cache with cache_destroy before them.
Test_Destruct_Host :: struct {
    assets:host.Assets,
    app:host.App,
    cache:Destruct_Cache,
    problems:core.Problems,
}

// What the declarations of destruct and of the libraries it uses name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    phys.test_types(types)
    append(types,
        core.test_type(Destructible,default=proc(dst:^Destructible) {dst^=destructible_default()}),
        core.test_type(Destruct_Cache,free=cache_free),
    )
}

// destruct_step alone, on the rows as they are and as the loop calls it.
test_step :: proc(d:^Test_Destruct,h:^Test_Destruct_Host,commands:core.Commands,time:core.Time) {
    destruct_step(&d.physics,&h.cache,&d.requests,&d.events,core.ref(&d.authority),h.app.assets,&h.app.jobs,time,commands,
        core.read(&d.configs),&d.meshes,&d.tints,core.read(&d.parents),&d.states,&d.groups,&d.elsewhere,&d.transforms,&d.ids,core.read(&d.colliders),{},&h.problems)
}
