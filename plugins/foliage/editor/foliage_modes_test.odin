package foliage_editor

import "core:testing"
import "mirai:core"
import mm "mirai:std/math"
import render "mirai:engine/render"
import foliage "plugins:foliage/runtime"

@(private="file")
manual_total :: proc(s:^foliage.Source) -> (n:int) {
    for cell in s.cells {n+=len(cell.manual)}
    return
}

@(test)
erase_leaves_the_density_it_is_given_and_none_at_zero :: proc(t:^testing.T) {
    s:foliage.Source;defer foliage.source_destroy(&s)
    fern:=foliage.source_type_add(&s,"fern",{1,1})
    fern.density=1
    id:=fern.id
    up:=u32(mm.quat_pack(1,10))
    for z in 0..<10 {for x in 0..<10 {foliage.source_instance_add(&s,id,{f32(x)*0.5+2,0,f32(z)*0.5+2},up,{1,1})}}
    work:foliage.Build_Work;defer foliage.build_work_destroy(&work)
    random:=mm.rng_make(5)
    // A ring of radius 2 holds about 4π of a density of 1: half of them stay.
    testing.expect(t,erase_touch(&s,nil,[]u32{id},{4.25,0,4.25},2,&work,0.5,&random))
    near:=make([dynamic]Near);defer delete(near)
    instances_near(&s,nil,[]u32{id},{4.25,0,4.25},2,&work,&near)
    testing.expect(t,abs(len(near)-6)<=1,"what erase density keeps of the ring")
    erase_touch(&s,nil,[]u32{id},{4.25,0,4.25},2,&work,0,&random)
    clear(&near)
    instances_near(&s,nil,[]u32{id},{4.25,0,4.25},2,&work,&near)
    testing.expect_value(t,len(near),0)
    testing.expect(t,manual_total(&s)>40,"what is out of the ring stays")
}

@(test)
generate_turns_on_the_cells_under_the_ring_and_ctrl_turns_them_off :: proc(t:^testing.T) {
    s:foliage.Source;defer foliage.source_destroy(&s)
    testing.expect(t,generate_touch(&s,{16,0,16},4,true))
    cell:=foliage.source_cell(&s,{0,0})
    testing.expect(t,cell!=nil && cell.generate)
    testing.expect(t,foliage.source_cell(&s,{3,3})==nil,"a cell far from the ring is not made")
    testing.expect(t,!generate_touch(&s,{16,0,16},4,true),"on again changes nothing")
    testing.expect(t,generate_touch(&s,{16,0,16},4,false) && foliage.source_cell(&s,{0,0})==nil,"off, the cell that holds nothing else goes")
}

@(test)
a_step_keeps_the_cells_it_changed_and_trades_them_back :: proc(t:^testing.T) {
    head,edit:foliage.Source
    defer foliage.source_destroy(&head);defer foliage.source_destroy(&edit)
    id:=foliage.source_type_add(&head,"fern",{1,1}).id
    up:=u32(mm.quat_pack(1,10))
    foliage.source_instance_add(&head,id,{1,0,1},up,{1,1})
    foliage.source_instance_add(&head,id,{40,0,1},up,{1,1})
    source_clone(&edit,&head)
    foliage.source_instance_add(&edit,id,{2,0,2},up,{1,1})
    foliage.source_instance_add(&edit,id,{100,0,100},up,{1,1})
    edit.types[0].density=3
    step:=Step{from=1,to=2}
    defer step_destroy(&step)
    testing.expect(t,step_make(&step,&head,&edit))
    testing.expect_value(t,len(step.cells),2)
    testing.expect(t,step.types_kept && head.types[0].density==3)
    testing.expect_value(t,manual_total(&head),4)
    step_apply(&step,&head)
    testing.expect_value(t,manual_total(&head),2)
    testing.expect(t,len(head.cells)==2 && head.types[0].density!=3,"undo takes the new cell and the type back")
    step_apply(&step,&head)
    testing.expect_value(t,manual_total(&head),4)
}

@(test)
a_group_moves_together_and_an_instance_that_leaves_its_cell_keeps_the_others_named :: proc(t:^testing.T) {
    tool:Foliage_Tool;tool_ready(&tool);defer foliage_tool_free(&tool)
    s:=&tool.edit.source
    id:=foliage.source_type_add(s,"fern",{1,1}).id
    up:=u32(mm.quat_pack(1,10))
    _,a:=foliage.source_instance_add(s,id,{30,0,1},up,{1,1})
    _,b:=foliage.source_instance_add(s,id,{31,0,1},up,{1,1})
    e:=core.Entity(1)
    owner:=mm.Transform{rotation=1,scale={1,1,1}}
    selected_add(&tool,e,{{0,0},foliage.MANUAL|u64(a)},id)
    selected_add(&tool,e,{{0,0},foliage.MANUAL|u64(b)},id)
    testing.expect(t,selected_pivot(&tool,owner,nil))
    tool.selected.pivot_start=tool.selected.pivot
    // Three metres along x: the first leaves cell 0 for cell 1, the second follows.
    tool.selected.pivot.position.x+=3
    testing.expect(t,selected_move(&tool,owner,nil))
    for ref in tool.selected.refs {
        placed,found:=instance_placed(s,nil,ref,&tool.work)
        testing.expect(t,found && placed.position.x>=33,"each is where the group went")
    }
    testing.expect_value(t,manual_total(s),2)
}

@(test)
reapply_gives_the_instances_the_scale_of_their_type_once_a_stroke :: proc(t:^testing.T) {
    tool:Foliage_Tool;tool_ready(&tool);defer foliage_tool_free(&tool)
    s:=&tool.edit.source
    fern:=foliage.source_type_add(s,"fern",{1,1})
    fern.scale,fern.height={2,3},{1,1}
    id:=fern.id
    up:=u32(mm.quat_pack(1,10))
    for x in 0..<4 {foliage.source_instance_add(s,id,{f32(x)+1,0,1},up,{1,1})}
    append(&tool.painted,id)
    testing.expect(t,reapply_touch(&tool,s,nil,{2,0,1},4))
    for p in s.cells[0].manual {testing.expect(t,p.scale[0]>=2 && p.scale[0]<=3)}
    testing.expect(t,!reapply_touch(&tool,s,nil,{2,0,1},4),"each once a stroke")
}

// Tint paints the instances under the ring, manual ones in place and
// generated ones by an override where they stand, and white and dry gives
// them their own look again.
@(test)
tint_paints_the_instances_under_the_ring_into_the_source :: proc(t:^testing.T) {
    tool:Foliage_Tool;tool_ready(&tool);defer foliage_tool_free(&tool)
    s:=&tool.edit.source
    s.info.seed=3
    fern:=foliage.source_type_add(s,"fern",{1,1})
    fern.density=0.05
    id:=fern.id
    foliage.source_instance_add(s,id,{40,0,5},u32(mm.quat_pack(1,10)),{1,1})
    foliage.source_cell(s,{0,0},true).generate=true
    work:foliage.Build_Work
    defer foliage.build_work_destroy(&work)
    foliage.cell_build(s,foliage.source_cell(s,{0,0}),{},&work)
    if !testing.expect(t,len(work.placed)>0) {return}
    generated:=work.placed[0]
    append(&tool.painted,id)
    tool.tint,tool.wet=[3]f32{1,0.5,0.25},0.5
    burnt:=render.batch_color(tool.tint,tool.wet)
    testing.expect(t,tint_touch(&tool,s,nil,{40,0,5},1))
    testing.expect(t,tint_touch(&tool,s,nil,generated.position,0.01))
    manual:=foliage.source_cell(s,{1,0}).manual[0]
    testing.expect(t,manual.flags&foliage.INSTANCE_COLORED!=0 && manual.color==burnt)
    foliage.cell_build(s,foliage.source_cell(s,{0,0}),{},&work)
    found:=false
    for p in work.placed {
        if p.id!=generated.id {continue}
        found=true
        testing.expect(t,p.colored && p.color==burnt && p.position==generated.position,"painted where it stands")
    }
    testing.expect(t,found)
    // A new stroke, white and dry: the manual one has no color of its own again.
    clear(&tool.reapplied)
    tool.tint,tool.wet={1,1,1},0
    testing.expect(t,tint_touch(&tool,s,nil,{40,0,5},1))
    manual=foliage.source_cell(s,{1,0}).manual[0]
    testing.expect(t,manual.flags&foliage.INSTANCE_COLORED==0 && manual.color==0)
}
