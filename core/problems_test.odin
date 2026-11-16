package core

import "core:strings"
import "core:testing"

@(test)
problems_count_the_same_entity_and_code_once_and_keep_the_first_message :: proc(t:^testing.T) {
    storage:Problems
    problems:=&storage
    a,b:=entity_make(1,1),entity_make(2,1)
    report(problems,a,"test.missing","asset %s is missing: import it","hero")
    report(problems,a,"test.missing","asset %s is missing: import it","other")
    report(problems,b,"test.missing","asset %s is missing: import it","hero")
    report(problems,a,"test.memory","out of memory")
    testing.expect_value(t,problems.count,3)
    testing.expect_value(t,problems.serial,u64(4))
    p:=problem_find(problems,a,"test.missing")
    if !testing.expect(t,p!=nil) {return}
    testing.expect_value(t,p.count,u64(2))
    testing.expect_value(t,p.first,u64(1))
    testing.expect_value(t,p.last,u64(2))
    testing.expect_value(t,problem_text(p),"asset hero is missing: import it")
    testing.expect_value(t,problem_code(p),"test.missing")
    testing.expect(t,problem_find(problems,b,"test.memory")==nil)
    report(nil,a,"test.missing","nothing to report into")
    problems_clear(problems)
    testing.expect_value(t,len(problems_list(problems)),0)
    report(problems,a,"test.missing","again")
    testing.expect_value(t,problems.entries[0].first,u64(5))
}

@(test)
problems_full_give_the_place_of_the_least_recent_to_a_new_one :: proc(t:^testing.T) {
    storage:Problems
    problems:=&storage
    for i in 0..<PROBLEM_CAPACITY {report(problems,entity_make(i+1,1),"test.full","problem %d",i)}
    report(problems,entity_make(1,1),"test.full","reported again")
    report(problems,entity_make(PROBLEM_CAPACITY+1,1),"test.full","newest")
    testing.expect_value(t,problems.count,PROBLEM_CAPACITY)
    testing.expect_value(t,problems.evicted,u64(1))
    testing.expect(t,problem_find(problems,entity_make(2,1),"test.full")==nil)
    first:=problem_find(problems,entity_make(1,1),"test.full")
    newest:=problem_find(problems,entity_make(PROBLEM_CAPACITY+1,1),"test.full")
    testing.expect(t,first!=nil && first.count==2 && problem_text(first)=="problem 0")
    testing.expect(t,newest!=nil && newest.count==1 && problem_text(newest)=="newest")
}

@(test)
problems_cut_long_codes_and_messages_to_their_room :: proc(t:^testing.T) {
    storage:Problems
    problems:=&storage
    code:=strings.repeat("c",PROBLEM_CODE*2,context.temp_allocator)
    text:=strings.repeat("m",PROBLEM_TEXT*2,context.temp_allocator)
    report(problems,NONE,code,"%s",text)
    report(problems,NONE,code,"%s",text)
    testing.expect_value(t,problems.count,1)
    p:=&problems.entries[0]
    testing.expect_value(t,p.count,u64(2))
    testing.expect_value(t,len(problem_code(p)),PROBLEM_CODE-1)
    testing.expect_value(t,len(problem_text(p)),PROBLEM_TEXT-1)
    testing.expect_value(t,p.entity,NONE)
}
