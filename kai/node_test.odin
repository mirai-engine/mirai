package kai

import "core:fmt"
import "core:testing"
import "core:time"
import net "mirai:net"
import "mirai:std/base"
import "mirai:store"

// A ddc node over its quota drops the derived data used least recently, and
// the store's sweep after it keeps every closure the node serves and the
// outputs it kept.
@(test)
a_ddc_node_drops_least_used_outputs_past_its_quota :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-ddc-quota")
    if folder=="" {return}
    m:Machine
    if !testing.expect_value(t,machine_open(&m,fmt.tprintf("%s/node",folder)),Error.None) {return}
    defer machine_close(&m)
    buffer:[RECOVERY_TEXT]u8
    _,ue:=machine_user_create(&m,"node",&buffer)
    testing.expect_value(t,ue,Error.None)
    org,oe:=machine_org_create(&m,"studio")
    testing.expect_value(t,oe,Error.None)
    project,pe:=machine_project_add(&m,org,random_id(Repo_Id),"game",false)
    testing.expect_value(t,pe,Error.None)
    s:=&m.store
    text:="the project's file\n"
    file,fe:=store.put(s,transmute([]u8)text)
    testing.expect_value(t,fe,store.Error.None)
    root,te:=tree_build(s,{{path="a.txt",kind=.File,address=file,size=u64(len(text))}})
    testing.expect_value(t,te,Error.None)
    c:=Change{id=random_id(Change_Id),tree=root,author=m.identity.key,created=1,written=1,description="files"}
    revision,ce:=change_put(s,&c,&m.identity)
    testing.expect_value(t,ce,Error.None)
    testing.expect_value(t,store.commit(s),store.Error.None)
    testing.expect_value(t,machine_publish_refs(&m,project,{{"main",revision}}),Error.None)
    outputs:[2]store.Hash
    keys:=[2]store.Hash{{0=1},{0=2}}
    for k in 0..<2 {
        bytes:=make([]u8,1000,context.temp_allocator)
        for &b,i in bytes {b=u8(i*7+k)}
        e:store.Error
        outputs[k],e=store.put(s,bytes)
        testing.expect_value(t,e,store.Error.None)
        testing.expect_value(t,store.commit(s),store.Error.None)
        _,de:=machine_publish_ddc(&m,org,keys[k],outputs[k],nil)
        testing.expect_value(t,de,Error.None)
        time.sleep(2*time.Millisecond)
    }
    r:Runner
    e:=runner_start(&r,{machine=&m,bind=net.address_loopback(0),modes={.Relay,.Seed,.DDC},observe_port=0,beacon_port=-1,ddc_quota=1500})
    if !testing.expect_value(t,e,Error.None) {return}
    defer runner_stop(&r)
    stats:=runner_ddc_stats(&r,org)
    testing.expect(t,stats.keys==2 && stats.whole==2 && stats.bytes==2000,"both outputs are here")
    runner_ddc_quota(&r)
    ns:[len(DDC_PREFIX)+64]u8
    name:[64]u8
    _,gone:=store.ref_get(s,ddc_namespace(org,&ns),store.hex(keys[0],&name))
    _,kept:=store.ref_get(s,ddc_namespace(org,&ns),store.hex(keys[1],&name))
    testing.expect(t,gone==.Missing && kept==.None,"the key used least recently goes; the newer stays")

    // A sweep once the grace of fresh writes is over keeps what the node serves.
    live:=make([dynamic]store.Hash,context.temp_allocator)
    runner_live(&r,&live)
    _,se:=store.sweep(s,live[:],time.time_add(time.now(),2*store.GRACE))
    testing.expect_value(t,se,store.Error.None)
    for address in ([?]store.Hash{revision,root,file,outputs[1]}) {
        testing.expectf(t,object_whole(s,address),"%v survives the sweep",address)
    }
}
