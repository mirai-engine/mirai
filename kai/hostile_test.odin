package kai

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:std/base"
import "mirai:store"

@(private="file")
hostile_store :: proc(t:^testing.T,folder,name:string) -> (s:store.Store,ok:bool) {
    e:store.Error
    s,e=store.open(strings.concatenate({folder,"/",name},context.temp_allocator))
    return s,testing.expect_value(t,e,store.Error.None)
}

// A checkout refuses to write under a folder that is a link, so nothing
// outside the root is written or removed; a link where a file goes is
// replaced, never followed; and a tree never writes what Kai keeps of the
// workspace, whatever the case of its names.
@(test)
a_checkout_writes_nothing_outside_its_root_or_into_kai :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-hostile-checkout")
    if folder=="" {return}
    s,ok:=hostile_store(t,folder,"store")
    if !ok {return}
    defer store.close(&s)
    root:=strings.concatenate({folder,"/work"},context.temp_allocator)
    outside:=strings.concatenate({folder,"/outside"},context.temp_allocator)
    os.make_directory_all(root)
    os.make_directory_all(outside)
    keep:=strings.concatenate({outside,"/keep.txt"},context.temp_allocator)
    testing.expect(t,os.write_entire_file(keep,transmute([]u8)string("mine"))==nil)
    w:Workspace
    if !testing.expect_value(t,workspace_create(&w,root,&s,identity_make()),Error.None) {return}
    defer workspace_close(&w)
    file :: proc(t:^testing.T,s:^store.Store,path,text:string) -> File {
        address,e:=store.put(s,transmute([]u8)text)
        testing.expect_value(t,e,store.Error.None)
        return {path=path,kind=.File,address=address,size=u64(len(text))}
    }
    tree :: proc(t:^testing.T,s:^store.Store,files:..File) -> store.Hash {
        root,e:=tree_build(s,files)
        testing.expect_value(t,e,Error.None)
        return root
    }
    kai_before:=make([dynamic][]u8,context.temp_allocator)
    for name in ([]string{"workspace","lock"}) {
        bytes,_:=os.read_entire_file(strings.concatenate({root,"/.mirai/kai/",name},context.temp_allocator),context.temp_allocator)
        append(&kai_before,bytes)
    }

    // What Kai keeps, by any case, is no file of the project.
    for prefix in ([]string{".mirai/kai/",".MIRAI/Kai/",".Mirai/KAI/"}) {
        target:=tree(t,&s,file(t,&s,strings.concatenate({prefix,"lock"},context.temp_allocator),"forged"),file(t,&s,strings.concatenate({prefix,"workspace"},context.temp_allocator),"forged"),file(t,&s,"a.txt","alpha"))
        testing.expect_value(t,checkout(&w,target),Error.None)
    }
    for name,k in ([]string{"workspace","lock"}) {
        bytes,_:=os.read_entire_file(strings.concatenate({root,"/.mirai/kai/",name},context.temp_allocator),context.temp_allocator)
        testing.expectf(t,name=="workspace" || slice.equal(bytes,kai_before[k]),"the tree writes no %s of Kai",name)
        testing.expect(t,!strings.contains(string(bytes),"forged"))
    }
    a,_:=os.read_entire_file(strings.concatenate({root,"/a.txt"},context.temp_allocator),context.temp_allocator)
    testing.expect_value(t,string(a),"alpha")

    linked:=strings.concatenate({root,"/linked"},context.temp_allocator)
    leaf:=strings.concatenate({root,"/leaf"},context.temp_allocator)
    if os.symlink(outside,linked)!=nil || os.symlink(outside,leaf)!=nil {
        fmt.println("a_checkout_writes_nothing_outside_its_root_or_into_kai: no symbolic links here, the link cases are skipped")
        return
    }
    under:=tree(t,&s,file(t,&s,"a.txt","alpha"),file(t,&s,"linked/evil.txt","escaped"),file(t,&s,"linked/keep.txt","replaced"))
    testing.expect_value(t,checkout(&w,under),Error.Unsupported)
    kept,_:=os.read_entire_file(keep,context.temp_allocator)
    testing.expect(t,string(kept)=="mine" && !os.exists(strings.concatenate({outside,"/evil.txt"},context.temp_allocator)),"nothing is written through a linked folder")
    // A file where the link was: the link goes, what it points at stays.
    over:=tree(t,&s,file(t,&s,"a.txt","alpha"),file(t,&s,"leaf","a file now"))
    testing.expect_value(t,checkout(&w,over),Error.None)
    info,le:=os.lstat(leaf,context.temp_allocator)
    testing.expect(t,le==nil && info.type==.Regular,"the link is replaced by the file")
    kept,_=os.read_entire_file(keep,context.temp_allocator)
    testing.expect_value(t,string(kept),"mine")
}

// A device secret that does not read now (its file is there and this user
// may not read it) is an error, never replaced by a new one.
@(test)
an_unreadable_device_secret_is_kept :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-hostile-secret")
    if folder=="" {return}
    s,ok:=hostile_store(t,folder,"store")
    if !ok {return}
    defer store.close(&s)
    first,e:=machine_identity(&s)
    testing.expect_value(t,e,Error.None)
    path:=strings.concatenate({s.root,"/",IDENTITY_FILE},context.temp_allocator)
    before,_:=os.read_entire_file(path,context.temp_allocator)
    if os.change_mode(path,{})!=nil {return}
    defer os.change_mode(path,{.Read_User,.Write_User})
    if _,readable:=os.read_entire_file(path,context.temp_allocator);readable==nil {
        fmt.println("an_unreadable_device_secret_is_kept: this user reads a file of no rights, skipped")
        return
    }
    _,again:=machine_identity(&s)
    testing.expect_value(t,again,Error.Io)
    os.change_mode(path,{.Read_User,.Write_User})
    after,_:=os.read_entire_file(path,context.temp_allocator)
    testing.expect(t,slice.equal(before,after),"the secret is the one made first")
    second,se:=machine_identity(&s)
    testing.expect(t,se==.None && second.key==first.key)
}

// gossip_parse takes only a count of at most GOSSIP_MAX entries, exactly
// that many, none with port zero; random bytes never pass as more than they
// hold.
@(test)
peers_messages_parse_only_whole_and_bounded :: proc(t:^testing.T) {
    entry:=Gossip_Entry{at={{10,0,0,2},7350}}
    good:=make([dynamic]u8,context.temp_allocator)
    append(&good,1,0)
    append(&good,..slice.to_bytes([]Gossip_Entry{entry}))
    entries,ok:=gossip_parse(good[:])
    testing.expect(t,ok && len(entries)==1 && entries[0].at==entry.at,"one good entry")
    _,ok=gossip_parse(good[:len(good)-1])
    testing.expect(t,!ok,"a short entry")
    _,ok=gossip_parse([]u8{0xff,0xff})
    testing.expect(t,!ok,"a count past GOSSIP_MAX")
    random:=make([]u8,200,context.temp_allocator)
    for _ in 0..<2000 {
        n:=int(rand.uint32()%200)
        for &x in random[:n] {x=u8(rand.uint32())}
        if rand.uint32()%2==0 && n>=2 {random[0],random[1]=u8((n-2)/size_of(Gossip_Entry)),0}
        parsed,parsed_ok:=gossip_parse(random[:n])
        if parsed_ok {testing.expect(t,2+len(parsed)*size_of(Gossip_Entry)==n,"what parses is exactly its entries")}
    }
}
