package core

import "base:runtime"

// Ids with names. A distinct integer type declared @(names) has as its values
// the constants of that type the generator finds in any package of the
// project; the code is where they are declared, and data (a scene, a setting)
// and the API name them. A value is saved as its number, so a
// name can change without touching what was saved. @(names="PREFIX_") takes
// the prefix off the identifiers; @(name="...") on a constant gives its name.
// A type @(name_bits="T") is a mask whose bit i is the value i of T.
//
// The values of a type @(names,actions) are not constants: each library
// declares its actions as an enum @(actions), and the generator gives the
// members of each enum the next free values, the libraries in order (the
// engine, the active plugins, the game). Their names are those of the
// members, in lower case. Those numbers move when a library adds an action,
// so saved data keeps the name of an action, and of each bit of its masks, as
// it keeps the member of an enum.

// A type @(names): where the editor declares a new value of it.
Named_Type_Info :: struct {
    type:typeid,
    name:string,   // of the type
    path:string,   // import path of its package: plugins:physics/runtime
    prefix:string, // its constants start with it
    limit:i64,     // its values are below it: what the integer holds, or the smallest mask @(name_bits) of them
    actions:bool,  // @(names,actions): the generator numbers its values, and saved data keeps their names
}

// A constant of a type @(names).
Name_Info :: struct {
    type:typeid,    // the @(names) type
    value:i64,
    name:string,    // how data and the API call it
    library:string, // the package that declares it
    file:string,    // where it is declared, for whoever renames it
    line:int,
    named:bool,     // its name is a @(name="...") of the constant, not its identifier
    project:bool,   // declared by the project, which the editor may change; else by the engine or a plugin
    requires:typeid, // @(name_requires): the component an entity needs to take this value; nil: none
}

// An enum @(actions): its member i is the value base+i of the type @(names,actions).
// defaults writes the [E]Action_Bindings of engine/input that its package
// declares beside it, <ENUM>_DEFAULTS or <enum>_defaults(); nil without one.
Actions_Info :: struct {
    type:typeid,
    info:^runtime.Type_Info,
    base:i64,
    library:string, // the package that declares it
    defaults:proc(dst:rawptr),
}

// A mask of a type @(name_bits): bit i is the value i of of.
Name_Bits_Info :: struct {
    type,of:typeid,
}

// The constants of a type @(names), by value; none when it is not one.
names_of :: proc(info:^World_Info,type:typeid) -> []Name_Info {
    if info==nil {return nil}
    first:=-1
    for entry,i in info.names {
        if entry.type!=type {
            if first>=0 {return info.names[first:i]}
            continue
        }
        if first<0 {first=i}
    }
    return first>=0?info.names[first:]:nil
}

// What the World knows of a type @(names); nil when it is not one.
named_type_of :: proc(info:^World_Info,type:typeid) -> ^Named_Type_Info {
    if info==nil {return nil}
    for &entry in info.named_types {
        if entry.type==type {return &entry}
    }
    return nil
}

// What the World knows of an enum @(actions); nil when it is not one.
actions_of :: proc(info:^World_Info,type:typeid) -> ^Actions_Info {
    if info==nil {return nil}
    for &entry in info.actions {
        if entry.type==type {return &entry}
    }
    return nil
}

// The name of a value of a type @(names).
name_of :: proc(info:^World_Info,type:typeid,value:i64) -> (string,bool) {
    for entry in names_of(info,type) {
        if entry.value==value {return entry.name,true}
    }
    return "",false
}

// The value of a name of a type @(names).
name_value :: proc(info:^World_Info,type:typeid,name:string) -> (i64,bool) {
    for entry in names_of(info,type) {
        if entry.name==name {return entry.value,true}
    }
    return 0,false
}

// The type @(names) whose values name the bits of a mask type; nil when it is not one.
name_bits_of :: proc(info:^World_Info,type:typeid) -> typeid {
    if info==nil {return nil}
    for entry in info.name_bits {
        if entry.type==type {return entry.of}
    }
    return nil
}
