package serial

// References inside values: where a type holds an Entity, an Entity_Id or an
// Asset. Whoever clones, loads, instantiates or replicates values walks them
// to remap identities, and an asset walks them to list what it depends on.

REFS_LIMIT :: 4096

Ref :: struct {
    offset:u32,
    kind:Type_Kind, // Entity, Entity_Id or Asset
}

Ref_Proc :: #type proc(kind:Type_Kind,ref:rawptr,user:rawptr)

// Appends the place of every reference inside one value of the type, in
// order of offset. Fails when there are more than limit.
refs_collect :: proc(s:^Schema,type:Type_Index,refs:^[dynamic]Ref,limit:=REFS_LIMIT) -> bool {
    if !type_valid(s,type) {return false}
    holds:=make([]bool,len(s.types),context.temp_allocator)
    for candidate,index in s.types {
        #partial switch candidate.kind {
        case .Entity,.Entity_Id,.Asset:
            holds[index]=true
        case .Struct:
            for field in s.fields[candidate.first:][:candidate.count] {
                if holds[field.type] {holds[index]=true;break}
            }
        case .Array:
            holds[index]=candidate.count>0 && holds[candidate.elem]
        }
    }
    return refs_add(s,type,0,refs,holds,len(refs)+limit)
}

@(private="file")
refs_add :: proc(s:^Schema,index:Type_Index,offset:u32,refs:^[dynamic]Ref,holds:[]bool,limit:int) -> bool {
    if !holds[index] {return true}
    type:=s.types[index]
    #partial switch type.kind {
    case .Struct:
        for field in s.fields[type.first:][:type.count] {
            refs_add(s,field.type,offset+field.offset,refs,holds,limit) or_return
        }
    case .Array:
        size:=s.types[type.elem].size
        for i in 0..<type.count {
            refs_add(s,type.elem,offset+i*size,refs,holds,limit) or_return
        }
    case:
        if len(refs)>=limit {return false}
        append(refs,Ref{offset,type.kind})
    }
    return true
}

// Calls visit with every reference of count values laid stride bytes apart.
// When data does not hold them all, or stride is not positive with more than
// one value, it visits nothing.
refs_visit :: proc(refs:[]Ref,data:[]u8,stride:int,count:int,visit:Ref_Proc,user:rawptr) {
    if len(refs)==0 || count<=0 || count>1 && stride<=0 {return}
    end:=0
    for ref in refs {end=max(end,int(ref.offset)+(ref.kind==.Asset?16:8))}
    if end>len(data) || count>1 && count-1>(len(data)-end)/stride {return}
    for i in 0..<count {
        row:=data[i*stride:]
        for ref in refs {visit(ref.kind,&row[ref.offset],user)}
    }
}
