package kai_assets

import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:store"
import vcs "mirai:kai"

@(private="file") Test_Transform :: struct {position:[3]f32,rotation:quaternion128,scale:[3]f32}
@(private="file") Test_Light :: struct {color:[3]f32,intensity:f32,range:f32}
@(private="file") ROOT :: base.Entity_Id(0x10)
@(private="file") LAMP :: base.Entity_Id(0x20)

// The bytes of the scene every side starts from, with what change makes to it.
@(private="file")
scene_file :: proc(t:^testing.T,types:^asset.Types,change:proc(scene:^asset.Scene)=nil) -> []u8 {
    scene:asset.Scene
    testing.expect_value(t,asset.scene_init(&scene,types,{0x61,0x62}),asset.Error.None)
    defer asset.scene_destroy(&scene)
    asset.scene_entity_add(&scene,ROOT,0,"Root")
    asset.scene_entity_add(&scene,LAMP,ROOT,"Lamp")
    for id in ([]base.Entity_Id{ROOT,LAMP}) {
        value:=Test_Transform{rotation=1,scale={1,1,1}}
        asset.scene_set(&scene,id,"Transform",&value)
    }
    light:=Test_Light{{1,1,1},3,10}
    asset.scene_set(&scene,LAMP,"Light",&light)
    if change!=nil {change(&scene)}
    bytes,e:=asset.scene_bytes(&scene,context.temp_allocator)
    testing.expect_value(t,e,asset.Error.None)
    return bytes
}

@(private="file")
tree_with :: proc(t:^testing.T,s:^store.Store,bytes:[]u8) -> store.Hash {
    address,e:=store.put(s,bytes)
    testing.expect_value(t,e,store.Error.None)
    root,f:=vcs.tree_build(s,{vcs.File{path="assets/level.scene",kind=.File,address=address,size=u64(len(bytes))}})
    testing.expect_value(t,f,vcs.Error.None)
    return root
}

@(test)
a_scene_merges_by_field_through_the_driver :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"cook-kai");if folder=="" {return}
    s,e:=store.open(strings.concatenate({folder,"/store"},context.temp_allocator))
    if !testing.expect_value(t,e,store.Error.None) {return}
    defer store.close(&s)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)

    origin:=scene_file(t,&types)
    ours:=scene_file(t,&types,proc(scene:^asset.Scene) {
        moved:=Test_Transform{position={5,0,0},rotation=1,scale={1,1,1}}
        asset.scene_set(scene,LAMP,"Transform",&moved)
    })
    theirs:=scene_file(t,&types,proc(scene:^asset.Scene) {
        brighter:=Test_Light{{1,1,1},7,10}
        asset.scene_set(scene,LAMP,"Light",&brighter)
    })

    d:=Asset_Driver{types=&types}
    drivers:=[1]vcs.Driver{driver(&d)}
    m:=vcs.Merger{s=&s,drivers=drivers[:]}
    root,merge_error:=vcs.tree_merge3(&m,tree_with(t,&s,origin),tree_with(t,&s,ours),tree_with(t,&s,theirs))
    testing.expect_value(t,merge_error,vcs.Error.None)
    totals,_:=vcs.tree_totals(&s,root)
    testing.expect_value(t,totals.conflicts,0)

    files:=make([dynamic]vcs.File,context.temp_allocator)
    testing.expect_value(t,vcs.tree_files(&s,root,&files,context.temp_allocator),vcs.Error.None)
    if !testing.expect_value(t,len(files),1) {return}
    merged_bytes,_:=vcs.file_bytes(&s,files[0].address,context.temp_allocator)
    merged:asset.Scene
    testing.expect_value(t,asset.scene_read(&merged,&types,merged_bytes),asset.Error.None)
    defer asset.scene_destroy(&merged)
    transform,_:=asset.scene_get(&merged,LAMP,"Transform",Test_Transform)
    light,_:=asset.scene_get(&merged,LAMP,"Light",Test_Light)
    testing.expect(t,transform.position==[3]f32{5,0,0},"ours moved the lamp")
    testing.expect_value(t,light.intensity,7)

    // A comment on the lamp follows it into the merge; one on an entity gone does not.
    anchor:=vcs.Anchor{kind=.Structural,key=u64(LAMP)}
    testing.expect(t,vcs.drivers_anchor(drivers[:],ours,merged_bytes,&anchor))
    gone:=vcs.Anchor{kind=.Structural,key=0x99}
    testing.expect(t,!vcs.drivers_anchor(drivers[:],ours,merged_bytes,&gone))

    // Both moved the lamp apart: a conflict, written with ours where they disagree.
    apart:=scene_file(t,&types,proc(scene:^asset.Scene) {
        moved:=Test_Transform{position={0,9,0},rotation=1,scale={1,1,1}}
        asset.scene_set(scene,LAMP,"Transform",&moved)
    })
    conflicted,_:=vcs.tree_merge3(&m,tree_with(t,&s,origin),tree_with(t,&s,ours),tree_with(t,&s,apart))
    totals,_=vcs.tree_totals(&s,conflicted)
    testing.expect_value(t,totals.conflicts,1)
    testing.expect(t,!filter().procedure(nil,".mirai/cache") && filter().procedure(nil,"assets/level.scene"))
}

// The summary of an asset of each kind: what a reviewer reads of it, the same
// record for the same bytes and another when what it summarizes changes; a
// file that is not an asset has none, one past SUMMARY_FILE_MAX says only its
// kind and size, and the detail of a change of a scene names the entity.
@(test)
asset_summaries_are_stable_and_follow_their_bytes :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    Case :: struct {name:string,bytes:[]u8,kind:string,fact:string,edit:string,value:string}
    cases:=[]Case{
        {"scene",scene_file(t,&types),"scene","Top entities","entities[0].name",`"Base"`},
        {"mesh",#load("../../demo/assets/blockout/column.mesh"),"mesh","Triangles","mesh.triangle_count","9"},
        {"texture",#load("../../demo/assets/interface/item_coin.tex"),"texture","Pixels","texture.mip_count","3"},
        {"animation",#load("../../demo/assets/showcase/lift.anim"),"animation","Names","keys[2].time","6"},
        {"material",#load("../../demo/assets/ocean/Ocean.mat"),"material","Roughness","material.roughness","0.25"},
        {"skeleton",#load("../../demo/assets/physics_gallery/ragdoll/rig.skeleton"),"skeleton","Bones","",""},
    }
    facts:=make([dynamic]vcs.Preview_Fact,context.temp_allocator)
    for c in cases {
        record,ok:=asset_summary(c.bytes,context.temp_allocator)
        if !testing.expectf(t,ok,"%s: a summary",c.name) {continue}
        testing.expectf(t,vcs.preview_check(.Summary,record)==.None,"%s: a node takes it",c.name)
        kind,e:=vcs.preview_summary_decode(record,&facts)
        testing.expectf(t,e==.None && kind==c.kind,"%s: of kind %q: %v %q",c.name,c.kind,e,kind)
        named:=false
        for f in facts {named||=f.label==c.fact && f.value!=""}
        testing.expectf(t,named,"%s: says %s: %s",c.name,c.fact,string(record))
        again,_:=asset_summary(c.bytes,context.temp_allocator)
        testing.expectf(t,string(again)==string(record),"%s: the same bytes, the same summary",c.name)
        if c.edit=="" {continue}
        doc:asset.Document
        if !testing.expectf(t,asset.document_read(&doc,c.bytes,context.temp_allocator)==.None,"%s reads",c.name) {continue}
        location,le:=asset.document_locate(&doc,c.edit)
        if !testing.expectf(t,le==.None,"%s: %s locates: %v",c.name,c.edit,le) {continue}
        reader:serial.Text_Reader
        serial.text_reader_init(&reader,c.value)
        testing.expectf(t,serial.text_read(&reader,&doc.schema,location.type,location.bytes,location.is_text),"%s: %s takes %s",c.name,c.edit,c.value)
        edited,be:=asset.document_bytes(&doc,context.temp_allocator)
        testing.expect_value(t,be,asset.Error.None)
        other,_:=asset_summary(edited,context.temp_allocator)
        testing.expectf(t,len(other)>0 && string(other)!=string(record),"%s: another summary once %s changes:\n%s",c.name,c.edit,string(other))
    }

    _,ok:=asset_summary(transmute([]u8)string("not an asset at all, only text\n"))
    testing.expect(t,!ok,"text has no summary")
    mesh:=#load("../../demo/assets/blockout/column.mesh")
    _,ok=asset_summary(mesh[:len(mesh)/2])
    testing.expect(t,!ok,"a truncated asset has no summary")
    large:=make([]u8,SUMMARY_FILE_MAX+1)
    defer delete(large)
    copy(large,mesh)
    record,large_ok:=asset_summary(large,context.temp_allocator)
    kind,_:=vcs.preview_summary_decode(record,&facts)
    testing.expectf(t,large_ok && kind=="mesh" && len(facts)==1 && facts[0].label=="File","an asset past SUMMARY_FILE_MAX is its kind and size: %s",string(record))

    // The detail of moving the lamp names it.
    moved:=scene_file(t,&types,proc(scene:^asset.Scene) {
        value:=Test_Transform{position={5,0,0},rotation=1,scale={1,1,1}}
        asset.scene_set(scene,LAMP,"Transform",&value)
    })
    detail,dok:=asset_detail(scene_file(t,&types),moved,context.temp_allocator)
    rows:=make([dynamic]vcs.Preview_Row,context.temp_allocator)
    d,de:=vcs.preview_detail_decode(detail,&rows)
    testing.expectf(t,dok && de==.None && d.changed>0 && len(d.rows)>0 && d.rows[0].name=="Lamp","the detail of a move names the lamp: %s",string(detail))
    _,dok=asset_detail(transmute([]u8)string("a"),transmute([]u8)string("b"),context.temp_allocator)
    testing.expect(t,!dok,"text has no asset detail")
}

// Rows of one table that name rows of another by what they hold, which a
// merge of rows does not follow. Ours removed what theirs then names: the
// merge breaks the rules of the kind, and the file conflicts whole as ours had
// it. What each side changed in a table of its own goes together.
@(test)
a_merge_that_breaks_its_kind_conflicts_as_ours :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    skeleton :: proc(t:^testing.T,types:^asset.Types,bones:[]asset.Skeleton_Bone,sockets:[]asset.Skeleton_Socket={}) -> []u8 {
        doc:asset.Document
        if !testing.expect_value(t,asset.skeleton_document(&doc,types,{id={0x5e1,1},bones=bones,sockets=sockets},context.temp_allocator),asset.Error.None) {return nil}
        bytes,e:=asset.document_bytes(&doc,context.temp_allocator)
        testing.expect_value(t,e,asset.Error.None)
        return bytes
    }
    texts :: proc(t:^testing.T,types:^asset.Types,languages:[]string,keys:[]string,entries:[]asset.String_Entry,text:string) -> []u8 {
        rows:=make([]asset.String_Language,len(languages),context.temp_allocator)
        for code,at in languages {asset.text_set(rows[at].code[:],code)}
        names:=make([]asset.String_Key,len(keys),context.temp_allocator)
        for name,at in keys {asset.text_set(names[at].name[:],name)}
        bytes,e:=asset.strings_bytes(types,{id={0x5e2,1},languages=rows,keys=names,entries=entries,text=transmute([]u8)text},context.temp_allocator)
        testing.expect_value(t,e,asset.Error.None)
        return bytes
    }
    bones:=[2]asset.Skeleton_Bone{{parent=-1,rotation=1,scale={1,1,1}},{parent=0,rotation=1,scale={1,1,1}}}
    asset.text_set(bones[0].name[:],"root");asset.text_set(bones[0].path[:],"root");bones[0].target=base.name_hash("root")
    asset.text_set(bones[1].name[:],"arm");asset.text_set(bones[1].path[:],"root/arm");bones[1].target=base.name_hash("root/arm")
    socket:=asset.Skeleton_Socket{bone=bones[1].path,offset={rotation=1,scale={1,1,1}}};asset.text_set(socket.name[:],"hand")
    raised:=bones
    raised[1].translation[1]=2
    one:=[]asset.String_Entry{{key=0,language=0,offset=0,length=1}}
    two:=[]asset.String_Entry{{key=0,language=0,offset=0,length=1},{key=1,language=0,offset=1,length=1}}

    Case :: struct {name:string,origin,breaks,theirs,own:[]u8,merged:[2][2]string}
    cases:=[]Case{
        {"skeleton",
            skeleton(t,&types,bones[:]),
            skeleton(t,&types,bones[:1]),                     // ours removed the arm
            skeleton(t,&types,bones[:],{socket}),             // theirs hung the hand from it
            skeleton(t,&types,raised[:]),                     // ours raised the arm
            {{"bones[1].translation[1]","2"},{"sockets[0].name",`"hand"`}}},
        {"strings",
            texts(t,&types,{"en"},{"a","b"},one,"A"),
            texts(t,&types,{"en"},{"a"},one,"A"),             // ours removed the key b
            texts(t,&types,{"en"},{"a","b"},two,"AB"),        // theirs gave it a text
            texts(t,&types,{"en-US"},{"a","b"},one,"A"),      // ours renamed the language
            {{"languages[0].code",`"en-US"`},{"entries[1].key","1"}}},
    }
    d:=Asset_Driver{types=&types}
    drivers:=[1]vcs.Driver{driver(&d)}
    out:=make([dynamic]u8,context.temp_allocator)
    for c in cases {
        input:=vcs.Driver_Input{path="assets/a",base=c.origin,ours=c.breaks,theirs=c.theirs,has_base=true}
        result:=vcs.drivers_merge(drivers[:],&input,&out)
        testing.expectf(t,result==.Conflicted && string(out[:])==string(c.breaks),"%s: a merge that breaks it conflicts as ours: %v",c.name,result)

        input.ours=c.own
        result=vcs.drivers_merge(drivers[:],&input,&out)
        if !testing.expectf(t,result==.Resolved,"%s: tables of its own merge: %v",c.name,result) {continue}
        doc:asset.Document
        if !testing.expectf(t,asset.document_read(&doc,out[:],context.temp_allocator)==.None,"%s: the merge reads",c.name) {continue}
        for pair in c.merged {
            got:=value_text(&doc,pair[0],context.temp_allocator)
            testing.expectf(t,got==pair[1],"%s: %s is %s, not %q",c.name,pair[0],pair[1],got)
        }
    }
}
