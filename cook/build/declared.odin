package build

import "core:fmt"
import "core:odin/ast"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "mirai:project"
import "mirai:std/base"

// What compiles against declarations follows the declarations it names, not
// the packages that hold them. declare leaves, per package, a line for each
// declaration with the hash of its text and the names that text carries
// (DECLARED_NAMES). From those, each declaration gets the hash of itself and
// of every declaration it reaches through them: a type with the types of its
// fields, a procedure with the types of its signature, an inline body with
// what it calls. A library, a program or a plugin hashes the ones its own
// parsed sources name (declared_named, declared_key): a field added to a
// struct builds again what reaches that struct, and nothing else. One index
// keys the declarations of the engine, of its plugins and of the project, each
// as `<collection>:<package>.<name>`.
//
// A name counts wherever a selector writes it, also where a local name hides
// the package: more is followed, never less. What reaches a struct through a
// pointer follows it too, since nothing in a text says that its fields are
// left alone.

// Beside the declarations of a package: what each declares and names.
@(private)
DECLARED_NAMES :: "declared.names"

// The collections whose declarations are keyed: the engine, its plugins and the project.
@(private)
DECLARED_COLLECTIONS :: [3]string{"mirai","plugins","project"}

// Of each declaration, by its key, the hash of what whoever names it compiles
// against. Empty: no build of the engine wrote it.
@(private)
Declared :: map[string]u64

@(private="file")
Declared_Node :: struct {
    key:string,
    own:u64,
    edges:[dynamic]int,
    index,low,component:int,
    stacked:bool,
}

// The packages of the keyed collections a file imports, by the name it gives
// each, as `<collection>:<package>`: the key of one of their declarations adds
// `.<name>`. The packages of skip are left out.
@(private)
imports_named :: proc(file:^ast.File,skip:[]string=nil) -> map[string]string {
    imports:=make(map[string]string,context.temp_allocator)
    for imp in file.imports {
        literal:=strings.trim(imp.fullpath,"\"`")
        colon:=strings.index_byte(literal,':')
        collections:=DECLARED_COLLECTIONS
        if colon<=0 || !slice.contains(collections[:],literal[:colon]) || slice.contains(skip,literal) {continue}
        name:=imp.name.text if imp.name.text!="" else literal[max(strings.last_index_byte(literal,'/'),colon)+1:]
        if name!="_" {imports[name]=literal}
    }
    return imports
}

// Adds to names the key of each declaration of another package the files
// name: what a selector picks of a package they import, but of those of skip,
// which compile with them.
@(private)
declared_named :: proc(files:[]^ast.File,skip:[]string,names:^map[string]bool) {
    for file in files {
        imports:=imports_named(file,skip)
        found:=Names{file=names,imports=&imports}
        for decl in file.decls {names_add(&found,decl)}
    }
}

// Writes to file the index of the declarations of the engine under decl
// (declared_add). False when it cannot be written.
@(private)
declared_write :: proc(decl,file:string) -> bool {
    declared:=make(Declared,context.temp_allocator)
    packages:=make([]string,ENGINE_PACKAGE_COUNT,context.temp_allocator)
    for &path,index in packages {path=engine_package(index)}
    declared_add(&declared,"mirai",decl,packages)
    lines:=make([dynamic]string,0,len(declared),context.temp_allocator)
    for key,hash in declared {append(&lines,fmt.tprintf("%s %x",key,hash))}
    slice.sort(lines[:])
    _,error:=write_changed(file,strings.join(lines[:],"\n",context.temp_allocator))
    return error==nil
}

// Adds to declared the declarations of the packages of a collection, from
// their DECLARED_NAMES under decl, each by its key with the hash of itself
// and of what it reaches. A declaration of another package that declared has
// counts with the hash it has there; one it lacks counts as missing, and
// moves what names it once it is declared.
@(private)
declared_add :: proc(declared:^Declared,collection,decl:string,packages:[]string) {
    nodes:=make([dynamic]Declared_Node,context.temp_allocator)
    ids:=make(map[string]int,context.temp_allocator)
    node :: proc(nodes:^[dynamic]Declared_Node,ids:^map[string]int,key:string) -> int {
        if id,found:=ids[key];found {return id}
        id:=len(nodes)
        append(nodes,Declared_Node{key=key,edges=make([dynamic]int,context.temp_allocator),index=-1,component=-1})
        ids[key]=id
        return id
    }
    texts:=make([]string,len(packages),context.temp_allocator)
    for path,at in packages {
        data,error:=os.read_entire_file(project.path(decl,path,DECLARED_NAMES,allocator=context.temp_allocator),context.temp_allocator)
        if error!=nil {continue}
        texts[at]=string(data)
        rest:=texts[at]
        for line in strings.split_lines_iterator(&rest) {
            name,hash:=declared_line(line) or_continue
            id:=node(&nodes,&ids,fmt.tprintf("%s:%s.%s",collection,path,name))
            nodes[id].own=base.hash_combine(nodes[id].own,hash)
        }
    }
    // Every declaration of these packages is known by now: a bare name that is none of its package is a local one.
    own:=len(nodes)
    for text,at in texts {
        rest:=text
        for line in strings.split_lines_iterator(&rest) {
            name,_:=declared_line(line) or_continue
            id:=ids[fmt.tprintf("%s:%s.%s",collection,packages[at],name)]
            fields:=line
            skipped:=0
            for ref in strings.fields_iterator(&fields) {
                if skipped<2 {skipped+=1;continue}
                if strings.index_byte(ref,':')>=0 {
                    _,known:=ids[ref]
                    to:=node(&nodes,&ids,ref)
                    if !known && to>=own {nodes[to].own=declared[ref]}
                    append(&nodes[id].edges,to)
                } else if to,found:=ids[fmt.tprintf("%s:%s.%s",collection,packages[at],ref)];found && to!=id {
                    append(&nodes[id].edges,to)
                }
            }
        }
    }
    hashes:=declared_reach(nodes[:])
    for n,id in nodes[:own] {declared[n.key]=hashes[id]}
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

// The first declaration of a package that two texts of its DECLARED_NAMES do
// not both have with the same hash, as `<package>.<name>`; the package alone
// when they declare the same in another order.
@(private)
declared_moved :: proc(path,old,new:string) -> string {
    texts:=[2]string{old,new}
    hashes:[2]map[string]u64
    for text,which in texts {
        hashes[which]=make(map[string]u64,context.temp_allocator)
        rest:=text
        for line in strings.split_lines_iterator(&rest) {
            name,hash:=declared_line(line) or_continue
            hashes[which][name]=base.hash_combine(hashes[which][name],hash)
        }
    }
    for text in texts {
        rest:=text
        for line in strings.split_lines_iterator(&rest) {
            name,_:=declared_line(line) or_continue
            if hashes[0][name]!=hashes[1][name] {return fmt.aprintf("%s.%s",path,name)}
        }
    }
    return strings.clone(path)
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
    declared=make(Declared,allocator)
    data,_:=os.read_entire_file(file,context.temp_allocator)
    rest:=string(data)
    for line in strings.split_lines_iterator(&rest) {
        if key,hash,ok:=declared_line(line);ok {declared[strings.clone(key,allocator)]=hash}
    }
    return
}

// The hash of the declarations named, as the index has them: what whoever
// names them is built again by. One the index does not have counts as
// missing, and moves the hash when it is declared.
@(private)
declared_key :: proc(declared:Declared,names:map[string]bool) -> u64 {
    keys,_:=slice.map_keys(names,context.temp_allocator)
    slice.sort(keys)
    hash:u64=1
    for key in keys {hash=base.hash_combine(base.hash_combine(hash,base.name_hash(key)),declared[key])}
    return hash
}
