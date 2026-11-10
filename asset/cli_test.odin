package asset

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import anim "mirai:std/anim"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:std/subprocess"

// End to end: builds the mirai tool from this tree and runs `mirai asset` on
// files written here. It needs MIRAI_ROOT, which `mirai test` sets, and the
// Odin compiler it used.

@(private="file") EXE :: ".exe" when ODIN_OS==.Windows else ""
@(private="file") KIND_QUEST :: Fourcc(u32('Q')|u32('U')<<8|u32('S')<<16|u32('T')<<24)
@(private="file") Quest_State :: enum u8 {Hidden,Open,Done}
@(private="file") Quest_Info :: struct {title:[32]u8 `mirai:"text"`,state:Quest_State,giver:base.Asset_Id}
@(private="file") Quest_Step :: struct {reward:u16,optional:bool,position:[3]f32}

@(private="file")
Cli :: struct {
    t:^testing.T,
    exe:string,
    folder:string,
}

@(private="file")
Result :: struct {code:int,out,err:string}

@(private="file")
run :: proc(cli:^Cli,args:..string) -> Result {
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,cli.exe,"asset")
    append(&command,..args)
    state,stdout,stderr,error:=subprocess.exec({command=command[:]},context.temp_allocator)
    if error!=nil {
        testing.expectf(cli.t,false,"could not run %s: %v",cli.exe,error)
        return {code=-1}
    }
    return {state.exit_code,string(stdout),string(stderr)}
}

@(private="file")
file :: proc(cli:^Cli,name:string) -> string {return fmt.tprintf("%s/%s",cli.folder,name)}

@(private="file")
expect_run :: proc(cli:^Cli,code:int,out:string,args:..string,loc:=#caller_location) -> Result {
    result:=run(cli,..args)
    if result.code!=code || out!="\x00" && result.out!=out {
        testing.expectf(cli.t,false,"mirai asset %v: exit %d\nstdout: %s\nstderr: %s\nexpected exit %d%s%s",args,result.code,result.out,result.err,code,out!="\x00"?" and stdout: ":"",out!="\x00"?out:"",loc=loc)
    }
    return result
}

@(private="file") ANY :: "\x00"

@(private="file")
same_bytes :: proc(cli:^Cli,a,b:string,loc:=#caller_location) {
    first,_:=serial.file_read(a,context.temp_allocator)
    second,_:=serial.file_read(b,context.temp_allocator)
    testing.expectf(cli.t,len(first)>0 && mem.compare(first,second)==0,"%s and %s hold the same bytes",a,b,loc=loc)
}

@(private="file")
write_assets :: proc(cli:^Cli,types:^Types) {
    t:=cli.t
    vertices,indices:=test_grid(4);defer delete(vertices);defer delete(indices)
    slots:=[1]Material_Slot{{id=1,material={0x3a7,1}}}
    text_set(slots[0].label[:],"plant.gltf:Leaf")
    source:Import_Info
    text_set(source.source[:],"models/plant.gltf")
    text_set(source.importer[:],"gltf")
    testing.expect_value(t,mesh_save(file(cli,"plant.mesh"),types,{id={0x3e5,1},geometry=test_geometry(vertices,indices),slots=slots[:],source=&source}),Error.None)

    pixels:=make([]u8,64+16+4);defer delete(pixels)
    for &b,i in pixels {b=u8(i)}
    testing.expect_value(t,texture_save(file(cli,"leaf.tex"),types,{id={0x7e8,1},width=4,height=4,format=.RGBA8,flags={.Srgb},mips={pixels[:64],pixels[64:80],pixels[80:]}}),Error.None)

    info:=MATERIAL_DEFAULTS
    info.maps.base_color.texture={0x7e8,1}
    info.roughness=0.5
    testing.expect_value(t,material_save(file(cli,"leaf.mat"),types,{id={0x3a7,1},info=info}),Error.None)

    scene:Scene;scene_init(&scene,types,{0x5ce,1})
    scene_entity_add(&scene,0x10,0,"Room")
    scene_entity_add(&scene,0x20,0x10,"Lamp")
    scene_entity_add(&scene,0x30,0x10,"Plant")
    for id,i in ([]base.Entity_Id{0x10,0x20,0x30}) {
        value:=Test_Transform{{f32(i),0,0},1,{1,1,1}}
        scene_set(&scene,id,"Transform",&value)
    }
    light:=Test_Light{{1,1,1},3,10}
    scene_set(&scene,0x20,"Light",&light)
    mesh:=Test_Mesh{mesh={0xdead,1},material={0x3a7,1}}
    scene_set(&scene,0x30,"Mesh",&mesh)
    testing.expect_value(t,scene_save(&scene,file(cli,"level.scene")),Error.None)
    scene_destroy(&scene)

    // A kind the engine knows nothing about: only its tables say what it is.
    quest:Document;document_init(&quest,KIND_QUEST,{0x9e5,1})
    quest_info:=Quest_Info{state=.Open,giver={0x3a7,1}}
    text_set(quest_info.title[:],"Water the plant")
    document_put_row(&quest,types,"quest",&quest_info)
    steps:=[2]Quest_Step{{10,false,{1,2,3}},{25,true,{4,5,6}}}
    document_put(&quest,types,"steps",steps[:])
    testing.expect_value(t,document_save(&quest,file(cli,"water.quest")),Error.None)
    document_destroy(&quest)
}

@(test)
cli_reads_and_edits_assets_of_every_kind :: proc(t:^testing.T) {
    root,has_root:=os.lookup_env("MIRAI_ROOT",context.temp_allocator)
    if !has_root {
        log.warn("MIRAI_ROOT is not set: the mirai asset command was not run. Use `mirai test asset`.")
        return
    }
    compiler,has_compiler:=os.lookup_env("MIRAI_ODIN",context.temp_allocator)
    if !has_compiler || compiler=="" {compiler="odin"}
    cli:=Cli{t=t,folder=base.test_folder(t,"cli")}
    cli.exe=fmt.tprintf("%s/bin/tests/mirai-asset-cli%s",root,EXE)
    os.make_directory_all(fmt.tprintf("%s/bin/tests",root))
    {
        state,stdout,stderr,error:=subprocess.exec({command={compiler,"build",fmt.tprintf("%s/tools/mirai",root),fmt.tprintf("-collection:mirai=%s",root),"-ignore-unknown-attributes","-o:minimal",fmt.tprintf("-out:%s",cli.exe)}},context.temp_allocator)
        if !testing.expectf(t,error==nil && state.exit_code==0,"the tool does not build: %v\n%s%s",error,string(stdout),string(stderr)) {return}
    }
    types:Types;types_init(&types);defer types_destroy(&types)
    write_assets(&cli,&types)
    names:=[5]string{"plant.mesh","leaf.tex","leaf.mat","level.scene","water.quest"}

    // info
    info:=expect_run(&cli,0,ANY,"info",file(&cli,"plant.mesh"))
    for expected in ([]string{"kind: MESH (mesh)\n",fmt.tprintf("kind_version: %d\n",MESH_VERSION),"id: 00000000000003e50000000000000001\n","flags: Cooked\n"," ok\n","dependencies: 1\n  00000000000003a70000000000000001\n",fmt.tprintf("  pages rows 1 Bulk\n    (row): Mesh_Page Struct, %d bytes\n",size_of(Mesh_Page)),fmt.tprintf("  mesh rows 1 Single\n    (row): Mesh_Info Struct, %d bytes\n",size_of(Mesh_Info)),"  BULK "}) {
        testing.expectf(t,strings.contains(info.out,expected),"info prints %q in\n%s",expected,info.out)
    }
    quest_info:=expect_run(&cli,0,ANY,"info",file(&cli,"water.quest"))
    testing.expect(t,strings.contains(quest_info.out,"kind: QUST\n") && strings.contains(quest_info.out,"  steps rows 2\n    (row): Quest_Step Struct, 16 bytes\n"),quest_info.out)

    // ls and deps: the scene names a mesh that no file is.
    LISTING :: "00000000000003a70000000000000001 MAT  %d 1 leaf.mat\n00000000000007e80000000000000001 TEX  %d 0 leaf.tex\n00000000000005ce0000000000000001 SCEN %d 2 level.scene\n00000000000003e50000000000000001 MESH %d 1 plant.mesh\n00000000000009e50000000000000001 QUST %d 1 water.quest\n"
    sizes:[5]i64
    for name,at in ([]string{"leaf.mat","leaf.tex","level.scene","plant.mesh","water.quest"}) {
        stat,_:=os.stat(file(&cli,name),context.temp_allocator)
        sizes[at]=stat.size
    }
    listing:=fmt.tprintf(LISTING,sizes[0],sizes[1],sizes[2],sizes[3],sizes[4])
    expect_run(&cli,1,fmt.tprintf("%s! missing 000000000000dead0000000000000001 level.scene\n",listing),"ls",cli.folder)
    expect_run(&cli,0,"00000000000007e80000000000000001\n","deps",file(&cli,"leaf.mat"))
    expect_run(&cli,0,"00000000000007e80000000000000001 leaf.tex\n","deps",file(&cli,"leaf.mat"),"--root",cli.folder)
    expect_run(&cli,1,"00000000000003a70000000000000001 leaf.mat\n000000000000dead0000000000000001 MISSING\n","deps",file(&cli,"level.scene"),"--root",cli.folder)
    expect_run(&cli,0,"00000000000003a70000000000000001 leaf.mat\n00000000000007e80000000000000001 leaf.tex\n","deps",file(&cli,"level.scene"),"--root",cli.folder,"--all")
    expect_run(&cli,0,"00000000000005ce0000000000000001 level.scene\n00000000000003e50000000000000001 plant.mesh\n00000000000009e50000000000000001 water.quest\n","deps",file(&cli,"leaf.mat"),"--root",cli.folder,"--users")

    // get
    expect_run(&cli,0,"16\n","get",file(&cli,"plant.mesh"),"mesh.vertex_count")
    expect_run(&cli,0,"\"plant.gltf:Leaf\"\n","get",file(&cli,"plant.mesh"),"slots[0].label")
    expect_run(&cli,0,"8\n","get",file(&cli,"plant.mesh"),"levels[0].triangle_count")
    expect_run(&cli,0,"false\n","get",file(&cli,"plant.mesh"),"mesh.flags.Has_Colors")
    expect_run(&cli,0,"\"Lamp\"\n","get",file(&cli,"level.scene"),"entities[@0x20].name")
    expect_run(&cli,0,"3\n","get",file(&cli,"level.scene"),"Light[@0x20].value.intensity")
    expect_run(&cli,0,"{\"id\": \"0x0000000000000030\", \"parent\": \"0x0000000000000010\", \"order\": 1, \"name\": \"Plant\"}\n","get",file(&cli,"level.scene"),"entities[2]")
    expect_run(&cli,0,"[\n  {\"entity\": 1, \"value\": {\"color\": [1, 1, 1], \"intensity\": 3, \"range\": 10}}\n]\n","get",file(&cli,"level.scene"),"Light")
    expect_run(&cli,0,"{\n  \"reward\": 25,\n  \"optional\": true,\n  \"position\": [4, 5, 6]\n}\n","get",file(&cli,"water.quest"),"steps[1]")
    expect_run(&cli,0,"\"Open\"\n","get",file(&cli,"water.quest"),"quest.state")
    wrong:=expect_run(&cli,1,"","get",file(&cli,"level.scene"),"Light[@0x20].value.brightness")
    testing.expect_value(t,wrong.err,fmt.tprintf("mirai asset get: %s: Light[@0x20].value.brightness: the type has no such field (column 20)\n",file(&cli,"level.scene")))
    wrong=expect_run(&cli,1,"","get",file(&cli,"level.scene"),"Light[@0x10].value")
    testing.expect(t,strings.contains(wrong.err,"no row has that key (column 8)"),wrong.err)
    wrong=expect_run(&cli,1,"","get",file(&cli,"missing.scene"),"entities")
    testing.expect(t,strings.contains(wrong.err,"missing.scene: does not exist"),wrong.err)

    // set: several values at once, typed as a shell gives them, and nothing on a mistake.
    copy_path:=file(&cli,"level-copy.scene")
    original,_:=serial.file_read(file(&cli,"level.scene"),context.temp_allocator)
    serial.file_write_atomic(copy_path,original)
    expect_run(&cli,0,"","set",copy_path,"Light[@0x20].value.intensity=7.5","entities[@0x20].name=Big \"lamp\"","Mesh[@0x30].value.mesh=00000000000003e50000000000000001","Transform[@0x30].value={\"position\": [9, 8, 7]}","entities[@0x30].parent=0x20")
    expect_run(&cli,0,"7.5\n","get",copy_path,"Light[@0x20].value.intensity")
    expect_run(&cli,0,"\"Big \\\"lamp\\\"\"\n","get",copy_path,"entities[@0x20].name")
    expect_run(&cli,0,"{\"entity\": 2, \"value\": {\"position\": [9, 8, 7], \"rotation\": [0, 0, 0, 1], \"scale\": [1, 1, 1]}}\n","get",copy_path,"Transform[@0x30]")
    expect_run(&cli,0,"00000000000003a70000000000000001\n00000000000003e50000000000000001\n","deps",copy_path)
    before,_:=serial.file_read(copy_path,context.temp_allocator)
    wrong=expect_run(&cli,1,"","set",copy_path,"Light[@0x20].value.range=1","Light[@0x20].value.intensity=bright")
    testing.expect(t,strings.contains(wrong.err,"Light[@0x20].value.intensity: expected a number in 'bright' (column 1)"),wrong.err)
    wrong=expect_run(&cli,1,"","set",copy_path,"entities[@0x20]=1")
    testing.expect(t,strings.contains(wrong.err,"set changes values inside a column"),wrong.err)
    wrong=expect_run(&cli,1,"","set",copy_path,"entities[@0x20].order=-1")
    testing.expect(t,strings.contains(wrong.err,"number out of range"),wrong.err)
    after,_:=serial.file_read(copy_path,context.temp_allocator)
    testing.expect(t,mem.compare(before,after)==0,"a failed set leaves the file as it was")
    expect_run(&cli,0,"","set",file(&cli,"leaf.mat"),"material.alpha_mode=Blend","material.maps.normal.uv_set=1")
    expect_run(&cli,0,"\"Blend\"\n","get",file(&cli,"leaf.mat"),"material.alpha_mode")
    expect_run(&cli,0,"","set",file(&cli,"plant.mesh"),"mesh.flags.Closed=true")
    expect_run(&cli,0,"[\"Closed\"]\n","get",file(&cli,"plant.mesh"),"mesh.flags")
    expect_run(&cli,0,"","set",file(&cli,"water.quest"),"quest.state=Done","steps[0].reward=11","quest.title=Water it")
    expect_run(&cli,0,"{\n  \"title\": \"Water it\",\n  \"state\": \"Done\",\n  \"giver\": \"00000000000003a70000000000000001\"\n}\n","get",file(&cli,"water.quest"),"quest")

    // diff: by entity and field, whatever the order of the rows.
    expect_run(&cli,0,"","diff",file(&cli,"level.scene"),file(&cli,"level.scene"))
    DIFF :: "~ entities[@0x0000000000000020].name: \"Lamp\" -> \"Big \\\"lamp\\\"\"\n~ entities[@0x0000000000000030].parent: \"0x0000000000000010\" -> \"0x0000000000000020\"\n~ Transform[@0x0000000000000030].value.position[0]: 2 -> 9\n~ Transform[@0x0000000000000030].value.position[1]: 0 -> 8\n~ Transform[@0x0000000000000030].value.position[2]: 0 -> 7\n~ Light[@0x0000000000000020].value.intensity: 3 -> 7.5\n~ Mesh[@0x0000000000000030].value.mesh: \"000000000000dead0000000000000001\" -> \"00000000000003e50000000000000001\"\n"
    expect_run(&cli,1,DIFF,"diff",file(&cli,"level.scene"),copy_path)
    expect_run(&cli,2,"","diff",file(&cli,"level.scene"),file(&cli,"missing.scene"))

    // verify, and ls once the scene names a mesh that exists.
    serial.file_write_atomic(file(&cli,"level.scene"),after)
    os.remove(copy_path)
    verified:=make([dynamic]string,context.temp_allocator)
    append(&verified,"verify")
    expected:=strings.builder_make(context.temp_allocator)
    for name in names {
        append(&verified,file(&cli,name))
        fmt.sbprintf(&expected,"ok %s\n",file(&cli,name))
    }
    expect_run(&cli,0,strings.to_string(expected),..verified[:])
    listed:=expect_run(&cli,0,ANY,"ls",cli.folder)
    testing.expect(t,!strings.contains(listed.out,"!") && strings.count(listed.out,"\n")==5,listed.out)

    // unpack and pack: the same bytes back, for every kind.
    for name in names {
        folder:=file(&cli,fmt.tprintf("%s.unpacked",name))
        expect_run(&cli,0,"","unpack",file(&cli,name),folder)
        packed:=file(&cli,fmt.tprintf("%s.packed",name))
        expect_run(&cli,0,"","pack",folder,packed)
        same_bytes(&cli,file(&cli,name),packed)
        testing.expect(t,os.exists(fmt.tprintf("%s/asset.json",folder)))
        os.remove(packed)
    }
    testing.expect(t,os.exists(file(&cli,"plant.mesh.unpacked/pages.bin")) && os.exists(file(&cli,"plant.mesh.unpacked/page_data.bin")) && os.exists(file(&cli,"leaf.tex.unpacked/texels.bin")))
    // The text of an unpacked asset is the asset: edit it, pack it, read it.
    manifest:=file(&cli,"water.quest.unpacked/asset.json")
    text,_:=serial.file_read(manifest,context.temp_allocator)
    edited,replaced:=strings.replace(string(text),`"reward": 25`,`"reward": 250`,1,context.temp_allocator)
    testing.expect(t,replaced)
    serial.file_write_atomic(manifest,transmute([]u8)edited)
    expect_run(&cli,0,"","pack",file(&cli,"water.quest.unpacked"),file(&cli,"water.quest"))
    expect_run(&cli,0,"250\n","get",file(&cli,"water.quest"),"steps[1].reward")
    broken,_:=strings.replace(edited,`"reward": 250`,`"reword": 250`,1,context.temp_allocator)
    serial.file_write_atomic(manifest,transmute([]u8)broken)
    wrong=expect_run(&cli,1,"","pack",file(&cli,"water.quest.unpacked"),file(&cli,"water.quest"))
    line,column:=serial.text_position(broken,strings.index(broken,`"reword"`))
    testing.expect(t,strings.has_prefix(wrong.err,"mirai asset pack: ") && strings.has_suffix(wrong.err,fmt.tprintf("asset.json:%d:%d: unknown field\n",line,column)),wrong.err)
    expect_run(&cli,0,"250\n","get",file(&cli,"water.quest"),"steps[1].reward")
    // A bulk file of another size is refused.
    serial.file_write_atomic(file(&cli,"plant.mesh.unpacked/page_data.bin"),original[:8])
    wrong=expect_run(&cli,1,"","pack",file(&cli,"plant.mesh.unpacked"),file(&cli,"plant-bad.mesh"))
    testing.expect(t,strings.contains(wrong.err,"a bulk column needs its file") && !os.exists(file(&cli,"plant-bad.mesh")),wrong.err)

    // dump: JSON, with the types when asked.
    dump:=expect_run(&cli,0,ANY,"dump",file(&cli,"level.scene"))
    testing.expect(t,strings.has_prefix(dump.out,"{\n  \"mirai_asset\": 1,\n  \"kind\": \"SCEN\",") && strings.contains(dump.out,`{"id": "0x0000000000000020", "parent": "0x0000000000000010", "order": 0, "name": "Big \"lamp\""}`) && !strings.contains(dump.out,`"schema"`),dump.out)
    reader:serial.Text_Reader
    serial.text_reader_init(&reader,dump.out,context.temp_allocator)
    testing.expect(t,serial.text_skip(&reader) && serial.text_end(&reader),"dump prints one JSON value")
    with_schema:=expect_run(&cli,0,ANY,"dump",file(&cli,"plant.mesh"),"--schema")
    testing.expect(t,strings.contains(with_schema.out,`{"kind": "Struct", "name": "Mesh_Page", "size": 44, "align": 4, "fields": [`) && !strings.contains(with_schema.out,`"data": [0,`),"the schema is printed and bulk rows are not")

    // dump --textconv, what git diffs: rows by the key of what they refer to, and a file that does not read in one line.
    for_diff:=expect_run(&cli,0,ANY,"dump",file(&cli,"level.scene"),"--textconv")
    testing.expect(t,strings.contains(for_diff.out,`{"entity": "0x0000000000000020", "value": {"color": `),for_diff.out)
    serial.file_write_atomic(file(&cli,"not.scene"),transmute([]u8)string("not an asset"))
    unread:=expect_run(&cli,0,ANY,"dump",file(&cli,"not.scene"),"--textconv")
    testing.expect(t,unread.out!="" && strings.count(unread.out,"\n")==1,unread.out)

    // merge: rows of one table that name rows of another by what they hold. Ours removed a bone
    // and theirs hung a socket from it: the result breaks the rules of a skeleton and is not written.
    {
        bones:=[2]Skeleton_Bone{{parent=-1,rotation=1,scale={1,1,1}},{parent=0,rotation=1,scale={1,1,1}}}
        text_set(bones[0].name[:],"root");text_set(bones[0].path[:],"root");bones[0].target=base.name_hash("root")
        text_set(bones[1].name[:],"arm");text_set(bones[1].path[:],"root/arm");bones[1].target=base.name_hash("root/arm")
        socket:=Skeleton_Socket{bone=bones[1].path,offset={rotation=1,scale={1,1,1}}};text_set(socket.name[:],"hand")
        testing.expect_value(t,skeleton_save(file(&cli,"base.skeleton"),&types,{id={0x5e1,1},bones=bones[:]}),Error.None)
        testing.expect_value(t,skeleton_save(file(&cli,"ours.skeleton"),&types,{id={0x5e1,1},bones=bones[:1]}),Error.None)
        testing.expect_value(t,skeleton_save(file(&cli,"theirs.skeleton"),&types,{id={0x5e1,1},bones=bones[:],sockets={socket}}),Error.None)
        testing.expect_value(t,skeleton_save(file(&cli,"kept.skeleton"),&types,{id={0x5e1,1},bones=bones[:1]}),Error.None)
        refused:=expect_run(&cli,2,"","merge",file(&cli,"base.skeleton"),file(&cli,"ours.skeleton"),file(&cli,"theirs.skeleton"))
        testing.expect(t,strings.contains(refused.err,"the result is not valid: skeleton"),refused.err)
        same_bytes(&cli,file(&cli,"ours.skeleton"),file(&cli,"kept.skeleton"))
        // What each side changed in a table of its own goes together.
        testing.expect_value(t,skeleton_save(file(&cli,"ours.skeleton"),&types,{id={0x5e1,1},bones=bones[:]}),Error.None)
        expect_run(&cli,0,"","set",file(&cli,"ours.skeleton"),"bones[1].translation[1]=2")
        expect_run(&cli,0,"","merge",file(&cli,"base.skeleton"),file(&cli,"ours.skeleton"),file(&cli,"theirs.skeleton"))
        expect_run(&cli,0,"2\n","get",file(&cli,"ours.skeleton"),"bones[1].translation[1]")
        expect_run(&cli,0,"\"hand\"\n","get",file(&cli,"ours.skeleton"),"sockets[0].name")
    }

    // verify finds what is wrong with a file.
    bytes,_:=serial.file_read(file(&cli,"plant.mesh"),context.temp_allocator)
    bytes[len(bytes)-3]~=0x40
    serial.file_write_atomic(file(&cli,"flipped.mesh"),bytes)
    serial.file_write_atomic(file(&cli,"cut.mesh"),bytes[:len(bytes)/2])
    serial.file_write_atomic(file(&cli,"text.mesh"),transmute([]u8)string("just some text, long enough to hold a header of eighty bytes or more, which an asset has"))
    expect_run(&cli,1,fmt.tprintf("FAIL %s: the content does not match its hash\nok %s\nFAIL %s: the file is truncated\nFAIL %s: not a Mirai asset\n",file(&cli,"flipped.mesh"),file(&cli,"leaf.tex"),file(&cli,"cut.mesh"),file(&cli,"text.mesh")),
        "verify",file(&cli,"flipped.mesh"),file(&cli,"leaf.tex"),file(&cli,"cut.mesh"),file(&cli,"text.mesh"))
    // A mesh whose tables are valid one by one and wrong together.
    expect_run(&cli,0,"","set",file(&cli,"plant.mesh"),"levels[0].triangle_count=99")
    expect_run(&cli,1,fmt.tprintf("FAIL %s: mesh: counts or ranges outside their tables\n",file(&cli,"plant.mesh")),"verify",file(&cli,"plant.mesh"))
    // A number that names no member of its enum, in any kind.
    expect_run(&cli,0,"","set",file(&cli,"water.quest"),"quest.state=7")
    expect_run(&cli,1,fmt.tprintf("FAIL %s: a value outside its schema: quest[0].state is not a member of its enum\n",file(&cli,"water.quest")),"verify",file(&cli,"water.quest"))
    // Animations and sounds follow the rules of their kind.
    keys:=[2]anim.Keyframe{{time=0},{time=1,value={0,1,0,0}}}
    clips:=[1]Animation_Clip_Desc{{name="rise",tracks={{target="lift",property=.Position,keys=keys[:]}}}}
    testing.expect_value(t,animation_save(file(&cli,"rise.anim"),&types,{id={0xa11,1},clips=clips[:]}),Error.None)
    lossless:=[8]u8{'M','L','P','C',0,0,0,0}
    testing.expect_value(t,sound_save(file(&cli,"tick.sound"),&types,{id={0x50d,1},channels=2,sample_rate=48000,frames=4,lossless=lossless[:]}),Error.None)
    expect_run(&cli,0,fmt.tprintf("ok %s\nok %s\n",file(&cli,"rise.anim"),file(&cli,"tick.sound")),"verify",file(&cli,"rise.anim"),file(&cli,"tick.sound"))
    expect_run(&cli,0,"","set",file(&cli,"rise.anim"),"tracks[0].key_count=9")
    expect_run(&cli,0,"","set",file(&cli,"tick.sound"),"sound.channels=7")
    expect_run(&cli,1,fmt.tprintf("FAIL %s: animation: an invalid range, key or name\nFAIL %s: sound: inconsistent channels, sample rate, lossless data or file\n",file(&cli,"rise.anim"),file(&cli,"tick.sound")),
        "verify",file(&cli,"rise.anim"),file(&cli,"tick.sound"))
    // And so do fonts, texts and prompts.
    testing.expect_value(t,font_save(file(&cli,"face.font"),&types,{id={0xf07,1},file=#load("../assets/fixtures/cff.otf")}),Error.None)
    language:=[1]String_Language{};text_set(language[0].code[:],"es")
    key:=[1]String_Key{};text_set(key[0].name[:],"menu.play")
    entry:=[1]String_Entry{{0,0,0,5}}
    testing.expect_value(t,strings_save(file(&cli,"menu.strings"),&types,{id={0x57e,1},languages=language[:],keys=key[:],entries=entry[:],text=transmute([]u8)string("Jugar")}),Error.None)
    prompt:=[1]Prompt_Image{{family=1,input=5,texture={0x7e8,1},uv={0,0,1,1},aspect=1}}
    testing.expect_value(t,prompts_save(file(&cli,"pad.prompts"),&types,{id={0x9a5,1},images=prompt[:]}),Error.None)
    expect_run(&cli,0,fmt.tprintf("ok %s\nok %s\nok %s\n",file(&cli,"face.font"),file(&cli,"menu.strings"),file(&cli,"pad.prompts")),"verify",file(&cli,"face.font"),file(&cli,"menu.strings"),file(&cli,"pad.prompts"))
    expect_run(&cli,0,"","set",file(&cli,"face.font"),"font.outlines=TrueType")
    expect_run(&cli,0,"","set",file(&cli,"menu.strings"),"entries[0].length=6")
    expect_run(&cli,0,"","set",file(&cli,"pad.prompts"),"prompts[0].uv.x=0.5")
    expect_run(&cli,1,fmt.tprintf("FAIL %s: font: the file is not a TrueType or OpenType font with the outlines it declares\nFAIL %s: strings: an empty or repeated language or key, or an entry out of order, repeated, or outside the text or the UTF-8\nFAIL %s: prompts: a family or an entry that does not exist, a key too many or too few, a part outside its texture, or a repeated entry\n",file(&cli,"face.font"),file(&cli,"menu.strings"),file(&cli,"pad.prompts")),
        "verify",file(&cli,"face.font"),file(&cli,"menu.strings"),file(&cli,"pad.prompts"))

    // Misuse.
    testing.expect_value(t,run(&cli).code,2)
    testing.expect_value(t,run(&cli,"explode").code,2)
    usage:=run(&cli,"get",file(&cli,"leaf.tex"))
    testing.expect(t,usage.code==2 && usage.err=="Usage: mirai asset get <file> <path>\n",usage.err)
    free_all(context.temp_allocator)
}

// The commands themselves, as processes, on files that are cut or changed:
// each one answers with 0, 1 or 2 and never ends any other way. The memory of
// what they call is checked in fuzz_test.odin.
@(test)
cli_commands_answer_for_damaged_files :: proc(t:^testing.T) {
    root,has_root:=os.lookup_env("MIRAI_ROOT",context.temp_allocator)
    if !has_root {
        log.warn("MIRAI_ROOT is not set: the mirai asset command was not run. Use `mirai test asset`.")
        return
    }
    compiler,has_compiler:=os.lookup_env("MIRAI_ODIN",context.temp_allocator)
    if !has_compiler || compiler=="" {compiler="odin"}
    cli:=Cli{t=t,folder=base.test_folder(t,"cli-damaged")}
    cli.exe=fmt.tprintf("%s/bin/tests/mirai-asset-damaged%s",root,EXE)
    os.make_directory_all(fmt.tprintf("%s/bin/tests",root))
    {
        state,stdout,stderr,error:=subprocess.exec({command={compiler,"build",fmt.tprintf("%s/tools/mirai",root),fmt.tprintf("-collection:mirai=%s",root),"-ignore-unknown-attributes","-o:minimal",fmt.tprintf("-out:%s",cli.exe)}},context.temp_allocator)
        if !testing.expectf(t,error==nil && state.exit_code==0,"the tool does not build: %v\n%s%s",error,string(stdout),string(stderr)) {return}
    }
    answered :: proc(cli:^Cli,args:..string) -> int {
        result:=run(cli,..args)
        if result.code<0 || result.code>2 {testing.expectf(cli.t,false,"mirai asset %v ended with %d\n%s",args,result.code,result.err)}
        return result.code
    }
    runs,refused:=0,0
    state:=u64(0x13198a2e03707344)
    // A sound is no file of the demo: its import builds it.
    {
        types:Types;types_init(&types);defer types_destroy(&types)
        lossless:=[8]u8{'M','L','P','C',0,0,0,0}
        testing.expect_value(t,sound_save(file(&cli,"tick.sound"),&types,{id={0x50d,2},channels=2,sample_rate=48000,frames=4,lossless=lossless[:]}),Error.None)
    }
    for name in ([]string{"showcase/hud.ui","showcase/lift.anim","tick.sound","gallery/plant.gltf/Leaves.mat"}) {
        seed:=file(&cli,name) if name=="tick.sound" else fmt.tprintf("%s/demo/assets/%s",root,name)
        good,read_error:=serial.file_read(seed,context.temp_allocator)
        if !testing.expectf(t,read_error==.None,"%s cannot be read",seed) {continue}
        // A value set would change: the first field of the first row of the first table.
        assignment:=""
        {
            doc:Document
            if !testing.expect_value(t,document_read(&doc,good),Error.None) {continue}
            if len(doc.tables)>0 && len(doc.tables[0].columns)>0 && doc.tables[0].columns[0].type!=serial.TYPE_NONE {
                if fields:=serial.schema_fields(&doc.schema,doc.tables[0].columns[0].type);len(fields)>0 {
                    assignment=fmt.tprintf("%s[0].%s=0",doc.tables[0].name,fields[0].name)
                }
            }
            document_destroy(&doc)
        }
        work:=make([]u8,len(good),context.temp_allocator)
        for variant in 0..<12 {
            damaged:=good
            if variant<6 {
                damaged=good[:len(good)*(variant*2+1)/12]
            } else {
                copy(work,good)
                for _ in 0..<variant-4 {
                    state=state*6364136223846793005+1442695040888963407
                    work[int((state>>33)%u64(min(len(work),variant%2==0?len(work):1024)))]=u8(state>>24)
                }
                damaged=work
            }
            subject:=file(&cli,"damaged.bin")
            if !testing.expect_value(t,serial.file_write_atomic(subject,damaged),serial.File_Error.None) {continue}
            codes:=[7]int{
                answered(&cli,"verify",subject),answered(&cli,"info",subject),answered(&cli,"dump",subject,"--schema"),
                answered(&cli,"diff",seed,subject),answered(&cli,"unpack",subject,file(&cli,"unpacked")),
                answered(&cli,"pack",file(&cli,"unpacked"),file(&cli,"packed.bin")),
                assignment!=""?answered(&cli,"set",subject,assignment):1,
            }
            runs+=len(codes)
            for code in codes {refused+=code!=0?1:0}
        }
        // pack, from text that is cut or changed.
        folder:=file(&cli,"text")
        if !testing.expect_value(t,answered(&cli,"unpack",seed,folder),0) {continue}
        manifest:=fmt.tprintf("%s/asset.json",folder)
        text,_:=serial.file_read(manifest,context.temp_allocator)
        testing.expect_value(t,answered(&cli,"pack",folder,file(&cli,"again.bin")),0)
        for variant in 0..<6 {
            changed:=make([]u8,len(text),context.temp_allocator)
            copy(changed,text)
            if variant<3 {
                changed=changed[:len(text)*(variant+1)/4]
            } else {
                for _ in 0..<variant {
                    state=state*6364136223846793005+1442695040888963407
                    marks:="{}[]\":,0"
                    changed[int((state>>33)%u64(len(changed)))]=marks[int(state>>20)%len(marks)]
                }
            }
            testing.expect_value(t,serial.file_write_atomic(manifest,changed),serial.File_Error.None)
            refused+=answered(&cli,"pack",folder,file(&cli,"again.bin"))!=0?1:0
            runs+=1
        }

    }
    testing.expectf(t,runs>300 && refused>100,"%d commands ran and %d refused their file",runs,refused)
}
