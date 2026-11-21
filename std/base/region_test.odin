package base

import "core:testing"

@(test)
a_region_commits_what_is_asked_and_keeps_its_address :: proc(t:^testing.T) {
    r:Region
    testing.expect(t,!region_reserve(&r,0))
    if !testing.expect(t,region_reserve(&r,1<<20)) {return}
    defer region_release(&r)
    testing.expect_value(t,r.committed,0)
    first:=raw_data(r.data)
    if !testing.expect(t,region_commit(&r,10)) {return}
    testing.expect_value(t,r.committed,REGION_STEP)
    values:=region_slice(&r,u64,REGION_STEP/8)
    for value in values {testing.expect_value(t,value,0)}
    values[len(values)-1]=7
    testing.expect(t,region_commit(&r,REGION_STEP))
    testing.expect_value(t,r.committed,REGION_STEP)
    if !testing.expect(t,region_commit(&r,3*REGION_STEP+1)) {return}
    testing.expect_value(t,r.committed,3*REGION_STEP+1)
    all:=region_slice(&r,u8,len(r.data))
    all[3*REGION_STEP]=1
    testing.expect(t,raw_data(r.data)==first && values[len(values)-1]==7)
    testing.expect(t,!region_commit(&r,(1<<20)+1))
    if !testing.expect(t,region_commit(&r,1<<20)) {return}
    testing.expect_value(t,r.committed,1<<20)
    all[(1<<20)-1]=2

    down:Region
    TAIL_SIZE :: (1<<20)+1
    if !testing.expect(t,region_reserve(&down,TAIL_SIZE)) {return}
    defer region_release(&down)
    if !testing.expect(t,region_commit_tail(&down,100)) {return}
    testing.expect(t,down.tail==REGION_STEP && down.committed==0)
    bytes:=region_slice(&down,u8,len(down.data))
    bytes[len(bytes)-REGION_STEP]=5
    bytes[len(bytes)-1]=6
    testing.expect(t,!region_commit_tail(&down,TAIL_SIZE+1))
    if !testing.expect(t,region_commit_tail(&down,TAIL_SIZE)) {return}
    testing.expect(t,down.tail==len(bytes) && bytes[0]==0 &&
        bytes[len(bytes)-REGION_STEP]==5 && bytes[len(bytes)-1]==6)

    listed:Region
    list,made:=region_dynamic(&listed,[3]u64,4)
    testing.expect(t,made && len(list)==0 && cap(list)==4)
    defer region_release(&listed)
    first_element:^[3]u64
    for i in 0..<4 {
        testing.expect(t,region_grow(&listed,&list))
        append(&list,[3]u64{u64(i),0,0})
        if i==0 {first_element=&list[0]}
    }
    testing.expect(t,!region_grow(&listed,&list))
    testing.expect(t,first_element==&list[0] && list[3][0]==3)
    clear(&list)
    testing.expect(t,region_grow(&listed,&list,4))
}
