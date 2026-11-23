package mirai_pcg

import "base:runtime"
import "core:math"
import "core:strings"
import "core:testing"

@(private="file")
FACADE_SYMBOLS :: []Grammar_Symbol{{"Corner",1,false},{"Wall",2,true},{"Window",1.5,true}}

@(private="file")
compile_or_fail :: proc(t:^testing.T,source:string,symbols:[]Grammar_Symbol,loc:=#caller_location) -> Grammar_Program {
    program,err:=grammar_compile(source,symbols)
    testing.expectf(t,err.kind==.None,"%q: %v",source,err,loc=loc)
    return program
}

@(private="file")
solve :: proc(program:Grammar_Program,length:f32,seed:u64,out:[]Grammar_Placed) -> (int,Grammar_Solve_Error) {
    frames:[GRAMMAR_MAX_DEPTH]Grammar_Frame
    scratch:=Grammar_Scratch{frames[:]}
    return grammar_subdivide(program,length,seed,&scratch,out)
}

@(private="file")
names_of :: proc(program:Grammar_Program,placed:[]Grammar_Placed) -> string {
    b:=strings.builder_make(context.temp_allocator)
    for p,i in placed {
        if i>0 {strings.write_byte(&b,' ')}
        strings.write_string(&b,program.symbols[p.sym].name)
    }
    return strings.to_string(b)
}

@(private="file")
near :: proc(a,b:f32) -> bool {return abs(a-b)<=1e-4*max(1,abs(b))}

// Contiguous from 0, ordinals in order, first and final marked, the last
// ending at length when anything scales.
@(private="file")
expect_layout :: proc(t:^testing.T,program:Grammar_Program,placed:[]Grammar_Placed,length:f32,loc:=#caller_location) {
    cursor:f32
    scales:=false
    for p,i in placed {
        testing.expectf(t,near(p.start,cursor),"placement %d starts at %v, not %v",i,p.start,cursor,loc=loc)
        testing.expectf(t,p.size>0 && p.ordinal==u32(i) && p.is_first==(i==0) && p.is_final==(i==len(placed)-1),"placement %d: %v",i,p,loc=loc)
        cursor=p.start+p.size
        scales|=program.symbols[p.sym].scalable
    }
    if scales {testing.expectf(t,cursor==length,"ends at %v, not %v",cursor,length,loc=loc)}
}

@(test)
facade_puts_corners_at_both_ends_and_stretches_the_bays :: proc(t:^testing.T) {
    program:=compile_or_fail(t,"[Corner, [Wall, Window]*, Corner]",FACADE_SYMBOLS)
    defer grammar_destroy(&program)
    testing.expect_value(t,program.depth,3)
    out:[32]Grammar_Placed
    count,err:=solve(program,12,1,out[:])
    testing.expect_value(t,err,Grammar_Solve_Error.None)
    testing.expect_value(t,names_of(program,out[:count]),"Corner Wall Window Wall Window Corner")
    expect_layout(t,program,out[:count],12)
    scale:=f32(1+3.0/7.0)
    testing.expectf(t,near(out[1].size,2*scale) && near(out[2].size,1.5*scale) && near(out[1].scale,scale),"bays: %v %v",out[1],out[2])
    testing.expectf(t,out[0].size==1 && out[0].scale==1 && out[5].size==1,"corners: %v %v",out[0],out[5])
    // Too short for a bay: the corners alone, with nothing to stretch.
    count,err=solve(program,2.5,1,out[:])
    testing.expect_value(t,err,Grammar_Solve_Error.None)
    testing.expect_value(t,names_of(program,out[:count]),"Corner Corner")
    testing.expect(t,out[1].start==1 && out[1].size==1)
    count,err=solve(program,1.5,1,out[:])
    testing.expect_value(t,err,Grammar_Solve_Error.Too_Short)
}

@(test)
fence_takes_the_gate_when_it_fits_and_posts_otherwise :: proc(t:^testing.T) {
    symbols:=[]Grammar_Symbol{{"Gate",4,true},{"Post",0.2,false},{"Rail",2,true}}
    program:=compile_or_fail(t,"<Gate, [Post, Rail]*>",symbols)
    defer grammar_destroy(&program)
    out:[32]Grammar_Placed
    count,err:=solve(program,5,9,out[:])
    testing.expect_value(t,err,Grammar_Solve_Error.None)
    testing.expect_value(t,names_of(program,out[:count]),"Gate")
    testing.expect(t,out[0].size==5 && near(out[0].scale,1.25))
    count,err=solve(program,3,9,out[:])
    testing.expect_value(t,names_of(program,out[:count]),"Post Rail")
    testing.expect(t,near(out[1].size,2.8))
    expect_layout(t,program,out[:count],3)
    count,err=solve(program,9,9,out[:])
    testing.expect_value(t,names_of(program,out[:count]),"Gate")
}

@(test)
weighted_choice_repeats_per_seed_and_follows_the_weights :: proc(t:^testing.T) {
    symbols:=[]Grammar_Symbol{{"A",1,true},{"B",1,true}}
    program:=compile_or_fail(t,"[{A:3, B}]*",symbols)
    defer grammar_destroy(&program)
    testing.expect_value(t,program.modules[program.children[program.modules[1].child_first]].weight,3)
    testing.expect_value(t,program.modules[program.children[program.modules[1].child_first+1]].weight,1)
    first,again,other:[1000]Grammar_Placed
    n1,e1:=solve(program,1000,42,first[:])
    n2,_:=solve(program,1000,42,again[:])
    n3,_:=solve(program,1000,43,other[:])
    testing.expect_value(t,e1,Grammar_Solve_Error.None)
    testing.expect(t,n1==1000 && n2==1000 && n3==1000)
    testing.expect(t,first==again,"the same seed gives the same placements")
    differs:=false
    a_count:=0
    for i in 0..<n1 {
        differs|=first[i].sym!=other[i].sym
        a_count+=int(first[i].sym==0)
    }
    testing.expect(t,differs,"another seed gives other choices")
    testing.expectf(t,a_count>=700 && a_count<=800,"A was picked %d times of 1000 for a weight of 3 in 4",a_count)
    // A choice skips the children that do not fit.
    wide:=[]Grammar_Symbol{{"Big",10,true},{"Small",1,true}}
    choice:=compile_or_fail(t,"{Big:255, Small:1}",wide)
    defer grammar_destroy(&choice)
    for seed in u64(0)..<64 {
        count,_:=solve(choice,5,seed,first[:])
        testing.expect(t,count==1 && first[0].sym==1)
    }
}

@(test)
fixed_repeats_and_one_or_more_need_their_least_length :: proc(t:^testing.T) {
    symbols:=[]Grammar_Symbol{{"Bay",2,true},{"Post",0.5,false},{"Rail",3,true}}
    bays:=compile_or_fail(t,"[Bay]3",symbols)
    defer grammar_destroy(&bays)
    testing.expect_value(t,grammar_module_min(bays.modules[0]),6)
    out:[16]Grammar_Placed
    count,err:=solve(bays,10,0,out[:])
    testing.expect_value(t,names_of(bays,out[:count]),"Bay Bay Bay")
    for p in out[:count] {testing.expect(t,near(p.size,10.0/3))}
    expect_layout(t,bays,out[:count],10)
    _,err=solve(bays,5.9,0,out[:])
    testing.expect_value(t,err,Grammar_Solve_Error.Too_Short)
    rails:=compile_or_fail(t,"[Post, Rail +, Post]",symbols)
    defer grammar_destroy(&rails)
    _,err=solve(rails,3.9,0,out[:])
    testing.expect_value(t,err,Grammar_Solve_Error.Too_Short)
    count,err=solve(rails,4,0,out[:])
    testing.expect_value(t,names_of(rails,out[:count]),"Post Rail Post")
    count,err=solve(rails,11,0,out[:])
    testing.expect_value(t,names_of(rails,out[:count]),"Post Rail Rail Rail Post")
    expect_layout(t,rails,out[:count],11)
}

@(test)
the_length_left_spreads_over_every_scalable_module_by_unit_size :: proc(t:^testing.T) {
    symbols:=[]Grammar_Symbol{{"A",1,true},{"B",2,false},{"C",3,true}}
    program:=compile_or_fail(t,"[A, B, C]",symbols)
    defer grammar_destroy(&program)
    out:[4]Grammar_Placed
    count,err:=solve(program,10,0,out[:])
    testing.expect_value(t,err,Grammar_Solve_Error.None)
    testing.expect_value(t,count,3)
    testing.expect(t,out[0]=={0,2,2,0,1,0,true,false},"A doubles")
    testing.expect(t,out[1].start==2 && out[1].size==2 && out[1].scale==1,"B keeps its size")
    testing.expect(t,out[2].start==4 && out[2].size==6 && out[2].scale==2,"C doubles")
    // Without a scalable module the rest stays after the last one.
    fixed:=compile_or_fail(t,"[B]*",symbols)
    defer grammar_destroy(&fixed)
    count,err=solve(fixed,7,0,out[:])
    testing.expect(t,count==3 && out[2].start==4 && out[2].size==2)
    // Odd lengths still end exactly.
    for length in ([]f32{4.1,6.7,123.456,1e5+0.3}) {
        many:=make([]Grammar_Placed,1<<16,context.temp_allocator)
        bays:=compile_or_fail(t,"[A, [C, B]*, A]",symbols)
        defer grammar_destroy(&bays)
        count,err=solve(bays,length,0,many)
        testing.expectf(t,err==.None,"%v: %v",length,err)
        expect_layout(t,bays,many[:count],length)
    }
}

@(test)
programs_hash_their_content :: proc(t:^testing.T) {
    a:=compile_or_fail(t,"[Corner, [Wall, Window]*, Corner]",FACADE_SYMBOLS)
    defer grammar_destroy(&a)
    b:=compile_or_fail(t," [ Corner,[Wall,Window] * ,Corner ] ",FACADE_SYMBOLS)
    defer grammar_destroy(&b)
    c:=compile_or_fail(t,"[Corner, [Wall, Window]+, Corner]",FACADE_SYMBOLS)
    defer grammar_destroy(&c)
    other:=[]Grammar_Symbol{{"Corner",1,false},{"Wall",2.5,true},{"Window",1.5,true}}
    d:=compile_or_fail(t,"[Corner, [Wall, Window]*, Corner]",other)
    defer grammar_destroy(&d)
    testing.expect(t,a.hash==b.hash,"whitespace does not change the hash")
    testing.expect(t,a.hash!=c.hash && a.hash!=d.hash,"the structure and the unit sizes do")
    testing.expect(t,raw_data(a.symbols[0].name)!=raw_data(FACADE_SYMBOLS[0].name),"names are copied")
}

@(test)
span_ids_depend_only_on_the_spline_the_span_and_the_ordinal :: proc(t:^testing.T) {
    seen:map[u64]bool
    defer delete(seen)
    for entity in u64(1)..=4 {for span in u32(0)..<8 {for ordinal in u32(0)..<8 {
        id:=grammar_span_id(entity,span,ordinal)
        testing.expect(t,!seen[id] && id==grammar_span_id(entity,span,ordinal))
        seen[id]=true
    }}}
}

@(test)
compile_reports_what_and_where :: proc(t:^testing.T) {
    symbols:=[]Grammar_Symbol{{"A",1,true},{"Wall_2",1,false},{"Huge",1e30,false}}
    deep_ok:=strings.concatenate({strings.repeat("[",GRAMMAR_MAX_DEPTH-1,context.temp_allocator),"A",strings.repeat("]",GRAMMAR_MAX_DEPTH-1,context.temp_allocator)},context.temp_allocator)
    deep:=strings.concatenate({"[",deep_ok,"]"},context.temp_allocator)
    wide:=strings.concatenate({"[",strings.repeat("A,",GRAMMAR_MAX_MODULES,context.temp_allocator),"A]"},context.temp_allocator)
    cases:=[]struct{source:string,kind:Grammar_Error_Kind,offset:int}{
        {"",.Unexpected_End,0},{"   ",.Unexpected_End,3},{"[A, A",.Unexpected_End,5},
        {"[A,]",.Unexpected_Character,3},{"[]",.Empty_Group,0},{"x < >",.Unknown_Symbol,0},
        {"< >",.Empty_Group,0},{"{ }",.Empty_Group,0},{"[A, Q]",.Unknown_Symbol,4},
        {"[A>",.Unexpected_Character,2},{"[A]0",.Bad_Repeat,3},{"[A]40000",.Bad_Repeat,3},
        {"{A:0}",.Bad_Weight,3},{"{A:300}",.Bad_Weight,3},{"{A:}",.Bad_Weight,3},
        {"[A] A",.Unexpected_Character,4},{"[A]**",.Unexpected_Character,4},{"[A]3+",.Unexpected_Character,4},
        {"[A:2]",.Unexpected_Character,2},{"Wall2",.Unknown_Symbol,0},{"9A",.Unexpected_Character,0},
        {"[[Huge]30000]30000",.Too_Large,0},{deep,.Too_Deep,GRAMMAR_MAX_DEPTH},
        {wide,.Too_Many_Modules,2*GRAMMAR_MAX_MODULES-1},
        {"A",.None,0},{"Wall_2 3",.None,0},{"[A]30000",.None,0},{deep_ok,.None,0},
        {"{A:255, [Wall_2, A]*:2, <A, Wall_2>+}",.None,0},{"\t[\nA\r,A ]\n",.None,0},
    }
    for c in cases {
        program,err:=grammar_compile(c.source,symbols)
        defer grammar_destroy(&program)
        shown:=c.source if len(c.source)<64 else c.source[:64]
        testing.expectf(t,err.kind==c.kind && err.symbol==-1,"%q: %v, not %v",shown,err,c.kind)
        if c.kind!=.None {
            testing.expectf(t,err.offset==c.offset,"%q: offset %d, not %d",shown,err.offset,c.offset)
            testing.expect(t,program.modules==nil)
        }
    }
}

@(test)
compile_rejects_bad_symbols :: proc(t:^testing.T) {
    nan:=math.nan_f32()
    inf:=math.inf_f32(1)
    cases:=[]struct{symbols:[]Grammar_Symbol,kind:Grammar_Error_Kind,symbol:int}{
        {{{"A",1,false},{"",1,false}},.Empty_Symbol_Name,1},
        {{{"Bad Name",1,false}},.Bad_Symbol_Name,0},
        {{{"9x",1,false}},.Bad_Symbol_Name,0},
        {{{"A",1,false},{"B",1,false},{"A",2,false}},.Duplicate_Symbol,2},
        {{{"A",0,false}},.Bad_Unit_Size,0},
        {{{"A",-1,false}},.Bad_Unit_Size,0},
        {{{"A",nan,false}},.Bad_Unit_Size,0},
        {{{"A",inf,false}},.Bad_Unit_Size,0},
        {{},.Unknown_Symbol,-1},
    }
    for c in cases {
        _,err:=grammar_compile("A",c.symbols)
        testing.expectf(t,err.kind==c.kind && err.symbol==c.symbol,"%v: %v",c.symbols,err)
    }
    many:=make([]Grammar_Symbol,GRAMMAR_MAX_SYMBOLS+1,context.temp_allocator)
    _,err:=grammar_compile("A",many)
    testing.expect_value(t,err.kind,Grammar_Error_Kind.Too_Many_Symbols)
}

@(private="file")
Counted :: struct {owner:runtime.Allocator,calls,refuse_after:int}

@(private="file")
counted_proc :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    c:=(^Counted)(data)
    c.calls+=1
    if mode!=.Free && c.calls>c.refuse_after {return nil,.Out_Of_Memory}
    return c.owner.procedure(c.owner.data,mode,size,alignment,old_memory,old_size,loc)
}

@(test)
compile_without_memory_fails_cleanly :: proc(t:^testing.T) {
    program,err:=grammar_compile("[Corner, [Wall, Window]*, Corner]",FACADE_SYMBOLS,runtime.nil_allocator())
    testing.expect_value(t,err.kind,Grammar_Error_Kind.Out_Of_Memory)
    testing.expect(t,program.modules==nil && program.symbols==nil)
    grammar_destroy(&program)
    counted:=Counted{owner=context.allocator,refuse_after=1}
    allocator:=runtime.Allocator{counted_proc,&counted}
    program,err=grammar_compile("[Corner, [Wall, Window]*, Corner]",FACADE_SYMBOLS,allocator)
    testing.expect(t,err.kind==.None && counted.calls==1,"one allocation holds the program")
    grammar_destroy(&program)
    testing.expect_value(t,counted.calls,2)
}

@(test)
subdivide_never_allocates :: proc(t:^testing.T) {
    symbols:=[]Grammar_Symbol{{"Corner",1,false},{"Wall",2,true},{"Window",1.5,true},{"Door",3,true}}
    program:=compile_or_fail(t,"[Corner, <Door, [Wall, {Window:3, Wall}]*>, [Wall, {Window:2, Door}]*, Corner]",symbols)
    defer grammar_destroy(&program)
    counted:=Counted{owner=runtime.nil_allocator()}
    context.allocator=runtime.Allocator{counted_proc,&counted}
    context.temp_allocator=runtime.nil_allocator()
    out:[256]Grammar_Placed
    for seed in u64(0)..<32 {
        length:=2+f32(seed)*7.3
        count,err:=solve(program,length,seed,out[:])
        testing.expectf(t,err==.None && count>=2,"%v: %d %v",length,count,err)
        expect_layout(t,program,out[:count],length)
    }
    testing.expect_value(t,counted.calls,0)
}

@(test)
subdivide_rejects_hostile_inputs_without_crashing :: proc(t:^testing.T) {
    symbols:=[]Grammar_Symbol{{"A",1,true},{"Tiny",1e-30,true}}
    program:=compile_or_fail(t,"[A]30000",symbols)
    defer grammar_destroy(&program)
    out:[100]Grammar_Placed
    for length in ([]f32{math.nan_f32(),math.inf_f32(1),math.inf_f32(-1),-1}) {
        _,err:=solve(program,length,0,out[:])
        testing.expectf(t,err==.Bad_Length,"%v: %v",length,err)
    }
    _,err:=solve(program,10,0,out[:])
    testing.expect_value(t,err,Grammar_Solve_Error.Too_Short)
    _,err=solve(program,0,0,out[:])
    testing.expect_value(t,err,Grammar_Solve_Error.Too_Short)
    count:int
    count,err=solve(program,1e6,0,out[:])
    testing.expect(t,err==.Capacity_Exceeded && count==len(out),"a full out keeps what fit")
    testing.expect(t,out[99].start==99 && out[99].size==1 && out[99].scale==1 && out[99].is_final,"unstretched")
    count,err=solve(program,1e6,0,nil)
    testing.expect(t,err==.Capacity_Exceeded && count==0)
    // Tiny units in a long span stop at the end of out.
    tiny:=compile_or_fail(t,"[Tiny]*",symbols)
    defer grammar_destroy(&tiny)
    count,err=solve(tiny,1e30,0,out[:])
    testing.expect(t,err==.Capacity_Exceeded && count==len(out))
    // Nothing fits a `*` of a `*`: no placements, and no endless loop.
    nested:=compile_or_fail(t,"[[A]*]*",symbols)
    defer grammar_destroy(&nested)
    count,err=solve(nested,0.5,0,out[:])
    testing.expect(t,err==.None && count==0)
    count,err=solve(nested,0,0,out[:])
    testing.expect(t,err==.None && count==0)
    count,err=solve(nested,3.5,0,out[:])
    testing.expect(t,err==.None && count==3 && out[2].start+out[2].size==3.5)
    // Scratch shallower than the program.
    deep:=compile_or_fail(t,"[[[A]]]",symbols)
    defer grammar_destroy(&deep)
    frames:[3]Grammar_Frame
    scratch:=Grammar_Scratch{frames[:]}
    _,err=grammar_subdivide(deep,2,0,&scratch,out[:])
    testing.expect_value(t,err,Grammar_Solve_Error.Capacity_Exceeded)
    scratch.frames=frames[:0]
    _,err=grammar_subdivide(deep,2,0,&scratch,out[:])
    testing.expect_value(t,err,Grammar_Solve_Error.Capacity_Exceeded)
    _,err=grammar_subdivide(deep,2,0,nil,out[:])
    testing.expect_value(t,err,Grammar_Solve_Error.Capacity_Exceeded)
    scratch.frames=frames[:]
    _,err=grammar_subdivide({},2,0,&scratch,out[:])
    testing.expect_value(t,err,Grammar_Solve_Error.Bad_Program)
    // Programs built by hand with bad indices, counts or sizes.
    four:[4]Grammar_Frame
    scratch.frames=four[:]
    bad_symbols:=[]Grammar_Symbol{{"A",1,true},{"N",math.nan_f32(),true}}
    children:=[]u16{1,9}
    bad:=[]Grammar_Module{
        {op=.Sequence,child_count=2,reps=1},{op=.Literal,reps=1},
        {op=.Literal,sym=7,reps=1},{op=.Literal,sym=1,reps=1},
        {op=.Literal,reps=0},{op=.Stochastic,child_count=1,reps=1},
    }
    weightless:=[]Grammar_Module{bad[5],bad[1]}
    weightless[1].weight=0
    programs:=[]Grammar_Program{
        {symbols=bad_symbols,modules=bad[:2],children=children},
        {symbols=bad_symbols,modules=bad[:2],children=children[:1]},
        {symbols=bad_symbols,modules=bad[2:3]},{symbols=bad_symbols,modules=bad[3:4]},
        {symbols=bad_symbols,modules=bad[4:5]},
        {symbols=bad_symbols,modules=weightless,children=[]u16{1}},
    }
    for p,i in programs {
        _,err=grammar_subdivide(p,4,0,&scratch,out[:])
        testing.expectf(t,err==.Bad_Program,"hand-built program %d: %v",i,err)
    }
    // A cycle runs out of frames.
    cycle:=[]Grammar_Module{{op=.Sequence,child_count=1,reps=1}}
    _,err=grammar_subdivide({symbols=bad_symbols,modules=cycle,children=[]u16{0}},4,0,&scratch,out[:])
    testing.expect_value(t,err,Grammar_Solve_Error.Capacity_Exceeded)
}
