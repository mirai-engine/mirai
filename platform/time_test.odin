package platform

import "core:testing"

@(test)
clock_advances_and_precise_sleep_does_not_wake_early :: proc(t:^testing.T) {
    start:=clock_ns()
    sleep_precise(3_000_000)
    elapsed:=clock_ns()-start
    testing.expect(t,elapsed>=3_000_000)
    // Late by the scheduler at most; generous because the machine is shared.
    testing.expect(t,elapsed<60_000_000)
    testing.expect(t,clock_seconds()>=f64(start)/1e9)
    before:=clock_ns()
    sleep_precise(0);sleep_coarse(0)
    testing.expect(t,clock_ns()-before<5_000_000)
}

@(test)
vsync_frame_time_is_whole_refresh_periods_that_keep_up_with_the_clock :: proc(t:^testing.T) {
    ms :: u64(1_000_000)
    period :: u64(16_666_667)
    vsync:=Frame_Pacing{vsync=true}
    carry:i64
    // The swapchain lets the loop go early and then late: each frame still stands for one period.
    testing.expect_value(t,frame_dt_ns(11*ms,vsync,true,60,&carry),period)
    testing.expect_value(t,frame_dt_ns(22*ms,vsync,true,60,&carry),period)
    testing.expect_value(t,frame_dt_ns(16*ms,vsync,true,60,&carry),period)
    // A missed blank stands for two.
    testing.expect_value(t,frame_dt_ns(35*ms,vsync,true,60,&carry),2*period)
    // Frames let go in pairs, 28 and 5 ms apart, each stand for one period.
    for _ in 0..<8 {
        testing.expect_value(t,frame_dt_ns(28*ms,vsync,true,60,&carry),period)
        testing.expect_value(t,frame_dt_ns(5333333,vsync,true,60,&carry),period)
    }
    total:=u64(0)
    clock:=u64(0)
    for i in 0..<600 {
        elapsed:=u64(i%2==0?9:24)*ms+u64(i%3)*ms/3
        clock+=elapsed
        total+=frame_dt_ns(elapsed,vsync,true,60,&carry)
    }
    testing.expect(t,max(total,clock)-min(total,clock)<=period)
    // Without vsync, or a frame that showed nothing, the clock time stands and the carry is gone.
    testing.expect_value(t,frame_dt_ns(5*ms,{},true,60,&carry),5*ms)
    testing.expect_value(t,carry,i64(0))
    testing.expect_value(t,frame_dt_ns(11*ms,vsync,true,60,&carry),period)
    testing.expect_value(t,frame_dt_ns(7*ms,vsync,false,60,&carry),7*ms)
    testing.expect_value(t,carry,i64(0))
    testing.expect_value(t,frame_dt_ns(7*ms,vsync,true,0,&carry),7*ms)
    // Two frames let go together: the second cannot owe more than a period, so it takes the clock time.
    testing.expect_value(t,frame_dt_ns(1*ms,vsync,true,60,&carry),period)
    testing.expect_value(t,frame_dt_ns(1*ms,vsync,true,60,&carry),1*ms)
    testing.expect_value(t,carry,i64(0))
}

@(test)
frame_budget_follows_the_limit_the_display_and_what_was_shown :: proc(t:^testing.T) {
    ms :: u64(1_000_000)
    testing.expect_value(t,pacing_budget_ns({limit=0},true,60),u64(0))
    testing.expect_value(t,pacing_budget_ns({limit=100},true,60),10*ms)
    testing.expect_value(t,pacing_budget_ns({limit=100},true,0),10*ms)
    // A frame that showed nothing waits like an idle one, or longer if the limit is lower.
    testing.expect_value(t,pacing_budget_ns({limit=0},false,60),IDLE_FRAME_NS)
    testing.expect_value(t,pacing_budget_ns({limit=250},false,60),IDLE_FRAME_NS)
    testing.expect_value(t,pacing_budget_ns({limit=10},false,60),100*ms)
    // With vsync a presented frame lasts a refresh period when the limit is not below the rate.
    testing.expect_value(t,pacing_budget_ns({limit=60,vsync=true},true,60),u64(16_666_667))
    testing.expect_value(t,pacing_budget_ns({limit=60,vsync=true},true,59.94),u64(16_683_350))
    testing.expect_value(t,pacing_budget_ns({limit=144,vsync=true},true,60),u64(16_666_667))
    testing.expect_value(t,pacing_budget_ns({limit=0,vsync=true},true,60),u64(16_666_667))
    testing.expect_value(t,pacing_budget_ns({limit=50,vsync=true},true,144),20*ms)
    // Unknown display, or nothing presented: vsync paced nothing.
    testing.expect_value(t,pacing_budget_ns({limit=100,vsync=true},true,0),10*ms)
    testing.expect_value(t,pacing_budget_ns({limit=100,vsync=true},false,60),IDLE_FRAME_NS)
}

@(test)
frame_target_is_spaced_from_the_previous_one_without_debt :: proc(t:^testing.T) {
    budget:=u64(10_000_000)
    // A frame that ended early waits until a budget after the previous target.
    testing.expect_value(t,pacing_target_ns(100_000_000,104_000_000,budget),u64(110_000_000))
    // The lateness of one sleep is absorbed by the next: targets stay on a grid.
    testing.expect_value(t,pacing_target_ns(110_000_000,110_300_000,budget),u64(120_000_000))
    // A frame that ran long does not wait, and the next ones do not hurry.
    testing.expect_value(t,pacing_target_ns(100_000_000,125_000_000,budget),u64(125_000_000))
    testing.expect_value(t,pacing_target_ns(125_000_000,127_000_000,budget),u64(135_000_000))
    // No limit: never waits.
    testing.expect_value(t,pacing_target_ns(100_000_000,104_000_000,0),u64(104_000_000))
    // A target left in the future by a larger budget is brought back.
    testing.expect_value(t,pacing_target_ns(500_000_000,104_000_000,budget),u64(114_000_000))
}

@(test)
frame_limit_paces_the_loop_and_reports_real_time :: proc(t:^testing.T) {
    p,error:=create({headless=true,pacing=Frame_Pacing{limit=200}})
    testing.expect_value(t,error,Error.None)
    defer destroy(p)
    FRAMES :: 20
    frame_begin(p);frame_end(p)
    start:=clock_ns()
    total:=f32(0)
    for _ in 0..<FRAMES {
        frame_begin(p)
        total+=input_frame(p).dt
        frame_end(p)
    }
    elapsed:=clock_ns()-start
    // 20 frames at 200 per second are 100 ms: never less, and not much more.
    testing.expect(t,elapsed>=u64(FRAMES-1)*5_000_000,"The loop ran faster than its limit")
    // The machine is shared with other tests and builds: only a gross error fails this bound.
    testing.expect(t,elapsed<3_000_000_000,"The loop ran far slower than its limit")
    if elapsed<1_000_000_000 {testing.expect(t,abs(total-f32(f64(elapsed)/1e9))<0.02,"dt does not add up to the time that passed")}
    testing.expect(t,stats(p).paced_ns>0)
    // Without a limit nothing is slept.
    set_pacing(p,{})
    paced:=stats(p).paced_ns
    for _ in 0..<5 {frame_begin(p);frame_end(p)}
    testing.expect_value(t,stats(p).paced_ns,paced)
    // A frame that presented nothing idles even without a limit.
    start=clock_ns()
    frame_begin(p);frame_end(p,presented=false)
    testing.expect(t,clock_ns()-start>=IDLE_FRAME_NS-1_000_000)
}

@(test)
frame_dt_is_capped_after_a_stall :: proc(t:^testing.T) {
    p,error:=create({headless=true,pacing=Frame_Pacing{}})
    testing.expect_value(t,error,Error.None)
    defer destroy(p)
    frame_begin(p)
    sleep_precise(u64(FRAME_DT_MAX*1e9)+20_000_000)
    frame_begin(p)
    testing.expect_value(t,input_frame(p).dt,FRAME_DT_MAX)
}
