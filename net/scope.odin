package mirai_net

import "base:intrinsics"
import "core:math"
import "core:mem"
import "core:slice"
import "mirai:std/base"

// What each connection of a server sees, and in which order it is sent.
//
// Scope. An object is wanted by a connection according to its filter: always,
// only by its owner, by distance to the connection's view, or by none; of
// those, by the connections that have one of its groups and share one of its
// visibility bits, when it has any. An object with a parent follows its
// parent. Spatial objects update the
// grid only when their cell changes. One that is seen stays seen up to a margin
// beyond the view, and past it for a number of evaluations before its replica
// is destroyed.
//
// Priority. Every tick, each object with something to send to a connection
// adds its priority to an accumulator of that connection, more if the
// connection owns it or it is near the view. The highest accumulators are
// written until the byte budget of the tick runs out; being sent resets the
// accumulator, so nothing waits forever.

// The grid holds only the cells that have spatial objects, each the head of
// a list of its objects, so a lookup of an empty cell is short.
@(private)
cell_key :: #force_inline proc "contextless" (x,z:i32) -> u64 {return u64(u32(x))<<32|u64(u32(z))}

@(private)
grid_coordinate :: #force_inline proc "contextless" (position:f64,cell:f32) -> i32 {
    return i32(clamp(math.floor(position/f64(cell)),f64(min(i32)),f64(max(i32))))
}
@(private)
grid_position_key :: #force_inline proc "contextless" (position:[3]f32,cell:f32) -> u64 {
    return cell_key(grid_coordinate(f64(position.x),cell),grid_coordinate(f64(position.z),cell))
}

@(private)
grid_mark :: #force_inline proc "contextless" (r:^Repl,o:int) {
    bitset_set(r.grid_dirty,o)
    r.grid_pending=true
}

@(private)
grid_remove :: proc(r:^Repl,o:int) {
    if !r.grid_listed[o] {return}
    before,after:=r.grid_prev[o],r.grid_next[o]
    if before>=0 {
        r.grid_next[before]=after
    } else if after>=0 {
        base.hash_map_set(&r.grid,r.grid_cell[o],after)
    } else {
        base.hash_map_remove(&r.grid,r.grid_cell[o])
    }
    if after>=0 {r.grid_prev[after]=before}
    r.grid_listed[o],r.grid_prev[o],r.grid_next[o]=false,-1,-1
}

@(private)
grid_update :: proc(h:^Host) {
    r:=&h.back.repl
    cell:=h.desc.replication.cell_size
    if r.grid_pending {
        for &word,index in r.grid_dirty {
            for rest:=word;rest!=0;rest&=rest-1 {
                o:=index*64+bitset_first(rest)
                r.grid_updates+=1
                if r.live[o]!=1 || r.filter[o]!=.Spatial {grid_remove(r,o);continue}
                key:=grid_position_key(r.position[o],cell)
                if r.grid_listed[o] && r.grid_cell[o]==key {continue}
                grid_remove(r,o)
                head,new_cell:=base.hash_map_insert(&r.grid,key)
                if head==nil {continue}
                if new_cell {head^=-1}
                r.grid_cell[o],r.grid_listed[o],r.grid_next[o],r.grid_prev[o]=key,true,head^,-1
                if head^>=0 {r.grid_prev[head^]=i32(o)}
                head^=i32(o)
            }
            word=0
        }
        r.grid_pending=false
    }
    if r.radius_stale {
        r.max_radius=0
        for o in 0..<r.high {
            if r.live[o]==1 && r.filter[o]==.Spatial {r.max_radius=max(r.max_radius,r.radius[o])}
        }
        r.radius_stale=false
    }
    if !r.special_stale {return}
    r.special_stale=false
    r.special_count=0
    for o in 0..<r.high {
        if r.live[o]==1 && (r.filter[o]==.Owner || r.filter[o]==.None || r.parent[o]!=0 || r.groups[o]!={} || r.visibility[o]!=0) {
            r.special[r.special_count]=u32(o)
            r.special_count+=1
        }
    }
}

@(private)
scope_distance_squared :: #force_inline proc "contextless" (a,b:[3]f32) -> f64 {
    offset:=a-b
    squared:=offset.x*offset.x+offset.y*offset.y+offset.z*offset.z
    if squared<=max(f32) {return f64(squared)}
    x,y,z:=f64(a.x)-f64(b.x),f64(a.y)-f64(b.y),f64(a.z)-f64(b.z)
    return x*x+y*y+z*z
}
@(private)
view_reaches :: #force_inline proc "contextless" (r:^Repl,pr:^Peer_Repl,o:int) -> bool {
    reach:=f64(pr.view_radius)+f64(r.radius[o])
    return scope_distance_squared(r.position[o],pr.position)<=reach*reach
}

// Whether a connection has none of the groups of an object that has some.
@(private)
groups_lacks :: #force_inline proc "contextless" (pr:^Peer_Repl,groups:Groups) -> bool {
    if groups=={} {return false}
    for group in groups {
        if group!=0 && bitset_test(pr.groups,int(group)) {return false}
    }
    return true
}

// Whether a connection may not see an object for its groups or its visibility bits.
@(private)
scope_lacks :: #force_inline proc "contextless" (r:^Repl,pr:^Peer_Repl,o:int) -> bool {
    return r.visibility[o]!=0 && r.visibility[o]&pr.visibility==0 || groups_lacks(pr,r.groups[o])
}

@(private)
scope_update :: proc(h:^Host,p:^Peer) {
    r:=&h.back.repl
    pr:=&p.repl
    d:=&h.desc.replication
    wanted:=r.wanted
    copy(wanted,r.always)
    if pr.has_view && pr.everywhere {
        for o in 0..<r.high {
            if r.live[o]==1 && r.filter[o]==.Spatial {bitset_set(wanted,o)}
        }
    } else if pr.has_view {
        cell:=d.cell_size
        reach:=f64(pr.view_radius)+f64(r.max_radius)
        x0,x1:=grid_coordinate(f64(pr.position.x)-reach,cell),grid_coordinate(f64(pr.position.x)+reach,cell)
        z0,z1:=grid_coordinate(f64(pr.position.z)-reach,cell),grid_coordinate(f64(pr.position.z)+reach,cell)
        width,height:=i64(x1)-i64(x0)+1,i64(z1)-i64(z0)+1
        // Past twice as many cells as objects, going over the objects is cheaper.
        cells:=i64(r.grid.capacity)*2
        if width>cells || height>cells || width*height>cells {
            for o in 0..<r.high {
                if r.live[o]==1 && r.filter[o]==.Spatial && view_reaches(r,pr,o) {bitset_set(wanted,o)}
            }
        } else {
            for z in i64(z0)..=i64(z1) {
                for x in i64(x0)..=i64(x1) {
                    head,found:=base.hash_map_get(&r.grid,cell_key(i32(x),i32(z)))
                    if !found {continue}
                    for o:=head;o>=0;o=r.grid_next[o] {
                        if view_reaches(r,pr,int(o)) {bitset_set(wanted,int(o))}
                    }
                }
            }
        }
    }
    handle:=peer_handle(h,p)
    special:=r.special[:r.special_count]
    for index in special {
        o:=int(index)
        if r.live[o]!=1 {continue}
        inside:=bitset_test(wanted,o)
        #partial switch r.filter[o] {
        case .Owner:  inside=r.owner[o]==handle
        case .None:   inside=false
        }
        if inside {bitset_set(wanted,o)} else {bitset_clear(wanted,o)}
    }
    // Objects out of view linger before leaving: the count starts again whenever they come back.
    for &word,i in wanted {
        for rest:=word;rest!=0;rest&=rest-1 {pr.away[i*64+bitset_first(rest)]=0}
        for rest:=pr.scope[i]&~word;rest!=0;rest&=rest-1 {
            o:=i*64+bitset_first(rest)
            if r.live[o]!=1 || r.filter[o]!=.Spatial || !pr.has_view {continue}
            // What is seen stays seen a little beyond the edge, so that walking along it does not make and unmake replicas.
            reach:=(f64(pr.view_radius)+f64(r.radius[o]))*(1+f64(d.leave_margin))
            if scope_distance_squared(r.position[o],pr.position)<=reach*reach {
                pr.away[o]=0
                word|=1<<uint(o&63)
            } else if int(pr.away[o])+1<d.hysteresis {
                pr.away[o]+=1
                word|=1<<uint(o&63)
            }
        }
    }
    // An object of groups or of visibility bits the connection lacks is not seen, however near, nor what follows it.
    for index in special {
        o:=int(index)
        if scope_lacks(r,pr,o) {bitset_clear(wanted,o)}
    }
    for index in special {
        o:=int(index)
        if r.parent[o]==0 || r.live[o]!=1 {continue}
        root:=o
        for depth:=0;r.parent[root]!=0 && depth<8;depth+=1 {
            root=int(r.parent[root])-1
            if r.live[root]!=1 {break}
        }
        lacks:=scope_lacks(r,pr,o)
        if r.live[root]==1 && r.parent[root]==0 && bitset_test(wanted,root) && !lacks {bitset_set(wanted,o)} else {bitset_clear(wanted,o)}
    }
    if pr.held {mem.zero_slice(wanted)}
    count:=0
    for word,i in wanted {
        changed:=word~pr.scope[i]
        pr.scope[i]=word
        count+=int(intrinsics.count_ones(word))
        for rest:=changed;rest!=0;rest&=rest-1 {link_sync(h,p,i*64+bitset_first(rest))}
    }
    pr.in_scope=u32(count)
    p.stats.objects_in_scope=u32(count)
}

// Once per tick with something to send, before any connection writes.
@(private)
repl_tick :: proc(h:^Host) {
    b:=&h.back
    r:=&b.repl
    if r.protocol==nil || !r.server {return}
    d:=&h.desc.replication
    if r.held>0 {
        for o in 0..<r.high {
            if r.holder[o]!=0 && r.live[o]==1 && i32(b.tick-r.lease[o])>0 {authority_set(h,o,0,0)}
        }
    }
    built:=false
    for &p in b.peers {
        if p.state!=.Connected {continue}
        pr:=&p.repl
        if !r.scope_stale && !pr.filter_due && (b.tick+p.index)%u32(d.filter_interval)!=0 {continue}
        if !built {grid_update(h);built=true}
        scope_update(h,&p)
        pr.filter_due=false
    }
    r.scope_stale=false
    events_replay(h)
    for index in r.dying[:r.dying_count] {object_end(h,int(index))}
    r.dying_count=0
}

// A key of repl_budget is the accumulator of an object, an f64 whose bits sort
// like its value, with the object in the low bits: max_objects is at most 1<<20.
// Finite priorities in f64 do not overflow however long an object waits.
@(private) KEY_OBJECT :: u64(1<<20-1)

// Picks what the connection sends in this update, best last in keys, and
// returns the bits of object data it may write.
@(private)
repl_budget :: proc(h:^Host,p:^Peer) -> int {
    b:=&h.back
    r:=&b.repl
    r.key_count,r.key_cursor,r.key_overflow,r.key_wrote=0,0,false,false
    if r.protocol==nil {return 0}
    if !r.server {return PACKET_BYTES*8*h.desc.packets_per_update}
    if !b.send_pending {return 0}
    pr:=&p.repl
    keys:=r.keys
    handle:=peer_handle(h,p)
    count:=0
    for word,i in pr.work {
        for rest:=word;rest!=0;rest&=rest-1 {
            o:=i*64+bitset_first(rest)
            if pr.link[o]==.None || pr.link[o]==.Creating || pr.link[o]==.Destroying {bitset_clear(pr.work,o);continue}
            gain:=f64(r.priority[o])
            if r.owner[o]==handle {gain*=2}
            if r.filter[o]==.Spatial && pr.has_view && !pr.everywhere {
                reach:=f64(pr.view_radius)+f64(r.radius[o])
                gain*=clamp(1.25-math.sqrt(scope_distance_squared(r.position[o],pr.position))/max(reach,1),0.25,1)
            }
            pr.accum[o]+=gain
            key:=transmute(u64)pr.accum[o]&~KEY_OBJECT|u64(o)
            if count<len(keys) {
                at:=count
                count+=1
                for at>0 && keys[(at-1)/2]>key {
                    keys[at]=keys[(at-1)/2]
                    at=(at-1)/2
                }
                keys[at]=key
                continue
            }
            r.key_overflow=true
            if key<=keys[0] {continue}
            at:=0
            for {
                child:=at*2+1
                if child>=count {break}
                if child+1<count && keys[child+1]<keys[child] {child+=1}
                if keys[child]>=key {break}
                keys[at]=keys[child]
                at=child
            }
            keys[at]=key
        }
    }
    slice.sort(keys[:count])
    r.key_count=count
    return min(h.desc.replication.budget_bytes,int(max(p.tokens,0)))*8
}
