package main

import "core:strings"
import "core:testing"

// Each source is the body of a file after its package line; flagged, the
// calls the lint reports, in order.
@(test)
the_lint_flags_an_allocation_whose_error_nothing_receives :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    Case :: struct {name,source:string,flagged:[]string}
    cases:=[]Case{
        {"one result",
            `f :: proc(n:int,allocator:runtime.Allocator) {x:=make([]int,n,allocator);x[0]=1}`,
            {"make([]int,n,allocator)"}},
        {"the allocator of the context",
            `f :: proc(n:int) {x:=make([]int,n);y:=new(int);_,_=x,y}`,
            {"make([]int,n)","new(int)"}},
        {"a nil write on the same line",
            `f :: proc(heap:runtime.Allocator) {job:=new(Job,heap);job^={state=.Open}}`,
            {"new(Job,heap)"}},
        {"only the dropped one of a line",
            `f :: proc(n:int,a:runtime.Allocator) -> bool {x:=make([]int,n,a);y,err:=make([]int,n,a);if err!=nil {return false};z:=make([]u8,n,a);return x!=nil && y!=nil && z!=nil}`,
            {"make([]int,n,a)","make([]u8,n,a)"}},
        {"a field of a literal, an argument and a branch",
            "f :: proc(n:int,a:runtime.Allocator) {\n    s:=Set{\n        items=make([]int,n,a),\n        names=make([dynamic]string,0,n,a),\n    }\n    use(make([]int,n,a))\n    y:=make([]int,n,a) if n>0 else nil\n}",
            {"make([]int,n,a)","make([dynamic]string,0,n,a)","make([]int,n,a)","make([]int,n,a)"}},
        {"an error given to _",
            `f :: proc(n:int,a:runtime.Allocator) {x,_:=make([]int,n,a);y:[dynamic]int;_=resize(&y,n);_=x}`,
            {"make([]int,n,a)","resize(&y,n)"}},
        {"or_else puts a value where the error was",
            `f :: proc(n:int,a:runtime.Allocator) {x:=make([]int,n,a) or_else nil;_=x}`,
            {"make([]int,n,a)"}},
        {"returned by a procedure with one result",
            `f :: proc(n:int,a:runtime.Allocator) -> []int {return make([]int,n,a)}`,
            {"make([]int,n,a)"}},
        {"a count where an allocator may go",
            `f :: proc(count:int,g:^Graph) {x:=make([dynamic]int,count);y:=make(map[int]int,g.nodes);z:=make([dynamic]int,4096);_,_,_=x,y,z}`,
            {"make([dynamic]int,count)","make(map[int]int,g.nodes)","make([dynamic]int,4096)"}},
        {"a growth that stands alone",
            `f :: proc(x:^[dynamic]int,n:int) {resize(x,n);reserve(x,n*2);non_zero_resize(x,n)}`,
            {"resize(x,n)","reserve(x,n*2)","non_zero_resize(x,n)"}},
        {"the named procedures of make",
            `f :: proc(n:int,a:runtime.Allocator) {x:=make_slice([]int,n,a);y:=make_dynamic_array_len_cap([dynamic]int,0,n,a);z:=new_clone(Job{},a);_,_,_=x,y,z}`,
            {"make_slice([]int,n,a)","make_dynamic_array_len_cap([dynamic]int,0,n,a)","new_clone(Job{},a)"}},
        {"an allocator a caller chose, whatever its name",
            `f :: proc(n:int,scratch:runtime.Allocator) {x:=make([]int,n,scratch);_=x}`,
            {"make([]int,n,scratch)"}},
        {"a name of the outer procedure does not reach the inner one",
            "f :: proc(n:int) {\n    scratch:=context.temp_allocator\n    inner :: proc(n:int,scratch:runtime.Allocator) -> []int {\n        x:=make([]int,n,scratch)\n        return x\n    }\n    y:=make([]int,n,scratch)\n    _=y\n}",
            {"make([]int,n,scratch)"}},
        {"a call over several lines is told on one",
            "f :: proc(n:int,a:runtime.Allocator) {\n    x:=make(\n        []int,\n        n,\n        a,\n    )\n}",
            {"make( []int, n, a, )"}},

        {"received by a name",
            `f :: proc(n:int,a:runtime.Allocator) -> bool {x,err:=make([]int,n,a);if err!=nil {return false};y:[]int;y,err=make([]int,n,a);return err==nil && x!=nil}`,
            {}},
        {"received by a branch",
            `f :: proc(n:int,a:runtime.Allocator) -> (out:[]int,err:runtime.Allocator_Error) {x:=make([]int,n,a) or_return;if y,e:=new(Job,a);e!=nil {return nil,e};for {z:=make([]int,n,a) or_break;_=z};return x,nil}`,
            {}},
        {"returned with its error",
            `f :: proc(n:int,a:runtime.Allocator) -> ([]int,runtime.Allocator_Error) {return make([]int,n,a)}`,
            {}},
        {"nothing asked for",
            `f :: proc(a:runtime.Allocator,doc:^Doc) {x:=make([dynamic]int,a);y:=make(map[string]int,doc.allocator);z:=make([dynamic]int);w:=make([]int,0,a);v:=make([dynamic]int,0,0,a);u:=make([dynamic]int,allocator=a);heap:=doc.allocator;s:=make([dynamic]int,heap);r:=make([dynamic]int,runtime.heap_allocator())}`,
            {}},
        {"the temporary allocator",
            `f :: proc(n:int) {x:=make([]int,n,context.temp_allocator);scratch:=context.temp_allocator;y:=make([]int,n,scratch);z:=new(Job,scratch);w:=make([dynamic]int,0,n,allocator=scratch);_,_,_,_=x,y,z,w}`,
            {}},
        {"an array of the temporary allocator grows in it",
            `f :: proc(n:int) {scratch:=context.temp_allocator;x:=make([dynamic]int,scratch);resize(&x,n);y:=make([dynamic]int,0,n,context.temp_allocator);reserve(&y,n*2)}`,
            {}},
        {"a growth whose error is read",
            `f :: proc(x:^[dynamic]int,n:int) -> runtime.Allocator_Error {resize(x,n) or_return;if reserve(x,n)!=nil {return .Out_Of_Memory};err:=resize(x,n);return err}`,
            {}},
        {"append and truncate are not requests the lint reads",
            `f :: proc(x:^[dynamic]int,n:int) {append(x,n);base.truncate(x,n);inject_at(x,0,n)}`,
            {}},
        {"a comment, a string and a procedure of another package",
            "// x:=make([]int,n)\nf :: proc(n:int,pool:^Pool) -> string {\n    /* y:=new(int) */\n    z:=pool.make(pool,n)\n    w:=other.new(n)\n    return \"x:=make([]int,n)\"\n}",
            {}},
    }
    for c in cases {
        findings:=make([dynamic]Alloc_Finding,context.temp_allocator)
        source:=strings.concatenate({"package sample\n",c.source,"\n"},context.temp_allocator)
        if !testing.expectf(t,alloc_lint_source("sample.odin",source,&findings),"%s: it parses",c.name) {continue}
        if !testing.expectf(t,len(findings)==len(c.flagged),"%s: %d flagged, %d expected: %v",c.name,len(findings),len(c.flagged),findings[:]) {continue}
        for f,i in findings {
            testing.expectf(t,f.call==c.flagged[i],"%s: flagged %s, expected %s",c.name,f.call,c.flagged[i])
            testing.expectf(t,f.line>=2 && f.column>=1,"%s: %s has its place",c.name,f.call)
        }
    }
}

// A finding names the line and the column of its call, so that two on a line are told apart.
@(test)
a_finding_names_the_place_of_its_call :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    findings:=make([dynamic]Alloc_Finding,context.temp_allocator)
    source:="package sample\n\nf :: proc(n:int) {\n    a:=make([]int,n);b:=new(int)\n}\n"
    if !testing.expect(t,alloc_lint_source("sample.odin",source,&findings)) || !testing.expect_value(t,len(findings),2) {return}
    testing.expect_value(t,findings[0].line,4)
    testing.expect_value(t,findings[0].column,8)
    testing.expect_value(t,findings[1].line,4)
    testing.expect_value(t,findings[1].column,25)
}
