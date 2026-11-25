package records

import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:std/base"
import "mirai:std/serial"

// The columns of a type as the records.* methods of the editor and mirai
// records take them, by the names of their kinds.

// The name of each kind of column.
KIND_NAMES :: [asset.Records_Kind]string{.Int="int",.Float="float",.Bool="bool",.Enum="enum",.Asset="asset",.Text="text",.String="string",.Record="record",.Type="type"}

// A column as records.create, records.column.add and records.column.set take it.
Column_Params :: struct {
    name:string `mirai:"optional,label=The name of the field: a word of ASCII letters, digits and _ that starts with a letter; a new name keeps the values of the rows"`,
    kind:string `mirai:"optional,label=int, float, bool, enum, asset, text (a key of the .strings of the game), string (a text of the row itself), record (a row of a table) or type (a type the code of its package declares)"`,
    count:int `mirai:"optional,label=A fixed array of this many values; 0: one value"`,
    length:int `mirai:"optional,label=Of a string: its bytes, its end included"`,
    min:serial.Json `mirai:"optional,label=Of an int or a float: the least value; null: none"`,
    max:serial.Json `mirai:"optional,label=Of an int or a float: the most value; null: none"`,
    unit:string `mirai:"optional,label=Of an int or a float: what it counts, as s or m/s"`,
    type:string `mirai:"optional,label=Of an enum: the name of its enum (Item_Rarity); of a record: the record type of the rows it names; of a type: a struct, enum or bit set the code of the package declares"`,
    values:[]string `mirai:"optional,label=Of an enum: the names of its values, in order; a row keeps its value by its name"`,
    asset_kind:string `mirai:"optional,label=Of an asset: the extensions it takes, separated by spaces (.tex)"`,
    description:string `mirai:"optional"`,
    default:serial.Json `mirai:"optional,label=What a new row holds in it, as records.set takes the field; a column added gives it to the rows there are too"`,
}

// Puts the options of params over a column: those whose keys given names
// (the keys of the params, null among them), or every one set when the column
// is new (given nil). message says which does not fit and how to fix it.
column_put :: proc(c:^asset.Records_Column,e:^Edit,p:^Column_Params,given_keys:[]string,new:bool) -> (message:string) {
    Given :: struct {keys:[]string,new:bool}
    keys:=Given{given_keys,new}
    given :: proc(keys:Given,name:string,set:bool) -> bool {
        if keys.new {return set}
        for key in keys.keys {
            if key==name {return true}
        }
        return false
    }
    if given(keys,"name",p.name!="") {
        c.name={}
        if !base.text_set(c.name[:],p.name) {return fmt.tprintf("name %q is longer than %d bytes",p.name,asset.RECORDS_NAME-1)}
    }
    if given(keys,"kind",p.kind!="") {
        kinds:=KIND_NAMES
        found:=false
        for name,kind in kinds {
            if strings.equal_fold(name,strings.trim_space(p.kind)) {
                kind_set(e,c,kind)
                found=true
            }
        }
        if !found {return fmt.tprintf("kind %q is not one there is: give int, float, bool, enum, asset, text, string, record or type",p.kind)}
    }
    if given(keys,"count",p.count!=0) {
        if p.count<0 || p.count>asset.RECORDS_COUNT {return fmt.tprintf("count %d is not from 0 (one value) to %d",p.count,asset.RECORDS_COUNT)}
        c.count=u16(p.count)
    }
    if given(keys,"length",p.length!=0) {
        if p.length<2 || p.length>asset.RECORDS_LENGTH {return fmt.tprintf("length %d is not from 2 to %d bytes",p.length,asset.RECORDS_LENGTH)}
        c.length=u16(p.length)
    }
    bound :: proc(text:serial.Json,has:^bool,value:^f64,name:string) -> string {
        trimmed:=strings.trim_space(string(text))
        if trimmed=="" || trimmed=="null" {
            has^=false
            return ""
        }
        number,ok:=strconv.parse_f64(trimmed)
        if !ok {return fmt.tprintf("%s %s is not a number, nor null for none",name,trimmed)}
        has^,value^=true,number
        return ""
    }
    if given(keys,"min",p.min!="") {
        if message=bound(p.min,&c.has_min,&c.min,"min");message!="" {return}
    }
    if given(keys,"max",p.max!="") {
        if message=bound(p.max,&c.has_max,&c.max,"max");message!="" {return}
    }
    text :: proc(field:[]u8,value,name:string) -> string {
        mem.zero_slice(field)
        if !base.text_set(field,value) {return fmt.tprintf("%s is longer than %d bytes",name,len(field)-1)}
        return ""
    }
    if given(keys,"unit",p.unit!="") {if message=text(c.unit[:],p.unit,"unit");message!="" {return}}
    if given(keys,"type",p.type!="") {if message=text(c.type[:],p.type,"type");message!="" {return}}
    if given(keys,"values",len(p.values)>0) {if message=text(c.values[:],strings.join(p.values," ",context.temp_allocator),"values");message!="" {return}}
    if given(keys,"asset_kind",p.asset_kind!="") {if message=text(c.asset_kind[:],p.asset_kind,"asset_kind");message!="" {return}}
    if given(keys,"description",p.description!="") {if message=text(c.description[:],p.description,"description");message!="" {return}}
    return ""
}

// Puts the default params give a column into the defaults of the table; with
// rows, the rows there are take it too. info, registry, types and files: what
// a reference of the default is read against (context_make).
column_default :: proc(e:^Edit,info:^core.World_Info,registry:^asset.Registry,types:^asset.Types,files:[]Table_File,name:string,value:serial.Json,rows:bool) -> (message:string) {
    if strings.trim_space(string(value))=="" {return ""}
    at:=column_find(e,name)
    field,_:=column_field(e,at)
    c,_:=context_make(e,info,registry,types,files)
    text:=fmt.tprintf(`{{%q:%s}}`,name,string(value))
    if message=values_put(&c,e.defaults,text);message!="" {return fmt.tprintf("default: %s",message)}
    if rows {
        size:=int(e.schema.types[field.type].size)
        for row in 0..<row_count(e) {copy(row_bytes(e,row)[field.offset:][:size],e.defaults[field.offset:][:size])}
    }
    return ""
}
