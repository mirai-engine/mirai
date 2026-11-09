package importer

import "core:mem"
import "core:os"
import "core:path/filepath"
import "mirai:asset"
import anim "mirai:std/anim"
import "mirai:std/base"

// Reads a source file into a model with the first of formats that recognizes
// it (format_find). Everything the model holds lives in one arena of
// allocator, released by model_destroy; the reading itself works in scratch
// memory that is gone when the procedure returns, so the size of a source
// never reaches the temp allocator of the caller.
//
// A rig faces -Z at run time: when a skeleton's body stands facing another
// axis (+Z, or a side), the source is read again with its axes turned.
import_model :: proc(path:string,formats:[]Format,options:Import_Options={},allocator:=context.allocator) -> (model:Imported_Model,error:Error) {
    facing:[3]f32
    model,facing,error=import_read(path,formats,options,{},allocator)
    if error.code==.None && facing!={} {
        model_destroy(&model)
        model,_,error=import_read(path,formats,options,facing,allocator)
    }
    return
}

// How sure the import must be of the axes of a body to turn it to -Z.
@(private="file")
BODY_FACING_CONFIDENCE :: f32(.5)

// Where the first skeleton with a body stands facing, when an axis other than -Z.
@(private="file")
body_facing :: proc(skeletons:[]Imported_Skeleton) -> [3]f32 {
    for skeleton in skeletons {
        body,found:=asset.skeleton_body_detect(skeleton.bones,anim.body_map_empty())
        if !found || body.axes_confidence<BODY_FACING_CONFIDENCE {continue}
        if body_turnable(body.forward) {return body.forward}
    }
    return {}
}

@(private="file")
import_read :: proc(path:string,formats:[]Format,options:Import_Options,turn:[3]f32,allocator:=context.allocator) -> (model:Imported_Model,facing:[3]f32,error:Error) {
    caller:=context.temp_allocator
    settings,stored:=options.settings,false
    if !options.ignore_stored {
        kept,found,settings_error:=settings_load(path)
        if settings_error.code!=.None {return {},{},settings_error}
        if found {settings,stored=kept,true}
    }
    arena:=new(mem.Dynamic_Arena,allocator)
    mem.dynamic_arena_init(arena,allocator,allocator,block_size=1<<20,out_band_size=1<<20)
    scratch:mem.Dynamic_Arena
    mem.dynamic_arena_init(&scratch,allocator,allocator,block_size=1<<20,out_band_size=1<<20)
    defer mem.dynamic_arena_destroy(&scratch)
    context.temp_allocator=base.dynamic_arena_allocator(&scratch)

    r:=Reader{out=base.dynamic_arena_allocator(arena),options=options,facing=turn}
    r.options.settings=settings
    mem.dynamic_arena_init(&r.polygon_arena,allocator,allocator,block_size=64<<10,out_band_size=64<<10)
    defer mem.dynamic_arena_destroy(&r.polygon_arena)
    r.meshes.allocator=context.temp_allocator;r.materials.allocator=context.temp_allocator;r.images.allocator=context.temp_allocator
    r.nodes.allocator=context.temp_allocator;r.warnings.allocator=context.temp_allocator;r.image_rows.allocator=context.temp_allocator
    r.programs.allocator=context.temp_allocator
    r.animations.allocator=context.temp_allocator
    r.skeletons.allocator=context.temp_allocator
    r.material_names.allocator=context.temp_allocator;r.mesh_names.allocator=context.temp_allocator
    r.path=normalize_path(&r,path)
    r.directory=filepath.dir(r.path)
    r.file_name=filepath.base(r.path)
    r.stem=filepath.stem(r.path)
    ok:=read_model(&r,formats,&model)
    if ok && turn=={} {facing=body_facing(r.skeletons[:])}
    if ok {ok=model_finish(&r,&model)}
    if !ok {
        mem.dynamic_arena_destroy(arena)
        free(arena,allocator)
        return {},{},error_make(r.code if r.code!=.None else .Malformed,"%s",r.message,allocator=caller)
    }
    model.arena=arena
    model.settings,model.stored,model.facing=settings,stored,turn
    model.allocator=allocator
    if settings.rig!=.Source {
        zone(options,"import.rig")
        if rig_error:=model_rig(&model,settings,caller);rig_error.code!=.None {
            model_destroy(&model)
            return {},{},rig_error
        }
    }
    return model,facing,{}
}

@(private="file")
read_model :: proc(r:^Reader,formats:[]Format,model:^Imported_Model) -> bool {
    _,stat_error:=os.stat(r.path,context.temp_allocator)
    if stat_error!=nil || unsafe_path(r.path) {return fail(r,.Not_Found,"%s does not exist",r.path)}
    bytes:[]u8
    {
        zone(r.options,"import.source")
        bytes=read_source(r,r.path) or_return
    }
    format,found:=format_find(formats,bytes,filepath.ext(r.path))
    if !found {return fail(r,.Unsupported,"%s: the formats read are %s",r.path,format_names(formats))}
    model.source=r.path
    model.source_size=u64(len(bytes))
    model.source_hash=base.hash64(bytes)
    model.format=format.name
    model.version=import_version(format.version)
    r.data=format.data
    space:=format.space
    space.axes=space_faced(space.axes,r.facing)
    basis,valid:=space_basis(space)
    if !valid {return fail(r,.Malformed,"the format %s declares a space without positive units and three distinct axes",format.name)}
    r.space,r.basis=space,basis
    {
        zone(r.options,"import.format")
        if !format.read(r,bytes) {return false}
    }
    zone(r.options,"import.space")
    space_bake(r)
    return true
}

// Checks what an asset would refuse and moves the lists into the model.
@(private="file")
model_finish :: proc(r:^Reader,model:^Imported_Model) -> bool {
    // A model of textures alone (a package of textures) is those textures.
    if len(r.meshes)==0 && len(r.animations)==0 && len(r.skeletons)==0 && (len(r.images)==0 || len(r.materials)>0) {return fail(r,.Malformed,"%s has no polygon geometry, skeleton, animation clips or images",r.file_name)}
    for &material in r.materials {
        space_material(r.space,&material.info)
        // Masked materials ask their base color image to keep its coverage.
        image:=material.images[.Base_Color]
        if image>=0 && material.info.alpha_mode==.Mask && r.images[image].alpha_cutoff==0 {r.images[image].alpha_cutoff=material.info.alpha_cutoff}
        if !asset.material_check({info=&material.info}) {return fail(r,.Malformed,"material %s has a value outside its range",material.name)}
    }
    for node in r.nodes {
        if !transform_finite(node.transform) {return fail(r,.Malformed,"node %s has a transform that is not finite",node.name)}
    }
    model.name=own(r,r.stem)
    model.meshes=own_slice(r,r.meshes[:])
    model.materials=own_slice(r,r.materials[:])
    model.images=own_slice(r,r.images[:])
    model.nodes=own_slice(r,r.nodes[:])
    model.skeletons=own_slice(r,r.skeletons[:])
    model.animations=own_slice(r,r.animations[:])
    model.warnings=own_slice(r,r.warnings[:])
    model.programs=make([]string,len(r.programs),r.out)
    for program,i in r.programs {model.programs[i]=own(r,program)}
    return true
}
