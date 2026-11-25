package kai

import "mirai:std/diff"
import "mirai:store"

// A driver merges the sides of one file and moves an anchor from one version
// of a file to another. It is a pure, deterministic procedure of its inputs:
// the same inputs give the same bytes. Drivers are asked in the order given,
// then the built-in text and binary ones; one that does not know the file
// says Unsupported.

Driver_Result :: enum u8 {
    Resolved,    // out holds the merged file
    Conflicted,  // out holds the partial result a checkout writes: text with markers, a document with ours where they disagree
    Unsupported, // not a file this driver knows
    Error,
}

Driver_Input :: struct {
    path:string,
    base,ours,theirs:[]u8,
    has_base:bool, // false: both sides added the file
}

Anchor_Kind :: enum u8 {File,Lines,Structural}

// A place in a file a comment hangs on.
Anchor :: struct {
    kind:Anchor_Kind,
    line:u32,  // Lines: the first line, from 1
    lines:u32, // Lines: how many
    key:u64,   // Structural: what a driver names, as an entity's id
    field:u64, // Structural: a table or field under it, by the hash of its name
}

Driver :: struct {
    data:rawptr,
    merge:proc(data:rawptr,input:^Driver_Input,out:^[dynamic]u8) -> Driver_Result,
    // known false: not a file this driver knows; moved false: what the anchor named is gone
    anchor:proc(data:rawptr,from,to:[]u8,anchor:^Anchor) -> (moved,known:bool),
}

// Asks the drivers, then text and binary, until one knows the file.
drivers_merge :: proc(drivers:[]Driver,input:^Driver_Input,out:^[dynamic]u8) -> (result:Driver_Result) {
    for d in drivers {
        if d.merge==nil {continue}
        clear(out)
        result=d.merge(d.data,input,out)
        if result!=.Unsupported {return}
    }
    builtin:=[2]Driver{{merge=text_merge},{merge=binary_merge}}
    for d in builtin {
        clear(out)
        result=d.merge(d.data,input,out)
        if result!=.Unsupported {return}
    }
    return .Unsupported
}

// Moves an anchor with the first driver that knows the file, else as text
// for lines. False when what it named is gone.
drivers_anchor :: proc(drivers:[]Driver,from,to:[]u8,anchor:^Anchor) -> bool {
    for d in drivers {
        if d.anchor==nil {continue}
        if moved,known:=d.anchor(d.data,from,to,anchor);known {return moved}
    }
    return text_anchor(from,to,anchor)
}

// A file is binary when a NUL appears in its first 8000 bytes.
binary :: proc "contextless" (bytes:[]u8) -> bool {
    for b in bytes[:min(len(bytes),8000)] {
        if b==0 {return true}
    }
    return false
}

@(private)
text_merge :: proc(_:rawptr,input:^Driver_Input,out:^[dynamic]u8) -> Driver_Result {
    if binary(input.base) || binary(input.ours) || binary(input.theirs) {return .Unsupported}
    base,ours,theirs:=string(input.base),string(input.ours),string(input.theirs)
    hunks:=make([dynamic]diff.Hunk,context.temp_allocator)
    conflicts,e:=diff.merge3(base,ours,theirs,&hunks,context.temp_allocator)
    if e!=.None {return e==.Too_Large?.Unsupported:.Error}
    if conflicts==0 {
        return diff.merged(base,ours,theirs,hunks[:],out)==.None ? .Resolved : .Error
    }
    texts:=[diff.Text]string{.Base=base,.Ours=ours,.Theirs=theirs}
    section :: proc(out:^[dynamic]u8,text:string) {
        append(out,text)
        if len(text)>0 && text[len(text)-1]!='\n' {append(out,'\n')}
    }
    for h in hunks {
        if !h.conflict {
            r:=h.bytes[h.take]
            append(out,texts[h.take][r.start:r.end])
            continue
        }
        append(out,"<<<<<<< ours\n")
        section(out,ours[h.bytes[.Ours].start:h.bytes[.Ours].end])
        append(out,"||||||| base\n")
        section(out,base[h.bytes[.Base].start:h.bytes[.Base].end])
        append(out,"=======\n")
        section(out,theirs[h.bytes[.Theirs].start:h.bytes[.Theirs].end])
        append(out,">>>>>>> theirs\n")
    }
    return .Conflicted
}

@(private)
binary_merge :: proc(_:rawptr,input:^Driver_Input,out:^[dynamic]u8) -> Driver_Result {
    append(out,..input.ours)
    return .Conflicted
}

// Moves the lines of an anchor to where they are in to; false when its first
// line is gone.
@(private)
text_anchor :: proc(from,to:[]u8,anchor:^Anchor) -> bool {
    if anchor.kind!=.Lines {return true}
    lines:=make([dynamic]diff.Line,context.temp_allocator)
    if _,e:=diff.lines(string(from),string(to),&lines,context.temp_allocator);e!=.None {return false}
    for l in lines {
        if l.op==.Same && u32(l.old)==anchor.line {
            anchor.line=u32(l.new)
            return true
        }
    }
    return false
}
