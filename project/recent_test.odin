package project

import "core:fmt"
import "core:os"
import "core:testing"
import "mirai:std/base"

@(test)
recent_projects_put_the_last_opened_first_and_read_back :: proc(t:^testing.T) {
    folder,_:=os.make_directory_temp("","mirai-recent",context.temp_allocator)
    defer base.remove_all(folder)
    engine:=path(folder,"engine",allocator=context.temp_allocator)
    a,b:=path(folder,"a",allocator=context.temp_allocator),path(folder,"b",allocator=context.temp_allocator)
    recent:Recent_Projects
    recent_add(&recent,a,1)
    recent_add(&recent,b,2)
    recent_add(&recent,a,3)
    testing.expect_value(t,recent_count(&recent),2)
    testing.expect(t,path_same(base.text_get(recent.projects[0].path[:]),path_absolute(a,context.temp_allocator)))
    testing.expect_value(t,recent.projects[0].opened,i64(3))
    recent.open_last=true
    testing.expect_value(t,recent_write(engine,&recent).code,Error_Code.None)
    read:Recent_Projects
    testing.expect_value(t,recent_read(engine,&read).code,Error_Code.None)
    testing.expect(t,read==recent)
    recent_remove(&read,0)
    testing.expect_value(t,recent_count(&read),1)
    testing.expect(t,path_same(base.text_get(read.projects[0].path[:]),path_absolute(b,context.temp_allocator)))
    // A full list lets the oldest go.
    full:Recent_Projects
    for i in 0..<RECENT_CAPACITY+1 {recent_add(&full,path(folder,fmt.tprint(i),allocator=context.temp_allocator),i64(i))}
    testing.expect_value(t,recent_count(&full),RECENT_CAPACITY)
    testing.expect_value(t,full.projects[0].opened,i64(RECENT_CAPACITY))
    testing.expect_value(t,full.projects[RECENT_CAPACITY-1].opened,i64(1))
}
