package diff

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
check :: proc(t:^testing.T,old,new,want:string,added,removed:int,max_edits:=2048,loc:=#caller_location) -> [dynamic]Line {
    out:[dynamic]Line
    stats:=lines(old,new,&out,max_edits)
    testing.expect_value(t,ops_of(out[:]),want,loc)
    testing.expect_value(t,stats,Stats{added,removed},loc)
    return out
}

@(private="file")
text_of :: proc(old,new:string,line:Line) -> string {
    text:=old if line.op==.Remove else new
    return text[line.start:line.end]
}

@(test)
diff_identical_texts_are_all_same :: proc(t:^testing.T) {
    out:=check(t,"a\nb\nc\n","a\nb\nc\n","===",0,0)
    defer delete(out)
    for line,i in out {testing.expect_value(t,line,Line{.Same,i32(i+1),i32(i+1),i32(2*i),i32(2*i+1)})}
    empty:=check(t,"","","",0,0)
    delete(empty)
}

@(test)
diff_empty_to_text_and_back :: proc(t:^testing.T) {
    added:=check(t,"","a\nbc","++",2,0)
    defer delete(added)
    testing.expect_value(t,added[1],Line{.Add,0,2,2,4})
    removed:=check(t,"a\nbc","","--",0,2)
    defer delete(removed)
    testing.expect_value(t,removed[0],Line{.Remove,1,0,0,1})
    testing.expect_value(t,removed[1],Line{.Remove,2,0,2,4})
}

@(test)
diff_insert_in_the_middle :: proc(t:^testing.T) {
    out:=check(t,"a\nb\nc\n","a\nb\nx\nc\n","==+=",1,0)
    defer delete(out)
    testing.expect_value(t,out[2],Line{.Add,0,3,4,5})
    testing.expect_value(t,out[3],Line{.Same,3,4,6,7})
}

@(test)
diff_delete :: proc(t:^testing.T) {
    old,new:="a\nbb\nc\n","a\nc\n"
    out:=check(t,old,new,"=-=",0,1)
    defer delete(out)
    testing.expect_value(t,out[1],Line{.Remove,2,0,2,4})
    testing.expect_value(t,text_of(old,new,out[1]),"bb")
    testing.expect_value(t,out[2],Line{.Same,3,2,2,3})
}

@(test)
diff_replace_emits_removes_before_adds :: proc(t:^testing.T) {
    delete(check(t,"a\nb\nc\nd\n","a\nx\ny\nd\n","=--++=",2,2))
    delete(check(t,"1\n2\n3\n","4\n5\n6\n","---+++",3,3))
    out:=check(t,"a\nx\nb\nx\nc\n","a\ny\nb\ny\nc\n","=-+=-+=",2,2)
    defer delete(out)
    testing.expect_value(t,out[1],Line{.Remove,2,0,2,3})
    testing.expect_value(t,out[2],Line{.Add,0,2,2,3})
    testing.expect_value(t,out[3],Line{.Same,3,3,4,5})
}

@(test)
diff_crlf_and_lf_are_equal :: proc(t:^testing.T) {
    delete(check(t,"a\r\nb\r\n","a\nb\n","==",0,0))
    old,new:="a\r\nbb\r\nc","a\nc\n"
    out:=check(t,old,new,"=-=",0,1)
    defer delete(out)
    testing.expect_value(t,out[1],Line{.Remove,2,0,3,5})
    testing.expect_value(t,text_of(old,new,out[1]),"bb")
}

@(test)
diff_missing_final_newline :: proc(t:^testing.T) {
    delete(check(t,"a\nb","a\nb\n","==",0,0))
    delete(check(t,"a\nb\n","a\nb\nc","==+",1,0))
    delete(check(t,"\n","","-",0,1))
    delete(check(t,"a\n\n","a\n","=-",0,1))
}

@(test)
diff_line_numbers_and_byte_ranges :: proc(t:^testing.T) {
    old:="keep\nold one\nshared\nold two\ntail\n"
    new:="new zero\nkeep\nshared\nnew two\nadded\ntail"
    out:=check(t,old,new,"+=-=-++=",3,2)
    defer delete(out)
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
    for line,i in out {
        testing.expect_value(t,line,want[i])
        testing.expect_value(t,text_of(old,new,line),texts[i])
    }
}

@(test)
diff_max_edits_falls_back_to_remove_then_add :: proc(t:^testing.T) {
    old,new:="a\nx\nb\nx\nc\n","a\ny\nb\ny\nc\n"
    delete(check(t,old,new,"=-+=-+=",2,2,max_edits=4))
    out:=check(t,old,new,"=---+++=",3,3,max_edits=3)
    defer delete(out)
    testing.expect_value(t,out[3],Line{.Remove,4,0,6,7})
    testing.expect_value(t,out[4],Line{.Add,0,2,2,3})
    testing.expect_value(t,out[6],Line{.Add,0,4,6,7})
    testing.expect_value(t,out[7],Line{.Same,5,5,8,9})
    delete(check(t,"a\nb\n","c\nd\n","--++",2,2,max_edits=0))
}

@(test)
diff_large_texts_keep_a_shortest_script :: proc(t:^testing.T) {
    old,new:=numbered(400,7,150,151,390),numbered(400,9,200,201,202)
    out:[dynamic]Line
    defer delete(out)
    stats:=lines(old,new,&out)
    testing.expect_value(t,stats,Stats{8,8})
    testing.expect_value(t,len(out),408)
    rebuilt_old,rebuilt_new:=strings.builder_make(context.temp_allocator),strings.builder_make(context.temp_allocator)
    i,j:=0,0
    for line in out {
        text:=text_of(old,new,line)
        if line.op!=.Add {i+=1;testing.expect_value(t,int(line.old),i);fmt.sbprintf(&rebuilt_old,"%s\n",text)}
        if line.op!=.Remove {j+=1;testing.expect_value(t,int(line.new),j);fmt.sbprintf(&rebuilt_new,"%s\n",text)}
    }
    testing.expect_value(t,strings.to_string(rebuilt_old),old)
    testing.expect_value(t,strings.to_string(rebuilt_new),new)
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
diff_random_texts_match_the_longest_common_subsequence :: proc(t:^testing.T) {
    random_text :: proc(words:[]string) -> (string,int) {
        b:=strings.builder_make(context.temp_allocator)
        count:=rand.int_max(13)
        for _ in 0..<count {fmt.sbprintf(&b,"%s\n",rand.choice(words))}
        return strings.to_string(b),count
    }
    words:=[]string{"a","b","c"}
    out:[dynamic]Line
    defer delete(out)
    for _ in 0..<500 {
        old,n:=random_text(words)
        new,m:=random_text(words)
        a,b:=strings.split_lines(old,context.temp_allocator),strings.split_lines(new,context.temp_allocator)
        table:=make([]int,(n+1)*(m+1),context.temp_allocator)
        for i:=n-1;i>=0;i-=1 {
            for j:=m-1;j>=0;j-=1 {
                table[i*(m+1)+j]=table[(i+1)*(m+1)+j+1]+1 if a[i]==b[j] else max(table[(i+1)*(m+1)+j],table[i*(m+1)+j+1])
            }
        }
        stats:=lines(old,new,&out)
        testing.expect_value(t,stats.added+stats.removed,n+m-2*table[0])
        rebuilt_old,rebuilt_new:=strings.builder_make(context.temp_allocator),strings.builder_make(context.temp_allocator)
        for line in out {
            if line.op!=.Add {fmt.sbprintf(&rebuilt_old,"%s\n",text_of(old,new,line))}
            if line.op!=.Remove {fmt.sbprintf(&rebuilt_new,"%s\n",text_of(old,new,line))}
        }
        testing.expect_value(t,strings.to_string(rebuilt_old),old)
        testing.expect_value(t,strings.to_string(rebuilt_new),new)
        free_all(context.temp_allocator)
    }
}
