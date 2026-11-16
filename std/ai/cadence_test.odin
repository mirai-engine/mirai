package ai

import "core:testing"

// What runs every period ticks runs once in each period, at the tick its
// phase says; the period grows with the distance up to the slowest, and a
// distance or a near that is not a number stays in range.
@(test)
a_cadence_runs_once_in_each_period_of_its_distance :: proc(t:^testing.T) {
    Due :: struct {period,phase:u64,runs:int}
    for c in ([]Due{{0,3,12},{1,9,12},{4,0,3},{4,7,3},{5,max(u64),3},{max(u64),2,0}}) {
        runs,first:=0,u64(0)
        for tick in u64(1)..=12 {
            if !cadence_due(tick,c.phase,c.period) {continue}
            if runs==0 {first=tick}
            runs+=1
        }
        testing.expectf(t,runs==c.runs,"period %v phase %v runs %v times",c.period,c.phase,runs)
        if c.period>1 && runs>0 {testing.expect(t,(first+c.phase)%c.period==0)}
    }
    nan,inf:=f32(0h7FC00000),f32(0h7F800000)
    Period :: struct {distance,near:f32,slowest,period:u64}
    for c in ([]Period{
        {10,50,30,1},{99,50,30,1},{100,50,30,2},{260,50,30,5},{1e9,50,30,30},{nan,50,30,30},
        {inf,50,30,30},{-inf,50,30,1},{-5,50,30,1},{500,0,30,1},{500,nan,30,1},{500,inf,30,1},
        {500,-1,30,1},{500,50,0,1},{1e38,1e-30,max(u64),max(u64)},
    }) {
        testing.expectf(t,cadence_period(c.distance,c.near,c.slowest)==c.period,"%v m by %v up to %v",c.distance,c.near,c.slowest)
    }
}
