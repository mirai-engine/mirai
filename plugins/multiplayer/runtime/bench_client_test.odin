package multiplayer

import "core:fmt"
import "core:slice"
import "core:testing"

@(private) NET_CLIENT_BENCH :: #config(NET_CLIENT_BENCH,false)

// The frames of a client at 144 Hz with 256 interpolated replicas that move
// every tick on the server: how long the game loop of the client takes, in
// the frames that run a tick and in those that run none.
@(test)
bench_client_frames :: proc(t:^testing.T) {
    if !NET_CLIENT_BENCH {return}
    OBJECTS :: 256
    FRAMES :: 2880
    x:=new(Timing);defer free(x)
    defer timing_destroy(x)
    if !timing_init(x,t,{latency=0.03,jitter=0.002},objects=OBJECTS) {return}
    x.shares[1].bare=true
    random:=u64(7)
    for _ in 0..<720 {timing_frame_run(x,timing_dt(&random,1.0/144,0))}
    ticked,idle:[FRAMES]f64
    ticks,idles:=0,0
    mean:f64
    for _ in 0..<FRAMES {
        ran:=x.shares[1].ran
        timing_frame_run(x,timing_dt(&random,1.0/144,0))
        ms:=x.client_seconds*1000
        mean+=ms
        if x.shares[1].ran>ran {ticked[ticks]=ms;ticks+=1} else {idle[idles]=ms;idles+=1}
    }
    testing.expect_value(t,x.sessions[1].stats.spawned,u64(OBJECTS))
    if !testing.expect(t,ticks>0 && idles>0) {return}
    slice.sort(ticked[:ticks])
    slice.sort(idle[:idles])
    fmt.printfln("NET_CLIENT_BENCH replicas=%d frame_hz=144 tick_frames=%d median_tick_ms=%.4f idle_frames=%d median_idle_ms=%.4f mean_ms=%.4f",
        OBJECTS,ticks,ticked[ticks/2],idles,idle[idles/2],mean/FRAMES)
}
