package vfx_editor

import "core:fmt"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:std/base"
import vfx "plugins:vfx/runtime"
import "plugins:vfx/runtime/effect"

// The file of an effect as the editor writes it: a file of the project, as a
// step of the history it is written in.

PARTICLE_FIELDS :: 64 // of Particle_Info that its hidden fields can name

// What the file of an effect holds, in room of its own: the document copies,
// compares and merges it as a value, and particle_desc gives it as the file
// is written.
Particle_File :: struct {
    info:effect.Particle_Info,
    parameters:[effect.PARTICLE_MAX_PARAMETERS]effect.Particle_Parameter,
    parameter_count:int,
    hidden:[PARTICLE_FIELDS]effect.Particle_Field,
    hidden_count:int,
}

particle_desc :: proc(file:^Particle_File,id:base.Asset_Id={}) -> effect.Particle_Desc {
    return {id=id,info=file.info,parameters=file.parameters[:file.parameter_count],hidden=file.hidden[:file.hidden_count]}
}

// What a file holds; hidden fields past PARTICLE_FIELDS are cut.
particle_file_of :: proc(desc:effect.Particle_Desc) -> (file:Particle_File) {
    file.info=desc.info
    file.parameter_count=copy(file.parameters[:],desc.parameters)
    file.hidden_count=copy(file.hidden[:],desc.hidden)
    return
}

// Writes the file of an effect at path as an edit, in the open gesture or in
// a step of its own named label, and loads it again. A message says what
// failed and how to correct it; "" when it was written.
@(private)
particle_publish :: proc(s:^editor.Session,id:base.Asset_Id,path:string,file:^Particle_File,label:string) -> string {
    a:=s.app.assets
    if a==nil {return "The editor has no assets"}
    desc:=particle_desc(file,id)
    if problem:=effect.particle_validate(desc);problem.message!="" {
        return fmt.tprintf("%s: %s",problem.field,problem.message)
    }
    bytes,error:=effect.particle_bytes(&a.types,desc,context.temp_allocator)
    if error!=.None || !editor.file_write(s,path,bytes,label) {return "The particle effect could not be written"}
    return ""
}

// Writes the file an effect of the project has, as an edit, and loads it
// again. What it refuses is told in a toast.
particle_write :: proc(s:^editor.Session,id:base.Asset_Id,file:^Particle_File) -> bool {
    a:=s.app.assets
    if a==nil || id=={} {return false}
    record,found:=asset.registry_find(&a.registry,id)
    if !found {return false}
    if problem:=particle_publish(s,id,asset.registry_file_path(&a.registry,record.path,context.temp_allocator),file,"Particle");problem!="" {
        editor.notify(s,problem)
        return false
    }
    return true
}

// What the file of an effect holds; the defaults without one.
@(private)
particle_file :: proc(s:^editor.Session,id:base.Asset_Id) -> (file:Particle_File) {
    file.info=effect.PARTICLE_DEFAULTS
    if a:=s.app.assets;a!=nil && id!={} {
        if view,ok:=vfx.effect_view(a,id);ok {file=particle_file_of(view)}
    }
    return
}

// Changes the file of the effect of an entity; the default effect has none.
@(private)
particle_change :: proc(s:^editor.Session,e:core.Entity,file:^Particle_File) -> bool {
    emitter,ok:=editor.entity_get(editor.shown_world(s),e,vfx.Particle_Emitter)
    return ok && emitter.particle!={} && particle_write(s,emitter.particle,file)
}
