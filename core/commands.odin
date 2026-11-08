package core

// What a function receives to make entities with components of any library,
// as a prefab, a chunk or a piece have: it creates and destroys entities,
// gives them rows of tables it does not write and takes rows away, at the end
// of the function. A row that exists belongs to whoever writes its table, so
// commands only give a row to an entity that lacks it; commands_added reads
// and writes what waits, to finish making it in the same function. The
// generator binds core.Commands and settles every table after the function.
Commands :: struct {
    entities:^Entities,
    data:rawptr, // the World
    info:^World_Info,
}

commands :: #force_inline proc "contextless" (data:rawptr,info:^World_Info) -> Commands {
    return {cast(^Entities)(uintptr(data)+info.entities),data,info}
}

// The commands of a World that generic code holds whole.
commands_of :: #force_inline proc "contextless" (w:World_Ref) -> Commands {return commands(w.data,w.info)}

commands_create :: proc(c:Commands) -> Entity {return create(c.entities)}

commands_destroy :: proc(c:Commands,e:Entity) -> bool {return destroy(c.entities,e)}

// Gives the entity a row of T at the end of the function. An entity that has
// one already keeps it: its table has its writer.
commands_add :: proc(c:Commands,e:Entity,value:$T) {
    t:=world_table_of(World_Ref{c.data,c.info,.World},T)
    if t==nil {
        fail("%v is no component of this World: declare it @(component) in a library",typeid_of(T))
        return
    }
    if raw_row(raw(t),e)>=0 {
        fail("commands give a %s only to an entity without one, and %v has one: write it with ^core.Table(%s) or ask the library that writes it",t.name,e,t.name)
        return
    }
    add(t,e,value)
}

// What a new row of T starts as in this World; zero when T is no component of it.
commands_default :: proc(c:Commands,$T:typeid) -> (value:T) {
    if t:=world_table_of(World_Ref{c.data,c.info,.World},T);t!=nil {value=table_default(t)}
    return
}

// Gives the entity a row of T at its default, as commands_add does.
commands_add_default :: proc(c:Commands,e:Entity,$T:typeid) {commands_add(c,e,commands_default(c,T))}

// Takes the row of T from the entity at the end of the function.
commands_remove :: proc(c:Commands,e:Entity,$T:typeid) {
    if t:=world_table_of(World_Ref{c.data,c.info,.World},T);t!=nil {remove(t,e)}
}

// The row of T an add of this function waits to give the entity; nil without one.
commands_added :: proc(c:Commands,e:Entity,$T:typeid) -> ^T {
    t:=world_table_of(World_Ref{c.data,c.info,.World},T)
    return t!=nil?added(t,e):nil
}
