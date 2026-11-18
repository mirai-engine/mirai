package main

import "core:fmt"
import "core:os"
import "core:time"
import "mirai:cook/workspace"
import "mirai:editor/api"
import "mirai:rhi"
import "mirai:std/subprocess"

// The GPU turn of a program of the engine a command starts, of the project at
// folder ("" for one without a project): it waits, saying for what, until the
// card has room for it (workspace.gpu_acquire). A person waits for nothing.
// Not held when the lock cannot be made or, for a person, when every turn is
// held: the program runs without one. A program no person watches runs under
// the GPU watchdog, with the limit of the tools unless one is set: nobody is
// there to see a submission hang before the driver resets the card.
gpu_turn :: proc(root,folder,what:string,person:=false) -> (lock:workspace.Lock,charge:i64) {
    if _,limited:=os.lookup_env(rhi.WATCHDOG_VARIABLE,context.temp_allocator);!person && !limited {
        _=os.set_env(rhi.WATCHDOG_VARIABLE,fmt.tprintf("%d",rhi.WATCHDOG_UNWATCHED_MS))
    }
    charge=workspace.gpu_charge(root,folder)
    held:bool
    lock,held=workspace.gpu_acquire(root,fmt.tprintf("pid %d, mirai %s",os.get_pid(),what),charge,person,gpu_wait_notice)
    if person && !held {fmt.eprintfln("mirai: the %d GPU turns are held; opening without one (mirai locks says who holds them)",workspace.GPU_TURNS)}
    return
}

@(private="file")
gpu_wait_notice :: proc(waiting:workspace.Gpu_Wait) {
    if waiting.measurement!="" {
        fmt.eprintfln("mirai: waiting for a measurement to finish before opening the GPU (%s)",waiting.measurement)
        return
    }
    card:=fmt.tprintf("%.1f GiB",f64(waiting.memory)/(1<<30))
    if !waiting.memory_known {card=fmt.tprintf("%s assumed until an editor opens it",card)}
    fmt.eprintfln("mirai: waiting for room on the GPU (%s, %d turns at most); these hold it:",card,workspace.GPU_TURNS)
    now:=time.now()
    for holder in waiting.holders {fmt.eprintfln("  %s, for %s",holder.holder,duration_text(time.diff(holder.since,now)))}
    fmt.eprintfln("A session closes with mirai session stop <project>, and by itself after %s without calls.",duration_text(api.SESSION_IDLE))
}

// The arguments that hand the turn to the editor started with them: it holds
// it from then on, and gives it to the editor it starts again as.
gpu_turn_args :: proc(lock:^workspace.Lock) -> []string {
    if !lock.held {return nil}
    args:=make([]string,2,context.temp_allocator)
    args[0],args[1]="--gpu-turn",fmt.tprintf("%d",lock.handle)
    return args
}

// The handles a child inherits to hold the turn.
gpu_turn_inherit :: proc(lock:^workspace.Lock) -> []uintptr {
    if !lock.held {return nil}
    handles:=make([]uintptr,1,context.temp_allocator)
    handles[0]=lock.handle
    return handles
}

// Once the editor started with gpu_turn_args runs, the turn is its own: its
// owner names it and this process lets go of it.
gpu_turn_hand_over :: proc(lock:^workspace.Lock,process:subprocess.Process,what:string,charge:i64) {
    if !lock.held {return}
    workspace.gpu_turn_rename(lock,fmt.tprintf("pid %d, %s",process.pid,what),charge)
    workspace.lock_hand_over(lock)
}

// Whether a person runs this command: one at a terminal. An agent runs it
// without one.
person_at_terminal :: proc() -> bool {
    return os.is_tty(os.stdin)
}

// What mirai locks says of the GPU turns: how many are held of how many, what
// they are charged of the card, and who holds each one since when.
gpu_turns_print :: proc(root:string) {
    holders:=workspace.gpu_holders(root,context.temp_allocator)
    said,known:=workspace.gpu_card(root)
    charged:i64
    for holder in holders {charged+=holder.charge}
    card:=known?fmt.tprintf("%.1f GiB, %s",f64(said.bytes)/(1<<30),said.name):"not said yet by any editor"
    fmt.printfln("  %-14s %d of %d turns, %.1f GiB charged; the card: %s",
        "gpu",len(holders),workspace.GPU_TURNS,f64(charged)/(1<<30),card)
    now:=time.now()
    for holder in holders {
        fmt.printf("  %-14s %s","",holder.holder)
        if holder.since!={} {fmt.printf(", for %s",duration_text(time.diff(holder.since,now)))}
        fmt.println()
    }
    memory,_:=workspace.gpu_memory(root)
    if over:=workspace.gpu_held_over(memory,holders);over>0 {
        fmt.printfln("  %-14s the holders held %.1f GiB more than the card has for the turns beside the part left to the desktop: it may be paging memory out and its frames slow","",f64(over)/(1<<30))
    }
}
