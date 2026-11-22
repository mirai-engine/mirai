package kai

import "core:fmt"
import "core:testing"
import "core:time"
import net "mirai:net"
import "mirai:std/base"
import "mirai:store"

// A ddc node over its quota drops the derived data used least recently and
// the store's sweep reclaims it at once: the store comes back under the
// quota, every closure the node serves and the results used most recently
// stay and are still served, and neither a key a lookup still fetches nor one
// a remote peer is fetching from the node is dropped.
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
    repo:=random_id(Repo_Id)
    project,pe:=machine_project_add(&m,org,repo,"game",false)
    testing.expect_value(t,pe,Error.None)
    s:=&m.store
    // A node holds no workspace: the project's repository is another machine's.
    testing.expect_value(t,store.ref_remove(s,MACHINE_NAMESPACE,machine_repo_name(repo)),store.Error.None)
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

    // A key whose output lacks an object, published first: its lookup holds it.
    small:=[64]u8{}
    busy_result,_:=store.put(s,small[:])
    busy:=store.Hash{0=0xbb}
    _,de:=machine_publish_ddc(&m,org,busy,{busy_result,store.Hash{0=0xee,31=1}},nil)
    testing.expect_value(t,de,Error.None)
    // Four results, each of two objects of SIZE random bytes.
    SIZE :: 128<<10
    QUOTA :: 600<<10
    keys:[4]store.Hash
    outputs:[4][2]store.Hash
    state:=u64(0x9e3779b97f4a7c15)
    for k in 0..<4 {
        time.sleep(2*time.Millisecond)
        keys[k]=store.Hash{0=u8(k+1)}
        for &o in outputs[k] {
            bytes:=make([]u8,SIZE,context.temp_allocator)
            for &b in bytes {
                state=state*6364136223846793005+1442695040888963407
                b=u8(state>>56)
            }
            e:store.Error
            o,e=store.put(s,bytes)
            testing.expect_value(t,e,store.Error.None)
        }
        testing.expect_value(t,store.commit(s),store.Error.None)
        _,de=machine_publish_ddc(&m,org,keys[k],outputs[k][:],nil)
        testing.expect_value(t,de,Error.None)
    }
    r:Runner
    e:=runner_start(&r,{machine=&m,bind=net.address_loopback(0),modes={.Relay,.Seed,.DDC},observe_port=0,beacon_port=-1,ddc_quota=QUOTA})
    if !testing.expect_value(t,e,Error.None) {return}
    defer runner_stop(&r)
    stats:=runner_ddc_stats(&r,org)
    testing.expect(t,stats.keys==5 && stats.whole==4 && stats.missing==1 && stats.bytes>4*2*SIZE,"four outputs are here, one lacks an object")
    used,_:=runner_ddc_ask(&r,org,keys[0])
    testing.expect(t,used==.Found,"the oldest result is asked for: it is used now")
    waiting,_:=runner_ddc_ask(&r,org,busy)
    testing.expect(t,waiting==.Waiting,"a lookup fetches what the output lacks")
    // A peer asks the node's exchange for an object of the second oldest result.
    agent_asked(&r.orgs[0].agent,{},outputs[1][1])
    before,_:=store.usage(s)
    testing.expect(t,before.bytes>QUOTA,"the store is past the quota")

    runner_ddc_quota(&r)
    after,_:=store.usage(s)
    testing.expectf(t,after.bytes<=QUOTA,"the sweep brings the store under the quota: %d bytes",after.bytes)
    ns:[len(DDC_PREFIX)+64]u8
    name:[64]u8
    for key,k in ([]store.Hash{busy,keys[0],keys[1],keys[2],keys[3]}) {
        _,re:=store.ref_get(s,ddc_namespace(org,&ns),store.hex(key,&name))
        kept:=k<=2
        testing.expectf(t,(re==.None)==kept,"key %d is kept %v",k,kept)
    }
    for k in 2..<4 {
        for o in outputs[k] {testing.expectf(t,!object_whole(s,o),"what key %d dropped leaves the store",k)}
    }
    for k in ([]int{0,1}) {
        found,output_root:=runner_ddc_ask(&r,org,keys[k])
        objects,ge:=ddc_output_get(s,output_root,context.temp_allocator)
        testing.expectf(t,found==.Found && ge==.None && len(objects)==2 && objects[0]==outputs[k][0],"key %d is still served",k)
    }
    for address in ([?]store.Hash{revision,root,file,busy_result}) {
        testing.expectf(t,object_whole(s,address),"%v survives the sweep",address)
    }
}
