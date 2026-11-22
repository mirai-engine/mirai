package main

import "core:strings"
import "core:testing"

// Lines as the player prints them (host/player.odin, host/load_profile.odin).
@(private="file")
BENCH_PIPELINES_COLD :: `mirai: Compiling shaders 0/97, 0:01 (only needed once per install or update)
mirai: load Scene control/control.scene: ready at 653 ms, resident at 932 ms, 18 entities
  phases: Startup 288424 ms Prepare 71 ms (summed) Nav_Tiles 32 ms (summed)
  pipelines: 3 pipelines compiled in 723 ms of the driver, although the kept pipelines were read: their shaders changed
mirai: 299 frames, mean frame time 18.09 ms, drawn at 1920x1017, no player options
  pipelines: 102 made (0 kept), 535205 ms in the driver, longest 184201.5 ms, store Missing; 3 frames late`

@(test)
bench_pipelines_reads_what_the_player_says :: proc(t:^testing.T) {
    run:=bench_pipelines_parse(BENCH_PIPELINES_COLD)
    testing.expect(t,run.found)
    testing.expect_value(t,run.startup_ms,288424)
    testing.expect_value(t,run.resident_ms,932)
    testing.expect_value(t,run.made,102)
    testing.expect_value(t,run.kept,0)
    testing.expect_value(t,run.driver_ms,535205)
    testing.expect_value(t,run.longest_ms,184201.5)
    testing.expect_value(t,run.store,"Missing")
    testing.expect_value(t,run.late,3)
    testing.expect(t,!bench_pipelines_parse("mirai: 299 frames, mean frame time 18 ms").found,"no summary, nothing found")
    later:=bench_pipelines_parse("  phases: Nav_Tiles 1074 ms (summed) Startup 1027 ms Prepare 53 ms (summed)")
    testing.expect_value(t,later.startup_ms,1027)
}

// A cold start is believed only with both caches empty: the kept pipelines
// missing and the driver writing its cache anew.
@(test)
bench_pipelines_doubts_a_start_that_was_not_cold :: proc(t:^testing.T) {
    cold:=bench_pipelines_parse(BENCH_PIPELINES_COLD)
    testing.expect_value(t,bench_pipelines_cold_doubt(cold,true),"")
    testing.expect(t,strings.contains(bench_pipelines_cold_doubt(cold,false),"own cache"),"a driver that kept its cache")
    read:=cold
    read.store="Read"
    testing.expect(t,strings.contains(bench_pipelines_cold_doubt(read,true),"reported Read"),"kept pipelines read")
    read.store="None"
    testing.expect(t,strings.contains(bench_pipelines_cold_doubt(read,true),"could not be verified"))
    testing.expect(t,bench_pipelines_cold_doubt({},true)!="","a run that printed nothing")
}
