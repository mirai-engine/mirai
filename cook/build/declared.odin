package build

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "mirai:project"
import "mirai:std/base"

// What compiles against the declarations of the engine follows the
// declarations it names, not the packages that hold them. declare leaves, per
// package, a line for each declaration with the hash of its text and the
// names that text carries (DECLARED_NAMES). From those, each declaration gets
// the hash of itself and of every declaration it reaches through them: a type
// with the types of its fields, a procedure with the types of its signature,
// an inline body with what it calls. A library, a program or a plugin hashes
// the ones its own sources name (declared_names, declared_key): a field added
// to a struct builds again what reaches that struct, and nothing else.
//
// A name counts wherever it is written, also where a local name hides it or
// inside a comment: more is followed, never less. What reaches a struct
// through a pointer follows it too, since nothing in a text says that its
// fields are left alone.

// Beside the declarations of a package: what each declares and names.
@(private)
DECLARED_NAMES :: "declared.names"

// The line of what every declaration of a package is read with: the tags of its files.
@(private)
DECLARED_HEAD :: "."

// Of each declaration of the engine, by `<package>.<name>`, the hash of what
// whoever names it compiles against. `<package>.` is the head of a package.
@(private)
Declared :: struct {
    hashes:map[string]u64,
    known:bool, // read from the index a build of the engine wrote
}

@(private="file")
Declared_Node :: struct {
    key:string,
    own:u64,
    edges:[dynamic]int,
    index,low,component:int,
    stacked:bool,
}

// Reads DECLARED_NAMES of every package of the engine under decl and writes
// to file the hash of each declaration with what it reaches. False when it
// cannot be written.
@(private)
declared_write :: proc(decl,file:string) -> bool {
    nodes:=make([dynamic]Declared_Node,context.temp_allocator)
    ids:=make(map[string]int,context.temp_allocator)
    node :: proc(nodes:^[dynamic]Declared_Node,ids:^map[string]int,key:string) -> int {
        if id,found:=ids[key];found {return id}
        id:=len(nodes)
        append(nodes,Declared_Node{key=key,edges=make([dynamic]int,context.temp_allocator),index=-1,component=-1})
        ids[key]=id
        return id
    }
    texts:[ENGINE_PACKAGE_COUNT]string
    for &text,index in texts {
        path:=engine_package(index)
        data,error:=os.read_entire_file(project.path(decl,path,DECLARED_NAMES,allocator=context.temp_allocator),context.temp_allocator)
        if error!=nil {continue}
        text=string(data)
        head:=node(&nodes,&ids,fmt.tprintf("%s.",path))
        rest:=text
        for line in strings.split_lines_iterator(&rest) {
            name,hash:=declared_line(line) or_continue
            id:=name==DECLARED_HEAD?head:node(&nodes,&ids,fmt.tprintf("%s.%s",path,name))
            nodes[id].own=base.hash_combine(nodes[id].own,hash)
            if id!=head {append(&nodes[id].edges,head)}
        }
    }
    // Every declaration is known by now: a bare name that is none of its package is a local one.
    for text,index in texts {
        path:=engine_package(index)
        rest:=text
        for line in strings.split_lines_iterator(&rest) {
            name,_:=declared_line(line) or_continue
            if name==DECLARED_HEAD {continue}
            id:=ids[fmt.tprintf("%s.%s",path,name)]
            fields:=line
            skipped:=0
            for ref in strings.fields_iterator(&fields) {
                if skipped<2 {skipped+=1;continue}
                if strings.index_byte(ref,'.')>=0 {
                    // Of another package, declared or not: one that is not yet moves what names it once it is.
                    append(&nodes[id].edges,node(&nodes,&ids,ref))
                } else if to,found:=ids[fmt.tprintf("%s.%s",path,ref)];found && to!=id {
                    append(&nodes[id].edges,to)
                }
            }
        }
    }
    hashes:=declared_reach(nodes[:])
    lines:=make([dynamic]string,0,len(nodes),context.temp_allocator)
    for n,id in nodes {append(&lines,fmt.tprintf("%s %x",n.key,hashes[id]))}
    slice.sort(lines[:])
    _,error:=write_changed(file,strings.join(lines[:],"\n",context.temp_allocator))
    return error==nil
}

@(private="file")
declared_line :: proc(line:string) -> (name:string,hash:u64,ok:bool) {
    space:=strings.index_byte(line,' ')
    if space<=0 {return}
    name=line[:space]
    rest:=line[space+1:]
    if end:=strings.index_byte(rest,' ');end>=0 {rest=rest[:end]}
    hash=strconv.parse_u64_of_base(rest,16) or_return
    return name,hash,true
}

// Of each node, the hash of itself and of every node it reaches. The nodes
// that reach each other (a type that names itself through another) are one
// component and share one hash; a component is closed once the ones it
// reaches are, so each takes theirs.
@(private="file")
declared_reach :: proc(nodes:[]Declared_Node) -> []u64 {
    hashes:=make([]u64,len(nodes),context.temp_allocator)
    components:=make([dynamic]u64,context.temp_allocator)
    Frame :: struct {node,edge:int}
    frames:=make([dynamic]Frame,context.temp_allocator)
    stack:=make([dynamic]int,context.temp_allocator)
    reached:=make([dynamic]u64,context.temp_allocator)
    members:=make([dynamic][2]u64,context.temp_allocator)
    member_ids:=make([dynamic]int,context.temp_allocator)
    next:=0
    for &start,first in nodes {
        if start.index>=0 {continue}
        append(&frames,Frame{first,0})
        for len(frames)>0 {
            frame:=&frames[len(frames)-1]
            n:=&nodes[frame.node]
            if frame.edge==0 && n.index<0 {
                n.index,n.low=next,next
                next+=1
                append(&stack,frame.node)
                n.stacked=true
            }
            if frame.edge<len(n.edges) {
                to:=n.edges[frame.edge]
                frame.edge+=1
                if nodes[to].index<0 {
                    append(&frames,Frame{to,0})
                } else if nodes[to].stacked {
                    n.low=min(n.low,nodes[to].index)
                }
                continue
            }
            closed:=frame.node
            pop(&frames)
            if len(frames)>0 {
                parent:=&nodes[frames[len(frames)-1].node]
                parent.low=min(parent.low,n.low)
            }
            if n.low!=n.index {continue}
            component:=len(components)
            clear(&members)
            clear(&member_ids)
            clear(&reached)
            for {
                member:=pop(&stack)
                nodes[member].stacked=false
                nodes[member].component=component
                append(&members,[2]u64{base.name_hash(nodes[member].key),nodes[member].own})
                append(&member_ids,member)
                if member==closed {break}
            }
            append(&components,0)
            slice.sort_by(members[:],proc(a,b:[2]u64) -> bool {return a[0]<b[0] || a[0]==b[0] && a[1]<b[1]})
            hash:u64=1
            for member in members {hash=base.hash_combine(base.hash_combine(hash,member[0]),member[1])}
            // The edges of a member go to this component or to one closed before it.
            for member in member_ids {
                for to in nodes[member].edges {
                    if nodes[to].component!=component {append(&reached,components[nodes[to].component])}
                }
            }
            slice.sort(reached[:])
            previous:u64
            for other,at in reached {
                if at>0 && other==previous {continue}
                hash=base.hash_combine(hash,other)
                previous=other
            }
            components[component]=hash
        }
    }
    for n,id in nodes {hashes[id]=components[n.component]}
    return hashes
}

// The index a build of the engine left in file. Without one nothing is known,
// and what compiles against the declarations follows every build of the engine.
@(private)
declared_read :: proc(file:string,allocator:=context.allocator) -> (declared:Declared) {
    declared.hashes=make(map[string]u64,allocator)
    data,error:=os.read_entire_file(file,context.temp_allocator)
    if error!=nil {return}
    rest:=string(data)
    for line in strings.split_lines_iterator(&rest) {
        space:=strings.index_byte(line,' ')
        if space<=0 {continue}
        hash,parsed:=strconv.parse_u64_of_base(line[space+1:],16)
        if !parsed {continue}
        declared.hashes[strings.clone(line[:space],allocator)]=hash
    }
    declared.known=len(declared.hashes)>0
    return
}

// Adds to names the declarations of the engine a source names, each as its
// key: of every package it imports, the head and whatever follows the name
// it gives the package and a dot. A literal that names a package counts only
// after `import` and the name it may give it: the text of a program a source
// carries imports nothing. The packages of skip are not followed: they are
// compiled with the source. A package of the engine imports only the ones
// before it, those under limit. reached, when given, marks the packages imported. followed is
// false when the source names declarations decl has that are of no package
// of the engine: what imports them compiles against something no hash follows.
@(private)
declared_names :: proc(decl,source:string,skip:[]string,names:^map[string]bool,reached:^[ENGINE_PACKAGE_COUNT]bool=nil,limit:=ENGINE_PACKAGE_COUNT) -> (followed:bool) {
    followed=true
    Alias :: struct {name,path:string}
    aliases:=make([dynamic]Alias,context.temp_allocator)
    at:=0
    for {
        found:=strings.index(source[at:],ENGINE_COLLECTION)
        if found<0 {break}
        start:=at+found
        at=start+len(ENGINE_COLLECTION)
        quote:=source[start-1] if start>0 else 0
        if quote!='"' && quote!='`' || start>1 && source[start-2]=='\\' {continue}
        end:=strings.index_byte(source[at:],quote)
        if end<=0 {continue}
        path:=source[at:at+end]
        index,is_package:=engine_package_index(path)
        if !is_package {
            if import_path(path) && len(engine_sources(decl,{path}))>0 {followed=false}
            continue
        }
        if index>=limit {continue}
        // `import "mirai:core"` or `import name "mirai:core"`: anything else is no import.
        before:=strings.trim_right(source[:start-1]," \t")
        first:=word_before(before)
        name:=""
        if first=="import" {
            name=path[strings.last_index_byte(path,'/')+1:]
        } else if first!="" && word_before(strings.trim_right(before[:len(before)-len(first)]," \t"))=="import" {
            name=first
        }
        if name=="" {continue}
        if reached!=nil {reached[index]=true}
        if slice.contains(skip,path) {continue}
        names[strings.concatenate({path,"."},context.temp_allocator)]=true
        if name!="_" {append(&aliases,Alias{name,path})}
    }
    for alias in aliases {
        at=0
        for {
            found:=strings.index(source[at:],alias.name)
            if found<0 {break}
            start:=at+found
            at=start+len(alias.name)
            if start>0 && name_byte(source[start-1]) {continue}
            dot:=blank_skip(source,at)
            if dot>=len(source) || source[dot]!='.' {continue}
            first:=blank_skip(source,dot+1)
            last:=first
            for last<len(source) && name_byte(source[last]) {last+=1}
            if last==first {continue}
            names[strings.concatenate({alias.path,".",source[first:last]},context.temp_allocator)]=true
        }
    }
    return

    word_before :: proc(text:string) -> string {
        start:=len(text)
        for start>0 && name_byte(text[start-1]) {start-=1}
        return text[start:]
    }
    blank_skip :: proc(text:string,from:int) -> int {
        at:=from
        for at<len(text) && (text[at]==' ' || text[at]=='\t' || text[at]=='\n' || text[at]=='\r') {at+=1}
        return at
    }
}

@(private)
name_byte :: proc(c:u8) -> bool {
    switch c {
    case 'a'..='z','A'..='Z','0'..='9','_',0x80..=0xff: return true
    }
    return false
}

// Whether a literal can be the path of an import: a field tag, a format or a
// message is not, and is not looked for in the declarations.
@(private)
import_path :: proc(path:string) -> bool {
    for c in transmute([]u8)path {
        switch c {
        case 'a'..='z','A'..='Z','0'..='9','_','-','.','/':
        case: return false
        }
    }
    return true
}

// The names of the files given, with declared_names.
@(private)
declared_names_of :: proc(decl:string,files:[]string,skip:[]string,names:^map[string]bool,reached:^[ENGINE_PACKAGE_COUNT]bool=nil,limit:=ENGINE_PACKAGE_COUNT) -> (followed:bool) {
    followed=true
    for file in files {
        data,error:=os.read_entire_file(file,context.temp_allocator)
        followed&&=error==nil && declared_names(decl,string(data),skip,names,reached,limit)
    }
    return
}

// The hash of the declarations named, as the index has them: what whoever
// names them is built again by. One the index does not have counts as
// missing, and moves the hash when it is declared.
@(private)
declared_key :: proc(declared:^Declared,names:map[string]bool) -> u64 {
    keys,_:=slice.map_keys(names,context.temp_allocator)
    slice.sort(keys)
    hash:u64=1
    for key in keys {hash=base.hash_combine(base.hash_combine(hash,base.name_hash(key)),declared.hashes[key])}
    return hash
}
