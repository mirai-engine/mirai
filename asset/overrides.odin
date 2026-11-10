package asset

import "core:slice"
import "core:strings"
import "mirai:std/serial"

// Overrides: what a value holds on its own over a base it follows. A member
// of a prefab instance over the prefab as the instance was last brought up to
// date, a material an import wrote over what its source gave then. Marking
// compares the value with its base leaf by leaf; following the next base
// takes all of it except the parts marked, which keep the value's.

// A field that holds data: a number, a vector, an enum, a text, an id.
Value_Leaf :: struct {
    path:string, // "roughness", "coat.weight", "maps.normal.texture"
    offset,size:int,
}

// The leaves of a type, without its transient fields. Paths from the temporary allocator.
value_leaves :: proc(schema:^serial.Schema,type:serial.Type_Index,out:^[dynamic]Value_Leaf) {
    leaves_add(schema,type,"",0,out)
}

@(private="file")
leaves_add :: proc(schema:^serial.Schema,type:serial.Type_Index,prefix:string,offset:u32,out:^[dynamic]Value_Leaf) {
    t:=schema.types[type]
    if t.kind!=.Struct {
        append(out,Value_Leaf{prefix,int(offset),int(t.size)})
        return
    }
    for field in schema.fields[t.first:][:t.count] {
        if .Transient in field.flags {continue}
        path:=prefix==""?field.name:strings.concatenate({prefix,".",field.name},context.temp_allocator)
        leaves_add(schema,field.type,path,offset+field.offset,out)
    }
}

// The paths of the leaves where a value differs from its base: what it holds on its own.
overrides_mark :: proc(leaves:[]Value_Leaf,value,base:[]u8,out:^[dynamic]string) {
    for leaf in leaves {
        if !slice.equal(value[leaf.offset:][:leaf.size],base[leaf.offset:][:leaf.size]) {append(out,leaf.path)}
    }
}

// Copies the part a path names ("" is all) from a value to an image of the
// same type, as an override keeps it over the next base. False when the path
// names no part of the type.
override_keep :: proc(schema:^serial.Schema,type:serial.Type_Index,value,image:[]u8,path:string) -> bool {
    _,from,from_error:=serial.value_slice(schema,type,value,path)
    _,to,to_error:=serial.value_slice(schema,type,image,path)
    if from_error!=.None || to_error!=.None {return false}
    copy(to,from)
    return true
}
