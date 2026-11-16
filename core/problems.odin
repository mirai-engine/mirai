package core

import "mirai:std/base"

PROBLEM_CAPACITY :: 64
PROBLEM_CODE :: 32  // bytes of a code, its NUL included
PROBLEM_TEXT :: 320 // bytes of a message, its NUL included

// Something a function of the loop could not do: on which entity, why, and
// what fixes it.
Problem :: struct {
    entity:Entity,         // NONE: of the world, not of one entity
    count:u64,             // reports, of the ticks that ran the first time
    first,last:u64,        // the Problems.serial of its first and of its last report
    code:[PROBLEM_CODE]u8, // the cause, "<library>.<cause>"
    text:[PROBLEM_TEXT]u8, // what failed and how to fix it, as its first report said
}

// What the functions of a World could not do, for whoever drives the engine:
// engine.diagnostics lists it. One for each World and outside it, so a
// rollback does not take back what a tick reported and Play starts without
// the problems of the document. Every library writes it, in the order of the
// loop. Full, a new problem takes the place of the one reported least recently.
@(storage,host,by_world,shared)
Problems :: struct {
    entries:[PROBLEM_CAPACITY]Problem,
    count:int,
    serial:u64,  // of the last report
    evicted:u64, // problems that gave their place to a newer one
    // The fixed tick that runs is one that ran before (Time.resimulating),
    // set by the host while it runs it: what it reports again does not count.
    resimulating:bool,
}

// Reports that something failed on an entity (NONE: on none) with a message,
// formatted as fmt does, that says what failed and how to fix it. code names
// the cause, "<library>.<cause>" in ASCII: a report of the same entity and
// code counts again without formatting, unless a resimulated tick repeats it.
// Nothing happens without problems (a World the application did not make).
report :: proc(problems:^Problems,entity:Entity,code:string,format:string,args:..any) {
    if problems==nil {return}
    code:=code[:min(len(code),PROBLEM_CODE-1)]
    for &p in problems.entries[:problems.count] {
        if p.entity!=entity || !base.text_equal(p.code[:],code) {continue}
        if problems.resimulating {return}
        problems.serial+=1
        p.count+=1
        p.last=problems.serial
        return
    }
    problems.serial+=1
    at:=problems.count
    if at<len(problems.entries) {
        problems.count+=1
    } else {
        at=0
        for p,i in problems.entries {if p.last<problems.entries[at].last {at=i}}
        problems.evicted+=1
    }
    p:=&problems.entries[at]
    p.entity,p.count,p.first,p.last=entity,1,problems.serial,problems.serial
    base.text_set(p.code[:],code)
    base.text_format(p.text[:],format,..args)
}

// The problems reported, in no order.
problems_list :: proc(problems:^Problems) -> []Problem {
    if problems==nil {return nil}
    return problems.entries[:problems.count]
}

// The problem of an entity and code; nil without one.
problem_find :: proc(problems:^Problems,entity:Entity,code:string) -> ^Problem {
    for &p in problems_list(problems) {
        if p.entity==entity && base.text_equal(p.code[:],code) {return &p}
    }
    return nil
}

problem_code :: proc(p:^Problem) -> string {return base.text_get(p.code[:])}
problem_text :: proc(p:^Problem) -> string {return base.text_get(p.text[:])}

// Forgets every problem, when what they named is gone: another document in
// the World. serial keeps growing.
problems_clear :: proc(problems:^Problems) {
    if problems!=nil {problems.count=0}
}
