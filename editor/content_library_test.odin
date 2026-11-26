package editor

import "core:fmt"
import "core:slice"
import "core:testing"
import "core:thread"
import "mirai:asset"
import "mirai:cook/share"
import "mirai:core"
import "mirai:editor/history"
import "mirai:host"
import "mirai:std/base"
import "mirai:store"
import "mirai:ui"

// The libraries the browser draws: a root for this machine and one per peer;
// what the project pins is in none, a peer's package this machine has is
// listed once under it, two of one name are told apart by the folder of
// their source, and a peer that leaves takes its root with it.
@(test)
content_libraries_are_roots_of_what_the_project_does_not_hold :: proc(t:^testing.T) {
    sound:=[]Library_Asset{{kind=asset.KIND_SOUND,bytes=100,built=true}}
    model:=[]Library_Asset{{kind=asset.KIND_MESH,bytes=300,built=true}}
    pinned_model:=[]Library_Asset{{kind=asset.KIND_MESH,bytes=300,built=true,pinned=true}}
    local:=[]Library_Package{
        {id={1,1},name="robot",origin="/work/chars/robot.glb",assets=model},
        {id={1,2},name="robot",origin="/work/props/robot.glb",assets=model},
        {id={1,3},name="crate",origin="/work/props/crate.glb",pinned=true,assets=pinned_model},
        {id={1,4},name="bell",origin="/work/sounds/bell.wav",assets=sound},
    }
    kinds:=[]asset.Fourcc{asset.KIND_MESH}
    lamp_assets:=[]share.Peer_Package_Asset{{{3,1},"shade",asset.KIND_MATERIAL},{{3,2},"glass",asset.KIND_TEXTURE}}
    ana:=[]share.Peer_Package{
        {id={1,1},name="robot",origin="/home/ana/robot.glb",kinds=kinds,bytes=300,built=true,here=true},
        {id={1,3},name="crate",kinds=kinds,bytes=300,built=true},
        {id={2,1},name="lamp",catalog_path="Crystal_Cave/Maps",origin="/home/ana/lamp.glb",kinds=kinds,assets=lamp_assets,bytes=2048,built=true},
        {id={2,2},name="tree",origin="/home/ana/trees/oak/tree.glb",kinds=kinds,bytes=4096,built=true},
        {id={2,3},name="tree",origin="/home/ana/trees/pine/tree.glb",kinds=kinds,bytes=4096,built=true},
    }
    ben:=[]share.Peer_Package{{id={3,1},name="rock",kinds=kinds,bytes=-1}}
    peers:=[]Content_Peer_Listing{{peer=1,name="Ana",list=ana},{peer=2,name="Ben",list=ben}}

    registry:=content_test_wall_registry()
    defer content_test_registry_free(&registry)
    c:=CONTENT_DEFAULT
    defer core.value_free(&c,type_info_of(Content))
    c.libraries.roots,c.libraries.packages=content_library_listing(local,peers,allocator=context.temp_allocator)
    testing.expect(t,len(c.libraries.roots)==3 && c.libraries.roots[0].peer==-1 && c.libraries.roots[1].name=="Ana" && c.libraries.roots[2].peer==2)
    PROJECT :: " [Castle] .[Props] ..barrel ..crate ..torch ..wall .[Towers] ..big .gate [Levels] .one rock"
    LIBRARIES :: "[This machine] .bell .robot (chars) .robot (props) [Ana] .[Crystal_Cave] ..[Maps] ...lamp .tree (oak) .tree (pine) [Ben] .rock"
    testing.expect_value(t,content_test_show(&c,&registry),CONTENT_TEST_MARKS+LIBRARIES+PROJECT)
    for &p in c.libraries.packages {
        if p.name=="lamp" {testing.expect(t,!p.here && p.bytes==2048 && p.root==1,"a package of a peer has to be fetched")}
        if p.name=="bell" {testing.expect(t,p.here && p.bytes==100 && p.root==0,"one of this machine is here")}
    }

    // A search in Folders finds packages under the names of their roots.
    c.filter_length=copy(c.filter[:],"tree")
    testing.expect_value(t,content_test_show(&c,&registry),"{Ana} tree (oak) tree (pine)")
    // Inside a root, in Cards, its packages are cells, and the search looks only there.
    c.view.arrangement=.Cards
    c.filter_length=0
    content_enter(&c,.Library,library=2)
    testing.expect_value(t,content_test_show(&c,&registry),"#Crystal_Cave,#tree (oak),#tree (pine)")
    c.filter_length=copy(c.filter[:],"pine")
    testing.expect_value(t,content_test_show(&c,&registry),"#tree (pine)")
    c.filter_length=0
    content_enter(&c,.Library,"Crystal_Cave",library=2)
    testing.expect_value(t,content_test_show(&c,&registry),"#Maps")
    content_enter(&c,.Library,"Crystal_Cave/Maps",library=2)
    testing.expect_value(t,content_test_show(&c,&registry),"#lamp")
    content_enter(&c,.Library,"Crystal_Cave/Maps",library=2,package_id={2,1})
    content_test_show(&c,&registry)
    testing.expect(t,len(c.cards)==2 && c.cards[0].name=="shade" && c.cards[0].pack_asset>0)
    c.filter_length=copy(c.filter[:],"glass")
    content_test_show(&c,&registry)
    testing.expect(t,len(c.cards)==1 && c.cards[0].name=="glass")
    c.filter_length=0
    // A selected peer asset can move the package into This machine without closing its folder.
    taken:=[]Library_Asset{{id={3,1},name="shade",kind=asset.KIND_MATERIAL,pinned=true},{id={3,2},name="glass",kind=asset.KIND_TEXTURE}}
    following:=[]Library_Package{{id={2,1},name="lamp",catalog_path="Crystal_Cave/Maps",assets=taken,pinned=true}}
    c.libraries.roots,c.libraries.packages=content_library_listing(following,peers,allocator=context.temp_allocator)
    content_library_restore(&c)
    c.revision+=1
    content_test_show(&c,&registry)
    testing.expect(t,c.at.library==0 && c.at.package_id==base.Asset_Id{2,1} && len(c.cards)==2)
    testing.expect_value(t,string(c.at.folder[:c.at.length]),"Crystal_Cave/Maps")
    for p in c.libraries.packages {
        if p.id==c.at.package_id {testing.expect(t,p.assets[0].pinned && !p.assets[1].pinned)}
    }
    c.libraries.roots,c.libraries.packages=content_library_listing(local,peers,allocator=context.temp_allocator)
    c.revision+=1
    // The filter of a kind keeps those of the kind.
    c.category=.Sound
    content_enter(&c,.Library,library=0)
    testing.expect_value(t,content_test_show(&c,&registry),"#bell")
    c.category=.None

    // Ana leaves: her root goes, and a browser inside it goes back to the project.
    content_enter(&c,.Library,library=2)
    c.libraries.roots,c.libraries.packages=content_library_listing(local,peers[1:],allocator=context.temp_allocator)
    c.revision+=1
    testing.expect(t,len(c.libraries.roots)==2 && content_library_root_of(&c,2)<0)
    c.restore=true
    content_test_show(&c,&registry)
    testing.expect(t,c.at.virtual==.None,"the root of a peer that left is not where the browser stays")
}

@(test)
content_library_folder_add_includes_all_descendants_while_searching :: proc(t:^testing.T) {
    public:=[]share.Peer_Package{
        {id={1,1},name="scene",catalog_path="Crystal Cave"},
        {id={1,2},name="lamp",catalog_path="Crystal Cave/Props"},
        {id={1,3},name="rail",catalog_path="Crystal Cave/Props/Rails"},
        {id={1,4},name="wood",catalog_path="Crystal Cave/Props Extra"},
        {id={1,5},name="tree",catalog_path="Crystal Cave Extra"},
    }
    other:=[]share.Peer_Package{{id={2,1},name="scene",catalog_path="Crystal Cave"}}
    peers:=[]Content_Peer_Listing{{peer=1,name="Ana",list=public},{peer=2,name="Ben",list=other}}
    c:=CONTENT_DEFAULT
    defer core.value_free(&c,type_info_of(Content))
    c.libraries.roots,c.libraries.packages=content_library_listing(nil,peers,false,context.temp_allocator)
    c.filter_length=copy(c.filter[:],"lamp")
    testing.expect_value(t,len(content_package_entries(&c,0,string(c.filter[:c.filter_length]))),1)
    testing.expect(t,slice.equal(content_library_folder_packages(&c,2,"Crystal Cave"),
        []base.Asset_Id{{1,2},{1,3},{1,1},{1,4}}))
    testing.expect(t,slice.equal(content_library_folder_packages(&c,2,"Crystal Cave/Props"),
        []base.Asset_Id{{1,2},{1,3}}))
    testing.expect(t,slice.equal(content_library_folder_packages(&c,3,"Crystal Cave"),[]base.Asset_Id{{2,1}}))
    testing.expect(t,len(content_library_folder_packages(&c,2,""))==0)
    testing.expect(t,len(content_library_folder_packages(&c,4,"Crystal Cave"))==0)

    ctx:ui.Context
    if !testing.expect(t,test_ui_init(&ctx,{})) {return}
    defer ui.context_destroy(&ctx)
    assets:=host.Assets{registry=content_test_registry(),indexed=true}
    defer content_test_registry_free(&assets.registry)
    app:=host.App{assets=&assets}
    g:=Editor_Ui{ctx=&ctx}
    selection:history.Selection
    info:core.World_Info
    session:=Session{app=&app,gui=&g,content=&c,selection=&selection,info=&info,headless=true}
    c.libraries.ready,c.libraries.key=true,{assets.registry.revision,0,c.library_revision,0}
    c.filter_length=0
    folder:="Crystal Cave"
    group:=content_library_folder_group(0,folder)
    row:=ui.id_derive(&ctx,100,"content_folder",int(group))
    add:=ui.id_derive(&ctx,row,"content_library_folder_add",int(content_library_folder_group(2,folder)))
    root:=ui.id_derive(&ctx,100,"content_folder",int(content_library_group(0)))
    content_test_still(&session)
    _,found:=ui.widget_rect(&ctx,root)
    testing.expect(t,found)
    root_add:=ui.id_derive(&ctx,root,"content_library_folder_add",int(content_library_folder_group(2,"")))
    _,found=ui.widget_rect(&ctx,root_add)
    testing.expect(t,!found,"peer roots are not folders to add")
    content_test_click(t,&session,add)
    testing.expect(t,!content_folded(&c,group),"the busy folder action does not fold the row")

    c.view.arrangement=.Cards
    content_enter(&c,.Library,library=2)
    modes:=[]Content_Mode{.Grid,.List}
    for mode in modes {
        c.view.mode=mode
        content_test_still(&session)
        content_test_click(t,&session,add)
        testing.expect(t,c.at.length==0,"the busy folder action does not open the folder")
    }
}

// A card of a peer's root asks for its thumbnail only while it is in sight:
// of two hundred packages, the few the browser draws, never all of them.
@(test)
the_browser_asks_peers_only_for_the_thumbnails_of_visible_cards :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,test_ui_init(&ctx,{}))
    defer ui.context_destroy(&ctx)
    assets:=host.Assets{registry=content_test_registry(),indexed=true}
    defer content_test_registry_free(&assets.registry)
    app:=host.App{assets=&assets}
    g:=Editor_Ui{ctx=&ctx}
    c:=CONTENT_DEFAULT
    defer core.value_free(&c,type_info_of(Content))
    selection:history.Selection
    info:core.World_Info
    session:=Session{app=&app,gui=&g,content=&c,selection=&selection,info=&info,headless=true}
    folder:=base.test_folder(t,"library-thumbs")
    if folder=="" {return}
    opened,error:=store.open(folder)
    if !testing.expect_value(t,error,store.Error.None) {return}
    session.store=opened
    defer store.close(&session.store)
    peers:=make([]share.Peer_Package,200,context.temp_allocator)
    for &p,k in peers {
        object:=store.address_of_bytes(transmute([]u8)fmt.tprintf("object %d",k))
        p={id={7,u64(k+1)},name=fmt.tprintf("p%03d",k),kinds=[]asset.Fourcc{asset.KIND_MESH},bytes=1000,built=true,root=object,objects=[]store.Hash{object}}
    }
    listing:=[]Content_Peer_Listing{{peer=1,name="Ana",list=peers}}
    c.libraries.roots,c.libraries.packages=content_library_listing(nil,listing,false,context.temp_allocator)
    // What content_libraries_update would read is what is set: it keeps it.
    c.libraries.ready,c.libraries.key=true,{assets.registry.revision,0,c.library_revision,u64(len(session.store.root))}
    _=content_test_frame(&session,{size={800,600},pointer_absent=true})
    _=content_test_frame(&session,{size={800,600},pointer_absent=true})
    wanted:=len(c.thumb_wants)
    testing.expectf(t,wanted>0 && wanted<30,"the visible cards ask: %d",wanted)
    first:=thumbnail_package_key(.Small,thumbnail_programs(&session),peers[0].root,peers[0].objects)
    last:=thumbnail_package_key(.Small,thumbnail_programs(&session),peers[199].root,peers[199].objects)
    asked_first,asked_last:=false,false
    for want in c.thumb_wants {
        testing.expect_value(t,want.peer,1)
        asked_first||=want.key==first
        asked_last||=want.key==last
    }
    testing.expect(t,asked_first && !asked_last,"the first card is in sight, the last is not")
}

@(test)
fetched_bytes_read_as_done_over_total_in_the_unit_of_the_total :: proc(t:^testing.T) {
    cases:=[]struct{done,total:u64,text:string}{
        {0,512,"0 / 512 B"},
        {12<<10,40<<10,"12 / 40 KB"},
        {5<<19,8<<20,"2.5 / 8.0 MB"},
        {128<<20,512<<20,"128 / 512 MB"},
        {1288490188,3650722201,"1.2 / 3.4 GB"},
        // What the node received for others too never reads past the total.
        {900<<20,512<<20,"512 / 512 MB"},
    }
    for c in cases {testing.expect_value(t,content_bytes_progress(c.done,c.total),c.text)}
}

// The rows of a peer's library end in one column: the add of a folder and of
// a package, then the ring of a fetch in the place of its add, whose click
// cancels it and gives the add back.
@(test)
library_rows_end_in_one_column_and_a_fetch_cancels_from_its_ring :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    if !prefab_fixture_init(t,f,"library-fetch") {return}
    defer prefab_fixture_destroy(f)
    ctx:ui.Context
    if !testing.expect(t,test_ui_init(&ctx,{})) {return}
    defer ui.context_destroy(&ctx)
    f.s.gui.ctx=&ctx
    c:=CONTENT_DEFAULT
    defer core.value_free(&c,type_info_of(Content))
    f.s.content=&c
    f.s.headless=true
    folder:="Crystal Cave"
    public:=[]share.Peer_Package{
        {id={1,1},name="scene",catalog_path=folder,bytes=512<<20},
        {id={1,2},name="lamp",catalog_path=folder,bytes=512<<20},
    }
    // Listed once the registry settled: what content_libraries_update would read is what is set.
    content_test_still(&f.s)
    c.libraries.roots,c.libraries.packages=content_library_listing(nil,[]Content_Peer_Listing{{peer=1,name="Ana",list=public}},false,context.temp_allocator)
    c.libraries.ready,c.libraries.key=true,{f.assets.registry.revision,0,c.library_revision,0}
    c.revision+=1

    group:=content_library_folder_group(0,folder)
    row:=ui.id_derive(&ctx,100,"content_folder",int(group))
    folder_add:=ui.id_derive(&ctx,row,"content_library_folder_add",int(content_library_folder_group(2,folder)))
    key:=base.hash_combine(content_library_group(0),base.hash_combine(1,2))
    package_add:=ui.id_derive(&ctx,100,"content_package_add",int(key))
    ring:=ui.id_derive(&ctx,100,"content_package_fetch",int(key))
    content_test_still(&f.s)
    folder_rect,folder_found:=ui.widget_rect(&ctx,folder_add)
    package_rect,package_found:=ui.widget_rect(&ctx,package_add)
    if !testing.expect(t,folder_found && package_found) {return}
    testing.expect_value(t,package_rect.x+package_rect.w,folder_rect.x+folder_rect.w)
    testing.expect_value(t,package_rect.w,folder_rect.w)

    node:=new(share.Node);defer free(node)
    st:=new(Collab_State);defer free(st)
    st.node=node
    take:=new(Collab_Take);defer free(take)
    take.id=public[1].id
    take.thread=thread.create_and_start(proc() {})
    st.take=take
    collab_of(&f.s).state=st
    defer collab_of(&f.s).state=nil
    content_test_still(&f.s)
    p:^Content_Package
    for &q in c.libraries.packages {if q.id==take.id {p=&q}}
    if !testing.expect(t,p!=nil) {return}
    text,_,_:=content_package_state(&f.s,p)
    testing.expect_value(t,text,"0 / 512 MB")
    ring_rect,ring_found:=ui.widget_rect(&ctx,ring)
    _,add_found:=ui.widget_rect(&ctx,package_add)
    testing.expect(t,ring_found && !add_found,"the ring takes the place of the add")
    testing.expect_value(t,ring_rect,package_rect)

    content_test_click(t,&f.s,ring)
    testing.expect(t,take.cancelled,"the click on the ring cancels the fetch")
    content_test_still(&f.s)
    _,add_found=ui.widget_rect(&ctx,package_add)
    testing.expect(t,add_found,"a cancelled fetch gives its add back")
    text,_,_=content_package_state(&f.s,p)
    testing.expect_value(t,text,"512.0 MB to fetch")
    // Its end adds nothing and tells nothing.
    take.done=true
    collab_take_update(&f.s,st)
    testing.expect(t,take.thread==nil && take.error=="")

    // A whole folder fetch puts its ring in the folder row's slot and cancels the same way.
    folder_key:=content_library_folder_group(2,folder)
    folder_ring:=ui.id_derive(&ctx,row,"content_library_folder_fetch",int(folder_key))
    take^={folder_key=folder_key,total_bytes=1<<30,thread=thread.create_and_start(proc() {})}
    content_test_still(&f.s)
    fring_rect,fring_found:=ui.widget_rect(&ctx,folder_ring)
    _,fadd_found:=ui.widget_rect(&ctx,folder_add)
    testing.expect(t,fring_found && !fadd_found,"a folder fetch puts the ring in place of its add")
    testing.expect_value(t,fring_rect,folder_rect)
    content_test_click(t,&f.s,folder_ring)
    testing.expect(t,take.cancelled,"the click on the folder ring cancels the fetch")
    take.done=true
    collab_take_update(&f.s,st)
    testing.expect(t,take.thread==nil && take.error=="")
}
