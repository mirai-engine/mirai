package ai

// Regions: the walkable spans split by a watershed over the distance to the
// walls, so that each region is a simple polygon without holes most of the
// time. The border columns are regions of their own that contours leave out.

@(private) NAV_BORDER_REGION :: u16(0x8000)
@(private) NAV_LEVEL_STACKS :: 8
@(private) NAV_EXPAND_ITERATIONS :: 8

@(private) Nav_Level_Entry :: struct {x,z,index:i32}
@(private) Nav_Dirty_Entry :: struct {index:i32,region,dist:u16}

@(private)
Nav_Region :: struct {
    connections:[dynamic]u16, // the regions around its outline in order, 0 for walls
    floors:[dynamic]u16,      // the regions above or below it in the same columns
    span_count:i32,
    id:u16,
    area:u8,
    remap,visited,overlap:bool,
}

// The distance of each span to the nearest span of another area or without a
// link, blurred once; returns the largest distance before the blur.
@(private="file")
nav_build_distance :: proc(s:^Nav_Build_Scratch,g:^Nav_Grid) -> (largest:u16,ok:bool) {
    n:=len(s.compact)
    if !nav_resize(&s.dist,n) || !nav_resize(&s.work,n) {return}
    side:=int(g.side)
    for z in 0..<side {
        for x in 0..<side {
            for i in int(s.cells[x+z*side])..<int(s.cells[x+z*side+1]) {
                same:=0
                for dir in 0..<4 {
                    con:=nav_con(s.compact[i],dir)
                    if con!=NAV_NOT_CONNECTED && s.area[nav_neighbor(s,side,x,z,dir,con)]==s.area[i] {same+=1}
                }
                s.dist[i]=0xffff if same==4 else 0
            }
        }
    }
    nav_chamfer(s,g,s.dist[:])
    for d in s.dist {largest=max(largest,d)}
    for z in 0..<side {
        for x in 0..<side {
            for i in int(s.cells[x+z*side])..<int(s.cells[x+z*side+1]) {
                center:=int(s.dist[i])
                if center<=2 {
                    s.work[i]=u16(center)
                    continue
                }
                sum:=center
                for dir in 0..<4 {
                    con:=nav_con(s.compact[i],dir)
                    if con==NAV_NOT_CONNECTED {
                        sum+=center*2
                        continue
                    }
                    ax,az:=x+nav_dx(dir),z+nav_dz(dir)
                    a:=int(s.cells[ax+az*side])+con
                    sum+=int(s.dist[a])
                    turn:=(dir+1)&3
                    con2:=nav_con(s.compact[a],turn)
                    sum+=int(s.dist[nav_neighbor(s,side,ax,az,turn,con2)]) if con2!=NAV_NOT_CONNECTED else center
                }
                s.work[i]=u16((sum+5)/9)
            }
        }
    }
    s.dist,s.work=s.work,s.dist
    return largest,true
}

@(private)
nav_build_regions :: proc(s:^Nav_Build_Scratch,g:^Nav_Grid) -> Nav_Build_Status {
    largest,ok:=nav_build_distance(s,g)
    if !ok {return .Out_Of_Memory}
    n:=len(s.compact)
    if !nav_resize(&s.region,n) || !nav_resize(&s.region_dist,n) {return .Out_Of_Memory}
    side:=int(g.side)
    id:=u16(1)
    border:=min(int(g.border),side)
    paint :: proc "contextless" (s:^Nav_Build_Scratch,side,x0,x1,z0,z1:int,id:u16) {
        for z in z0..<z1 {
            for x in x0..<x1 {
                for i in int(s.cells[x+z*side])..<int(s.cells[x+z*side+1]) {
                    if s.area[i]!=NAV_AREA_BLOCKED {s.region[i]=id}
                }
            }
        }
    }
    paint(s,side,0,border,0,side,id|NAV_BORDER_REGION);id+=1
    paint(s,side,side-border,side,0,side,id|NAV_BORDER_REGION);id+=1
    paint(s,side,0,side,0,border,id|NAV_BORDER_REGION);id+=1
    paint(s,side,0,side,side-border,side,id|NAV_BORDER_REGION);id+=1
    level:=u16((int(largest)+1)&~1)
    stack_id:=-1
    for level>0 {
        level=level-2 if level>=2 else 0
        stack_id=(stack_id+1)&(NAV_LEVEL_STACKS-1)
        stack:=&s.levels[stack_id]
        if stack_id==0 {
            if !nav_sort_levels(s,g,level) {return .Out_Of_Memory}
        } else {
            for e in s.levels[stack_id-1] {
                if e.index<0 || s.region[e.index]!=0 {continue}
                if _,error:=append(stack,e);error!=nil {return .Out_Of_Memory}
            }
        }
        if !nav_expand_regions(s,g,NAV_EXPAND_ITERATIONS,level,stack,false) {return .Out_Of_Memory}
        for j in 0..<len(stack) {
            e:=stack[j]
            if e.index<0 || s.region[e.index]!=0 {continue}
            flooded,flood_ok:=nav_flood_region(s,g,e,level,id)
            if !flood_ok {return .Out_Of_Memory}
            if flooded {
                if id>=0x7ffe {return .Too_Large}
                id+=1
            }
        }
    }
    if !nav_expand_regions(s,g,NAV_EXPAND_ITERATIONS*8,0,&s.stack,true) {return .Out_Of_Memory}
    return nav_filter_regions(s,g,id)
}

// Spreads the cells of the next levels into the stacks, two distance levels each.
@(private="file")
nav_sort_levels :: proc(s:^Nav_Build_Scratch,g:^Nav_Grid,level:u16) -> bool {
    side:=int(g.side)
    start:=int(level>>1)
    for &stack in s.levels {clear(&stack)}
    for z in 0..<side {
        for x in 0..<side {
            for i in int(s.cells[x+z*side])..<int(s.cells[x+z*side+1]) {
                if s.area[i]==NAV_AREA_BLOCKED || s.region[i]!=0 {continue}
                stack_id:=max(start-int(s.dist[i]>>1),0)
                if stack_id>=NAV_LEVEL_STACKS {continue}
                if _,error:=append(&s.levels[stack_id],Nav_Level_Entry{i32(x),i32(z),i32(i)});error!=nil {return false}
            }
        }
    }
    return true
}

// Grows the regions into the cells of the stack, a ring per iteration.
@(private="file")
nav_expand_regions :: proc(s:^Nav_Build_Scratch,g:^Nav_Grid,iterations:int,level:u16,stack:^[dynamic]Nav_Level_Entry,fill:bool) -> bool {
    side:=int(g.side)
    if fill {
        clear(stack)
        for z in 0..<side {
            for x in 0..<side {
                for i in int(s.cells[x+z*side])..<int(s.cells[x+z*side+1]) {
                    if s.dist[i]<level || s.region[i]!=0 || s.area[i]==NAV_AREA_BLOCKED {continue}
                    if _,error:=append(stack,Nav_Level_Entry{i32(x),i32(z),i32(i)});error!=nil {return false}
                }
            }
        }
    } else {
        for &e in stack {if e.index>=0 && s.region[e.index]!=0 {e.index=-1}}
    }
    iteration:=0
    for len(stack)>0 {
        failed:=0
        clear(&s.dirty)
        for &e in stack {
            if e.index<0 {failed+=1;continue}
            i:=int(e.index)
            region:=s.region[i]
            best:=0xffff
            for dir in 0..<4 {
                con:=nav_con(s.compact[i],dir)
                if con==NAV_NOT_CONNECTED {continue}
                a:=nav_neighbor(s,side,int(e.x),int(e.z),dir,con)
                if s.area[a]!=s.area[i] {continue}
                if s.region[a]>0 && s.region[a]&NAV_BORDER_REGION==0 && int(s.region_dist[a])+2<best {
                    region=s.region[a]
                    best=int(s.region_dist[a])+2
                }
            }
            if region!=0 {
                e.index=-1
                if _,error:=append(&s.dirty,Nav_Dirty_Entry{i32(i),region,u16(best)});error!=nil {return false}
            } else {
                failed+=1
            }
        }
        for d in s.dirty {
            s.region[d.index]=d.region
            s.region_dist[d.index]=d.dist
        }
        if failed==len(stack) {break}
        if level>0 {
            iteration+=1
            if iteration>=iterations {break}
        }
    }
    return true
}

// Floods a new region from the span over the cells at the level or above
// that do not touch another region; false when it took no cell.
@(private="file")
nav_flood_region :: proc(s:^Nav_Build_Scratch,g:^Nav_Grid,start:Nav_Level_Entry,level,id:u16) -> (flooded,ok:bool) {
    side:=int(g.side)
    area:=s.area[start.index]
    clear(&s.stack)
    if _,error:=append(&s.stack,start);error!=nil {return}
    s.region[start.index]=id
    s.region_dist[start.index]=0
    low:=level-2 if level>=2 else 0
    count:=0
    for len(s.stack)>0 {
        e:=pop(&s.stack)
        x,z,i:=int(e.x),int(e.z),int(e.index)
        span:=s.compact[i]
        other:u16
        for dir in 0..<4 {
            con:=nav_con(span,dir)
            if con==NAV_NOT_CONNECTED {continue}
            ax,az:=x+nav_dx(dir),z+nav_dz(dir)
            a:=int(s.cells[ax+az*side])+con
            if s.area[a]!=area {continue}
            r:=s.region[a]
            if r&NAV_BORDER_REGION!=0 {continue}
            if r!=0 && r!=id {other=r;break}
            turn:=(dir+1)&3
            con2:=nav_con(s.compact[a],turn)
            if con2==NAV_NOT_CONNECTED {continue}
            a2:=nav_neighbor(s,side,ax,az,turn,con2)
            if s.area[a2]!=area {continue}
            if r2:=s.region[a2];r2!=0 && r2!=id {other=r2;break}
        }
        if other!=0 {
            s.region[i]=0
            continue
        }
        count+=1
        for dir in 0..<4 {
            con:=nav_con(span,dir)
            if con==NAV_NOT_CONNECTED {continue}
            ax,az:=x+nav_dx(dir),z+nav_dz(dir)
            a:=int(s.cells[ax+az*side])+con
            if s.area[a]!=area || s.dist[a]<low || s.region[a]!=0 {continue}
            s.region[a]=id
            s.region_dist[a]=0
            if _,error:=append(&s.stack,Nav_Level_Entry{i32(ax),i32(az),i32(a)});error!=nil {return}
        }
    }
    return count>0,true
}

@(private="file")
nav_solid_edge :: #force_inline proc "contextless" (s:^Nav_Build_Scratch,side,x,z,i,dir:int) -> bool {
    r:u16
    if con:=nav_con(s.compact[i],dir);con!=NAV_NOT_CONNECTED {r=s.region[nav_neighbor(s,side,x,z,dir,con)]}
    return r!=s.region[i]
}

// The regions met walking the outline of the region of the span, starting at
// a solid edge in direction dir.
@(private="file")
nav_region_outline :: proc(s:^Nav_Build_Scratch,side,x,z,i,dir:int,out:^[dynamic]u16) -> bool {
    x,z,i,dir:=x,z,i,dir
    start_i,start_dir:=i,dir
    current:u16
    if con:=nav_con(s.compact[i],dir);con!=NAV_NOT_CONNECTED {current=s.region[nav_neighbor(s,side,x,z,dir,con)]}
    if _,error:=append(out,current);error!=nil {return false}
    for _ in 0..<4*len(s.compact)+4 {
        con:=nav_con(s.compact[i],dir)
        if nav_solid_edge(s,side,x,z,i,dir) {
            r:u16
            if con!=NAV_NOT_CONNECTED {r=s.region[nav_neighbor(s,side,x,z,dir,con)]}
            if r!=current {
                current=r
                if _,error:=append(out,current);error!=nil {return false}
            }
            dir=(dir+1)&3
        } else {
            if con==NAV_NOT_CONNECTED {break}
            i=nav_neighbor(s,side,x,z,dir,con)
            x,z=x+nav_dx(dir),z+nav_dz(dir)
            dir=(dir+3)&3
        }
        if i==start_i && dir==start_dir {break}
    }
    nav_remove_adjacent(out)
    return true
}

@(private="file")
nav_remove_adjacent :: proc(list:^[dynamic]u16) {
    for i:=0;i<len(list) && len(list)>1; {
        if list[i]==list[(i+1)%len(list)] {ordered_remove(list,i)} else {i+=1}
    }
}

@(private="file")
nav_replace_neighbor :: proc(r:^Nav_Region,old,new:u16) {
    changed:=false
    for &c in r.connections {if c==old {c=new;changed=true}}
    for &f in r.floors {if f==old {f=new}}
    if changed {nav_remove_adjacent(&r.connections)}
}

@(private="file")
nav_can_merge :: proc "contextless" (a,b:^Nav_Region) -> bool {
    if a.area!=b.area {return false}
    shared:=0
    for c in a.connections {if c==b.id {shared+=1}}
    if shared>1 {return false}
    for f in a.floors {if f==b.id {return false}}
    return true
}

@(private="file")
nav_add_floor :: proc(r:^Nav_Region,id:u16) -> bool {
    for f in r.floors {if f==id {return true}}
    _,error:=append(&r.floors,id)
    return error==nil
}

// Joins b into a: the outlines are spliced where they meet.
@(private="file")
nav_merge_regions :: proc(s:^Nav_Build_Scratch,a,b:^Nav_Region) -> (merged,ok:bool) {
    insert_a,insert_b:=-1,-1
    for c,i in a.connections {if c==b.id {insert_a=i;break}}
    for c,i in b.connections {if c==a.id {insert_b=i;break}}
    if insert_a<0 || insert_b<0 {return false,true}
    clear(&s.ints)
    for c in a.connections {if _,error:=append(&s.ints,i32(c));error!=nil {return}}
    clear(&a.connections)
    na,nb:=len(s.ints),len(b.connections)
    for i in 0..<na-1 {if _,error:=append(&a.connections,u16(s.ints[(insert_a+1+i)%na]));error!=nil {return}}
    for i in 0..<nb-1 {if _,error:=append(&a.connections,b.connections[(insert_b+1+i)%nb]);error!=nil {return}}
    nav_remove_adjacent(&a.connections)
    for f in b.floors {if !nav_add_floor(a,f) {return}}
    a.span_count+=b.span_count
    b.span_count=0
    clear(&b.connections)
    return true,true
}

// Drops the islands smaller than min_region (unless they reach the tile
// border, whose size the tile cannot know), merges the regions smaller than
// merge_region into a neighbor, and numbers the rest from 1.
@(private="file")
nav_filter_regions :: proc(s:^Nav_Build_Scratch,g:^Nav_Grid,count_id:u16) -> Nav_Build_Status {
    side:=int(g.side)
    count:=int(count_id)+1
    for len(s.regions)<count {
        if _,error:=append(&s.regions,Nav_Region{});error!=nil {return .Out_Of_Memory}
    }
    regions:=s.regions[:count]
    for &r,i in regions {
        clear(&r.connections)
        clear(&r.floors)
        r.span_count=0
        r.id=u16(i)
        r.area=0
        r.remap,r.visited,r.overlap=false,false,false
    }
    for z in 0..<side {
        for x in 0..<side {
            c:=x+z*side
            for i in int(s.cells[c])..<int(s.cells[c+1]) {
                id:=s.region[i]
                if id==0 || int(id)>=count {continue}
                r:=&regions[id]
                r.span_count+=1
                for j in int(s.cells[c])..<int(s.cells[c+1]) {
                    if i==j {continue}
                    floor:=s.region[j]
                    if floor==0 || int(floor)>=count {continue}
                    if floor==id {r.overlap=true}
                    if !nav_add_floor(r,floor) {return .Out_Of_Memory}
                }
                if len(r.connections)>0 {continue}
                r.area=s.area[i]
                for dir in 0..<4 {
                    if !nav_solid_edge(s,side,x,z,i,dir) {continue}
                    if !nav_region_outline(s,side,x,z,i,dir,&r.connections) {return .Out_Of_Memory}
                    break
                }
            }
        }
    }
    for i in 0..<count {
        r:=&regions[i]
        if r.id==0 || r.id&NAV_BORDER_REGION!=0 || r.span_count==0 || r.visited {continue}
        reaches_border:=false
        spans:=0
        clear(&s.ints)
        clear(&s.trace)
        r.visited=true
        if _,error:=append(&s.ints,i32(i));error!=nil {return .Out_Of_Memory}
        for len(s.ints)>0 {
            ri:=pop(&s.ints)
            current:=&regions[ri]
            spans+=int(current.span_count)
            if _,error:=append(&s.trace,ri);error!=nil {return .Out_Of_Memory}
            for c in current.connections {
                if c&NAV_BORDER_REGION!=0 {reaches_border=true;continue}
                other:=&regions[c]
                if other.visited || other.id==0 || other.id&NAV_BORDER_REGION!=0 {continue}
                other.visited=true
                if _,error:=append(&s.ints,i32(other.id));error!=nil {return .Out_Of_Memory}
            }
        }
        if spans<int(g.min_region) && !reaches_border {
            for t in s.trace {regions[t].span_count=0;regions[t].id=0}
        }
    }
    for {
        merges:=0
        for i in 0..<count {
            r:=&regions[i]
            if r.id==0 || r.id&NAV_BORDER_REGION!=0 || r.overlap || r.span_count==0 {continue}
            walled:=false
            for c in r.connections {if c==0 {walled=true;break}}
            if int(r.span_count)>int(g.merge_region) && walled {continue}
            smallest:=max(i32)
            target:=r.id
            for c in r.connections {
                if c&NAV_BORDER_REGION!=0 {continue}
                other:=&regions[c]
                if other.id==0 || other.id&NAV_BORDER_REGION!=0 || other.overlap {continue}
                if other.span_count<smallest && nav_can_merge(r,other) && nav_can_merge(other,r) {
                    smallest=other.span_count
                    target=other.id
                }
            }
            if target==r.id {continue}
            old:=r.id
            merged,ok:=nav_merge_regions(s,&regions[target],r)
            if !ok {return .Out_Of_Memory}
            if !merged {continue}
            for &other in regions {
                if other.id==0 || other.id&NAV_BORDER_REGION!=0 {continue}
                if other.id==old {other.id=target}
                nav_replace_neighbor(&other,old,target)
            }
            merges+=1
        }
        if merges==0 {break}
    }
    for &r in regions {r.remap=r.id!=0 && r.id&NAV_BORDER_REGION==0}
    next:=u16(0)
    for i in 0..<count {
        if !regions[i].remap {continue}
        old:=regions[i].id
        next+=1
        for j in i..<count {
            if regions[j].id==old {regions[j].id=next;regions[j].remap=false}
        }
    }
    for &id in s.region {
        if id&NAV_BORDER_REGION==0 && int(id)<count {id=regions[id].id}
    }
    return .Built
}
