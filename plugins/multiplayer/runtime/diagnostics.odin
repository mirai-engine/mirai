package multiplayer

import "mirai:core"
import wire "mirai:net"

// What a session tells of its links and its prediction while it plays, for
// whoever diagnoses it (play.network.status). It lives in the session, outside
// the World: no copy of the World carries it and a correction that restores
// the World keeps it. Its rings are fixed, so noting never allocates.

CORRECTIONS_KEPT :: 32
RESIMULATIONS_KEPT :: 16

// What of a predicted replica the state of the server had otherwise.
Correction_Field :: enum u8 {
    Position,  // meters apart, where the mass of a body is
    Rotation,  // radians between both
    Scale,     // length of the difference
    Linear,    // meters per second apart
    Angular,   // radians per second apart
    Component, // a replicated component: words of its quantized state that differ
}

// A state of the server that differed from what the client predicted for its tick.
Correction :: struct {
    tick:u32, // server tick of the state
    entity:core.Entity,
    object:Object,
    field:Correction_Field, // the first that differs, in the order of Correction_Field
    table:i32,              // Component: its table in the world info; -1 for the rest
    magnitude:f32,          // in the unit of field
    placed:bool,            // the world could not go back for it: the replica took the state in the present
}

// One time the world went back and ran its ticks again.
Resimulation :: struct {
    from,to:u32, // the first tick run again and the present
    ticks:int,
}

Net_Diagnostics :: struct {
    corrections:[CORRECTIONS_KEPT]Correction, // by count modulo CORRECTIONS_KEPT
    correction_count:u64,
    resimulations:[RESIMULATIONS_KEPT]Resimulation,
    resimulation_count:u64,
}

// A connection of the session as its link stands: those of a server, the
// one to the server of a client.
Link_Stats :: struct {
    connection:Connection,
    rtt,jitter:f32, // seconds
    loss:f32,       // share of the datagrams sent found lost, smoothed
}

@(private)
correction_note :: proc(d:^Net_Diagnostics,c:Correction) {
    d.corrections[d.correction_count%CORRECTIONS_KEPT]=c
    d.correction_count+=1
}

@(private)
resimulation_note :: proc(d:^Net_Diagnostics,r:Resimulation) {
    d.resimulations[d.resimulation_count%RESIMULATIONS_KEPT]=r
    d.resimulation_count+=1
}

// The corrections noted since count was the total: the world did not go back for them.
@(private)
corrections_placed :: proc(d:^Net_Diagnostics,since:u64) {
    for n in max(since,d.correction_count-min(d.correction_count,CORRECTIONS_KEPT))..<d.correction_count {
        d.corrections[n%CORRECTIONS_KEPT].placed=true
    }
}

// The newest corrections, newest first, as many as out holds.
corrections_recent :: proc(d:^Net_Diagnostics,out:[]Correction) -> []Correction {
    count:=int(min(d.correction_count,CORRECTIONS_KEPT,u64(len(out))))
    for k in 0..<count {out[k]=d.corrections[(d.correction_count-1-u64(k))%CORRECTIONS_KEPT]}
    return out[:count]
}

// The newest times the world ran again, newest first, as many as out holds.
resimulations_recent :: proc(d:^Net_Diagnostics,out:[]Resimulation) -> []Resimulation {
    count:=int(min(d.resimulation_count,RESIMULATIONS_KEPT,u64(len(out))))
    for k in 0..<count {out[k]=d.resimulations[(d.resimulation_count-1-u64(k))%RESIMULATIONS_KEPT]}
    return out[:count]
}

// The links of the session as of its last poll, as many as out holds; none without a network.
links :: proc(s:^Net_Session,out:[]Link_Stats) -> []Link_Stats {
    if !s.host_ready {return out[:0]}
    count:=0
    for connection in s.host.connection_handles {
        if count==len(out) {break}
        if connection==0 {continue}
        stats:=wire.connection_stats(&s.host,connection) or_continue
        out[count]={connection=connection,rtt=stats.rtt,jitter=stats.jitter,loss=stats.loss}
        count+=1
    }
    return out[:count]
}
