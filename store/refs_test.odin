package store

import "core:strings"
import "core:testing"
import "mirai:std/base"

@(test)
refs_set_get_replace_remove_and_list :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-refs");if folder=="" {return}
    s,ok:=test_store(t,folder);if !ok {return}
    defer close(&s)
    one,_:=put_bytes(&s,transmute([]u8)string("one"))
    two,_:=put_bytes(&s,transmute([]u8)string("two"))
    _,missing:=ref_get(&s,"library","knight")
    testing.expect_value(t,missing,Error.Missing)
    testing.expect_value(t,ref_set(&s,"library","knight",one),Error.None)
    testing.expect_value(t,ref_set(&s,"library","castle-2.v1",two),Error.None)
    testing.expect_value(t,ref_set(&s,"derived","knight",two),Error.None)
    got,error:=ref_get(&s,"library","knight")
    testing.expect(t,error==.None && got==one)
    testing.expect_value(t,ref_set(&s,"library","knight",two),Error.None)
    got,_=ref_get(&s,"library","knight")
    testing.expect(t,got==two,"set replaces the ref")
    refs,list_error:=ref_list(&s,"library")
    defer ref_list_delete(refs)
    testing.expect_value(t,list_error,Error.None)
    testing.expect_value(t,len(refs),2)
    for ref in refs {testing.expect(t,ref.name=="knight" || ref.name=="castle-2.v1",ref.name)}
    testing.expect_value(t,ref_remove(&s,"library","knight"),Error.None)
    testing.expect_value(t,ref_remove(&s,"library","knight"),Error.Missing)
    after,_:=ref_list(&s,"library",context.temp_allocator)
    testing.expect(t,len(after)==1 && after[0].name=="castle-2.v1" && after[0].hash==two)
    none,none_error:=ref_list(&s,"nobody",context.temp_allocator)
    testing.expect(t,none_error==.None && len(none)==0,"an unknown namespace has no refs")
    got,_=ref_get(&s,"derived","knight")
    testing.expect(t,got==two,"namespaces are apart")
    root:=default_root(context.temp_allocator)
    testing.expect(t,root=="" || strings.has_suffix(root,"/Mirai/store"),root)
}
