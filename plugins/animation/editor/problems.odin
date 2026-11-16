package animation_editor

import "core:slice"
import "core:strings"
import "mirai:core"
import "mirai:host"

PREVIEW_PROBLEMS :: 4

// A problem of an entity as the animation methods list it.
Problem_Result :: struct {
    code:[core.PROBLEM_CODE]u8 `mirai:"text"`,
    message:[core.PROBLEM_TEXT]u8 `mirai:"text"`,
    count:u64,
}

// The problems the functions of world w reported on entity e whose code
// starts with prefix, the most recent first: as many as fit in out, and how
// many there are.
entity_problems :: proc(app:^host.App,w:core.World_Ref,e:core.Entity,prefix:string,out:[]Problem_Result) -> (written,total:int) {
    if app==nil || w.data==nil {return}
    problems:=host.app_world_storage(app,w.data,core.Problems)
    matched:=make([dynamic]core.Problem,context.temp_allocator)
    for &p in core.problems_list(problems) {
        if p.entity==e && strings.has_prefix(core.problem_code(&p),prefix) {append(&matched,p)}
    }
    slice.sort_by(matched[:],proc(a,b:core.Problem) -> bool {return a.last>b.last})
    for &p,i in matched[:min(len(matched),len(out))] {out[i]={code=p.code,message=p.text,count=p.count}}
    return min(len(matched),len(out)),len(matched)
}
