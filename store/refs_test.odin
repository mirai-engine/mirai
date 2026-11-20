package store

import "core:fmt"
import "core:strings"
import "core:testing"
import "mirai:std/base"

@(test)
refs_set_get_replace_remove_and_list :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-refs");if folder=="" {return}
    s,ok:=test_store(t,folder);if !ok {return}
    defer close(&s)
    one,_:=test_put(&s,transmute([]u8)string("one"))
    two,_:=test_put(&s,transmute([]u8)string("two"))
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

@(test)
a_read_index_refreshes_once_for_many_package_lookups :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-read-index");if folder=="" {return}
    reader,ok:=test_store(t,folder);if !ok {return}
    defer close(&reader)
    writer,opened:=test_store(t,folder);if !opened {return}
    defer close(&writer)
    text:=transmute([]u8)string("a record")
    record,put_error:=test_put(&writer,text)
    if !testing.expect_value(t,put_error,Error.None) {return}
    names:[12]string
    for &name,k in names {
        name=fmt.tprintf("package-%d",k)
        testing.expect_value(t,ref_set(&writer,"manifests",name,record),Error.None)
        testing.expect_value(t,ref_set(&writer,"builds",name,record),Error.None)
    }
    hooks:Hooks
    reader.state.hooks=&hooks
    defer reader.state.hooks=nil
    index:=read_index(&reader)
    listings:=hooks.listings
    testing.expect(t,listings>0,"a new pass sees commits from another Store")
    for name in names {
        for namespace in ([2]string{"manifests","builds"}) {
            address,error:=ref_get(&index,namespace,name)
            testing.expect(t,error==.None && address==record)
            testing.expect(t,chunk_has(&index,address) && test_holds(&index,address,text))
        }
    }
    testing.expect_value(t,hooks.listings,listings)

    buffer:=make([]u8,CHUNK_MAX,context.temp_allocator)
    _,missing:=chunk_read(&index,address_of_bytes(transmute([]u8)string("absent")),buffer)
    testing.expect_value(t,missing,Error.Missing)
    listings=hooks.listings
    for name in names {
        _,ref_error:=ref_get(&index,"missing",name)
        testing.expect_value(t,ref_error,Error.Missing)
        _,chunk_error:=chunk_read(&index,address_of_bytes(transmute([]u8)name),buffer)
        testing.expect_value(t,chunk_error,Error.Missing)
    }
    testing.expect_value(t,hooks.listings,listings)

    testing.expect_value(t,ref_set(&writer,"builds","new",record),Error.None)
    _,missing=ref_get(&index,"builds","new")
    testing.expect_value(t,missing,Error.Missing)
    testing.expect_value(t,hooks.listings,listings)
    _,visible:=ref_get(&reader,"builds","new")
    testing.expect_value(t,visible,Error.None)
}
