package vfx_editor

import "base:runtime"
import "core:mem"
import "core:testing"
import "mirai:editor"
import "mirai:editor/kit"
import "mirai:host"
import "mirai:project"
import gpu "mirai:render"
import "mirai:std/base"
import "mirai:ui"
import vfx "plugins:vfx/runtime"
import "plugins:vfx/runtime/effect"

@(test)
particle_document_shows_every_field_of_the_effect_once_in_its_group :: proc(t:^testing.T) {
    fields:=runtime.type_info_base(type_info_of(effect.Particle_Info)).variant.(runtime.Type_Info_Struct)
    testing.expect(t,int(fields.field_count)<=PARTICLE_FIELDS)
    rows:=PARTICLE_ROWS
    for i in 0..<int(fields.field_count) {
        shown:=0
        for row in rows {if row.field==fields.names[i] {shown+=1}}
        testing.expectf(t,shown==1,"%s is shown %d times",fields.names[i],shown)
    }
    testing.expect_value(t,len(rows),int(fields.field_count))
    // Each group is one run of rows.
    for row,at in rows[1:] {testing.expect(t,row.group>=rows[at].group)}
}

@(test)
particle_document_keeps_its_edits_over_a_file_read_again_and_builds_the_file_to_write :: proc(t:^testing.T) {
    info:=effect.PARTICLE_DEFAULTS
    stored:=[1]effect.Particle_Parameter{{kind=.Float,components=1,value={0.5,0,0,0}}}
    base.text_set(stored[0].name[:],"strength")
    hidden:=[2]effect.Particle_Field{}
    base.text_set(hidden[0].name[:],"rate")
    base.text_set(hidden[1].name[:],"no_such_field")
    file:=effect_values_of({info=&info,parameters=stored[:],hidden=hidden[:]})
    testing.expect_value(t,file.parameter_count,1)
    testing.expect(t,file.hidden=={particle_field_index("rate")})
    held:=file
    testing.expect(t,!effect_edited(&held,&file))
    held.info.duration=5
    testing.expect(t,effect_edited(&held,&file))
    // Another writer changed the file: what the document did not change follows it.
    now:=file
    now.info.duration,now.info.rate=3,40
    base.text_set(now.info.program[:],"sparks")
    now.parameters[0].value[0]=0.75
    effect_merge(&held,&file,&now)
    testing.expect_value(t,held.info.duration,f32(5))
    testing.expect_value(t,held.info.rate,f32(40))
    testing.expect_value(t,base.text_get(held.info.program[:]),"sparks")
    testing.expect_value(t,held.parameters[0].value[0],0.75)
    file=now
    effect_hidden_toggle(&held,"lifetime")
    effect_hidden_toggle(&held,"rate")
    effect_hidden_toggle(&held,"rate")
    effect_hidden_toggle(&held,"no_such_field")
    testing.expect(t,held.hidden=={particle_field_index("rate"),particle_field_index("lifetime")})
    // Hidden fields the panel changed stay when the file changes them too.
    now.hidden={}
    effect_merge(&held,&file,&now)
    testing.expect(t,held.hidden=={particle_field_index("rate"),particle_field_index("lifetime")})
    built:=effect_file(&held)
    testing.expect_value(t,built.info,held.info)
    testing.expect_value(t,len(built.parameters),1)
    testing.expect(t,len(built.hidden)==2 && base.text_get(built.hidden[0].name[:])=="rate" && base.text_get(built.hidden[1].name[:])=="lifetime")
    problem:=effect.particle_validate({info=&built.info,parameters=built.parameters[:],hidden=built.hidden[:]})
    testing.expectf(t,problem.message=="","%s: %s",problem.field,problem.message)
    // Reverting every edit leaves nothing to write.
    held=file
    testing.expect(t,!effect_edited(&held,&file))
}

@(test)
particle_document_parameters_take_the_kind_the_program_declares_and_go_back_to_the_file :: proc(t:^testing.T) {
    tint:=gpu.Program_Parameter{name="tint",kind=.Float,components=3,defaults={1,1,1,0},min=0,max=1}
    noise:=gpu.Program_Parameter{name="noise",kind=.Texture,components=1}
    file:Effect_Values
    held:=file
    testing.expect(t,effect_parameter_put(&held,&tint,{0.5,0.25,1,9},{}))
    stored:=effect_parameter(&held,"tint")
    testing.expect(t,stored!=nil && stored.kind==.Float && stored.components==3 && stored.value==[4]f64{0.5,0.25,1,0})
    testing.expect_value(t,effect.particle_parameter_validate(stored).message,"")
    testing.expect(t,effect_parameter_put(&held,&noise,{1,2,3,4},{7,8}))
    texture:=effect_parameter(&held,"noise")
    testing.expect(t,texture!=nil && texture.kind==.Texture && texture.texture==base.Asset_Id{7,8} && texture.value=={})
    testing.expect_value(t,effect.particle_parameter_validate(texture).message,"")
    testing.expect_value(t,effect.particle_parameters_validate(held.parameters[:held.parameter_count]).message,"")
    testing.expect(t,effect_edited(&held,&file))
    // The file stores another texture and no tint.
    effect_parameter_put(&file,&noise,{},{9,9})
    effect_parameter_revert(&held,&file,"tint")
    testing.expect(t,effect_parameter(&held,"tint")==nil)
    effect_parameter_revert(&held,&file,"noise")
    testing.expect(t,!effect_edited(&held,&file))
    // A parameter taken away moves the next ones down and leaves the last slot empty.
    effect_parameter_put(&held,&tint,{0,0,0,0},{})
    effect_parameter_remove(&held,"noise")
    testing.expect_value(t,held.parameter_count,1)
    testing.expect_value(t,base.text_get(held.parameters[0].name[:]),"tint")
    testing.expect_value(t,held.parameters[1],effect.Particle_Parameter{})
}

@(test)
particle_document_builds_the_rows_of_every_field_and_its_eyes_hide_them :: proc(t:^testing.T) {
    ctx:ui.Context
    if !testing.expect(t,ui.context_init(&ctx,{}) && kit.theme_set(&ctx)) {return}
    defer ui.context_destroy(&ctx)
    g:=editor.Editor_Ui{ctx=&ctx}
    inspector:editor.Inspector
    app:host.App
    s:=new(editor.Session)
    defer free(s)
    s.gui,s.inspector,s.app=&g,&inspector,&app
    p:Effect_Document
    p.read=true
    p.file.info=effect.PARTICLE_DEFAULTS
    p.held=p.file
    p.base=p.file
    p.held.info.size_over_life.values[1]=2
    p.open={.Spawn=true,.Shape=true,.Motion=true,.Look=true,.Collision=true,.Program=true}
    frame :: proc(t:^testing.T,ctx:^ui.Context,s:^editor.Session,p:^Effect_Document,app:^host.App,input:ui.Input) {
        ui.frame_begin(ctx,input)
        if ui.box(ctx,{width=ui.fixed(264),height=ui.FIT,direction=.Column,gap=3}) {effect_rows(s,p,app.assets)}
        output:=ui.frame_end(ctx)
        testing.expect(t,!output.overflow)
        testing.expect_value(t,ctx.stats.layout_errors,u32(0))
        stats:=ctx.stats
        testing.expect(t,stats.dropped_elements==0 && stats.dropped_widgets==0 && stats.dropped_paints==0 && stats.dropped_text==0 && stats.dropped_clips==0)
    }
    still:=ui.Input{size={300,6000},pointer_absent=true,dt=1.0/60}
    for _ in 0..<3 {frame(t,&ctx,s,&p,&app,still)}
    // A frame that changes nothing allocates nothing.
    track:mem.Tracking_Allocator
    mem.tracking_allocator_init(&track,context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    {
        context.allocator=mem.tracking_allocator(&track)
        frame(t,&ctx,s,&p,&app,still)
        testing.expect(t,!effect_edited(&p.held,&p.held))
    }
    testing.expect_value(t,track.total_allocation_count,i64(0))
    // A click on the eye of lifetime hides it from the instances.
    index:=particle_field_index("lifetime")
    eye,found:=ui.widget_rect(&ctx,ui.id(&ctx,"hidden",index+1))
    if !testing.expect(t,found) {return}
    for phase in 0..<3 {
        input:=ui.Input{size={300,6000},pointer=ui.rect_center(eye),dt=1.0/60}
        if phase==1 {input.down,input.pressed={.Left},{.Left}}
        if phase==2 {input.released={.Left}}
        frame(t,&ctx,s,&p,&app,input)
    }
    testing.expect(t,index in p.held.hidden)
    testing.expect(t,p.held.info.size_over_life.values[1]==2 && effect_edited(&p.held,&p.file))
    built:=effect_file(&p.held)
    testing.expect(t,len(built.hidden)==1 && base.text_get(built.hidden[0].name[:])=="lifetime")
}

@(test)
the_preview_of_a_document_shows_what_its_rows_hold_and_frames_where_its_particles_reach :: proc(t:^testing.T) {
    info:=effect.PARTICLE_DEFAULTS
    info.duration,info.rate=1,0
    info.bursts={}
    info.bursts[0]={time=0.5,count=10,cycles=1}
    info.lifetime={1,1}
    cycle,shown:=particle_span(&info)
    testing.expect(t,cycle==1 && shown==2)
    // The values the rows changed and the file does not have yet are those of an instance; assets are not.
    file:=effect_values_of({info=&info})
    held:=file
    held.info.colors[1]={1,0,0,1}
    held.info.material={3,4}
    override:=preview_values(&held,&file)
    testing.expect_value(t,override.count,u32(1))
    resolved:=vfx.particle_resolve(nil,{},&override)
    testing.expect_value(t,resolved.colors[1],[4]f32{1,0,0,1})
    testing.expect_value(t,resolved.material,base.Asset_Id{})
    tint:=gpu.Program_Parameter{name="tint",kind=.Float,components=1,max=1}
    effect_parameter_put(&held,&tint,{0.5,0,0,0},{})
    override=preview_values(&held,&file)
    testing.expect(t,override.count==2 && override.names[1]==vfx.parameter_hash("tint"))
    // Up from a cone, then down where gravity pulls: the box holds both.
    info.speed,info.gravity={2,2},1
    low,high:=effect_reach(nil,&info)
    testing.expect(t,high.y>0.3 && low.y<-6,"it goes up and falls")
    testing.expect(t,low.x<0 && high.x>0 && low.z<0 && high.z>0)
}
