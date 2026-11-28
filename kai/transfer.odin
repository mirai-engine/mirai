package kai

import "core:fmt"
import "core:sync"
import "core:time"
import "mirai:store"

// What moves between this machine and its peers, as the agent sees it: each
// transfer is one direction, one peer and one thing (a repository, derived
// data or the org's records), kept in a fixed table of the agent, so counting
// allocates nothing. What a peer asks this end names no repository: the
// heads it was told (Transfer_Root) say what a want is for when it names one
// of them, and the peer's later wants follow it until it goes quiet. A
// transfer nothing moved in for TRANSFER_KEEP leaves the table.

TRANSFERS_MAX :: 32
TRANSFER_BUCKETS :: 8                    // the window the speed is measured over...
TRANSFER_BUCKET :: 250*time.Millisecond  // ...in buckets of this long
TRANSFER_KEEP :: 5*time.Second           // a transfer nothing moved in for this long leaves the list

Transfer_Direction :: enum u8 {Download,Upload}

Transfer_Kind :: enum u8 {
    Sync,    // the org's records, admissions and shared bookmarks
    Project, // the files of a repository
    Ddc,     // derived data
}

// A transfer with one peer, as agent_transfers gives it.
Transfer :: struct {
    direction:Transfer_Direction,
    kind:Transfer_Kind,
    org:Org_Id,
    repo:Repo_Id,         // Project: the repository
    peer:Key,
    label:string,         // the repository's name, "DDC", or the org's name for Sync
    peer_name:string,     // "name (device)" as the peer says
    bytes:i64,            // moved since it began
    chunks:int,
    left:int,             // Download: chunks asked and not here yet
    bytes_per_second:f64, // over the last TRANSFER_BUCKETS*TRANSFER_BUCKET
    seconds:f64,          // since it began
    active:bool,          // something moved within the speed's window
}

// What a want is for: the kind, org and repository of what it asks.
@(private)
Transfer_Root :: struct {
    kind:Transfer_Kind,
    org:Org_Id,
    repo:Repo_Id,
}

@(private)
Transfer_Slot :: struct {
    used:bool,
    direction:Transfer_Direction,
    root:Transfer_Root,
    peer:Key,
    label:[NAME_MAX]u8,
    label_length:int,
    peer_name:[2*NAME_MAX+3]u8,
    peer_name_length:int,
    bytes:i64,
    chunks:int,
    left:int,
    window:[TRANSFER_BUCKETS]i64, // bytes of each bucket, by bucket % TRANSFER_BUCKETS
    bucket:i64,                   // the newest bucket window holds: tick ns / TRANSFER_BUCKET
    started,last:i64,             // tick ns
}

@(private)
transfer_now :: proc() -> i64 {return time.tick_now()._nsec}

// The transfers that move or moved within TRANSFER_KEEP, into out, their
// texts in allocator. Those older leave the table.
agent_transfers :: proc(a:^Agent,out:^[dynamic]Transfer,allocator:=context.allocator) {
    now:=transfer_now()
    sync.mutex_lock(&a.lock)
    defer sync.mutex_unlock(&a.lock)
    for &x in a.transfers {
        if !x.used {continue}
        if now-x.last>i64(TRANSFER_KEEP) {
            x.used=false
            continue
        }
        texts:=make([dynamic]string,context.temp_allocator)
        text_add(&texts,string(x.label[:x.label_length]),allocator)
        text_add(&texts,string(x.peer_name[:x.peer_name_length]),allocator)
        if len(texts)<2 {return}
        append(out,Transfer{
            direction=x.direction,kind=x.root.kind,org=x.root.org,repo=x.root.repo,peer=x.peer,
            label=texts[0],peer_name=texts[1],bytes=x.bytes,chunks=x.chunks,left=x.left,
            bytes_per_second=transfer_speed(&x,now),
            seconds=f64(now-x.started)/f64(time.Second),
            active=now-x.last<i64(TRANSFER_BUCKETS*TRANSFER_BUCKET),
        })
    }
}

// Bytes a second over the window: the full buckets before the current one
// and what of the current one passed, or since it began when that is less.
@(private)
transfer_speed :: proc(x:^Transfer_Slot,now:i64) -> f64 {
    transfer_roll(x,now)
    sum:i64
    for b in x.window {sum+=b}
    span:=min(now-x.started,i64((TRANSFER_BUCKETS-1)*TRANSFER_BUCKET)+now%i64(TRANSFER_BUCKET))
    span=max(span,i64(TRANSFER_BUCKET))
    return f64(sum)*f64(time.Second)/f64(span)
}

// Moves the window to the bucket of now, emptying the buckets it passes.
@(private)
transfer_roll :: proc(x:^Transfer_Slot,now:i64) {
    b:=now/i64(TRANSFER_BUCKET)
    if b<=x.bucket {return}
    for k:=x.bucket+1;k<=b && k<=x.bucket+TRANSFER_BUCKETS;k+=1 {x.window[k%TRANSFER_BUCKETS]=0}
    x.bucket=b
}

@(private)
transfer_find_locked :: proc(a:^Agent,direction:Transfer_Direction,root:Transfer_Root,peer:Key) -> ^Transfer_Slot {
    for &x in a.transfers {
        if x.used && x.direction==direction && x.root==root && x.peer==peer {return &x}
    }
    return nil
}

// Counts chunks and bytes that moved with p, of root, in direction; left,
// what a download has asked and not had. The texts of a new transfer are
// made outside the agent's lock, from the peer and the org's record, and
// made again when its slot left the table meanwhile.
@(private)
agent_transfer :: proc(a:^Agent,p:^Peer,direction:Transfer_Direction,root:Transfer_Root,chunks:int,bytes:i64,left:int) {
    if chunks<=0 {return}
    key:=p.conn.peer
    label:[NAME_MAX]u8
    peer_name:[2*NAME_MAX+3]u8
    label_length,peer_name_length:int
    named:=false
    x:^Transfer_Slot
    now:i64
    for {
        now=transfer_now()
        sync.mutex_lock(&a.lock)
        x=transfer_find_locked(a,direction,root,key)
        if x!=nil || named {break}
        sync.mutex_unlock(&a.lock)
        label_length=transfer_label(a,root,label[:])
        sync.mutex_lock(&p.lock)
        name,device:=string(p.name[:p.name_len]),string(p.device[:p.device_len])
        switch {
        case name!="" && device!="": peer_name_length=len(fmt.bprintf(peer_name[:],"%s (%s)",name,device))
        case name!="": peer_name_length=copy(peer_name[:],name)
        case: peer_name_length=copy(peer_name[:],device)
        }
        sync.mutex_unlock(&p.lock)
        named=true
    }
    defer sync.mutex_unlock(&a.lock)
    if x==nil {
        // The table is full: the transfer that moved longest ago gives its place.
        for &y in a.transfers {
            if !y.used || now-y.last>i64(TRANSFER_KEEP) {
                x=&y
                break
            }
            if x==nil || y.last<x.last {x=&y}
        }
        x^={used=true,direction=direction,root=root,peer=key,started=now,bucket=now/i64(TRANSFER_BUCKET)}
        // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
        x.label=label
        x.label_length=label_length
        x.peer_name=peer_name
        x.peer_name_length=peer_name_length
    }
    transfer_roll(x,now)
    x.window[x.bucket%TRANSFER_BUCKETS]+=bytes
    x.bytes+=bytes
    x.chunks+=chunks
    x.left=left
    x.last=now
    agent_moved(a)
}

// What a transfer of root is called: its repository's name, "DDC", or its org's name.
@(private)
transfer_label :: proc(a:^Agent,root:Transfer_Root,out:[]u8) -> int {
    if root.kind==.Ddc {return copy(out,"DDC")}
    s,e:=team_store(&a.team,root.org)
    if e!=.None {return 0}
    o,_,he:=org_effective_head(s,root.org,context.temp_allocator)
    if he!=.None {return 0}
    if root.kind==.Project {
        for r in o.repos {
            if r.id==root.repo {return copy(out,r.name)}
        }
    }
    return copy(out,o.name)
}

// What the wants of p for org, at addresses, are for: the first head among
// them a pull starts from, else what its wants of org were for while it kept
// asking, else the org's one repository, else the org's records.
@(private)
agent_serving :: proc(a:^Agent,p:^Peer,org:Org_Id,addresses:[]store.Hash) -> Transfer_Root {
    now:=transfer_now()
    found:Transfer_Root
    matched:=false
    sync.mutex_lock(&a.lock)
    for address in addresses {
        if r,ok:=a.roots[address];ok && r.org==org {
            found,matched=r,true
            break
        }
    }
    sync.mutex_unlock(&a.lock)
    sync.mutex_lock(&p.lock)
    if serving,ok:=p.serving.?;!matched && ok && serving.root.org==org && now-serving.at<i64(TRANSFER_KEEP) {
        found,matched=serving.root,true
    }
    sync.mutex_unlock(&p.lock)
    if !matched {
        found={kind=.Sync,org=org}
        if s,e:=team_store(&a.team,org);e==.None {
            if o,_,he:=org_effective_head(s,org,context.temp_allocator);he==.None && len(o.repos)==1 {
                found={kind=.Project,org=org,repo=o.repos[0].id}
            }
        }
    }
    sync.mutex_lock(&p.lock)
    p.serving=Peer_Serving{found,now}
    sync.mutex_unlock(&p.lock)
    return found
}

// The heads a pull starts from, and what each is for (agent_serving): the
// org's records, each repository's shared bookmarks, the change each names
// and its tree, and each derived data set. Made again when a head moves.
@(private)
agent_roots :: proc(a:^Agent,heads:[]Tell_Entry) {
    roots:=make([dynamic]struct{address:store.Hash,root:Transfer_Root},context.temp_allocator)
    for h in heads {
        switch h.kind {
        case .Org,.Admit: append(&roots,struct{address:store.Hash,root:Transfer_Root}{h.address,{kind=.Sync,org=h.org}})
        case .Ddc: append(&roots,struct{address:store.Hash,root:Transfer_Root}{h.address,{kind=.Ddc,org=h.org}})
        case .Repo:
            repo:Repo_Id
            id:=h.id
            copy(repo[:],id[:16])
            root:=Transfer_Root{kind=.Project,org=h.org,repo=repo}
            append(&roots,struct{address:store.Hash,root:Transfer_Root}{h.address,root})
            s,e:=team_store(&a.team,h.org)
            if e!=.None {continue}
            refs,re:=repo_refs_get(s,h.address,context.temp_allocator)
            if re!=.None {continue}
            for b in refs.bookmarks {
                append(&roots,struct{address:store.Hash,root:Transfer_Root}{b.target,root})
                if c,ce:=change_get(s,b.target,context.temp_allocator);ce==.None && c.tree!={} {
                    append(&roots,struct{address:store.Hash,root:Transfer_Root}{c.tree,root})
                }
            }
        }
    }
    sync.mutex_lock(&a.lock)
    defer sync.mutex_unlock(&a.lock)
    clear(&a.roots)
    for r in roots {a.roots[r.address]=r.root}
}

// Waits until no peer asked this machine for anything for idle, at most
// limit: what an agent that ends soon after it told the org's nodes of what
// it published gives them to take it. At once when no peer is connected.
agent_drain :: proc(a:^Agent,idle,limit:time.Duration) {
    started:=time.tick_now()
    for time.tick_since(started)<limit {
        quiet:=transfer_now()-sync.atomic_load(&a.asked)>=i64(idle)
        live,waiting:=0,false
        sync.mutex_lock(&a.lock)
        for p in a.peers {
            sync.mutex_lock(&p.lock)
            if p.phase==.Live {
                live+=1
                waiting||=len(p.requests)>0
            }
            sync.mutex_unlock(&p.lock)
        }
        sync.mutex_unlock(&a.lock)
        if live==0 || quiet && !waiting {return}
        time.sleep(50*time.Millisecond)
    }
}
