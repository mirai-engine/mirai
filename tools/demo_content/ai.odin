package main

import "mirai:core"
import game "mirai:demo/game"

WAVES_FILE :: "assets/ai/horde_waves.records"

// The waves of the horde of the AI level: three of ten, so the horde ends as many as it had
// before it had waves. Which zombie comes out is the prefab of its spawn point.
write_horde_records :: proc(o:^Out) {
    next :: proc(name:string) -> core.Record(game.Horde_Wave) {return record_ref(game.Horde_Wave,WAVES_FILE,name)}
    waves:=[]Row_Out(game.Horde_Wave){
        {"first",{delay=10,interval=0.5,count=10,next=next("second")}},
        {"second",{delay=20,interval=0.4,count=10,next=next("last")}},
        {"last",{delay=30,interval=0.5,count=10}},
    }
    write_records(o,WAVES_FILE,"game.Horde_Wave",game.Horde_Wave,waves)
}
