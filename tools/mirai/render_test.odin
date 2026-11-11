package main

import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import img "mirai:cook/image"
import "mirai:std/base"

@(private="file")
measured :: proc(view:string,frame_ms,stability,luma:f64,luma_target:=0.0) -> Render_Measure {
    return {view=view,size={1440,900},render={1440,900},frame_ms=frame_ms,stability=stability,stability_worst=stability,luma=luma,luma_target=luma_target}
}

@(private="file")
judged :: proc(report:Render_Report,view,metric:string) -> (verdict:Render_Verdict,found:bool) {
    for v in report.verdicts {
        if v.view==view && v.metric==metric {return v,true}
    }
    return
}

// A frame 10 % longer, an image that changes twice as much and a luminance
// half a stop away are regressions; less than that, or a change too small
// to see, is not.
@(test)
render_judge_finds_the_regressions_of_head_against_base :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    report:Render_Report
    head:=Render_Run{name="head"}
    base:=Render_Run{name="base"}
    append(&base.measures,measured("slower",2,0.04,0.1),measured("boils",2,0.04,0.1),measured("same",2,0.04,0.1),measured("brighter",2,0.04,0.1))
    append(&head.measures,measured("slower",2.3,0.04,0.1),measured("boils",2,0.9,0.1),measured("same",2.1,0.085,0.12),measured("brighter",2,0.04,0.15))
    append(&report.runs,head,base)
    render_judge(&report)
    expect :: proc(t:^testing.T,report:Render_Report,view,metric:string,failed:bool) {
        verdict,found:=judged(report,view,metric)
        testing.expectf(t,found && verdict.failed==failed,"%s %s: %v",view,metric,verdict)
    }
    expect(t,report,"slower","cost",true)
    expect(t,report,"boils","stability",true)
    expect(t,report,"boils","stability_worst",true)
    expect(t,report,"same","cost",false)
    expect(t,report,"same","stability",false) // twice as much, but 0.045 more does not show
    expect(t,report,"same","luma",false)
    expect(t,report,"brighter","luma",true)
    testing.expect_value(t,report.regressions,4)
}

// A view away from its art direction fails, unless the base is away too:
// then it is not the change. A change that brings it back from a base away
// from it is not a regression of the luminance either.
@(test)
render_judge_holds_the_art_direction_of_a_view :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    report:Render_Report
    head:=Render_Run{name="head"}
    append(&head.measures,measured("night",2,0.04,0.25,0.028))
    append(&report.runs,head)
    render_judge(&report)
    verdict,found:=judged(report,"night","art")
    testing.expect(t,found && verdict.failed && verdict.change>3)
    base:=Render_Run{name="base"}
    append(&base.measures,measured("night",2,0.04,0.25))
    append(&report.runs,base)
    render_judge(&report)
    verdict,found=judged(report,"night","art")
    testing.expect(t,found && !verdict.failed && verdict.note!="")
    testing.expect_value(t,report.regressions,0)

    mended:Render_Report
    head=Render_Run{name="head"}
    base=Render_Run{name="base"}
    append(&head.measures,measured("lights",2,0.04,0.1,0.1))
    append(&base.measures,measured("lights",2,0.04,0.01))
    append(&mended.runs,head,base)
    render_judge(&mended)
    verdict,found=judged(mended,"lights","luma")
    testing.expect(t,found && !verdict.failed && verdict.note!="",verdict.note)
    testing.expect_value(t,mended.regressions,0)
}

// A trail twice as bright and big enough to show is a regression, judged only
// where both builds flew the view.
@(test)
render_judge_finds_a_trail_where_both_builds_flew :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    report:Render_Report
    head:=Render_Run{name="head"}
    base:=Render_Run{name="base"}
    flown :: proc(view:string,trail:f64,flew:=true) -> Render_Measure {
        m:=measured(view,2,0.04,0.1)
        m.flown,m.trail=flew,trail
        return m
    }
    append(&base.measures,flown("church",0.4),flown("night",0.4),flown("old",0,false))
    append(&head.measures,flown("church",1.2),flown("night",0.6),flown("old",3))
    append(&report.runs,head,base)
    render_judge(&report)
    verdict,found:=judged(report,"church","trail")
    testing.expect(t,found && verdict.failed)
    verdict,found=judged(report,"night","trail")
    testing.expect(t,found && !verdict.failed)
    _,found=judged(report,"old","trail")
    testing.expect(t,!found)
    testing.expect_value(t,report.regressions,1)
}

// Blotches on the move twice as strong and past their floor are a
// regression, right after flying or once the histories had their frames.
@(test)
render_judge_finds_blotches_where_both_builds_flew :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    report:Render_Report
    head:=Render_Run{name="head"}
    base:=Render_Run{name="base"}
    flown :: proc(view:string,mottle,after:f64) -> Render_Measure {
        m:=measured(view,2,0.04,0.1)
        m.flown,m.mottle,m.mottle_after=true,mottle,after
        return m
    }
    append(&base.measures,flown("wall",0.2,0.15),flown("night",0.03,0.02),flown("church",0.5,0.4))
    append(&head.measures,flown("wall",0.6,0.2),flown("night",0.09,0.08),flown("church",0.5,1.2))
    append(&report.runs,head,base)
    render_judge(&report)
    verdict,found:=judged(report,"wall","mottle")
    testing.expect(t,found && verdict.failed)
    verdict,found=judged(report,"night","mottle")
    testing.expect(t,found && !verdict.failed,"three times a blotch that does not show is none")
    verdict,found=judged(report,"church","mottle_after")
    testing.expect(t,found && verdict.failed)
    testing.expect_value(t,report.regressions,2)
}

// What the stability and the luminance measure: the window less the bar and
// the panels, with the margin the editor leaves them, in pixels.
@(test)
render_free_region_leaves_out_the_bar_and_the_panels :: proc(t:^testing.T) {
    region:=render_free_region({1440,900},1440,900,{0,0,1440,72},{16,88,300,440},{},{})
    testing.expect_value(t,region,img.Region{332,88,1092,796})
    doubled:=render_free_region({1440,900},2880,1800,{0,0,1440,72},{},{},{})
    testing.expect_value(t,doubled,img.Region{32,176,2816,1592})
}

// A plan that does not say what to measure is refused with what to fix.
@(test)
render_plan_load_refuses_a_camera_without_a_target :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder:=base.test_folder(t,"render-plan-camera")
    if folder=="" {return}
    write :: proc(t:^testing.T,folder,text:string) {testing.expect(t,os.write_entire_file(join(folder,RENDER_PLAN_FILE),text)==nil)}
    write(t,folder,`{"sizes":[[1440,900]],"warmup":10,"frames":10,"interval":5,"captures":2,"views":[{"name":"a","scene":"scenes/a.scene","position":[0,1,2]}]}`)
    _,ok:=render_plan_load(folder,"","")
    testing.expect(t,!ok)
    write(t,folder,`{"sizes":[[1440,900]],"warmup":10,"frames":10,"interval":5,"captures":2,"views":[{"name":"a","scene":"scenes/a.scene","position":[0,1,2],"target":[0,0,0]},{"name":"b","scene":"scenes/b.scene"}]}`)
    plan,loaded:=render_plan_load(folder,"b","800x600")
    testing.expect(t,loaded && len(plan.views)==1 && plan.views[0].name=="b" && plan.sizes[0]==[2]int{800,600})
}

// The options of a check, and those that cannot go together, refused with
// what is wrong.
@(test)
render_options_parse_reads_the_flags_and_refuses_what_cannot_go_together :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    o,problem:=render_options_parse({"demo","--quality","--fresh-base","--wait","30","--allow-load","--base","none"})
    testing.expect_value(t,problem,"")
    testing.expect(t,o.folder=="demo" && o.quality && o.fresh_base && o.allow_load && o.wait==30 && o.base=="none")
    o,problem=render_options_parse({})
    testing.expect(t,problem=="" && o.folder=="." && o.base=="main" && o.wait==RENDER_WAIT && !o.quality && !o.release)
    o,problem=render_options_parse({"--release"})
    testing.expect(t,problem=="" && o.release)
    for args in ([][]string{{"--wait","soon"},{"--wait","-1"},{"--rerun","r.json","--views","night"},{"--views"},{"--optimized"},{"--dev"},{"demo","other"}}) {
        _,problem=render_options_parse(args)
        testing.expectf(t,problem!="","%v was accepted",args)
    }
}

// A saved base serves the check that would measure the same images: the key
// changes with the GPU, the view, its size and the frames of the plan.
@(test)
render_base_key_names_what_a_measure_depends_on :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    view:=Render_View{name="night",scene="scenes/night.scene",position={0,1,2},target={0,0,0},play={{repeat=2,step=`{"for":1}`}}}
    plan:=Render_Plan{sizes={{1440,900}},warmup=600,frames=180,interval=60,captures=3,views={view}}
    key:=render_base_key("demo","RTX 3070",plan,view,{1440,900})
    moved:=view
    moved.position={0,1,3}
    longer:=plan
    longer.frames=240
    testing.expect(t,render_base_key("demo","RX 7900",plan,view,{1440,900})!=key)
    testing.expect(t,render_base_key("demo","RTX 3070",plan,moved,{1440,900})!=key)
    testing.expect(t,render_base_key("demo","RTX 3070",plan,view,{3072,1728})!=key)
    testing.expect(t,render_base_key("demo","RTX 3070",longer,view,{1440,900})!=key)
    testing.expect(t,render_base_key("demo","RTX 3070",plan,view,{1440,900},true)!=key,"a dev build does not serve a --release one")
}

// The quality of a saved base serves any check; its cost, only a check that
// measures the cost within RENDER_SAVED_COST_HOURS. A quality measure does not
// replace one with the cost.
@(test)
render_saved_find_gives_the_cost_only_while_it_is_recent :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    now:=i64(1_000_000)
    saved:=make([dynamic]Render_Saved)
    render_saved_merge(&saved,{key="a",date=now-3600,measure=measured("a",2,0.04,0.1)})
    render_saved_merge(&saved,{key="old",date=now-(RENDER_SAVED_COST_HOURS+1)*3600,measure=measured("old",2,0.04,0.1)})
    render_saved_merge(&saved,{key="q",date=now,quality=true,measure=measured("q",0,0.04,0.1)})
    _,found:=render_saved_find(saved[:],"a",false,now)
    testing.expect(t,found)
    _,found=render_saved_find(saved[:],"old",false,now)
    testing.expect(t,!found,"a cost a day old is not this machine now")
    _,found=render_saved_find(saved[:],"old",true,now)
    testing.expect(t,found)
    _,found=render_saved_find(saved[:],"q",false,now)
    testing.expect(t,!found,"a measure without the cost does not give it")
    _,found=render_saved_find(saved[:],"q",true,now)
    testing.expect(t,found)
    _,found=render_saved_find(saved[:],"b",true,now)
    testing.expect(t,!found)

    render_saved_merge(&saved,{key="a",date=now,quality=true,measure=measured("a",0,0.5,0.1)})
    m,_:=render_saved_find(saved[:],"a",false,now)
    testing.expect_value(t,m.frame_ms,2)
    render_saved_merge(&saved,{key="a",date=now,measure=measured("a",3,0.04,0.1)})
    m,_=render_saved_find(saved[:],"a",false,now)
    testing.expect_value(t,m.frame_ms,3)
    testing.expect_value(t,len(saved),3)
}

// A cost past the limit is measured again; the verdict is that of the repeat
// and keeps the first. A quality regression, a cost that is not comparable
// or one already repeated is not measured again.
@(test)
render_judge_repeats_a_cost_past_the_limit_and_judges_the_repeat :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    report:Render_Report
    head:=Render_Run{name="head"}
    base:=Render_Run{name="base"}
    other:=measured("other",2.6,0.04,0.1)
    other.render={1280,800}
    append(&base.measures,measured("showcase",2.1,0.04,0.1),measured("boils",2,0.04,0.1),measured("other",2,0.04,0.1))
    append(&head.measures,measured("showcase",4.0,0.04,0.1),measured("boils",2,0.9,0.1),other)
    append(&report.runs,head,base)
    render_judge(&report)
    repeat:=render_repeat_list(report)
    testing.expectf(t,len(repeat)==1 && repeat[0]==Render_Key{"showcase",{1440,900}},"%v",repeat)
    sub:=render_plan_only({views={{name="showcase"},{name="boils"}}},repeat,{1440,900})
    testing.expect(t,len(sub.views)==1 && sub.views[0].name=="showcase")
    testing.expect_value(t,len(render_plan_only({views={{name="showcase"}}},repeat,{3072,1728}).views),0)

    append(&report.runs[0].repeats,measured("showcase",2.15,0.04,0.1))
    append(&report.runs[1].repeats,measured("showcase",2.1,0.04,0.1))
    render_judge(&report)
    verdict,found:=judged(report,"showcase","cost")
    testing.expectf(t,found && !verdict.failed && verdict.repeated && verdict.first==[2]f64{2.1,4.0},"%v",verdict)
    testing.expect_value(t,len(render_repeat_list(report)),0)
    testing.expect_value(t,report.regressions,3) // the stability of boils, twice, and other, not comparable
}

// A view the base has no scene for, or does not list, is not compared: it is
// no regression. One the base failed to measure fails the check. The base
// does not stop the art direction of head.
@(test)
render_judge_does_not_compare_a_view_the_base_did_not_measure :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    report:Render_Report
    head:=Render_Run{name="head"}
    base:=Render_Run{name="base"}
    new_scene:=measured("new",0,0,0)
    new_scene.failure,new_scene.scene_missing="this build has no scene scenes/new.scene",true
    broken:=measured("broken",0,0,0)
    broken.failure="scene.open failed"
    append(&base.measures,new_scene,broken)
    append(&head.measures,measured("new",9,0.9,0.5,0.1),measured("unlisted",9,0.9,0.1),measured("broken",9,0.9,0.1))
    append(&report.runs,head,base)
    render_judge(&report)
    verdict,found:=judged(report,"new","base")
    testing.expectf(t,found && !verdict.failed && strings.contains(verdict.note,"scenes/new.scene"),"%v",verdict)
    _,found=judged(report,"new","cost")
    testing.expect(t,!found)
    verdict,found=judged(report,"unlisted","base")
    testing.expect(t,found && !verdict.failed)
    verdict,found=judged(report,"new","art")
    testing.expect(t,found && verdict.failed)
    testing.expect_value(t,report.regressions,1)
    testing.expect_value(t,report.failed_views,1)
}

// Without the cost (--quality) the check judges all but the cost, also
// against a base that measured it.
@(test)
render_judge_leaves_the_cost_out_of_a_quality_check :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    report:Render_Report
    head:=Render_Run{name="head",quality=true}
    base:=Render_Run{name="base"}
    append(&base.measures,measured("night",2,0.04,0.1))
    append(&head.measures,measured("night",0,0.9,0.1))
    append(&report.runs,head,base)
    render_judge(&report)
    _,found:=judged(report,"night","cost")
    testing.expect(t,!found)
    verdict,stability:=judged(report,"night","stability")
    testing.expect(t,stability && verdict.failed)
    lines:=render_summary(report)
    testing.expectf(t,slice.any_of_proc(lines,proc(line:string) -> bool {return strings.has_prefix(line,"Quality only")}),"%v",lines)
}

// --rerun measures what a report marked: its regressions and the views it
// could not measure, at their sizes.
@(test)
render_flagged_lists_what_a_report_marked :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    report:Render_Report
    head:=Render_Run{name="head"}
    broken:=measured("broken",0,0,0)
    broken.size,broken.failure={3072,1728},"capture failed"
    append(&head.measures,measured("fine",2,0.04,0.1),measured("slower",2.5,0.04,0.1),broken)
    append(&report.runs,head)
    append(&report.verdicts,Render_Verdict{view="slower",size={1440,900},metric="cost",failed=true},Render_Verdict{view="fine",size={1440,900},metric="cost"},Render_Verdict{view="slower",size={1440,900},metric="stability",failed=true})
    views,sizes:=render_flagged(report)
    testing.expectf(t,len(views)==2 && views[0]=="slower" && views[1]=="broken","%v",views)
    testing.expectf(t,len(sizes)==2 && sizes[0]==[2]int{1440,900} && sizes[1]==[2]int{3072,1728},"%v",sizes)
}

// The summary names, per view that regressed, each metric with its change and
// the GPU pass that changed most; without regressions, one line says so.
@(test)
render_summary_says_what_regressed_and_the_pass_that_changed_most :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    report:Render_Report
    head:=Render_Run{name="head"}
    base:=Render_Run{name="base"}
    slower:=measured("night",3,0.9,0.1)
    slower.passes={{"gi trace",1.6},{"taa",0.3},{"glass",0.2}}
    before:=measured("night",2,0.04,0.1)
    before.passes={{"gi trace",0.8},{"taa",0.3},{"fog",0.5}}
    append(&base.measures,before,measured("same",2,0.04,0.1))
    append(&head.measures,slower,measured("same",2,0.04,0.1))
    append(&report.runs,head,base)
    render_judge(&report)
    lines:=render_summary(report)
    testing.expectf(t,len(lines)==2,"%v",lines)
    testing.expect(t,strings.has_prefix(lines[0],"REGRESSION night 1440x900: frame 2.00 → 3.00 ms (+50 %); stability"),lines[0])
    testing.expect(t,strings.contains(lines[0],"the pass that changed most: gi trace, 0.80 → 1.60 ms (+0.80)"),lines[0])
    name,from,to,found:=render_pass_change({{"fog",0.9}},{{"taa",0.3}})
    testing.expect(t,found && name=="fog" && from==0.9 && to==0)

    calm:Render_Report
    head=Render_Run{name="head"}
    base=Render_Run{name="base"}
    append(&base.measures,measured("same",2,0.04,0.1))
    append(&head.measures,measured("same",2,0.04,0.1))
    append(&calm.runs,head,base)
    render_judge(&calm)
    lines=render_summary(calm)
    testing.expectf(t,len(lines)==1 && lines[0]=="No regressions.","%v",lines)
}

// How many frames after a push stops the image stays near its settled self:
// the first capture after which every one is within the share of the first,
// or under the floor no change shows below.
@(test)
render_settle_frames_waits_for_the_last_capture_off_settled :: proc(t:^testing.T) {
    frames:=[]int{1,2,4,8,16,32}
    testing.expect_value(t,render_settle_frames({10,5,2,0.5,0.08,0.04},frames,0.1),8)
    testing.expect_value(t,render_settle_frames({10,5,2,0.5,0.08,0.04},frames,0.01),16)
    // What comes back off settled counts.
    testing.expect_value(t,render_settle_frames({10,0.5,3,0.5,0.2,0.04},frames,0.1),8)
    testing.expect_value(t,render_settle_frames({10,9,9,9,9,9},frames,0.1),-1)
    // A push that changes nothing visible settles at once.
    testing.expect_value(t,render_settle_frames({0.03,0.02,0.04,0.01,0,0},frames,0.01),1)
}

// How far from settled a push leaves the image midway is judged as the
// change between captures, where both builds pushed.
@(test)
render_judge_finds_a_push_that_leaves_more_behind :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    report:Render_Report
    head:=Render_Run{name="head"}
    base:=Render_Run{name="base"}
    pushed :: proc(view:string,error:f64) -> Render_Measure {
        m:=measured(view,2,0.04,0.1)
        m.pushed,m.push_error=true,error
        return m
    }
    append(&base.measures,pushed("church",0.2),pushed("dim",0.02))
    append(&head.measures,pushed("church",0.6),pushed("dim",0.06))
    append(&report.runs,head,base)
    render_judge(&report)
    verdict,found:=judged(report,"church","push")
    testing.expect(t,found && verdict.failed)
    verdict,found=judged(report,"dim","push")
    testing.expect(t,found && !verdict.failed,"three times a change that does not show is none")
}

// A push needs the camera of its view, its entity, where it goes from and to,
// and two frames at least: it captures midway.
@(test)
render_plan_load_refuses_a_push_it_cannot_make :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder:=base.test_folder(t,"render-plan-push")
    if folder=="" {return}
    write :: proc(t:^testing.T,folder,push:string) {
        testing.expect(t,os.write_entire_file(join(folder,RENDER_PLAN_FILE),strings.concatenate({`{"sizes":[[1440,900]],"warmup":10,"frames":10,"interval":5,"captures":2,"views":[{"name":"a","scene":"scenes/a.scene","position":[0,1,2],"target":[0,0,0],"push":`,push,`}]}`}))==nil)
    }
    write(t,folder,`{"entity":"0x4f","from":[0,0,0],"to":[1,0,0],"frames":1,"ev100":7}`)
    _,ok:=render_plan_load(folder,"","")
    testing.expect(t,!ok,"one frame has no midway")
    write(t,folder,`{"entity":"0x4f","from":[0,0,0],"frames":30,"ev100":7}`)
    _,ok=render_plan_load(folder,"","")
    testing.expect(t,!ok,"nowhere to go")
    write(t,folder,`{"entity":"0x4f","from":[0,0,0],"to":[1,0,0],"frames":30,"ev100":7}`)
    plan,loaded:=render_plan_load(folder,"","")
    testing.expect(t,loaded && plan.views[0].push.frames==30 && plan.views[0].push.entity=="0x4f")
}

// A base folder left without its .git sits inside the repository: moving it
// would move the checkout that holds it, so the check refuses it.
@(test)
render_base_prepare_refuses_a_folder_that_is_not_a_worktree :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    root:=base.test_folder(t,"render-base")
    if root=="" {return}
    commit :: proc(t:^testing.T,root,text:string) {
        testing.expect(t,os.write_entire_file(join(root,"file.txt"),text)==nil)
        _,added:=render_git(root,"add","file.txt")
        _,done:=render_git(root,"-c","user.name=mirai","-c","user.email=mirai@test","commit","--quiet","-m",text)
        testing.expect(t,added && done)
    }
    _,created:=render_git(root,"init","--quiet","--initial-branch=main")
    if !testing.expect(t,created) {return}
    commit(t,root,"one");commit(t,root,"two")
    folder:=join(root,".worktrees","render-base")
    testing.expect(t,os.make_directory_all(folder)==nil && os.write_entire_file(join(folder,"left.txt"),"left")==nil)
    _,ok,_:=render_base_prepare(root,"main~1","demo")
    testing.expect(t,!ok)
    branch,attached:=render_git(root,"symbolic-ref","--short","HEAD")
    testing.expect(t,attached && branch=="main","the checkout keeps its branch")
}
