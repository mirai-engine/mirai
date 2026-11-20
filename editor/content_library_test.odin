package editor

import "core:fmt"
import "core:testing"
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
