package core

import "core:fmt"

// What the attributes of a @(component) or @(storage) say of its table or
// storage. The generator reads it from the declarations of a project and a
// test world from those of the types of its fields, both through
// declared_read.
Declared :: struct {
    shared,host,by_world:bool,
    single:bool, // a component the world uses one of at a time: its table keeps one row on
    far:bool,    // a component that draws a far form of its own: its entity stays when its section unloads
    derived:bool, // a component only code adds and nobody authors: a save, a copy and the undo leave it out
    was:string,   // a component: the names it had, separated by spaces; a table of a document under one of them is its table
    replication:Replication,
    queue:bool,        // a storage of requests that many push and one library takes
    keep:bool,         // a storage of the World that survives clearing it: the state of the run, not of its entities
    persist:bool,      // a keep storage that the save library writes to the profile of the player and reads back
    presentation:bool, // what comes back from the GPU: it decides nothing a rollback runs again, so no function of fixed reads it
    setting:Setting_Kind,
    // Procedures of its package, by name.
    copy:string,      // "false": it is not copied
    copy_kept:string, // of the copy a history keeps, which copy_changed makes; copy otherwise
    swap:string,
    free:string,      // releases what the storage holds; value_free otherwise
    reset:string,     // gives a storage of the World its start when the World is cleared
    lock_names:string, // the components whose rows a row of this one owns, as written: separated by spaces
    description:string,
    place:Place,
}

// The name of a type in snake case, as the generator names its field in the
// World and looks for its defaults: UI_Settings is ui_settings. It is
// written in buffer; "" when it does not fit.
snake_name :: proc "contextless" (name:string,buffer:[]u8) -> string {
    n:=0
    for i in 0..<len(name) {
        c:=name[i]
        upper:=c>='A' && c<='Z'
        // A capital after a capital is in the same word.
        word:=upper && i>0 && !(name[i-1]>='A' && name[i-1]<='Z')
        if (word || c=='_') && n>0 && buffer[n-1]=='_' {
            if c=='_' {continue}
            word=false
        }
        if n+2>len(buffer) {return ""}
        if word {
            buffer[n]='_'
            n+=1
        }
        buffer[n]=upper?c+('a'-'A'):c
        n+=1
    }
    return string(buffer[:n])
}

// What the package of a component or a storage declares for it by its name:
// the constant or the procedure that gives what a row or the storage starts
// as, and the procedure that gives the default of a storage on a GPU. They
// are written in buffer; "" when they do not fit.
default_names :: proc(name:string,buffer:[]u8) -> (constant,maker,for_device:string) {
    snake:=snake_name(name,buffer)
    if snake=="" || 4*len(snake)+len("_DEFAULT_default_for_device")>len(buffer) {return}
    rest:=buffer[len(snake):]
    constant=fmt.bprintf(rest,"%s_DEFAULT",snake)
    for &c in transmute([]u8)constant[:len(snake)] {
        if c>='a' && c<='z' {c-='a'-'A'}
    }
    rest=rest[len(constant):]
    maker=fmt.bprintf(rest,"%s_default",snake)
    for_device=fmt.bprintf(rest[len(maker):],"%s_for_device",snake)
    return
}

// options: each attribute of the declaration by its name, with its value or
// "". editor: its package is of the editor. invalid: the option whose value
// is not one it takes, "replicated" or "setting"; "" when all are.
declared_read :: proc(d:^Declared,options:map[string]string,editor:bool) -> (invalid:string) {
    d^={}
    _,d.shared=options["shared"]
    _,d.host=options["host"]
    _,d.by_world=options["by_world"]
    _,d.single=options["single"]
    _,d.far=options["far"]
    _,d.derived=options["derived"]
    d.was=options["was"] or_else ""
    _,d.queue=options["queue"]
    _,d.persist=options["persist"]
    _,d.keep=options["keep"]
    d.keep||=d.persist
    _,d.presentation=options["presentation"]
    if replicated,has:=options["replicated"];has {
        switch replicated {
        case "":       d.replication=.All
        case "owner":  d.replication=.Owner
        case "others": d.replication=.Others
        case "object": d.replication=.Object
        case:          invalid="replicated"
        }
    }
    if kind,has:=options["setting"];has {
        switch kind {
        case "":        d.setting=.Project
        case "machine": d.setting=.Machine
        case:           if invalid=="" {invalid="setting"}
        }
    }
    d.copy=options["copy"] or_else ""
    d.copy_kept=options["copy_kept"] or_else ""
    d.swap=options["swap"] or_else ""
    d.free=options["free"] or_else ""
    d.reset=options["reset"] or_else ""
    d.lock_names=options["locks"] or_else ""
    d.description=options["description"] or_else ""
    d.place=editor?.Editor:(d.host?.Shared:.World)
    return
}
