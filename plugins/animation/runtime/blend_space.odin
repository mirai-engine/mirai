package anim

import "core:mem"
import "mirai:asset"
import "mirai:host"
import "mirai:std/base"
import lib "mirai:std/anim"
import mm "mirai:std/math"
import "base:runtime"

BLEND_KIND :: asset.Fourcc(u32('B')|u32('L')<<8|u32('N')<<16|u32('D')<<24)
BLEND_VERSION :: 1
Blend_Axis :: struct {name:[32]u8 `mirai:"text"`,min,max:f32}
Blend_Info :: struct {animation:base.Asset_Id,dimension:lib.Blend_Dimension,x,y:Blend_Axis}
Blend_Sample :: struct {position:mm.Vec2,clip:[64]u8 `mirai:"text"`,speed:f32,animation:base.Asset_Id}
Blend_Profile :: struct {info:Blend_Info,samples:[]Blend_Sample,segments:[]lib.Blend_Segment,triangles:[]lib.Blend_Triangle}

blend_position :: proc "contextless" (info:Blend_Info,position:mm.Vec2) -> mm.Vec2 {
    x:=(f64(position.x)-f64(info.x.min))/(f64(info.x.max)-f64(info.x.min))
    y:f64
    if info.dimension==.Two {y=(f64(position.y)-f64(info.y.min))/(f64(info.y.max)-f64(info.y.min))}
    magnitude:=max(abs(x),abs(y))
    if magnitude>1e30 {factor:=1e30/magnitude;x*=factor;y*=factor}
    return {f32(x),f32(y)}
}

blend_space_prepare :: proc(profile:^Blend_Profile,allocator:=context.allocator) -> asset.Error {
    if profile==nil || !blend_definition_check(profile^) {return .Invalid}
    points:[lib.BLEND_MAX_SAMPLES]mm.Vec2
    for sample,i in profile.samples {points[i]=blend_position(profile.info,sample.position)}
    failure:lib.Blend_Error
    space,ok:=lib.blend_space_prepare(points[:len(profile.samples)],profile.info.dimension,allocator,&failure)
    if !ok {return .Out_Of_Memory if failure==.Out_Of_Memory else .Invalid}
    defer lib.blend_space_destroy(&space)
    delete(profile.segments,allocator);delete(profile.triangles,allocator)
    profile.segments,profile.triangles=space.segments,space.triangles
    space.segments,space.triangles=nil,nil
    return .None
}

blend_space_check :: proc "contextless" (profile:Blend_Profile) -> bool {
    if !blend_definition_check(profile) {return false}
    points:[lib.BLEND_MAX_SAMPLES]mm.Vec2
    for sample,i in profile.samples {points[i]=blend_position(profile.info,sample.position)}
    return lib.blend_space_validate({dimension=profile.info.dimension,points=points[:len(profile.samples)],segments=profile.segments,triangles=profile.triangles})
}

@(private)
blend_definition_check :: proc "contextless" (profile:Blend_Profile) -> bool {
    if profile.info.animation=={} || profile.info.dimension>max(lib.Blend_Dimension) || len(profile.samples)==0 || len(profile.samples)>lib.BLEND_MAX_SAMPLES {return false}
    axes:=[2]Blend_Axis{profile.info.x,profile.info.y}
    for &axis,i in axes {
        if i==1 && profile.info.dimension==.One {continue}
        if !blend_text_valid(axis.name[:],false) || !finite(axis.min) || !finite(axis.max) || axis.min>=axis.max {return false}
    }
    for &sample in profile.samples {
        if !finite(sample.position.x) || !finite(sample.position.y) || !finite(sample.speed) || !blend_text_valid(sample.clip[:],false) {return false}
        if sample.position.x<profile.info.x.min || sample.position.x>profile.info.x.max {return false}
        if profile.info.dimension==.Two && (sample.position.y<profile.info.y.min || sample.position.y>profile.info.y.max) {return false}
    }
    return true
}
@(private)
blend_text_valid :: proc "contextless" (value:[]u8,empty:bool) -> bool {
    for byte,i in value {if byte==0 {return empty || i>0}}
    return false
}

blend_content_sample :: proc "contextless" (content:^Blend_Content,position:mm.Vec2) -> (lib.Blend_Weights,bool) {
    if content==nil || !content.valid || !finite(position.x) || !finite(position.y) {return {},false}
    normalized:=blend_position(content.profile.info,position)
    return lib.blend_space_sample(content.space,normalized)
}
blend_sample :: proc "contextless" (profile:Blend_Profile,position:mm.Vec2) -> (lib.Blend_Weights,bool) {
    if !blend_definition_check(profile) || !finite(position.x) || !finite(position.y) {return {},false}
    points:[lib.BLEND_MAX_SAMPLES]mm.Vec2
    for sample,i in profile.samples {points[i]=blend_position(profile.info,sample.position)}
    return lib.blend_space_sample({dimension=profile.info.dimension,points=points[:len(profile.samples)],segments=profile.segments,triangles=profile.triangles},blend_position(profile.info,position))
}

blend_space_document :: proc(doc:^asset.Document,types:^asset.Types,id:base.Asset_Id,profile:Blend_Profile,allocator:=context.allocator) -> asset.Error {
    if !blend_space_check(profile) {return .Invalid}
    asset.document_init(doc,BLEND_KIND,id,allocator);doc.kind_version=BLEND_VERSION
    error:=blend_space_tables(doc,types,profile)
    if error!=.None {asset.document_destroy(doc)}
    return error
}
@(private)
blend_space_tables :: proc(doc:^asset.Document,types:^asset.Types,profile:Blend_Profile) -> asset.Error {
    info:=profile.info
    asset.document_put_row(doc,types,"blend",&info) or_return
    asset.document_put(doc,types,"samples",profile.samples) or_return
    asset.document_put(doc,types,"segments",profile.segments) or_return
    asset.document_put(doc,types,"triangles",profile.triangles) or_return
    return .None
}
blend_space_save :: proc(path:string,types:^asset.Types,id:base.Asset_Id,profile:Blend_Profile,allocator:=context.allocator) -> asset.Error {
    doc:asset.Document
    blend_space_document(&doc,types,id,profile,allocator) or_return
    defer asset.document_destroy(&doc)
    return asset.document_save(&doc,path)
}
blend_space_view :: proc(file:^asset.Asset,types:^asset.Types) -> (profile:Blend_Profile,error:asset.Error) {
    asset.kind_check(file,BLEND_KIND,BLEND_VERSION) or_return
    info:=asset.asset_row(file,types,"blend",Blend_Info) or_return
    profile.info=info^
    profile.samples=asset.asset_rows(file,types,"samples","",Blend_Sample) or_return
    profile.segments=asset.asset_rows(file,types,"segments","",lib.Blend_Segment) or_return
    profile.triangles=asset.asset_rows(file,types,"triangles","",lib.Blend_Triangle) or_return
    if !blend_space_check(profile) {return {},.Corrupt}
    return profile,.None
}

// axis_names and sample_names: base.name_hash of the name of each axis and of the clip of each sample.
Blend_Content :: struct {id:base.Asset_Id,checked,revision:u64,stamp:[2]i64,profile:Blend_Profile,space:lib.Blend_Space,axis_names:[2]u64,sample_names:[]u64,valid:bool,error:asset.Error}
@(storage,host,free="blend_assets_free")
Blend_Assets :: struct {allocator:mem.Allocator,contents:[dynamic]Blend_Content}

blend_profile_free :: proc(profile:^Blend_Profile,allocator:=context.allocator) {
    if profile==nil {return}
    delete(profile.samples,allocator);delete(profile.segments,allocator);delete(profile.triangles,allocator);profile^={}
}
blend_assets_free :: proc(cache:^Blend_Assets) {
    if cache==nil {return}
    allocator:=cache.allocator
    if allocator.procedure==nil {allocator=context.allocator}
    for &content in cache.contents {blend_profile_free(&content.profile,allocator);delete(content.space.points,allocator);delete(content.sample_names,allocator);content.space={}}
    delete(cache.contents);cache^={}
}
blend_content :: proc(cache:^Blend_Assets,assets:^host.Assets,allocator:runtime.Allocator,id:base.Asset_Id) -> ^Blend_Content {
    if cache==nil || assets==nil || id=={} {return nil}
    if cache.allocator.procedure==nil {cache.allocator=allocator}
    context.allocator=cache.allocator
    row:=-1
    for content,i in cache.contents {if content.id==id {row=i;break}}
    if row<0 {row=len(cache.contents);if append(&cache.contents,Blend_Content{id=id})!=1 {return nil}}
    content:=&cache.contents[row]
    if content.checked==assets_stamp(assets) {return content if content.valid else nil}
    record,found:=asset.registry_find(&assets.registry,id)
    stamp:=[2]i64{}
    if found {stamp={record.size,record.time}}
    if content.checked!=0 && stamp==content.stamp {content.checked=assets_stamp(assets);return content if content.valid else nil}
    next:Blend_Content
    error:=asset.Error.Not_Found
    if found {next,error=blend_profile_read(assets,id,cache.allocator)}
    if error==.Out_Of_Memory {content.error=error;content.checked=0;return nil}
    blend_profile_free(&content.profile,cache.allocator);delete(content.space.points,cache.allocator);delete(content.sample_names,cache.allocator)
    revision:=content.revision+1
    content^=next;content.id,content.stamp,content.checked,content.revision=id,stamp,assets_stamp(assets),revision
    content.valid,content.error=error==.None,error
    if content.valid {content.axis_names={base.name_hash(base.text_get(content.profile.info.x.name[:])),base.name_hash(base.text_get(content.profile.info.y.name[:]))}}
    return content if content.valid else nil
}
@(private)
blend_profile_read :: proc(assets:^host.Assets,id:base.Asset_Id,allocator:mem.Allocator) -> (content:Blend_Content,error:asset.Error) {
    file:asset.Asset
    if error:=host.assets_file(assets,id,BLEND_KIND,&file);error!=.None {return {},error};defer asset.asset_close(&file)
    view,read:=blend_space_view(&file,&assets.types)
    if read!=.None {return {},read}
    clone :: proc(source:[]$T,allocator:mem.Allocator) -> ([]T,bool) {
        out,error:=make([]T,len(source),allocator);if error!=nil {return nil,false};copy(out,source);return out,true
    }
    profile:Blend_Profile;profile.info=view.info
    success:=false
    defer {if !success {blend_profile_free(&profile,allocator);delete(content.space.points,allocator);delete(content.sample_names,allocator);content={}}}
    ok:bool
    profile.samples,ok=clone(view.samples,allocator);if !ok {return {},.Out_Of_Memory}
    profile.segments,ok=clone(view.segments,allocator);if !ok {return {},.Out_Of_Memory}
    profile.triangles,ok=clone(view.triangles,allocator);if !ok {return {},.Out_Of_Memory}
    points,allocation:=make([]mm.Vec2,len(profile.samples),allocator)
    names,names_allocation:=make([]u64,len(profile.samples),allocator)
    content.space.points,content.sample_names=points,names
    if allocation!=nil || names_allocation!=nil {return {},.Out_Of_Memory}
    for &sample,i in profile.samples {points[i]=blend_position(profile.info,sample.position);names[i]=base.name_hash(base.text_get(sample.clip[:]))}
    content.profile=profile
    content.space={dimension=profile.info.dimension,points=points,segments=profile.segments,triangles=profile.triangles,allocator=allocator}
    success=true
    return content,.None
}
