package store

import "base:runtime"

// An object is a tree of nodes over its chunks, and its address is the address
// of its root node. A node is a chunk whose bytes are a Node record, then its
// entries, then (in the root only) its groups and its meta, little endian.
// Entries are grouped into nodes with content-defined boundaries over their
// addresses, so an insert rewrites one node per level.

#assert(ODIN_ENDIAN==.Little)

Node :: struct #packed {
    magic:u32,   // NODE_MAGIC
    version:u8,  // NODE_VERSION
    level:u8,    // 0: entries are data chunks; n>0: entries are nodes of level n-1
    reserved:u16,
    count:u32,   // entries
    groups:u16,  // group records after the entries (root node only)
    meta:u16,    // bytes of meta after the groups (root node only)
    total:u64,   // bytes of data under this node
}

Entry :: struct #packed {
    address:Hash,
    size:u64, // data bytes under it
}

// A run of the root's leaf order: container chunk (tag, index) is the leaves
// [first, first+count), whose bytes begin at offset in the object. The groups
// of a root follow each other from leaf 0 and byte 0, and a plain file has
// one; the store reads neither tag, index, align nor meta.
Group :: struct #packed {
    tag:u32,
    index:u32,
    first:u32,
    count:u32,
    offset:u64,
    align:u8,
    reserved:[7]u8,
}

#assert(size_of(Node)==24 && size_of(Entry)==40 && size_of(Group)==32)

NODE_MAGIC :: u32('M')|u32('N')<<8|u32('O')<<16|u32('D')<<24
NODE_VERSION :: 2
NODE_ENTRIES_MIN :: 64
NODE_ENTRIES_TARGET :: 1024
NODE_ENTRIES_MAX :: (CHUNK_MAX-size_of(Node))/size_of(Entry)
// Enough for 2^64 bytes of CHUNK_MIN chunks in nodes of NODE_ENTRIES_MIN, plus
// a root of one entry above a top node that leaves no room for groups and meta.
NODE_LEVEL_MAX :: 9

// A node, its slices into the bytes it was parsed from.
Node_View :: struct {
    level:int,
    total:u64,
    entries:[]Entry,
    groups:[]Group,
    meta:[]u8,
}

// The bytes of a node in buffer, which needs node_bytes of them.
node_encode :: proc "contextless" (buffer:[]u8,level:int,entries:[]Entry,groups:[]Group={},meta:[]u8={}) -> (bytes:[]u8,error:Error) {
    size:=node_bytes(len(entries),len(groups),len(meta))
    if size<0 || size>len(buffer) || level<0 || level>NODE_LEVEL_MAX {return nil,.Invalid_Argument}
    total:u64
    for e in entries {
        if e.size==0 || (level==0 && e.size>CHUNK_MAX) || e.size>max(u64)-total {return nil,.Invalid_Argument}
        total+=e.size
    }
    bytes=buffer[:size]
    copy(bytes[size_of(Node):],([^]u8)(raw_data(entries))[:len(entries)*size_of(Entry)])
    node_close(bytes,level,len(entries),groups,meta,total)
    if _,e:=node_parse(bytes);e!=.None {return nil,.Invalid_Argument}
    return bytes,.None
}

// The bytes of a node of these counts; -1 above CHUNK_MAX or the counts the
// record holds.
node_bytes :: proc "contextless" (entries,groups,meta:int) -> int {
    if entries<0 || entries>NODE_ENTRIES_MAX || groups<0 || groups>int(max(u16)) || meta<0 || meta>int(max(u16)) {return -1}
    size:=size_of(Node)+entries*size_of(Entry)+groups*size_of(Group)+meta
    return size<=CHUNK_MAX?size:-1
}

// Writes the head, the groups and the meta of a node whose entries are already
// in place in bytes.
@(private)
node_close :: proc "contextless" (bytes:[]u8,level,count:int,groups:[]Group,meta:[]u8,total:u64) {
    head:=Node{magic=NODE_MAGIC,version=NODE_VERSION,level=u8(level),count=u32(count),groups=u16(len(groups)),meta=u16(len(meta)),total=total}
    copy(bytes,([^]u8)(&head)[:size_of(Node)])
    at:=size_of(Node)+count*size_of(Entry)
    at+=copy(bytes[at:],([^]u8)(raw_data(groups))[:len(groups)*size_of(Group)])
    copy(bytes[at:],meta)
}

// Parses the bytes of a node, of any origin: every count, size, sum and group
// is checked, and reserved bytes are zero, so each node has one encoding.
node_parse :: proc "contextless" (bytes:[]u8) -> (n:Node_View,error:Error) {
    if len(bytes)<size_of(Node) || len(bytes)>CHUNK_MAX {return {},.Corrupt}
    head:=(^Node)(raw_data(bytes))^
    if head.magic!=NODE_MAGIC || head.version!=NODE_VERSION || head.reserved!=0 || int(head.level)>NODE_LEVEL_MAX {return {},.Corrupt}
    if head.count>NODE_ENTRIES_MAX || node_bytes(int(head.count),int(head.groups),int(head.meta))!=len(bytes) {return {},.Corrupt}
    n.level=int(head.level)
    n.total=head.total
    at:=size_of(Node)
    n.entries=([^]Entry)(raw_data(bytes[at:]))[:head.count]
    at+=int(head.count)*size_of(Entry)
    n.groups=([^]Group)(raw_data(bytes[at:]))[:head.groups]
    at+=int(head.groups)*size_of(Group)
    n.meta=bytes[at:]
    total:u64
    for e in n.entries {
        if e.size==0 || (n.level==0 && e.size>CHUNK_MAX) || e.size>max(u64)-total {return {},.Corrupt}
        total+=e.size
    }
    if total!=head.total || (len(n.entries)==0 && n.level!=0) {return {},.Corrupt}
    if !groups_valid(n) {return {},.Corrupt}
    return n,.None
}

// Groups follow each other from leaf 0 and byte 0, each offset where its
// first leaf begins: exactly, by the entries of a node of level 0; above it,
// as far as leaves of 1 to CHUNK_MAX bytes allow, up to the node's total.
@(private)
groups_valid :: proc "contextless" (n:Node_View) -> bool {
    leaf,offset:u64
    for g,i in n.groups {
        if g.reserved!={} || u64(g.first)!=leaf || u64(g.first)+u64(g.count)>u64(max(u32)) {return false}
        if g.offset!=offset && !(n.level>0 && i>0 && g.offset>offset) {return false}
        if i>0 && n.level>0 {
            previous:=n.groups[i-1]
            bytes:=g.offset-previous.offset
            if bytes<u64(previous.count) || bytes>u64(previous.count)*CHUNK_MAX {return false}
        }
        if n.level==0 {
            if leaf+u64(g.count)>u64(len(n.entries)) {return false}
            for e in n.entries[leaf:][:g.count] {offset+=e.size}
        } else {
            offset=g.offset
        }
        leaf+=u64(g.count)
    }
    if len(n.groups)==0 {return true}
    last:=n.groups[len(n.groups)-1]
    if n.level==0 {return leaf==u64(len(n.entries))}
    if last.offset>n.total {return false}
    bytes:=n.total-last.offset
    return bytes>=u64(last.count) && bytes<=u64(last.count)*CHUNK_MAX
}

Chunk_Kind :: enum u8 {Data,Node}

// Receives each chunk an object is cut into, data chunks before the nodes that
// name them and the root last; the bytes are valid during the call. An error
// stops the object.
Sink :: struct {
    procedure:proc(data:rawptr,kind:Chunk_Kind,address:Hash,bytes:[]u8) -> Error,
    data:rawptr,
}

// Builds the nodes of an object from its leaves in order, holding one open
// node per level: an entry whose address begins (as a little-endian u32) below
// 2^32/NODE_ENTRIES_TARGET is the last of its node once the node has
// NODE_ENTRIES_MIN entries, and the entry NODE_ENTRIES_MAX always is. The level
// that ends as one node is the root, which carries the groups and the meta.
Tree :: struct {
    sink:Sink,
    levels:[NODE_LEVEL_MAX+1]Tree_Level,
    depth:int, // levels that have received an entry
    leaves:u64,
    bytes:u64,  // of the leaves so far
    groups:[dynamic]Group,
    failed:Error,
    allocator:runtime.Allocator,
}

@(private)
Tree_Level :: struct {
    buffer:[]u8, // CHUNK_MAX, allocated when the level is first reached
    count:int,
    total:u64,
    ended:bool, // the last entry ended the node, which closes at the next one or is the root
}

@(private)
NODE_SLICE :: u32((u64(1)<<32)/NODE_ENTRIES_TARGET)

tree_init :: proc(t:^Tree,sink:Sink,allocator:=context.allocator) {
    t^={sink=sink,allocator=allocator}
    t.groups=make([dynamic]Group,0,0,allocator)
}

tree_destroy :: proc(t:^Tree) {
    for &l in t.levels {delete(l.buffer,t.allocator)}
    delete(t.groups)
    t^={}
}

// Starts a new object, keeping the buffers.
tree_reset :: proc(t:^Tree) {
    for &l in t.levels {l.count,l.total,l.ended=0,0,false}
    t.depth,t.leaves,t.bytes,t.failed=0,0,0,.None
    clear(&t.groups)
}

// Starts a group at the next leaf; it runs until the next group or the end.
tree_group :: proc(t:^Tree,tag,index:u32,align:u8=0) -> Error {
    if t.failed!=.None {return t.failed}
    if len(t.groups)>=int(max(u16)) {return tree_fail(t,.Invalid_Argument)}
    if len(t.groups)>0 {
        last:=&t.groups[len(t.groups)-1]
        last.count=u32(t.leaves-u64(last.first))
    }
    if _,e:=append(&t.groups,Group{tag=tag,index=index,first=u32(t.leaves),offset=t.bytes,align=align});e!=nil {return tree_fail(t,.Out_Of_Memory)}
    return .None
}

// Hands a data chunk to the sink and adds it as the next leaf.
tree_put_chunk :: proc(t:^Tree,chunk:[]u8) -> Error {
    if len(chunk)==0 || len(chunk)>CHUNK_MAX {return .Invalid_Argument}
    if t.failed!=.None {return t.failed}
    address:=address_of_bytes(chunk)
    if e:=t.sink.procedure(t.sink.data,.Data,address,chunk);e!=.None {return tree_fail(t,e)}
    return tree_put_leaf(t,address,u64(len(chunk)))
}

// Adds a leaf whose chunk the sink already has.
tree_put_leaf :: proc(t:^Tree,address:Hash,size:u64) -> Error {
    if size==0 || size>CHUNK_MAX {return .Invalid_Argument}
    if t.failed!=.None {return t.failed}
    if t.leaves>=u64(max(u32)) {return tree_fail(t,.Invalid_Argument)}
    t.leaves+=1
    t.bytes+=size
    return tree_push(t,0,{address=address,size=size})
}

// A container chunk of a native asset as one group of leaves, cut as
// native_cuts says.
tree_put_native :: proc(t:^Tree,tag,index:u32,align:u8,data:[]u8,cuts:[]int) -> Error {
    n:=native_cuts(data,cuts) or_return
    tree_group(t,tag,index,align) or_return
    for chunk in native_next(&n) {tree_put_chunk(t,chunk) or_return}
    return .None
}

// Closes every open node and writes the root with its groups and meta; the
// tree is then reset for the next object.
tree_finish :: proc(t:^Tree,meta:[]u8={}) -> (root:Hash,total:u64,error:Error) {
    defer tree_reset(t)
    if t.failed!=.None {return {},0,t.failed}
    if len(t.groups)>0 {
        last:=&t.groups[len(t.groups)-1]
        last.count=u32(t.leaves-u64(last.first))
    }
    if node_bytes(1,len(t.groups),len(meta))<0 {return {},0,.Invalid_Argument}
    if t.depth==0 {
        tree_level_buffer(t,0) or_return
        t.depth=1
    }
    for level:=0;level<t.depth;level+=1 {
        l:=&t.levels[level]
        if level<t.depth-1 {
            if l.count>0 {tree_close(t,level) or_return}
            continue
        }
        if node_bytes(l.count,len(t.groups),len(meta))<0 {
            tree_close(t,level) or_return
            continue
        }
        node_close(l.buffer,level,l.count,t.groups[:],meta,l.total)
        bytes:=l.buffer[:node_bytes(l.count,len(t.groups),len(meta))]
        root=address_of_bytes(bytes)
        if e:=t.sink.procedure(t.sink.data,.Node,root,bytes);e!=.None {return {},0,e}
        return root,l.total,.None
    }
    return {},0,.Invalid_Argument
}

@(private)
tree_fail :: proc(t:^Tree,error:Error) -> Error {
    t.failed=error
    return error
}

@(private)
tree_level_buffer :: proc(t:^Tree,level:int) -> Error {
    if level>NODE_LEVEL_MAX {return tree_fail(t,.Invalid_Argument)}
    if t.levels[level].buffer!=nil {return .None}
    buffer,e:=make([]u8,CHUNK_MAX,t.allocator)
    if e!=nil {return tree_fail(t,.Out_Of_Memory)}
    t.levels[level].buffer=buffer
    return .None
}

@(private)
tree_push :: proc(t:^Tree,level:int,entry:Entry) -> Error {
    if level>=t.depth {
        tree_level_buffer(t,level) or_return
        t.depth=level+1
    }
    l:=&t.levels[level]
    if l.ended {tree_close(t,level) or_return}
    entry:=entry
    copy(l.buffer[size_of(Node)+l.count*size_of(Entry):],([^]u8)(&entry)[:size_of(Entry)])
    l.count+=1
    l.total+=entry.size
    first:=u32(entry.address[0])|u32(entry.address[1])<<8|u32(entry.address[2])<<16|u32(entry.address[3])<<24
    l.ended=l.count==NODE_ENTRIES_MAX || (l.count>=NODE_ENTRIES_MIN && first<NODE_SLICE)
    return .None
}

@(private)
tree_close :: proc(t:^Tree,level:int) -> Error {
    l:=&t.levels[level]
    node_close(l.buffer,level,l.count,nil,nil,l.total)
    bytes:=l.buffer[:size_of(Node)+l.count*size_of(Entry)]
    address:=address_of_bytes(bytes)
    if e:=t.sink.procedure(t.sink.data,.Node,address,bytes);e!=.None {return tree_fail(t,e)}
    total:=l.total
    l.count,l.total,l.ended=0,0,false
    return tree_push(t,level+1,{address=address,size=total})
}

// Cuts external bytes on content and builds their tree, one group of tag 0.
Object_Writer :: struct {
    chunker:Chunker,
    tree:Tree,
    started:bool,
}

object_writer_init :: proc(w:^Object_Writer,sink:Sink,allocator:=context.allocator) -> Error {
    w^={}
    chunker_init(&w.chunker,allocator) or_return
    tree_init(&w.tree,sink,allocator)
    return .None
}

object_writer_destroy :: proc(w:^Object_Writer) {
    chunker_destroy(&w.chunker)
    tree_destroy(&w.tree)
}

object_write :: proc(w:^Object_Writer,data:[]u8) -> Error {
    if !w.started {
        tree_group(&w.tree,0,0) or_return
        w.started=true
    }
    chunker_feed(&w.chunker,data) or_return
    for chunk in chunker_next(&w.chunker) {tree_put_chunk(&w.tree,chunk) or_return}
    return .None
}

object_finish :: proc(w:^Object_Writer,meta:[]u8={}) -> (root:Hash,total:u64,error:Error) {
    defer {
        chunker_reset(&w.chunker)
        w.started=false
    }
    if !w.started {tree_group(&w.tree,0,0) or_return}
    chunker_end(&w.chunker)
    for chunk in chunker_next(&w.chunker) {
        if e:=tree_put_chunk(&w.tree,chunk);e!=.None {
            tree_reset(&w.tree)
            return {},0,e
        }
    }
    return tree_finish(&w.tree,meta)
}

// Gives the bytes of the node at an address; they stay valid until the walk
// that asked returns.
Node_Source :: struct {
    procedure:proc(data:rawptr,address:Hash) -> ([]u8,Error),
    data:rawptr,
}

// A data chunk of an object and where its bytes begin in the object.
Leaf :: struct {
    address:Hash,
    size:u64,
    offset:u64,
}

// The leaf that holds byte offset of the object at root, descending with the
// sizes of the entries.
tree_locate :: proc(source:Node_Source,root:Hash,offset:u64) -> (leaf:Leaf,error:Error) {
    n:=node_fetch(source,root) or_return
    return tree_descend(source,n,offset)
}

// The leaf that holds byte offset of group of the object at root, descending
// from where the group begins with the sizes of the entries.
group_locate :: proc(source:Node_Source,root:Hash,group:int,offset:u64) -> (leaf:Leaf,error:Error) {
    n:=node_fetch(source,root) or_return
    if group<0 || group>=len(n.groups) {return {},.Invalid_Argument}
    start:=n.groups[group].offset
    end:=group+1<len(n.groups)?n.groups[group+1].offset:n.total
    if offset>=end-start {return {},.Invalid_Argument}
    return tree_descend(source,n,start+offset)
}

@(private)
tree_descend :: proc(source:Node_Source,root:Node_View,offset:u64) -> (leaf:Leaf,error:Error) {
    if offset>=root.total {return {},.Invalid_Argument}
    n:=root
    at:=offset
    leaf.offset=0
    for {
        next:=-1
        for e,i in n.entries {
            if at<e.size {next=i;break}
            at-=e.size
            leaf.offset+=e.size
        }
        if next<0 {return {},.Corrupt}
        e:=n.entries[next]
        if n.level==0 {return {address=e.address,size=e.size,offset=leaf.offset},.None}
        n=node_child(source,n,e) or_return
    }
}

@(private)
node_fetch :: proc(source:Node_Source,address:Hash) -> (n:Node_View,error:Error) {
    bytes:=source.procedure(source.data,address) or_return
    return node_parse(bytes)
}

// A node an entry of parent names, which must be one level below it, hold the
// bytes the entry says and carry no groups or meta.
@(private)
node_child :: proc(source:Node_Source,parent:Node_View,entry:Entry) -> (n:Node_View,error:Error) {
    n=node_fetch(source,entry.address) or_return
    if n.level!=parent.level-1 || n.total!=entry.size || len(n.groups)>0 || len(n.meta)>0 {return {},.Corrupt}
    return n,.None
}
