package sources

import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:cook/prefab"
import importer "mirai:cook/import"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/subprocess"
import "mirai:store"

// End to end: imports the fixtures with the command of `mirai import`, as the
// import program of the engine runs it, and checks what it writes with
// `mirai asset verify` of the mirai tool built from this tree. It needs
// MIRAI_ROOT, which `mirai test` sets, and the Odin compiler it used.

@(private="file") EXE :: ".exe" when ODIN_OS==.Windows else ""

@(private="file")
Result :: struct {code:int,out,err:string}

// mirai import with args, with --store store_root when it has any: the
// store of a test is never the machine's.
@(private="file")
import_run :: proc(store_root:string,args:..string) -> Result {
    output,errors:=strings.builder_make(context.temp_allocator),strings.builder_make(context.temp_allocator)
    all:=make([dynamic]string,context.temp_allocator)
    append(&all,..args)
    if len(args)>0 {append(&all,"--store",store_root)}
    code:=command(all[:],strings.to_writer(&output),strings.to_writer(&errors),test_library)
    return {code,strings.to_string(output),strings.to_string(errors)}
}

@(private="file")
run :: proc(t:^testing.T,exe:string,args:..string) -> Result {
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,exe)
    append(&command,..args)
    state,stdout,stderr,error:=subprocess.exec({command=command[:]},context.temp_allocator)
    if error!=nil {
        testing.expectf(t,false,"could not run %s: %v",exe,error)
        return {code=-1}
    }
    return {state.exit_code,string(stdout),string(stderr)}
}

// The paths printed at the end of each line of a report.
@(private="file")
reported_paths :: proc(out:string) -> []string {
    paths:=make([dynamic]string,context.temp_allocator)
    for line in strings.split_lines(out,context.temp_allocator) {
        fields:=strings.fields(line,context.temp_allocator)
        if len(fields)>=4 && len(fields[0])==32 {append(&paths,strings.join(fields[3:]," ",context.temp_allocator))}
    }
    return paths[:]
}

// Opens each object of the store at root a report names ("object <address>"),
// as the engine loads it: how many open.
objects_open :: proc(t:^testing.T,root:string,paths:[]string,loc:=#caller_location) -> (opened:int) {
    s:=test_store(t,root,loc)
    if s==nil {return}
    defer store.close(s)
    for path in paths {
        if !strings.has_prefix(path,"object ") {continue}
        address,ok:=store.parse_hex(path[len("object "):])
        a:asset.Asset
        if testing.expectf(t,ok && asset.asset_open_object(&a,s,address,context.temp_allocator)==.None,"%s opens",path,loc=loc) {
            asset.asset_close(&a)
            opened+=1
        }
    }
    return
}

// The lines of a report that name an asset: id, kind, bytes and path.
reported_assets :: proc(out:string) -> []string {
    lines:=make([dynamic]string,context.temp_allocator)
    for line in strings.split_lines(out,context.temp_allocator) {
        fields:=strings.fields(line,context.temp_allocator)
        if len(fields)>=4 && len(fields[0])==32 {append(&lines,line)}
    }
    return lines[:]
}

@(test)
mirai_import_writes_assets_that_mirai_asset_verifies :: proc(t:^testing.T) {
    root,has_root:=os.lookup_env("MIRAI_ROOT",context.temp_allocator)
    if !has_root {
        log.warn("MIRAI_ROOT is not set: the mirai import command was not run. Use `mirai test cook/import`.")
        return
    }
    compiler,has_compiler:=os.lookup_env("MIRAI_ODIN",context.temp_allocator)
    if !has_compiler || compiler=="" {compiler="odin"}
    root_folder,folder:=test_project(t,"cli")
    if folder=="" {return}
    context.user_ptr=prefab.import_world(t)
    exe:=fmt.tprintf("%s/bin/tests/mirai-import-cli%s",root,EXE)
    os.make_directory_all(fmt.tprintf("%s/bin/tests",root))
    {
        state,stdout,stderr,error:=subprocess.exec({command={compiler,"build",fmt.tprintf("%s/tools/mirai",root),fmt.tprintf("-collection:mirai=%s",root),"-ignore-unknown-attributes","-o:minimal",fmt.tprintf("-out:%s",exe)}},context.temp_allocator)
        if !testing.expectf(t,error==nil && state.exit_code==0,"the tool does not build: %v\n%s%s",error,string(stdout),string(stderr)) {return}
    }

    kept:=fmt.tprintf("%s/store",root_folder)
    // A model with a texture in the assets of a project: ingested (mesh, three materials, the
    // image of the leaves) and added to the project, with its documents and prefab beside it.
    plant:=copy_in(root_folder,DEMO,"gallery/plant.gltf","gallery/leaves_color.png")
    first:=import_run(kept,plant,"--uncompressed")
    testing.expectf(t,first.code==0 && first.err=="","import fails: %d\n%s%s",first.code,first.out,first.err)
    paths:=reported_paths(first.out)
    testing.expect_value(t,len(paths),6)
    testing.expect(t,strings.contains(first.out,"6 assets\n") && strings.contains(first.out,"\npackage ") && !strings.contains(first.out,"warning"),first.out)
    for kind in ([]string{"mesh ","material ","texture ","scene "}) {testing.expectf(t,strings.contains(first.out,kind),"the report names a %s",kind)}
    list,_,list_error:=asset.packages_load(root_folder,context.temp_allocator)
    testing.expect(t,list_error==.None && len(list.packages)==1 && list.packages[0].folder=="gallery","the project pins the package under the folder of the source")
    // The scene is checked against the game of a project, which this folder is not.
    verify:=make([dynamic]string,context.temp_allocator)
    append(&verify,"asset","verify")
    for path in paths {if !strings.has_suffix(path,".scene") && !strings.has_prefix(path,"object ") {append(&verify,path)}}
    checked:=run(t,exe,..verify[:])
    testing.expectf(t,checked.code==0,"asset verify fails: %s%s",checked.out,checked.err)
    objects_open(t,kept,paths)

    // Importing again keeps every id, and the mesh and the texture are not built again.
    again:=import_run(kept,plant,"--uncompressed")
    testing.expect(t,again.code==0 && strings.contains(again.out,"6 assets, 2 were already up to date") && slice.equal(reported_paths(again.out),paths),again.out)
    rebuilt:=import_run(kept,plant,"--uncompressed","--rebuild")
    testing.expect(t,rebuilt.code==0 && slice.equal(reported_assets(rebuilt.out),reported_assets(first.out)),"--rebuild builds everything again, to the same bytes")

    // An image on its own.
    bricks:=copy_in(root_folder,DEMO,"surfaces/bricks/bricks_color.png")
    texture:=import_run(kept,bricks,"--srgb")
    testing.expectf(t,texture.code==0 && strings.contains(texture.out,"texture"),"%d: %s%s",texture.code,texture.out,texture.err)
    testing.expect_value(t,objects_open(t,kept,reported_paths(texture.out)),1)
    current:=import_run(kept,bricks)
    testing.expectf(t,current.code==0 && strings.contains(current.out,"0 assets"),"a current source is not imported again: %s%s",current.out,current.err)

    // The package of a source keeps its settings: the options change them, and importing again uses them.
    copy:=copy_in(root_folder,DEMO,"gallery/vase.obj","gallery/vase.mtl","gallery/vase_color.png")
    turned:=import_run(kept,copy,"--front","x","--rebuild")
    testing.expectf(t,turned.code==0 && strings.contains(turned.out," triangles") && !strings.contains(turned.out,"hull"),"%d: %s%s",turned.code,turned.out,turned.err)
    stored,_,_:=importer.settings_load({store=test_store(t,kept)},copy)
    testing.expect_value(t,stored.front,importer.Front.X)
    ids :: proc(out:string) -> []string {
        found:=make([dynamic]string,context.temp_allocator)
        for line in reported_assets(out) {append(&found,line[:32])}
        return found[:]
    }
    repeated:=import_run(kept,copy,"--rebuild")
    testing.expect(t,repeated.code==0 && slice.equal(reported_paths(repeated.out),reported_paths(turned.out)),"importing again without options gives the same assets")
    bare:=import_run(kept,copy,"--front","negative_z","--lods","none")
    testing.expect(t,bare.code==0 && slice.equal(ids(bare.out),ids(turned.out)) && strings.contains(bare.out,"  3232 triangles"),bare.out)
    baked:=import_run(kept,copy,"--bake-scale")
    stored,_,_=importer.settings_load({store=test_store(t,kept)},copy)
    testing.expect(t,baked.code==0 && stored.bake_scale,"--bake-scale is a setting the package keeps")
    unbaked:=import_run(kept,copy,"--no-bake-scale")
    stored,_,_=importer.settings_load({store=test_store(t,kept)},copy)
    testing.expect(t,unbaked.code==0 && !stored.bake_scale && stored.lods==.None,"--no-bake-scale takes it away and keeps the others")

    // A source outside any project: ingested into the library alone.
    outside:=fmt.tprintf("%s/outside",root_folder)
    os.make_directory_all(outside)
    data,_:=os.read_entire_file(DEMO+"surfaces/bricks/bricks_color.png",context.temp_allocator)
    loose:=fmt.tprintf("%s/loose.png",outside)
    _=os.write_entire_file(loose,data)
    alone:=import_run(kept,loose)
    testing.expectf(t,alone.code==0 && strings.contains(alone.out,"texture") && strings.contains(alone.out,"package "),"%d: %s%s",alone.code,alone.out,alone.err)
    list,_,_=asset.packages_load(root_folder,context.temp_allocator)
    testing.expect_value(t,len(list.packages),3)
    // Added to a project when it is named, under the folder given.
    named:=import_run(kept,loose,"--project",root_folder,"--folder","loose")
    testing.expectf(t,named.code==0,"%d: %s%s",named.code,named.out,named.err)
    list,_,_=asset.packages_load(root_folder,context.temp_allocator)
    testing.expect(t,len(list.packages)==4 && list.packages[3].folder=="loose")

    // A refresh of the project: everything is here, nothing is built.
    refreshed:=import_run(kept,"--refresh",root_folder)
    testing.expectf(t,refreshed.code==0 && strings.contains(refreshed.out,"4 packages, 0 ingested"),"%d: %s%s",refreshed.code,refreshed.out,refreshed.err)

    // Misuse and failures.
    testing.expect_value(t,import_run(kept,copy,"--lods","some").code,2)
    testing.expect_value(t,import_run(kept,copy,"--front","up").code,2)
    testing.expect_value(t,import_run(kept,bricks,"--front","x").code,2)
    testing.expect_value(t,import_run(kept,bricks,"--bake-scale").code,2)
    testing.expect_value(t,import_run(kept).code,2)
    testing.expect_value(t,import_run(kept,copy,"--srgb").code,2)
    testing.expect_value(t,import_run(kept,copy,"--alpha-coverage","0.5").code,2)
    testing.expect_value(t,import_run(kept,bricks,"--alpha-coverage","1.5").code,2)
    testing.expect_value(t,import_run(kept,bricks,"--rdo-lambda","101").code,2)
    testing.expect_value(t,import_run(kept,bricks,"--rdo-lambda","-1").code,2)
    testing.expect_value(t,import_run(kept,copy,"--nope").code,2)
    testing.expect_value(t,import_run(kept,copy,"--out",folder).code,2)
    testing.expect_value(t,import_run(kept,loose,"--folder","loose").code,2)
    testing.expect_value(t,import_run(kept,"--refresh",root_folder,copy).code,2)
    missing:=import_run(kept,fmt.tprintf("%s/missing.obj",folder))
    testing.expect(t,missing.code==1 && strings.contains(missing.err,"mirai import:") && strings.contains(missing.err,"missing.obj"),missing.err)
    write_text(folder,"broken.obj","v 0 0 0\nf 1 2 3\n")
    broken:=import_run(kept,fmt.tprintf("%s/broken.obj",folder))
    testing.expect(t,broken.code==1 && strings.contains(broken.err,"outside"),broken.err)
}

// mirai import takes what the editor's import left of the same source: an
// image the editor ingested with Fast textures, with no Final in the store,
// is current for the command, which builds nothing again. Final
// is what --final asks for, and builds them again.
@(test)
mirai_import_takes_what_the_import_of_the_editor_left :: proc(t:^testing.T) {
    root_folder,folder:=test_project(t,"cli-fast")
    if folder=="" {return}
    context.user_ptr=prefab.import_world(t)
    kept:=fmt.tprintf("%s/store",root_folder)
    s:=test_store(t,kept)
    if s==nil {return}
    bricks:=copy_in(root_folder,DEMO,"surfaces/bricks/bricks_color.png")
    // As the editor imports it: Fast, with the use it gives an image by its name.
    settings:=importer.Import_Settings{image=image_use(bricks)}
    report,_,error:=project_ingest(root_folder,bricks,"",{store=s,root=root_folder,plugins=test_library,fast_textures=true},&settings,context.temp_allocator)
    if !testing.expectf(t,error.code==.None && !report.final,"%s",error.message) {return}
    Case :: struct {source:string,args:[]string,built:bool}
    cases:=[]Case{
        {bricks,{},false},
        {bricks,{"--final"},true},
    }
    for c in cases {
        args:=make([dynamic]string,context.temp_allocator)
        append(&args,c.source)
        append(&args,..c.args)
        done:=import_run(kept,..args[:])
        testing.expectf(t,done.code==0 && (len(reported_paths(done.out))>0)==c.built,"%s %v: %s%s",c.source,c.args,done.out,done.err)
    }
}
