package editor

import "core:testing"
import "mirai:asset"
import "mirai:cook/share"
import "mirai:core"

// The libraries the browser draws: a root for this machine and one per peer;
// what the project pins is in none, a peer's package this machine has is
// listed once under it, two of one name are told apart by the folder of
// their source, and a peer that leaves takes its root with it.
@(test)
content_libraries_are_roots_of_what_the_project_does_not_hold :: proc(t:^testing.T) {
    sound:=[]Library_Asset{{kind=asset.KIND_SOUND,bytes=100,built=true}}
    model:=[]Library_Asset{{kind=asset.KIND_MESH,bytes=300,built=true}}
    local:=[]Library_Package{
        {id={1,1},name="robot",origin="/work/chars/robot.glb",assets=model},
        {id={1,2},name="robot",origin="/work/props/robot.glb",assets=model},
        {id={1,3},name="crate",origin="/work/props/crate.glb",pinned=true,assets=model},
        {id={1,4},name="bell",origin="/work/sounds/bell.wav",assets=sound},
    }
    kinds:=[]asset.Fourcc{asset.KIND_MESH}
    ana:=[]share.Peer_Package{
        {id={1,1},name="robot",origin="/home/ana/robot.glb",kinds=kinds,bytes=300,built=true,here=true},
        {id={1,3},name="crate",kinds=kinds,bytes=300,built=true},
        {id={2,1},name="lamp",origin="/home/ana/lamp.glb",kinds=kinds,bytes=2048,built=true},
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
    LIBRARIES :: "[This machine] .bell .robot (chars) .robot (props) [Ana] .lamp .tree (oak) .tree (pine) [Ben] .rock"
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
    testing.expect_value(t,content_test_show(&c,&registry),"#lamp,#tree (oak),#tree (pine)")
    c.filter_length=copy(c.filter[:],"pine")
    testing.expect_value(t,content_test_show(&c,&registry),"#tree (pine)")
    c.filter_length=0
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
