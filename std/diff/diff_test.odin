package diff

import "base:runtime"
import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:testing"

@(private="file")
ops_of :: proc(lines:[]Line) -> string {
    b:=strings.builder_make(context.temp_allocator)
    marks:=[Op]u8{.Same='=',.Add='+',.Remove='-'}
    for line in lines {strings.write_byte(&b,marks[line.op])}
    return strings.to_string(b)
}

@(private="file")
rows_of :: proc(rows:[]Row) -> string {
    b:=strings.builder_make(context.temp_allocator)
    for row in rows {
        if row.line<0 {fmt.sbprintf(&b,"[%d]",row.skipped)} else {fmt.sbprintf(&b,"%d ",row.line)}
    }
    return strings.to_string(b)
}

@(private="file")
numbered :: proc(count:int,changed:..int) -> string {
    b:=strings.builder_make(context.temp_allocator)
    outer: for i in 0..<count {
        for c in changed {if c==i {fmt.sbprintf(&b,"X%d\n",i);continue outer}}
        fmt.sbprintf(&b,"L%d\n",i)
    }
    return strings.to_string(b)
}

@(private="file")
text_of :: proc(old,new:string,line:Line) -> string {
    text:=old if line.op==.Remove else new
    return text[line.start:line.end]
}

// The lines rebuild both texts, line numbers count up in each and stats count the edits.
@(private="file")
expect_script :: proc(t:^testing.T,old,new:string,out:[]Line,stats:Stats,loc:=#caller_location) {
    rebuilt:[2]strings.Builder
    for &b in rebuilt {b=strings.builder_make(context.temp_allocator)}
    i,j,added,removed:=0,0,0,0
    for line in out {
        text:=text_of(old,new,line)
        if line.op!=.Add {i+=1;testing.expect_value(t,int(line.old),i,loc);fmt.sbprintf(&rebuilt[0],"%s\n",text)}
        if line.op!=.Remove {j+=1;testing.expect_value(t,int(line.new),j,loc);fmt.sbprintf(&rebuilt[1],"%s\n",text)}
        if line.op==.Add {added+=1}
        if line.op==.Remove {removed+=1}
    }
    testing.expect_value(t,stats,Stats{added,removed},loc)
    plain :: proc(text:string) -> string {
        s,_:=strings.replace_all(text,"\r\n","\n",context.temp_allocator)
        if len(s)>0&&s[len(s)-1]!='\n' {s=strings.concatenate({s,"\n"},context.temp_allocator)}
        return s
    }
    testing.expect_value(t,strings.to_string(rebuilt[0]),plain(old),loc)
    testing.expect_value(t,strings.to_string(rebuilt[1]),plain(new),loc)
}

// The hunks cover each text in order, without gaps.
@(private="file")
expect_tiling :: proc(t:^testing.T,texts:[Text]string,hunks:[]Hunk,loc:=#caller_location) {
    for k in Text {
        at:=i32(0)
        for h in hunks {
            testing.expect_value(t,h.bytes[k].start,at,loc)
            at=h.bytes[k].end
        }
        testing.expect_value(t,int(at),len(texts[k]),loc)
    }
}

// Merges, checks the tiling and gives the merged text or "" with the count of conflicts.
@(private="file")
merge_text :: proc(t:^testing.T,base,ours,theirs:string,loc:=#caller_location) -> (text:string,conflicts:int) {
    hunks:[dynamic]Hunk
    defer delete(hunks)
    err:Error
    conflicts,err=merge3(base,ours,theirs,&hunks)
    testing.expect_value(t,err,Error.None,loc)
    expect_tiling(t,{.Base=base,.Ours=ours,.Theirs=theirs},hunks[:],loc)
    bytes:=make([dynamic]u8,context.temp_allocator)
    e:=merged(base,ours,theirs,hunks[:],&bytes)
    testing.expect_value(t,e,Error.Conflict if conflicts>0 else Error.None,loc)
    return string(bytes[:]),conflicts
}

@(test)
histogram_diff_and_merge3_cases :: proc(t:^testing.T) {
    Diff_Case :: struct {old,new,ops:string}
    diffs:=[]Diff_Case{
        {"","",""},
        {"a\nb\nc\n","a\nb\nc\n","==="},
        {"","a\nbc","++"},
        {"a\nbc","","--"},
        {"a\n","b\n","-+"},
        {"a","a\n","="},
        {"a\nb\nc\n","a\nb\nx\nc\n","==+="},
        {"a\nbb\nc\n","a\nc\n","=-="},
        {"a\nb\nc\nd\n","a\nx\ny\nd\n","=--++="},
        {"1\n2\n3\n","4\n5\n6\n","---+++"},
        {"a\nx\nb\nx\nc\n","a\ny\nb\ny\nc\n","=-+=-+="},
        {"a\r\nb\r\n","a\nb\n","=="},
        {"a\r\nbb\r\nc","a\nc\n","=-="},
        {"a\nb\n","a\nb\nc","==+"},
        {"\n","","-"},
        {"a\n\n","a\n","=-"},
        {"a\na\na\n","a\na\n","==-"},
        {"x\ny\nx\ny\n","y\nx\ny\nx\n","-===+"},
        {"{\n}\n{\n}\n","{\nk\n}\n{\n}\n","=+==="},
        {"keep\nold one\nshared\nold two\ntail\n","new zero\nkeep\nshared\nnew two\nadded\ntail","+=-=-++="},
    }
    out:[dynamic]Line
    defer delete(out)
    for c in diffs {
        stats,err:=lines(c.old,c.new,&out)
        testing.expect_value(t,err,Error.None)
        testing.expect_value(t,ops_of(out[:]),c.ops)
        expect_script(t,c.old,c.new,out[:],stats)
    }

    Merge_Case :: struct {base,ours,theirs,want:string,conflicts:int}
    merges:=[]Merge_Case{
        {"","","","",0},
        {"a\n","a\n","a\n","a\n",0},
        {"","x\n","","x\n",0},
        {"","x\n","y\n","",1},
        {"","x\n","x\n","x\n",0},
        {"a\nb\nc\n","a\nB\nc\n","a\nb\nc\n","a\nB\nc\n",0},
        {"a\nb\nc\n","a\nb\nc\n","a\nb\n","a\nb\n",0},
        {"1\n2\n3\n4\n5\n","1\nX\n3\n4\n5\n","1\n2\n3\n4\nY\n","1\nX\n3\n4\nY\n",0},
        {"a\nb\nc\n","a\nX\nc\nd\n","a\nX\nc\n","a\nX\nc\nd\n",0},
        {"a\nb\nc\n","a\nc\n","a\nc\n","a\nc\n",0},
        {"a\nb\nc\n","a\nX\nc\n","a\nY\nc\n","",1},
        {"a\nb\nc\n","A\nb\nc\n","a\nB\nc\n","",1},
        {"a\nb\nc\n","a\nc\n","a\nB\nc\n","",1},
        {"a\nb\nc\nd\ne\n","a\nX\nc\nd\ne\n","a\nb\nc\nd\nY\n","a\nX\nc\nd\nY\n",0},
        {"a\r\nb\r\nc\r\n","a\r\nB\r\nc\r\n","a\r\nb\r\nc\r\nd\r\n","a\r\nB\r\nc\r\nd\r\n",0},
        {"a\nb\n","a\r\nb\n","a\nb\nc\n","a\r\nb\nc\n",0},
        {"a\nb","a\nb\n","x\na\nb","x\na\nb\n",0},
        {"a\nb","a\nb\n","a\nb\r\n","",1},
    }
    for c in merges {
        text,conflicts:=merge_text(t,c.base,c.ours,c.theirs)
        testing.expect_value(t,conflicts,c.conflicts)
        testing.expect_value(t,text,c.want)
    }

    hunks:[dynamic]Hunk
    defer delete(hunks)
    conflicts,err:=merge3("a\nb\nc\n","a\nXX\nc\n","a\nY\nc\n",&hunks)
    testing.expect_value(t,conflicts,1)
    testing.expect_value(t,err,Error.None)
    testing.expect_value(t,len(hunks),3)
    testing.expect_value(t,hunks[1],Hunk{bytes={.Base={2,4},.Ours={2,5},.Theirs={2,4}},conflict=true})
}

@(test)
diff_line_numbers_and_byte_ranges :: proc(t:^testing.T) {
    old:="keep\nold one\nshared\nold two\ntail\n"
    new:="new zero\nkeep\nshared\nnew two\nadded\ntail"
    out:[dynamic]Line
    defer delete(out)
    _,err:=lines(old,new,&out)
    testing.expect_value(t,err,Error.None)
    want:=[]Line{
        {.Add,0,1,0,8},
        {.Same,1,2,9,13},
        {.Remove,2,0,5,12},
        {.Same,3,3,14,20},
        {.Remove,4,0,20,27},
        {.Add,0,4,21,28},
        {.Add,0,5,29,34},
        {.Same,5,6,35,39},
    }
    texts:=[]string{"new zero","keep","old one","shared","old two","new two","added","tail"}
    testing.expect_value(t,len(out),len(want))
    for line,i in out {
        testing.expect_value(t,line,want[i])
        testing.expect_value(t,text_of(old,new,line),texts[i])
    }
    crlf:="a\r\nbb\r\nc"
    _,err=lines(crlf,"a\nc\n",&out)
    testing.expect_value(t,out[1],Line{.Remove,2,0,3,5})
    testing.expect_value(t,text_of(crlf,"",out[1]),"bb")
}

@(test)
diff_rows_fold_long_runs_of_same :: proc(t:^testing.T) {
    out:[dynamic]Line
    view:[dynamic]Row
    defer {delete(out);delete(view)}
    lines(numbered(10),numbered(10,5),&out)
    testing.expect_value(t,ops_of(out[:]),"=====-+====")
    rows(out[:],0,&view)
    testing.expect_value(t,rows_of(view[:]),"[5]5 6 [4]")
    rows(out[:],3,&view)
    testing.expect_value(t,rows_of(view[:]),"[2]2 3 4 5 6 7 8 9 [1]")
    rows(out[:],5,&view)
    testing.expect_value(t,rows_of(view[:]),"0 1 2 3 4 5 6 7 8 9 10 ")
    rows(out[:],-4,&view)
    testing.expect_value(t,rows_of(view[:]),"[5]5 6 [4]")

    lines(numbered(6),numbered(6,0,5),&out)
    testing.expect_value(t,ops_of(out[:]),"-+====-+")
    rows(out[:],1,&view)
    testing.expect_value(t,rows_of(view[:]),"0 1 2 [2]5 6 7 ")

    lines(numbered(12),numbered(12,2,9),&out)
    testing.expect_value(t,ops_of(out[:]),"==-+======-+==")
    rows(out[:],3,&view)
    testing.expect_value(t,rows_of(view[:]),"0 1 2 3 4 5 6 7 8 9 10 11 12 13 ")
    rows(out[:],2,&view)
    testing.expect_value(t,rows_of(view[:]),"0 1 2 3 4 5 [2]8 9 10 11 12 13 ")

    lines(numbered(4),numbered(4),&out)
    rows(out[:],3,&view)
    testing.expect_value(t,rows_of(view[:]),"[4]")
    lines("","",&out)
    rows(out[:],3,&view)
    testing.expect_value(t,len(view),0)
}

@(test)
diff_and_merge3_of_random_texts_keep_their_inputs :: proc(t:^testing.T) {
    random_text :: proc(words:[]string,count:int) -> string {
        b:=strings.builder_make(context.temp_allocator)
        for _ in 0..<rand.int_max(count+1) {strings.write_string(&b,rand.choice(words))}
        if rand.int_max(4)==0 {strings.write_string(&b,"tail")}
        return strings.to_string(b)
    }
    edit :: proc(text:string,words:[]string) -> string {
        parts:=strings.split_after(text,"\n",context.temp_allocator)
        b:=strings.builder_make(context.temp_allocator)
        for part in parts {
            switch rand.int_max(6) {
            case 0:
            case 1:strings.write_string(&b,rand.choice(words))
            case 2:strings.write_string(&b,rand.choice(words));strings.write_string(&b,part)
            case:strings.write_string(&b,part)
            }
        }
        return strings.to_string(b)
    }
    words:=[]string{"a\n","b\n","c\n","a\r\n","{\n","}\n","\n"}
    out:[dynamic]Line
    defer delete(out)
    for _ in 0..<500 {
        base:=random_text(words,16)
        ours,theirs:=edit(base,words),edit(base,words)
        stats,err:=lines(ours,theirs,&out)
        testing.expect_value(t,err,Error.None)
        expect_script(t,ours,theirs,out[:],stats)
        text,conflicts:=merge_text(t,base,ours,base)
        testing.expect_value(t,conflicts,0)
        testing.expect_value(t,text,ours)
        text,conflicts=merge_text(t,base,base,theirs)
        testing.expect_value(t,conflicts,0)
        testing.expect_value(t,text,theirs)
        text,conflicts=merge_text(t,base,ours,ours)
        testing.expect_value(t,conflicts,0)
        testing.expect_value(t,text,ours)
        merge_text(t,base,ours,theirs)
        free_all(context.temp_allocator)
    }

    old,new:=numbered(400,7,150,151,390),numbered(400,9,200,201,202)
    stats,err:=lines(old,new,&out)
    testing.expect_value(t,err,Error.None)
    testing.expect_value(t,stats,Stats{8,8})
    expect_script(t,old,new,out[:],stats)
}

@(private="file")
Failing :: struct {left:int,backing:runtime.Allocator}

@(private="file")
failing_proc :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    f:=(^Failing)(data)
    #partial switch mode {
    case .Alloc,.Alloc_Non_Zeroed,.Resize,.Resize_Non_Zeroed:
        if f.left==0 {return nil,.Out_Of_Memory}
        f.left-=1
    }
    return f.backing.procedure(f.backing.data,mode,size,alignment,old_memory,old_size,loc)
}

@(test)
diff_and_merge3_survive_hostile_inputs :: proc(t:^testing.T) {
    out:[dynamic]Line
    view:[dynamic]Row
    hunks:[dynamic]Hunk
    defer {delete(out);delete(view);delete(hunks)}

    alphabet:=[]u8{'\n','\r','a','b',0,0xff}
    random_bytes :: proc(alphabet:[]u8) -> string {
        b:=make([]u8,rand.int_max(200),context.temp_allocator)
        for &c in b {c=rand.choice(alphabet)}
        return string(b)
    }
    for _ in 0..<300 {
        texts:=[Text]string{.Base=random_bytes(alphabet),.Ours=random_bytes(alphabet),.Theirs=random_bytes(alphabet)}
        stats,err:=lines(texts[.Ours],texts[.Theirs],&out)
        testing.expect_value(t,err,Error.None)
        expect_script(t,texts[.Ours],texts[.Theirs],out[:],stats)
        testing.expect_value(t,rows(out[:],rand.int_max(5)-1,&view),Error.None)
        _,err=merge3(texts[.Base],texts[.Ours],texts[.Theirs],&hunks)
        testing.expect_value(t,err,Error.None)
        expect_tiling(t,texts,hunks[:])
        free_all(context.temp_allocator)
    }

    many :: proc(count:int,line:proc(i:int) -> string) -> string {
        b:=strings.builder_make(context.temp_allocator)
        for i in 0..<count {strings.write_string(&b,line(i))}
        return strings.to_string(b)
    }
    same_line:=many(50_000,proc(i:int) -> string {return "x\n"})
    one_changed:=many(50_000,proc(i:int) -> string {return "y\n" if i==25_000 else "x\n"})
    alternating:=many(40_000,proc(i:int) -> string {return "a\n" if i%2==0 else "b\n"})
    shifted:=many(40_000,proc(i:int) -> string {return "b\n" if i%2==0 else "a\n"})
    unique:=many(20_000,proc(i:int) -> string {return fmt.tprintf("%d\n",i)})
    scrambled:=many(20_000,proc(i:int) -> string {return fmt.tprintf("%d\n",(i*7919)%20_000)})
    Pair :: struct {old,new:string}
    for p in ([]Pair{{same_line,one_changed},{alternating,shifted},{same_line,alternating},{unique,scrambled}}) {
        stats,err:=lines(p.old,p.new,&out)
        testing.expect_value(t,err,Error.None)
        expect_script(t,p.old,p.new,out[:],stats)
        _,err=merge3(p.old,p.new,p.old,&hunks)
        testing.expect_value(t,err,Error.None)
        expect_tiling(t,{.Base=p.old,.Ours=p.new,.Theirs=p.old},hunks[:])
    }
    stats,_:=lines(same_line,one_changed,&out)
    testing.expect_value(t,stats,Stats{1,1})
    free_all(context.temp_allocator)

    huge:=transmute(string)runtime.Raw_String{data=raw_data(same_line),len=MAX_BYTES}
    _,err:=lines(huge,"a\n",&out)
    testing.expect_value(t,err,Error.Too_Large)
    _,err=merge3("",huge,"a",&hunks)
    testing.expect_value(t,err,Error.Too_Large)

    base,ours,theirs:="a\nb\nc\nd\n","a\nB\nc\nd\n","a\nb\nc\nD\n"
    _,err=merge3(base,ours,theirs,&hunks)
    testing.expect_value(t,err,Error.None)
    bytes:[dynamic]u8
    defer delete(bytes)
    bad:=[]Hunk{
        {bytes={.Base={0,99},.Ours={},.Theirs={}},take=.Base},
        {bytes={.Base={},.Ours={3,2},.Theirs={}},take=.Ours},
        {bytes={.Base={},.Ours={},.Theirs={-1,0}},take=.Theirs},
        {take=Text(7)},
    }
    for h in bad {testing.expect_value(t,merged(base,ours,theirs,[]Hunk{h},&bytes),Error.Invalid_Hunk)}
    testing.expect_value(t,len(bytes),0)

    for limit in 0..<64 {
        failing:=Failing{left=limit,backing=context.allocator}
        allocator:=runtime.Allocator{failing_proc,&failing}
        lines_out:=make([dynamic]Line,allocator)
        rows_out:=make([dynamic]Row,allocator)
        hunks_out:=make([dynamic]Hunk,allocator)
        bytes_out:=make([dynamic]u8,allocator)
        _,e1:=lines(numbered(30,3),numbered(30,4),&lines_out,allocator)
        e2:=rows(lines_out[:],2,&rows_out)
        _,e3:=merge3(base,ours,theirs,&hunks_out,allocator)
        e4:=merged(base,ours,theirs,hunks_out[:],&bytes_out)
        for e in ([]Error{e1,e2,e3,e4}) {testing.expect(t,e==.None||e==.Out_Of_Memory)}
        if limit==63 {
            testing.expect_value(t,e3,Error.None)
            testing.expect_value(t,e4,Error.None)
            testing.expect_value(t,string(bytes_out[:]),"a\nB\nc\nD\n")
        }
        delete(lines_out);delete(rows_out);delete(hunks_out);delete(bytes_out)
        free_all(context.temp_allocator)
    }
}
