package sources

import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import importer "mirai:cook/import"
import "mirai:std/base"
import "mirai:std/subprocess"

// End to end: imports the fixtures with the command of `mirai import`, as the
// import program of the engine runs it, and checks what it writes with
// `mirai asset verify` of the mirai tool built from this tree. It needs
// MIRAI_ROOT, which `mirai test` sets, and the Odin compiler it used.

@(private="file") EXE :: ".exe" when ODIN_OS==.Windows else ""

@(private="file")
Result :: struct {code:int,out,err:string}

@(private="file")
import_run :: proc(args:..string) -> Result {
    output,errors:=strings.builder_make(context.temp_allocator),strings.builder_make(context.temp_allocator)
    code:=command(args,strings.to_writer(&output),strings.to_writer(&errors))
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
    exe:=fmt.tprintf("%s/bin/tests/mirai-import-cli%s",root,EXE)
    os.make_directory_all(fmt.tprintf("%s/bin/tests",root))
    {
        state,stdout,stderr,error:=subprocess.exec({command={compiler,"build",fmt.tprintf("%s/tools/mirai",root),fmt.tprintf("-collection:mirai=%s",root),"-ignore-unknown-attributes","-o:minimal",fmt.tprintf("-out:%s",exe)}},context.temp_allocator)
        if !testing.expectf(t,error==nil && state.exit_code==0,"the tool does not build: %v\n%s%s",error,string(stdout),string(stderr)) {return}
    }

    // A model with a texture in the assets of a project: mesh, three materials, the image of the leaves and the prefab.
    plant:=copy_in(root_folder,DEMO,"gallery/plant.gltf","gallery/leaves_color.png")
    first:=import_run(plant,"--max-texture","16")
    testing.expectf(t,first.code==0 && first.err=="","import fails: %d\n%s%s",first.code,first.out,first.err)
    paths:=reported_paths(first.out)
    testing.expect_value(t,len(paths),6)
    testing.expect(t,strings.contains(first.out,"6 assets\n") && !strings.contains(first.out,"warning"),first.out)
    for kind in ([]string{"mesh ","material ","texture ","scene "}) {testing.expectf(t,strings.contains(first.out,kind),"the report names a %s",kind)}
    // The scene is checked against the game of a project, which this folder is not.
    verify:=make([dynamic]string,context.temp_allocator)
    append(&verify,"asset","verify")
    for path in paths {if !strings.has_suffix(path,".scene") {append(&verify,path)}}
    checked:=run(t,exe,..verify[:])
    testing.expectf(t,checked.code==0,"asset verify fails: %s%s",checked.out,checked.err)
    listing:=run(t,exe,"asset","ls",folder)
    testing.expect(t,listing.code==0 && strings.contains(listing.out," gallery/plant/Leaves.mat") && strings.contains(listing.out," gallery/plant/Plant.mesh") && strings.contains(listing.out," gallery/plant/leaves_color.tex"),listing.out)

    // Importing again keeps every id, and the mesh and the texture are not built again.
    again:=import_run(plant,"--max-texture","16")
    testing.expect(t,again.code==0 && strings.contains(again.out,"6 assets, 2 were already up to date") && slice.equal(reported_paths(again.out),paths),again.out)
    rebuilt:=import_run(plant,"--max-texture","16","--rebuild")
    testing.expect(t,rebuilt.code==0 && slice.equal(reported_assets(rebuilt.out),reported_assets(first.out)),"--rebuild builds everything again, to the same bytes")

    // An image on its own.
    bricks:=copy_in(root_folder,DEMO,"surfaces/bricks/bricks_color.png")
    texture:=import_run(bricks,"--srgb")
    testing.expectf(t,texture.code==0 && strings.contains(texture.out,"texture") && strings.contains(texture.out,".tex"),"%d: %s%s",texture.code,texture.out,texture.err)
    verify_texture:=make([dynamic]string,context.temp_allocator)
    append(&verify_texture,"asset","verify")
    append(&verify_texture,..reported_paths(texture.out))
    verified:=run(t,exe,..verify_texture[:])
    testing.expect_value(t,verified.code,0)

    // The sidecar of an import, next to its source, keeps its settings: the options change them, and importing again uses them.
    copy:=copy_in(root_folder,DEMO,"gallery/vase.obj","gallery/vase.mtl","gallery/vase_color.png")
    hulled:=import_run(copy,"--collision","hull")
    testing.expectf(t,hulled.code==0 && strings.contains(hulled.out," triangles, 1 hull of ") && strings.contains(hulled.out,"sidecar ") && strings.contains(hulled.out,"vase.obj.import"),"%d: %s%s",hulled.code,hulled.out,hulled.err)
    sidecar:=fmt.tprintf("%s.import",copy)
    stored,_:=os.read_entire_file(sidecar,context.temp_allocator)
    testing.expect(t,strings.contains(string(stored),"\"collision\": \"Hull\""),string(stored))
    ids :: proc(out:string) -> []string {
        found:=make([dynamic]string,context.temp_allocator)
        for line in reported_assets(out) {append(&found,line[:32])}
        return found[:]
    }
    mesh_path:string
    for line in reported_assets(hulled.out) {if strings.contains(line," mesh ") {mesh_path=reported_paths(line)[0]}}
    with_hull,_:=os.read_entire_file(mesh_path,context.temp_allocator)
    repeated:=import_run(copy)
    same,_:=os.read_entire_file(mesh_path,context.temp_allocator)
    testing.expect(t,repeated.code==0 && slice.equal(reported_paths(repeated.out),reported_paths(hulled.out)) && string(same)==string(with_hull) && len(same)>0,"importing again without options gives the same assets")
    bare:=import_run(copy,"--collision","none","--lods","none")
    testing.expect(t,bare.code==0 && !strings.contains(bare.out,"hull") && slice.equal(ids(bare.out),ids(hulled.out)) && strings.contains(bare.out,"  3232 triangles"),bare.out)
    _=os.write_entire_file(sidecar,"{\"lods\": \"Never\"}")
    refused:=import_run(copy)
    testing.expect(t,refused.code==1 && strings.contains(refused.err,"vase.obj.import"),refused.err)

    // Misuse and failures.
    testing.expect_value(t,import_run(copy,"--lods","some").code,2)
    testing.expect_value(t,import_run(copy,"--collision","soft").code,2)
    testing.expect_value(t,import_run(bricks,"--collision","hull").code,2)
    testing.expect_value(t,import_run().code,2)
    testing.expect_value(t,import_run(copy,"--max-texture","0").code,2)
    testing.expect_value(t,import_run(copy,"--srgb").code,2)
    testing.expect_value(t,import_run(copy,"--alpha-coverage","0.5").code,2)
    testing.expect_value(t,import_run(bricks,"--alpha-coverage","1.5").code,2)
    testing.expect_value(t,import_run(bricks,"--rdo-lambda","101").code,2)
    testing.expect_value(t,import_run(bricks,"--rdo-lambda","-1").code,2)
    testing.expect_value(t,import_run(copy,"--nope").code,2)
    testing.expect_value(t,import_run(copy,"--out",folder).code,2)
    missing:=import_run(fmt.tprintf("%s/missing.obj",folder))
    testing.expect(t,missing.code==1 && strings.contains(missing.err,"mirai import:") && strings.contains(missing.err,"missing.obj"),missing.err)
    outside:=import_run(fmt.tprintf("%s/elsewhere.obj",root_folder))
    testing.expect(t,outside.code==1 && strings.contains(outside.err,"assets"),outside.err)
    write_text(folder,"broken.obj","v 0 0 0\nf 1 2 3\n")
    broken:=import_run(fmt.tprintf("%s/broken.obj",folder))
    testing.expect(t,broken.code==1 && strings.contains(broken.err,"outside"),broken.err)
}
