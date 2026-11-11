package importer

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"
import "mirai:asset"
import "mirai:std/serial"

// Texts as CSV (RFC 4180, UTF-8), the exchange of mirai texts export and
// import: the first row is "key" and the code of each language
// ("key,es,en,pt-BR"); every other row is a key and its text in each
// language. A field in double quotes may hold commas, line breaks and
// doubled quotes; an empty cell is a text the language does not have.

Strings_Table :: struct {
    languages:[dynamic]asset.String_Language,
    keys:[dynamic]asset.String_Key,
    entries:[dynamic]asset.String_Entry,
    text:[dynamic]u8,
}

// The records of a CSV text, each a list of its fields, and the line each
// starts on. Lines that are empty are no record. message says what is wrong
// and on which line; everything lives in allocator.
csv_records :: proc(text:string,allocator:=context.allocator) -> (records:[][]string,lines:[]int,message:string) {
    text:=strings.trim_prefix(text,"\xef\xbb\xbf") // a byte order mark
    list:=make([dynamic][]string,allocator)
    starts:=make([dynamic]int,allocator)
    fields:=make([dynamic]string,allocator)
    field:=strings.builder_make(allocator)
    line,at:=1,0
    for at<len(text) {
        start:=line
        clear(&fields)
        for {
            strings.builder_reset(&field)
            if at<len(text) && text[at]=='"' {
                at+=1
                for {
                    if at>=len(text) {return nil,nil,fmt.aprintf("line %d: a quoted field is not closed",start,allocator=allocator)}
                    c:=text[at]
                    if c=='"' {
                        if at+1<len(text) && text[at+1]=='"' {strings.write_byte(&field,'"');at+=2;continue}
                        at+=1
                        break
                    }
                    if c=='\n' {line+=1}
                    strings.write_byte(&field,c)
                    at+=1
                }
                if at<len(text) && text[at]!=',' && text[at]!='\n' && !(text[at]=='\r' && at+1<len(text) && text[at+1]=='\n') {
                    return nil,nil,fmt.aprintf("line %d: a quoted field goes on after its closing quote; double the quotes inside it",line,allocator=allocator)
                }
            } else {
                for at<len(text) && text[at]!=',' && text[at]!='\n' && !(text[at]=='\r' && at+1<len(text) && text[at+1]=='\n') {
                    if text[at]=='"' {return nil,nil,fmt.aprintf("line %d: a field with a quote has to be in quotes, with the quote doubled",line,allocator=allocator)}
                    strings.write_byte(&field,text[at])
                    at+=1
                }
            }
            append(&fields,strings.clone(strings.to_string(field),allocator))
            if at<len(text) && text[at]==',' {at+=1;continue}
            if at<len(text) && text[at]=='\r' {at+=1}
            if at<len(text) && text[at]=='\n' {at+=1;line+=1}
            break
        }
        if len(fields)==1 && fields[0]=="" {continue}
        append(&list,slice.clone(fields[:],allocator))
        append(&starts,start)
    }
    return list[:],starts[:],""
}

// A field of a CSV, in quotes when it holds a comma, a quote or a line break.
csv_cell :: proc(b:^strings.Builder,cell:string) {
    if !strings.contains_any(cell,",\"\r\n") {
        strings.write_string(b,cell)
        return
    }
    strings.write_byte(b,'"')
    for i in 0..<len(cell) {
        if cell[i]=='"' {strings.write_byte(b,'"')}
        strings.write_byte(b,cell[i])
    }
    strings.write_byte(b,'"')
}

// The table of a CSV text of texts. message says what is wrong, naming the
// line; it lives in allocator, as the table does.
strings_table :: proc(text:string,allocator:=context.allocator) -> (table:Strings_Table,message:string) {
    if !utf8.valid_string(text) {return {},strings.clone("the file is not UTF-8",allocator)}
    records,lines,failure:=csv_records(text,allocator)
    if failure!="" {return {},failure}
    if len(records)==0 || len(records[0])<2 || !strings.equal_fold(strings.trim_space(records[0][0]),"key") {
        return {},strings.clone("the first row names the columns: key and the code of each language, as in key,es,en",allocator)
    }
    table.languages=make([dynamic]asset.String_Language,allocator)
    table.keys=make([dynamic]asset.String_Key,allocator)
    table.entries=make([dynamic]asset.String_Entry,allocator)
    table.text=make([dynamic]u8,allocator)
    header:=records[0]
    for code,column in header[1:] {
        language:asset.String_Language
        valid:=code!="" && len(code)<len(language.code)
        for c in transmute([]u8)code {valid&&=c>='a' && c<='z' || c>='A' && c<='Z' || c>='0' && c<='9' || c=='-' || c=='_'}
        if !valid {return {},fmt.aprintf("line %d: column %d names the language %q: a code of letters, digits, - and _, as en or pt-BR, of at most %d bytes",lines[0],column+2,code,len(language.code)-1,allocator=allocator)}
        for &earlier in table.languages {
            if serial.text_field(earlier.code[:])==code {return {},fmt.aprintf("line %d: the language %s has two columns",lines[0],code,allocator=allocator)}
        }
        asset.text_set(language.code[:],code)
        append(&table.languages,language)
    }
    named:=make(map[string]int,allocator=allocator)
    for record,row in records[1:] {
        line:=lines[row+1]
        name:=record[0]
        key:asset.String_Key
        if name=="" {return {},fmt.aprintf("line %d: the row has no key",line,allocator=allocator)}
        if len(name)>=len(key.name) {return {},fmt.aprintf("line %d: the key %q is longer than %d bytes",line,name,len(key.name)-1,allocator=allocator)}
        if earlier,seen:=named[name];seen {return {},fmt.aprintf("line %d: the key %s is also on line %d",line,name,earlier,allocator=allocator)}
        if len(record)>len(header) {return {},fmt.aprintf("line %d: the row has %d cells and the first row %d",line,len(record),len(header),allocator=allocator)}
        named[name]=line
        asset.text_set(key.name[:],name)
        append(&table.keys,key)
        for language in 0..<len(table.languages) {
            cell:=record[language+1] if language+1<len(record) else ""
            if cell=="" {continue}
            if len(table.text)+len(cell)>int(max(u32)) {return {},strings.clone("the texts take more than 4 GiB",allocator)}
            append(&table.entries,asset.String_Entry{key=u32(len(table.keys)-1),language=u32(language),offset=u32(len(table.text)),length=u32(len(cell))})
            append(&table.text,cell)
        }
    }
    return table,""
}
