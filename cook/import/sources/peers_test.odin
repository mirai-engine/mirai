package sources

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "mirai:asset"
import "mirai:cook/cache"
import importer "mirai:cook/import"
import ka "mirai:cook/kai"
import "mirai:cook/textures"
import net "mirai:net"
import "mirai:std/base"
import "mirai:store"
import vcs "mirai:kai"
import stbi "vendor:stb/image"

@(private="file")
Mesh_Machine :: struct {
    machine:vcs.Machine,
    runner:vcs.Runner,
    started:bool,
    stop:bool,
    worker:^thread.Thread,
    target:[1]net.Address,
}

@(private="file")
mesh_run :: proc(t:^thread.Thread) {
    m:=(^Mesh_Machine)(t.data)
    for !sync.atomic_load(&m.stop) {
        vcs.runner_update(&m.runner,0.01)
        free_all(context.temp_allocator)
    }
}

@(private="file")
mesh_start :: proc(m:^Mesh_Machine) {
    m.worker=thread.create(mesh_run)
    m.worker.data=m
    m.worker.init_context=context
    thread.start(m.worker)
}

@(private="file")
mesh_stop :: proc(m:^Mesh_Machine) {
    if m.worker!=nil {
        sync.atomic_store(&m.stop,true)
        thread.join(m.worker)
        thread.destroy(m.worker)
        m.worker=nil
    }
    if m.started {vcs.runner_stop(&m.runner)}
    m.started=false
}

@(private="file")
until :: proc(seconds:f64,data:rawptr,done:proc(data:rawptr) -> bool) -> bool {
    start:=time.tick_now()
    for time.duration_seconds(time.tick_since(start))<seconds {
        if done(data) {return true}
        free_all(context.temp_allocator)
        time.sleep(20*time.Millisecond)
    }
    return false
}

@(private="file")
Peer_Goal :: struct {control:^vcs.Control,class:vcs.Agent_Class,node:bool}

@(private="file")
peer_connected :: proc(data:rawptr) -> bool {
    g:=(^Peer_Goal)(data)
    peers:=make([dynamic]vcs.Runner_Peer_Info,context.temp_allocator)
    vcs.control_peers(g.control,&peers)
    for p in peers {
        if p.class==g.class && p.node==g.node {return true}
    }
    return false
}

@(private="file")
FIXTURES :: #directory+"/../../../assets/fixtures/"

// A PNG of 4×4 texels of one color.
@(private="file")
Png_Sink :: struct {bytes:[dynamic]u8,ctx:runtime.Context}

@(private="file")
png_of :: proc(rgb:[3]u8) -> []u8 {
    pixels:=make([]u8,4*4*4,context.temp_allocator)
    for at:=0;at<len(pixels);at+=4 {pixels[at],pixels[at+1],pixels[at+2],pixels[at+3]=rgb[0],rgb[1],rgb[2],255}
    sink:=Png_Sink{bytes=make([dynamic]u8,context.temp_allocator),ctx=context}
    stbi.write_png_to_func(proc "c" (user:rawptr,data:rawptr,size:c.int) {
        s:=(^Png_Sink)(user)
        context=s.ctx
        append(&s.bytes,..([^]u8)(data)[:size])
    },&sink,4,4,4,raw_data(pixels),4*4)
    return sink.bytes[:]
}

// The ref name of a result the cache name of s keeps whose record in org
// names no scope, and its key.
@(private="file")
public_result :: proc(s:^store.Store,org:vcs.Log_Id,name:string,version:u64) -> (ref:string,key:u64,ok:bool) {
    namespace_buffer:[store.NAME_MAX]u8
    namespace:=asset.cache_namespace(name,&namespace_buffer)
    refs,_:=store.ref_list(s,namespace,context.temp_allocator)
    for r in refs {
        records:=make([dynamic]vcs.DDC_Record,context.temp_allocator)
        vcs.ddc_lookup(s,org,ka.ddc_key(namespace,r.name),&records)
        if len(records)==0 || len(records[0].tainted_scopes)>0 || len(r.name)<16 {continue}
        key,ok=strconv.parse_u64_of_base(r.name[:16],16)
        // Of what built it: its ref is that of the key and version.
        buffer:[64]u8
        if !ok || fmt.bprintf(buffer[:],"%016x-%016x",key,base.hash_combine(version,cache.RESULTS_VERSION))!=r.name {continue}
        return strings.clone(r.name,context.temp_allocator),key,ok
    }
    return
}

// Alice and Bob run their machines' agents, each on its own thread over
// 127.0.0.1, as `mirai kai agent` does, with a seed+ddc node beside them. A
// cook of Alice's keeps a result in her cache, which publishes it as her
// signed derived data; a cook of Bob's misses the same result in his cache,
// asks his agent through its control, and loads what Alice built without
// building it. Alice imports a model into a project of the org through the
// library: Bob's project, without its source, resolves the package by taking
// the build Alice published, and his cook takes the texture and the mesh her
// import built. What Alice imports from a path of a scope Bob does not read is
// published sealed: he does not open it, she does. Dave, whose store holds the
// org but who is no member, takes nothing. A build Alice publishes lists the
// objects that come with it: the node mirrors all of them, and once Alice is
// gone Bob and Carol, who holds only a ddc grant, take the whole build from the
// node. A record that lists an object nobody has is no result.
@(test)
a_cook_takes_derived_data_a_peer_built :: proc(t:^testing.T) {
    // A copy that outlives the temp allocator, which until frees.
    folder:=strings.clone(base.test_folder(t,"kai-mesh-cook"))
    defer delete(folder)
    if folder=="" {return}
    machines:=new([5]Mesh_Machine)
    defer free(machines)
    alice,bob,node,carol,dave:=&machines[0],&machines[1],&machines[2],&machines[3],&machines[4]
    for &m,k in machines {
        if !testing.expect_value(t,vcs.machine_open(&m.machine,fmt.tprintf("%s/m%d",folder,k)),vcs.Error.None) {return}
    }
    defer for &m in machines {
        mesh_stop(&m)
        vcs.machine_close(&m.machine)
    }
    buffer:[vcs.RECOVERY_TEXT]u8
    names:=[]string{"alice","bob","carol","dave"}
    for x,k in ([]^Mesh_Machine{alice,bob,carol,dave}) {
        _,e:=vcs.machine_user_create(&x.machine,names[k],&buffer)
        testing.expect_value(t,e,vcs.Error.None)
    }
    org,oe:=vcs.machine_org_create(&alice.machine,"studio")
    testing.expect_value(t,oe,vcs.Error.None)
    l:vcs.Log
    vcs.log_init(&l,bob.machine.user,context.temp_allocator)
    vcs.log_open(&bob.machine.store,&l,bob.machine.user,.User)
    vcs.log_save(&alice.machine.store,&l)
    testing.expect_value(t,vcs.machine_member_add(&alice.machine,org,bob.machine.user,.Writer),vcs.Error.None)
    modes:=vcs.Node_Modes{.Relay,.Seed,.DDC}
    if !testing.expect_value(t,vcs.runner_start(&node.runner,{machine=&node.machine,bind=net.address_loopback(0),modes=modes,observe_port=0,beacon_port=-1}),vcs.Error.None) {return}
    node.started=true
    node.target[0]=net.address_loopback(vcs.runner_port(&node.runner))
    testing.expect_value(t,vcs.machine_node_add(&alice.machine,org,node.machine.identity.key,vcs.Dh_Key(node.machine.dh.public),modes,node.target[:]),vcs.Error.None)
    // Bob's store and the node's hold the org as a pairing left them.
    for x in ([]^Mesh_Machine{bob,node,dave}) {
        for id in ([]vcs.Log_Id{org,alice.machine.user}) {
            kind:=id==org?vcs.Log_Kind.Org:.User
            y:vcs.Log
            vcs.log_init(&y,id,context.temp_allocator)
            vcs.log_open(&alice.machine.store,&y,id,kind)
            vcs.log_save(&x.machine.store,&y)
        }
        testing.expect_value(t,vcs.machine_org_join(&x.machine,org),vcs.Error.None)
    }
    vcs.runner_reload(&node.runner)

    for x in ([]^Mesh_Machine{alice,bob,dave}) {
        if !testing.expect_value(t,vcs.runner_start(&x.runner,{machine=&x.machine,bind=net.address_loopback(0),beacon=true,beacon_port=-1,control=true}),vcs.Error.None) {return}
        x.started=true
    }
    // Each one's beacons reach the other's socket.
    alice.target[0]=net.address_loopback(vcs.runner_port(&bob.runner))
    bob.target[0]=net.address_loopback(vcs.runner_port(&alice.runner))
    dave.target[0]=bob.target[0]
    alice.runner.desc.beacon_targets=alice.target[:]
    bob.runner.desc.beacon_targets=bob.target[:]
    dave.runner.desc.beacon_targets=dave.target[:]
    // Carol holds a grant of the ddc right only.
    issued,ie:=vcs.machine_grant_issue(&alice.machine,org,vcs.Dh_Key(carol.machine.dh.public),carol.machine.identity.key,{.DDC},{},"",7,{net.address_loopback(vcs.runner_port(&alice.runner))},context.temp_allocator)
    if !testing.expectf(t,ie==.None,"alice issues: %s",alice.machine.why) {return}
    _,le:=vcs.machine_grant_load(&carol.machine,issued)
    if !testing.expectf(t,le==.None,"carol loads: %s",carol.machine.why) {return}
    if !testing.expect_value(t,vcs.runner_start(&carol.runner,{machine=&carol.machine,bind=net.address_loopback(0),beacon_port=-1,control=true}),vcs.Error.None) {return}
    carol.started=true
    for &m in machines {mesh_start(&m)}

    // The cooks are other machines of the same stores: they reach the agents
    // through the control, as another process would.
    cooks:=new([5]vcs.Machine)
    defer free(cooks)
    meshes:=new([5]ka.Mesh_Cache)
    defer free(meshes)
    for k in 0..<5 {testing.expect_value(t,vcs.machine_open(&cooks[k],machines[k].machine.store.root),vcs.Error.None)}
    for k in ([]int{0,1,3,4}) {testing.expect_value(t,ka.mesh_cache_open(&meshes[k],&cooks[k],org),vcs.Error.None)}
    defer for k in 0..<5 {
        ka.mesh_cache_close(&meshes[k])
        vcs.machine_close(&cooks[k])
    }
    g:=Peer_Goal{control=&meshes[1].control,class=.Member}
    if !testing.expect(t,until(10,&g,peer_connected),"bob's agent connects to alice's") {return}
    g.class,g.node=.Node,true
    if !testing.expect(t,until(10,&g,peer_connected),"bob's agent connects to the node") {return}
    g.control=&meshes[3].control
    if !testing.expect(t,until(15,&g,peer_connected),"carol's agent reaches the node through alice's") {return}

    types:asset.Types
    asset.types_init(&types)
    defer asset.types_destroy(&types)
    KEY,VERSION :: 0x5eed,3
    pixels:=make([]u8,4*4*4,context.temp_allocator)
    for &p,i in pixels {p=u8(i)}
    mips:=[1][]u8{pixels}
    doc:asset.Document
    testing.expect_value(t,asset.texture_document(&doc,&types,{id=cache.id(KEY,VERSION),width=4,height=4,format=.RGBA8,mips=mips[:]},context.temp_allocator),asset.Error.None)
    bytes,_:=asset.document_bytes(&doc,context.allocator)
    defer delete(bytes)
    asset.document_destroy(&doc)

    built:=cache.Cache{store=&cooks[0].store,source=ka.mesh_source(&meshes[0])}
    testing.expect(t,cache.put(built,"textures",KEY,VERSION,bytes),"alice's cook keeps and publishes its result")
    taken:=cache.Cache{store=&cooks[1].store,source=ka.mesh_source(&meshes[1])}
    file:asset.Asset
    if !testing.expect(t,cache.load(taken,"textures",KEY,VERSION,&file),"bob's cook takes what alice built") {return}
    defer asset.asset_close(&file)
    testing.expect(t,file.blob.header.id==cache.id(KEY,VERSION))
    other:=cache.Cache{store=&cooks[1].store,source=ka.mesh_source(&meshes[1])}
    testing.expect(t,!cache.has(other,"textures",KEY+1,VERSION),"what no peer built is a miss")

    // A project of the org in Alice's workspace and in Bob's; its files under
    // assets/private/ are a scope only admins read, which Bob, a writer, does not.
    pa,pb:=new(ka.Project),new(ka.Project)
    defer free(pa)
    defer free(pb)
    a_root,b_root:=fmt.aprintf("%s/alice-game",folder),fmt.aprintf("%s/bob-game",folder)
    props:=fmt.aprintf("%s/assets/props",a_root)
    defer {delete(a_root);delete(b_root);delete(props)}
    for made in ([]string{props,fmt.tprintf("%s/assets/private",a_root),fmt.tprintf("%s/assets",b_root)}) {os.make_directory_all(made)}
    if !testing.expect_value(t,ka.project_create(pa,a_root,&alice.machine.store),vcs.Error.None) {return}
    defer ka.project_close(pa)
    project,je:=ka.project_join(pa,&alice.machine,org,false)
    if !testing.expectf(t,je==.None,"alice makes the project: %s",alice.machine.why) {return}
    _,se:=vcs.machine_scope_add(&alice.machine,org,project,{"assets/private/**"},.Admin,false)
    testing.expect_value(t,se,vcs.Error.None)
    Logged :: struct {m:^vcs.Machine,project:vcs.Log_Id}
    logged:=Logged{&bob.machine,project}
    project_logged :: proc(data:rawptr) -> bool {
        x:=(^Logged)(data)
        l:vcs.Log
        vcs.log_init(&l,x.project,context.temp_allocator)
        return vcs.log_open(&x.m.store,&l,x.project,.Project)==.None
    }
    if !testing.expect(t,until(10,&logged,project_logged),"the project's log reaches bob") {return}
    if !testing.expect_value(t,ka.project_create(pb,b_root,&bob.machine.store),vcs.Error.None) {return}
    defer ka.project_close(pb)
    if !testing.expectf(t,ka.project_link(pb,&bob.machine,project)==.None,"bob links the project: %s",bob.machine.why) {return}

    // Alice imports a model with a texture, and an image of the scope.
    model,secret:=fmt.tprintf("%s/concave.obj",props),fmt.tprintf("%s/assets/private/secret.png",a_root)
    obj,_:=os.read_entire_file(FIXTURES+"concave.obj",context.temp_allocator)
    mtl,_:=os.read_entire_file(FIXTURES+"concave.mtl",context.temp_allocator)
    _=os.write_entire_file(model,obj)
    _=os.write_entire_file(fmt.tprintf("%s/concave.mtl",props),transmute([]u8)strings.concatenate({string(mtl),"map_Kd red.png\n"},context.temp_allocator))
    _=os.write_entire_file(fmt.tprintf("%s/red.png",props),png_of({200,30,30}))
    _=os.write_entire_file(secret,png_of({10,200,10}))
    a_shared,a_close:=ka.peers_open(cooks[0].store.root,a_root)
    if !testing.expect(t,a_close!=nil,"alice's project shares with the peers of its org") {return}
    a_options:=Library_Options{store=&cooks[0].store,root=a_root,source=a_shared}
    built_keys:[2]store.Hash
    for file,k in ([]string{model,secret}) {
        report,ie:=ingest(file,a_options,allocator=context.temp_allocator)
        if !testing.expectf(t,ie.code==.None,"%s: %s",file,ie.message) {
            a_close(a_shared)
            return
        }
        built_keys[k]=report.key
        added:=project_add(a_root,report.manifest,"",nil,a_options,context.temp_allocator)
        testing.expectf(t,len(added.failures)==0 && len(added.missing)==0,"%v %v",added.failures[:],added.missing[:])
    }
    _,published:=a_close(a_shared)
    testing.expectf(t,published>=5,"alice publishes both builds and what her imports' caches kept: %d",published)
    model_name,secret_name:[64]u8
    model_key,secret_key:=store.hex(built_keys[0],&model_name),store.hex(built_keys[1],&secret_name)

    // Bob's project has the packages Alice's pins, not their 
    for file in ([]string{asset.PACKAGES_FILE,asset.PACKAGE_FILES}) {
        from,to:=fmt.tprintf("%s/%s",a_root,file),fmt.tprintf("%s/%s",b_root,file)
        if os.is_dir(from) {
            os.make_directory_all(to)
            entries,_:=os.read_all_directory_by_path(from,context.temp_allocator)
            for entry in entries {
                data,_:=os.read_entire_file(fmt.tprintf("%s/%s",from,entry.name),context.temp_allocator)
                _=os.write_entire_file(fmt.tprintf("%s/%s",to,entry.name),data)
            }
        } else {
            data,_:=os.read_entire_file(from,context.temp_allocator)
            _=os.write_entire_file(to,data)
        }
    }
    testing.expect(t,!os.exists(fmt.tprintf("%s/assets/props/concave.obj",b_root)),"bob has no source to import")
    b_shared,b_close:=ka.peers_open(cooks[1].store.root,b_root)
    if !testing.expect(t,b_close!=nil,"bob's project shares with the peers of its org") {return}
    b_options:=Library_Options{store=&cooks[1].store,root=b_root,source=b_shared}
    refreshed:=project_refresh(b_root,b_options,context.temp_allocator)
    testing.expectf(t,refreshed.fetched==1 && refreshed.ingested==0 && len(refreshed.failures)==0 && len(refreshed.missing)==1,
        "bob takes the model's build from the mesh and imports nothing; the private one is missing: %v",refreshed)
    if object,re:=store.ref_get(&cooks[1].store,asset.REF_IMPORTS,model_key);testing.expect(t,re==.None,"bob holds the model's build") {
        b,be:=asset.build_get(&cooks[1].store,object,context.temp_allocator)
        testing.expect(t,be==.None && asset.build_whole(&cooks[1].store,&b,true),"and every object it lists")
    }
    // His cook takes the texture and the mesh Alice's import built.
    texture_ref,texture_key,has_texture:=public_result(&cooks[0].store,org,textures.CACHE,textures.BUILD_VERSION)
    mesh_ref,mesh_key,has_mesh:=public_result(&cooks[0].store,org,importer.MESH_CACHE,importer.MESH_CACHE_VERSION)
    if testing.expectf(t,has_texture && has_mesh,"alice's cache keeps a texture %q and a mesh %q of the model",texture_ref,mesh_ref) {
        here:=cache.Cache{store=&cooks[1].store}
        testing.expect(t,!textures.cache_has(here,texture_key),"bob's cache has no texture of it")
        taking:=cache.Cache{store=&cooks[1].store,source=b_shared}
        built,read:=textures.cache_read(taking,texture_key,&types,context.temp_allocator)
        testing.expect(t,read && built.width==4,"bob's cook takes the texture")
        mesh_file:asset.Asset
        if testing.expect(t,cache.load(taking,importer.MESH_CACHE,mesh_key,importer.MESH_CACHE_VERSION,&mesh_file),"bob's cook takes the mesh") {asset.asset_close(&mesh_file)}
    }
    // The private build: its record names the scope, its output is one sealed blob Bob does not open.
    testing.expect(t,!cache.source_fetch(b_shared,&cooks[1].store,asset.REF_IMPORTS,secret_key),"bob, who does not read the scope, takes no private result")
    secret_object,_:=store.ref_get(&cooks[0].store,asset.REF_IMPORTS,secret_key)
    records:=make([dynamic]vcs.DDC_Record,context.temp_allocator)
    vcs.ddc_lookup(&cooks[1].store,org,ka.ddc_key(asset.REF_IMPORTS,secret_key),&records)
    if testing.expect(t,len(records)==1 && len(records[0].tainted_scopes)==1,"the private build's record reaches bob, tainted") {
        objects,_:=vcs.ddc_output_get(&cooks[1].store,records[0].output_root,context.temp_allocator)
        testing.expect(t,len(objects)==1 && objects[0]!=secret_object,"its output is one sealed object, not the build")
    }
    took,_:=b_close(b_shared)
    testing.expectf(t,took==3,"bob took the build, the texture and the mesh: %d",took)
    // Alice, who reads the scope, opens what she sealed.
    testing.expect_value(t,store.ref_remove(&cooks[0].store,asset.REF_IMPORTS,secret_key),store.Error.None)
    again_shared,again_close:=ka.peers_open(cooks[0].store.root,a_root)
    if testing.expect(t,again_close!=nil) {
        testing.expect(t,cache.source_fetch(again_shared,&cooks[0].store,asset.REF_IMPORTS,secret_key),"a reader of the scope opens the sealed build")
        object,_:=store.ref_get(&cooks[0].store,asset.REF_IMPORTS,secret_key)
        testing.expect(t,object==secret_object,"and it is the build she made")
        again_close(again_shared)
    }
    // Dave holds the org's logs, but no member admits him: he takes nothing.
    testing.expect(t,!cache.source_fetch(ka.mesh_source(&meshes[4]),&cooks[4].store,asset.REF_IMPORTS,model_key),"a machine outside the org takes nothing")

    // A build of Alice's: the object of its ref lists the texture with it.
    texture,te:=asset.object_put(&cooks[0].store,bytes)
    testing.expect_value(t,te,asset.Error.None)
    b:=asset.Build{package_id=cache.id(KEY,1),key=store.Hash{0=9},final=true}
    b.outputs=make([dynamic]asset.Build_Output,context.temp_allocator)
    append(&b.outputs,asset.Build_Output{id=cache.id(KEY,VERSION),kind=asset.KIND_TEXTURE,object=texture})
    build,be:=asset.build_put(&cooks[0].store,&b)
    testing.expect_value(t,be,asset.Error.None)
    digits:[64]u8
    name:=store.hex(b.key,&digits)
    testing.expect_value(t,store.ref_set(&cooks[0].store,asset.REF_IMPORTS,name,build),store.Error.None)
    source:=ka.mesh_source(&meshes[0])
    source.kept(source.user,asset.REF_IMPORTS,name,build,nil)
    // And a record that lists an object nobody has.
    broken:=ka.ddc_key(asset.REF_IMPORTS,"broken")
    _,pe:=vcs.machine_publish_ddc(&cooks[0],org,broken,{build,store.Hash{0=0xee,31=1}},nil)
    testing.expect_value(t,pe,vcs.Error.None)

    // The node mirrors every object of the build, then Alice goes.
    Mirror :: struct {s:^store.Store,org:vcs.Log_Id,key:store.Hash}
    mirror:=Mirror{s=&cooks[2].store,org=org,key=ka.ddc_key(asset.REF_IMPORTS,name)}
    mirrored :: proc(data:rawptr) -> bool {
        m:=(^Mirror)(data)
        records:=make([dynamic]vcs.DDC_Record,context.temp_allocator)
        if vcs.ddc_lookup(m.s,m.org,m.key,&records)!=.None || len(records)==0 {return false}
        lacking:=make([dynamic]store.Hash,context.temp_allocator)
        objects,e:=vcs.ddc_output_lacking(m.s,records[0].output_root,&lacking)
        return e==.None && len(lacking)==0 && len(objects)==2
    }
    if !testing.expect(t,until(15,&mirror,mirrored),"the node mirrors the build and what it lists") {return}
    mesh_stop(alice)

    for k in ([]int{1,3}) {
        fetched:=cache.source_fetch(ka.mesh_source(&meshes[k]),&cooks[k].store,asset.REF_IMPORTS,name)
        if !testing.expectf(t,fetched,"machine %d takes the build from the node",k) {continue}
        object,re:=store.ref_get(&cooks[k].store,asset.REF_IMPORTS,name)
        got,ge:=asset.build_get(&cooks[k].store,object,context.temp_allocator)
        testing.expectf(t,re==.None && object==build && ge==.None && asset.build_whole(&cooks[k].store,&got,true),"machine %d holds the whole build",k)
    }
    testing.expect(t,!cache.source_fetch(ka.mesh_source(&meshes[1]),&cooks[1].store,asset.REF_IMPORTS,"broken") ,"a record whose objects are not all here is no result")
}
