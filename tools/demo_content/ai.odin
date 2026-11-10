package main

import "mirai:core"
import game "mirai:demo/game"

WAVES_FILE :: "assets/ai/horde_waves.records"
ZOMBIES_FILE :: "assets/ai/zombie_kinds.records"

// The waves of the horde of the AI level and the kinds of zombie they send: three of ten,
// so the horde ends as many as it had before it had waves.
write_horde_records :: proc(o:^Out) {
    kinds:=[]Row_Out(game.Zombie_Kind){
        {"walker",game.ZOMBIE_KIND_DEFAULT},
        {"runner",{speed=5.5,sight=30,color={0.85,0.55,0.25,1}}},
        {"brute",{speed=2.5,sight=18,color={0.55,0.25,0.25,1}}},
    }
    write_records(o,ZOMBIES_FILE,"game.Zombie_Kind",game.Zombie_Kind,kinds,nil)
    kind :: proc(name:string,weight:f32) -> game.Horde_Wave_Kind {return {record_ref(game.Zombie_Kind,ZOMBIES_FILE,name),weight}}
    next :: proc(name:string) -> core.Record(game.Horde_Wave) {return record_ref(game.Horde_Wave,WAVES_FILE,name)}
    waves:=[]Row_Out(game.Horde_Wave){
        {"first",{delay=10,interval=0.5,count=10,kinds={kind("walker",1),{},{},{}},next=next("second")}},
        {"second",{delay=20,interval=0.4,count=10,kinds={kind("walker",2),kind("runner",1),{},{}},next=next("last")}},
        {"last",{delay=30,interval=0.5,count=10,kinds={kind("walker",2),kind("runner",2),kind("brute",1),{}}}},
    }
    write_records(o,WAVES_FILE,"game.Horde_Wave",game.Horde_Wave,waves,nil)
}
