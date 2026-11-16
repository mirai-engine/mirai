package usd

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import importer "mirai:cook/import"

// The text form of USD (USDA) after composition: a tree of prims with
// properties, which the readers of meshes and materials look into.

@(private)
Usd_Token_Kind :: enum {Word,Quoted,Symbol,Newline}

@(private)
Usd_Token :: struct {
    kind:Usd_Token_Kind,
    text:string,
}

@(private)
Usd_Property :: struct {value:[]Usd_Token}

@(private)
Usd_Prim :: struct {
    name,path,type_name:string,
    parent:int,
    properties:map[string]Usd_Property,
    local,world:matrix[4,4]f32,
}

@(private)
Usd_Parser :: struct {
    r:^importer.Reader,
    tokens:[]Usd_Token,
    cursor:int,
    prims:[dynamic]Usd_Prim,
    metadata:map[string]Usd_Property,
    depth:int,
    ok:bool,
}

@(private)
usd_tokens :: proc(r:^importer.Reader,source:string) -> (tokens:[dynamic]Usd_Token,ok:bool) {
    tokens.allocator=context.temp_allocator
    i:=0
    for i<len(source) {
        ch:=source[i]
        if ch==' ' || ch=='\t' || ch=='\r' {i+=1;continue}
        if ch=='\n' {append(&tokens,Usd_Token{.Newline,"\n"});i+=1;continue}
        if ch=='#' {
            for i<len(source) && source[i]!='\n' {i+=1}
            continue
        }
        if ch=='"' || ch=='\'' || ch=='@' || ch=='<' {
            close:=ch
            if ch=='<' {close='>'}
            start:=i+1
            i+=1
            triple:=ch=='"' && i+1<len(source) && source[i]=='"' && source[i+1]=='"'
            if triple {i+=2;start=i}
            found:=false
            for i<len(source) {
                if source[i]=='\\' {i+=2;continue}
                if source[i]==close {
                    if triple && (i+2>=len(source) || source[i+1]!='"' || source[i+2]!='"') {i+=1;continue}
                    append(&tokens,Usd_Token{.Quoted,source[start:min(i,len(source))]})
                    i+=1
                    if triple {i+=2}
                    found=true
                    break
                }
                i+=1
            }
            if !found {return tokens,importer.fail(r,.Malformed,"unterminated string or path in the USD text")}
            continue
        }
        if ch=='{' || ch=='}' || ch=='[' || ch==']' || ch=='(' || ch==')' || ch=='=' || ch==',' || ch==';' {
            append(&tokens,Usd_Token{.Symbol,source[i:i+1]})
            i+=1
            continue
        }
        start:=i
        for i<len(source) {
            b:=source[i]
            if b==' ' || b=='\t' || b=='\r' || b=='\n' || b=='{' || b=='}' || b=='[' || b==']' || b=='(' || b==')' || b=='=' || b==',' || b==';' {break}
            i+=1
        }
        append(&tokens,Usd_Token{.Word,source[start:i]})
    }
    return tokens,true
}

@(private="file")
skip_newlines :: proc(p:^Usd_Parser) {
    for p.cursor<len(p.tokens) && p.tokens[p.cursor].kind==.Newline {p.cursor+=1}
}

@(private="file")
parse_property :: proc(p:^Usd_Parser,properties:^map[string]Usd_Property,closing:string) {
    start:=p.cursor
    equals:=-1
    bracket:=0
    for p.cursor<len(p.tokens) {
        t:=p.tokens[p.cursor]
        if t.text=="=" && bracket==0 {equals=p.cursor;break}
        if t.text=="[" {bracket+=1}
        if t.text=="]" {bracket-=1}
        if (t.kind==.Newline || t.text==closing) && bracket==0 {break}
        p.cursor+=1
    }
    if equals<0 {
        if p.cursor==start && p.cursor<len(p.tokens) && p.tokens[p.cursor].text!=closing {p.cursor+=1}
        return
    }
    name:=""
    // Array type brackets precede the actual property name.
    for t in p.tokens[start:equals] {
        if t.kind==.Word || t.kind==.Quoted {name=t.text}
    }
    p.cursor=equals+1
    value_start:=p.cursor
    depth:=0
    for p.cursor<len(p.tokens) {
        t:=p.tokens[p.cursor]
        if depth==0 && (t.kind==.Newline || t.text==closing || t.text==";") {break}
        if t.text=="[" || t.text=="(" || t.text=="{" {depth+=1}
        if t.text=="]" || t.text==")" || t.text=="}" {depth-=1}
        if depth<0 {break}
        p.cursor+=1
    }
    if name!="" {properties[name]=Usd_Property{p.tokens[value_start:p.cursor]}}
}

@(private="file")
parse_prim :: proc(p:^Usd_Parser,parent:int) {
    r:=p.r
    if p.depth>=importer.MAX_DEPTH {p.ok=importer.fail(r,.Limit,"the USD prims nest deeper than %d levels",importer.MAX_DEPTH);return}
    p.depth+=1
    defer p.depth-=1
    p.cursor+=1
    skip_newlines(p)
    if p.cursor>=len(p.tokens) {p.ok=importer.fail(r,.Malformed,"a USD prim has no declaration");return}
    type_name:=""
    if p.tokens[p.cursor].kind!=.Quoted {type_name=p.tokens[p.cursor].text;p.cursor+=1}
    if p.cursor>=len(p.tokens) || p.tokens[p.cursor].kind!=.Quoted {p.ok=importer.fail(r,.Malformed,"a USD prim has no quoted name");return}
    name:=p.tokens[p.cursor].text
    p.cursor+=1
    path:=fmt.tprintf("/%s",name)
    if parent>=0 {path=fmt.tprintf("%s/%s",p.prims[parent].path,name)}
    properties:=make(map[string]Usd_Property,context.temp_allocator)
    skip_newlines(p)
    if p.cursor<len(p.tokens) && p.tokens[p.cursor].text=="(" {
        p.cursor+=1
        for p.cursor<len(p.tokens) && p.tokens[p.cursor].text!=")" {
            skip_newlines(p)
            if p.cursor<len(p.tokens) && p.tokens[p.cursor].text!=")" {parse_property(p,&properties,")")}
        }
        p.cursor+=1
    }
    skip_newlines(p)
    if p.cursor>=len(p.tokens) || p.tokens[p.cursor].text!="{" {p.ok=importer.fail(r,.Malformed,"the USD prim %s has no body",path);return}
    p.cursor+=1
    index:=len(p.prims)
    append(&p.prims,Usd_Prim{name=name,path=path,type_name=type_name,parent=parent,properties=properties})
    for p.cursor<len(p.tokens) && p.ok {
        skip_newlines(p)
        if p.cursor>=len(p.tokens) {break}
        text:=p.tokens[p.cursor].text
        if text=="}" {p.cursor+=1;return}
        if text=="def" || text=="over" {
            parse_prim(p,index)
        } else if text=="class" {
            p.ok=importer.fail(r,.Unsupported,"USD class prims are unsupported after flattening")
            return
        } else {
            parse_property(p,&p.prims[index].properties,"}")
        }
    }
    if p.ok {p.ok=importer.fail(r,.Malformed,"the USD prim %s is not closed",path)}
}

// The prims and the metadata of the layer.
@(private)
usd_parse :: proc(r:^importer.Reader,source:string) -> (p:Usd_Parser,ok:bool) {
    tokens:=usd_tokens(r,source) or_return
    p={r=r,tokens=tokens[:],ok=true}
    p.prims.allocator=context.temp_allocator
    p.metadata=make(map[string]Usd_Property,context.temp_allocator)
    for p.cursor<len(p.tokens) && p.ok {
        skip_newlines(&p)
        if p.cursor>=len(p.tokens) {break}
        text:=p.tokens[p.cursor].text
        if text=="(" {
            p.cursor+=1
            for p.cursor<len(p.tokens) && p.tokens[p.cursor].text!=")" {
                skip_newlines(&p)
                if p.cursor<len(p.tokens) && p.tokens[p.cursor].text!=")" {parse_property(&p,&p.metadata,")")}
            }
            p.cursor+=1
        } else if text=="def" || text=="over" {
            parse_prim(&p,-1)
        } else {
            p.cursor+=1
        }
    }
    return p,p.ok && r.code==.None
}

@(private)
usd_numbers :: proc(r:^importer.Reader,property:Usd_Property) -> (values:[]f64,ok:bool) {
    out:=make([dynamic]f64,context.temp_allocator)
    depth:=0
    for t,i in property.value {
        // Property metadata follows the attribute value in parentheses of its importer.own, e.g. interpolation.
        if t.kind==.Symbol && t.text=="(" && depth==0 && i>0 {break}
        if t.text=="[" || t.text=="(" {depth+=1}
        if t.text=="]" || t.text==")" {depth-=1}
        if t.kind==.Word {
            value,parsed:=strconv.parse_f64(t.text)
            if !parsed {return nil,importer.fail(r,.Malformed,"a USD attribute expects numbers, found %s",t.text)}
            if value-value!=0 {return nil,importer.fail(r,.Malformed,"a USD numeric attribute holds a value that is not finite")}
            append(&out,value)
        }
    }
    return out[:],true
}

@(private)
usd_string :: proc(property:Usd_Property) -> string {
    for t in property.value {
        if t.kind==.Quoted || t.kind==.Word {return t.text}
    }
    return ""
}

@(private)
usd_strings :: proc(property:Usd_Property) -> []string {
    out:=make([dynamic]string,context.temp_allocator)
    for t in property.value {
        if t.kind==.Quoted {append(&out,t.text)}
    }
    return out[:]
}

@(private)
usd_interpolation :: proc(property:Usd_Property,fallback:string) -> string {
    for t,i in property.value {
        if t.text=="interpolation" && i+2<len(property.value) {return property.value[i+2].text}
    }
    return fallback
}

@(private)
usd_vec3s :: proc(r:^importer.Reader,property:Usd_Property) -> (out:[][3]f32,ok:bool) {
    values:=usd_numbers(r,property) or_return
    if len(values)%3!=0 {return nil,importer.fail(r,.Malformed,"a USD vector array is not a multiple of three numbers")}
    out=make([][3]f32,len(values)/3,context.temp_allocator)
    for &v,i in out {v={f32(values[i*3]),f32(values[i*3+1]),f32(values[i*3+2])}}
    return out,true
}

@(private)
usd_vec2s :: proc(r:^importer.Reader,property:Usd_Property) -> (out:[][2]f32,ok:bool) {
    values:=usd_numbers(r,property) or_return
    if len(values)%2!=0 {return nil,importer.fail(r,.Malformed,"a USD vector array is not a multiple of two numbers")}
    out=make([][2]f32,len(values)/2,context.temp_allocator)
    for &v,i in out {v={f32(values[i*2]),f32(values[i*2+1])}}
    return out,true
}

@(private)
usd_ints :: proc(r:^importer.Reader,property:Usd_Property) -> (out:[]int,ok:bool) {
    values:=usd_numbers(r,property) or_return
    out=make([]int,len(values),context.temp_allocator)
    for v,i in values {
        if v!=math.floor(v) || abs(v)>2147483647 {return nil,importer.fail(r,.Malformed,"an integer of the USD topology is invalid")}
        out[i]=int(v)
    }
    return out,true
}

// The values of a primvar after its indices, and what each one belongs to: the
// mesh (constant), a face (uniform), a point (vertex, varying) or a corner of a
// face (faceVarying). An empty primvar counts as one that is not there.
@(private)
usd_primvar :: proc(r:^importer.Reader,prim:Usd_Prim,name:string,values:[]$T,fallback:string,faces,points,corners:int) -> (unpacked:[]T,interpolation:string,ok:bool) {
    interpolation=usd_interpolation(prim.properties[name],fallback)
    if len(values)==0 {return nil,interpolation,true}
    unpacked=values
    if index_property,indexed:=prim.properties[fmt.tprintf("%s:indices",name)];indexed {
        value_indices:=usd_ints(r,index_property) or_return
        unpacked=make([]T,len(value_indices),context.temp_allocator)
        for v,i in value_indices {
            if v<0 || v>=len(values) {return nil,interpolation,importer.fail(r,.Malformed,"an index of %s is outside its values",name)}
            unpacked[i]=values[v]
        }
    }
    expected:=1
    switch interpolation {
    case "constant":
    case "uniform": expected=faces
    case "vertex","varying": expected=points
    case "faceVarying": expected=corners
    case: return nil,interpolation,importer.fail(r,.Unsupported,"%s has the interpolation %s, which is unsupported",name,interpolation)
    }
    if len(unpacked)!=expected {return nil,interpolation,importer.fail(r,.Malformed,"%s has %d values, which does not match its interpolation %s",name,len(unpacked),interpolation)}
    return unpacked,interpolation,true
}

@(private)
usd_primvar_index :: proc(interpolation:string,face,point,corner:int) -> int {
    switch interpolation {
    case "uniform": return face
    case "vertex","varying": return point
    case "faceVarying": return corner
    }
    return 0
}
