package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import "core:testing"

@(private="file")
near :: proc(a,b:f64) -> bool {return abs(a-b)<1e-9}

// A summary as profile.capture answers it, with what the comparison reads.
@(private="file")
summary_of :: proc(frame,cpu,gpu,game,shadows:f64,zones:string) -> (s:Bench_Summary) {
    text:=fmt.tprintf(`{{"id":1,"frame":{{"count":240,"p50_ms":%f,"p95_ms":%f}},"cpu":{{"ms":%f,"parts":[{{"name":"game","mean_ms":%f,"p95_ms":1}},{{"name":"audio","mean_ms":0.0001}}],"zones":[%s]}},"gpu":{{"recorded":true,"mean_ms":%f,"passes":[{{"name":"shadows","mean_ms":%f}}]}},"notes":["Headless"]}}`,frame,frame+2,cpu,game,zones,gpu,shadows)
    _=json.unmarshal_string(text,&s,allocator=context.temp_allocator)
    return
}

@(private="file")
line_named :: proc(lines:[]Bench_Line,section:Bench_Section,name:string) -> (l:Bench_Line,found:bool) {
    for candidate in lines {
        if candidate.section==section && candidate.name==name {return candidate,true}
    }
    return
}

// head, base, base, head: neither build always measures first nor right after the other.
@(test)
bench_pairs_alternate_which_build_measures_first :: proc(t:^testing.T) {
    order:=bench_order(4,context.temp_allocator)
    testing.expect(t,slice.equal(order,[]int{0,1,1,0,0,1,1,0}),fmt.tprint(order))
    testing.expect_value(t,len(bench_order(1,context.temp_allocator)),2)
}

@(test)
bench_options_take_the_defaults_and_say_what_is_wrong :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    o,error:=bench_options({})
    testing.expect_value(t,error,"")
    testing.expect_value(t,o.folder,".")
    testing.expect_value(t,o.base,"main")
    testing.expect_value(t,o.size,BENCH_SIZE)
    testing.expect_value(t,o.pairs,BENCH_PAIRS)
    testing.expect_value(t,o.frames,BENCH_FRAMES)

    o,error=bench_options({"demo","--base","abc123","--scene","scenes/night.scene","--camera","-2,7.5,7,0.5,0.8,-8,60","--size","1920x1080","--pairs","3","--frames","120","--warmup","0","--out","bin/x"})
    testing.expect_value(t,error,"")
    testing.expect_value(t,o.folder,"demo")
    testing.expect_value(t,o.base,"abc123")
    testing.expect_value(t,o.scene,"scenes/night.scene")
    testing.expect(t,slice.equal(o.camera,[]f64{-2,7.5,7,0.5,0.8,-8,60}),fmt.tprint(o.camera))
    testing.expect_value(t,o.size,[2]int{1920,1080})
    testing.expect_value(t,o.pairs,3)
    testing.expect_value(t,o.frames,120)
    testing.expect_value(t,o.warmup,0)
    testing.expect_value(t,o.out,"bin/x")

    wrong:=[?][]string{
        {"demo","other"},{"--pairs","1"},{"--frames","10"},{"--pairs","x"},{"--camera","1,2,3"},
        {"--camera","0,0,0,1,1,1,200"},{"--size","10x10"},{"--dev"},{"--base"},
    }
    for args in wrong {
        _,error=bench_options(args)
        testing.expectf(t,error!="","%v is wrong",args)
    }
}

// The median of what is there and the median of the distances to it.
@(test)
bench_stat_is_the_median_and_its_median_distance :: proc(t:^testing.T) {
    s:=bench_stat({3,1,2,math.nan_f64(),10})
    testing.expect_value(t,s.count,4)
    testing.expect(t,near(s.median,2.5),fmt.tprint(s))
    testing.expect(t,near(s.spread,1),fmt.tprint(s)) // distances 0.5 1.5 0.5 7.5
    s=bench_stat({5,7,6})
    testing.expect(t,near(s.median,6) && near(s.spread,1),fmt.tprint(s))
    testing.expect_value(t,bench_stat({math.nan_f64()}).count,0)
}

// The change of a measure is the median of the differences of its pairs,
// with the smallest and the largest; a pair where a capture lacks it does not count.
@(test)
bench_line_reads_the_change_from_the_pairs :: proc(t:^testing.T) {
    nan:=math.nan_f64()
    l:=bench_line({section=.Frame,name="frame p50",values={{10,10.2,9.8,7},{11,11.1,10.9,nan}}})
    testing.expect_value(t,l.pairs,3)
    testing.expect(t,near(l.delta,-1),fmt.tprint(l))
    testing.expect(t,near(l.low,-1.1) && near(l.high,-0.9),fmt.tprint(l))
    testing.expect(t,near(l.base.median,11),fmt.tprint(l))
    testing.expect(t,near(l.delta_pct,-100.0/11),fmt.tprint(l))
    testing.expect_value(t,l.head.count,4)
}

// The frame comes first and as it is; the functions are those every capture
// has, by how much they changed; what no build spends a microsecond on is out.
@(test)
bench_lines_keep_what_says_something :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    head:=[]Bench_Summary{
        summary_of(10,6,9,1.0,2.0,`{"name":"a","thread":"main","self_ms":1},{"name":"job","thread":"workers","self_ms":0.5},{"name":"sometimes","thread":"main","self_ms":3}`),
        summary_of(10.2,6.1,9.1,1.1,2.1,`{"name":"a","thread":"main","self_ms":1.1},{"name":"job","thread":"workers","self_ms":0.6}`),
    }
    base:=[]Bench_Summary{
        summary_of(11,7,9,1.5,2.0,`{"name":"a","thread":"main","self_ms":2},{"name":"job","thread":"workers","self_ms":0.5},{"name":"sometimes","thread":"main","self_ms":3}`),
        summary_of(11.1,7.1,9.2,1.6,2.0,`{"name":"a","thread":"main","self_ms":2.1},{"name":"job","thread":"workers","self_ms":0.5}`),
    }
    lines:=bench_lines(bench_rows(head,base))
    testing.expect_value(t,lines[0].name,"frame p50")
    testing.expect_value(t,lines[1].name,"frame p95")
    frame,_:=line_named(lines,.Frame,"frame p50")
    testing.expect(t,near(frame.delta,-0.95),fmt.tprint(frame))
    _,audio:=line_named(lines,.Parts,"audio")
    testing.expect(t,!audio,"a part of a tenth of a microsecond says nothing")
    _,sometimes:=line_named(lines,.Zones,"sometimes")
    testing.expect(t,!sometimes,"a function that a capture lacks has no change to read")
    zones:=make([dynamic]Bench_Line)
    for l in lines {if l.section==.Zones {append(&zones,l)}}
    testing.expect_value(t,len(zones),2)
    testing.expect_value(t,zones[0].name,"a")
    testing.expect_value(t,zones[1].thread,"workers")
    shadows,_:=line_named(lines,.Passes,"shadows")
    testing.expect(t,near(shadows.base.median,2) && near(shadows.delta,0.05),fmt.tprint(shadows))
}

// The table is Markdown for a report: a dash where a
// build lacks a measure, prose within BENCH_LINE characters.
@(test)
bench_markdown_is_a_table_for_the_benchmarks :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    nan:=math.nan_f64()
    report:=Bench_Report{project="demo",date="2026-10-27 12:00:00 UTC",device="NVIDIA GeForce RTX 4070",scene="scenes/night.scene",size={1440,900},pairs=2,frames=240,warmup=600}
    report.runs={{name="head",commit="abc+changes"},{name="base",commit="def"}}
    rows:=[]Bench_Row{
        {section=.Frame,name="frame p50",values={{10,10.2},{11,11.1}}},
        {section=.Passes,name="new pass",values={{0.5,0.5},{nan,nan}}},
        {section=.Zones,name="job",thread="workers",values={{1,1},{1.5,1.5}}},
    }
    report.lines=bench_lines(rows)
    append(&report.warnings,strings.repeat("a long warning ",12))
    text:=bench_markdown(report)
    testing.expect(t,strings.contains(text,"## demo: `abc+changes` against `def`"),text)
    testing.expect(t,strings.contains(text,"| Frame, ms | base | head | Δ | Δ % | Δ per pair |"),text)
    testing.expect(t,strings.contains(text,"| frame p50 | 11.050 ± 0.050 | 10.100 ± 0.100 | -0.950 | -8.6 % | -1.000 to -0.900 |"),text)
    testing.expect(t,strings.contains(text,"| `new pass` | — | 0.500 ± 0.000 | — | — | — |"),text)
    testing.expect(t,strings.contains(text,"| `job` (workers) |"),text)
    testing.expect(t,strings.contains(text,"Warnings:"),text)
    for line in strings.split_lines(text) {
        if strings.has_prefix(line,"|") {continue}
        testing.expectf(t,strings.rune_count(line)<=BENCH_LINE,"a line of %d characters: %s",strings.rune_count(line),line)
    }
}

// Conditions that differ between the builds are warned about, but the
// entities, which the change may add, and the threads.
@(test)
bench_conditions_warn_when_the_builds_were_measured_apart :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    parse :: proc(text:string) -> json.Value {
        value,_:=json.parse_string(text,parse_integers=true)
        return value
    }
    report:Bench_Report
    report.runs={{name="head"},{name="base"}}
    bench_conditions(&report,{
        parse(`{"optimization":"Speed","device":"GPU","preset":"Ultra","entities":10,"workers":7,"validation":false}`),
        parse(`{"optimization":"Minimal","device":"GPU","preset":"High","entities":12,"workers":7,"validation":true}`),
    })
    testing.expect_value(t,report.device,"GPU")
    joined:=strings.join(report.warnings[:],"\n")
    testing.expect(t,strings.contains(joined,"preset"),joined)
    testing.expect(t,strings.contains(joined,"base is not built at --release"),joined)
    testing.expect(t,strings.contains(joined,"base measured with the validation"),joined)
    testing.expect(t,!strings.contains(joined,"entities"),joined)
    testing.expect(t,!strings.contains(joined,"head is not"),joined)
}
