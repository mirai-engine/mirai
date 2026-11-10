package asset

import "core:mem"
import "core:fmt"
import cmath "core:math"
import "core:slice"
import "core:testing"
import anim "mirai:std/anim"
import math "mirai:std/math"
import "mirai:std/base"
import "mirai:std/serial"

// What `mirai asset unpack` and `pack` do: the text of a document, with its
// bulk columns apart, read back and written again gives the same file.
@(private="file")
same_through_text :: proc(t:^testing.T,doc:^Document,loc:=#caller_location) {
    original,text,again:serial.Writer
    serial.writer_init(&original);defer serial.writer_destroy(&original)
    serial.writer_init(&text);defer serial.writer_destroy(&text)
    serial.writer_init(&again);defer serial.writer_destroy(&again)
    testing.expect_value(t,document_write(doc,&original),Error.None,loc)
    testing.expect_value(t,document_text_write(doc,&text,{schema=true,bulk=.Files}),Error.None,loc)
    back:Document
    problem,ok:=document_text_read(&back,string(serial.writer_bytes(&text)),test_bulk_loader(doc))
    if !testing.expectf(t,ok,"%v %v at %d",problem.code,problem.rule,problem.offset,loc=loc) {return}
    defer document_destroy(&back)
    testing.expect_value(t,document_write(&back,&again),Error.None,loc)
    testing.expect(t,mem.compare(serial.writer_bytes(&again),serial.writer_bytes(&original))==0,"the text gives the same file back",loc=loc)
}

@(private="file")
Test_Animation :: struct {
    rise:[3]anim.Keyframe,
    turn,grow:[2]anim.Keyframe,
    lift_tracks:[2]Animation_Track_Desc,
    lift_markers:[2]Animation_Marker_Desc,
    pulse_tracks:[1]Animation_Track_Desc,
    clips:[2]Animation_Clip_Desc,
}
@(private="file")
test_animation :: proc(s:^Test_Animation) -> Animation_Desc {
    s.rise={{time=0,value={0,0,0,0}},{time=1,value={0,2,0,0}},{time=2,value={0,0,0,0},interpolation=.Cubic}}
    s.turn={{time=0,value={0,0,0,1}},{time=2,value={0,1,0,0},ease=.Quad_Out}}
    s.grow={{time=0,value={1,1,1,0}},{time=0.5,value={2,2,2,0},interpolation=.Step}}
    s.lift_tracks={{target="platform",property=.Position,keys=s.rise[:]},{target="",property=.Rotation,keys=s.turn[:]}}
    s.lift_markers={{2,"down",0},{1,"top",0}}
    s.pulse_tracks={{target="lamp",property=.Scale,keys=s.grow[:]}}
    s.clips={{name="lift",tracks=s.lift_tracks[:],markers=s.lift_markers[:]},{name="pulse",tracks=s.pulse_tracks[:]}}
    return {id={0xa11,1},clips=s.clips[:]}
}

@(test)
animation_round_trips_and_fills_a_library :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    types:Types;types_init(&types);defer types_destroy(&types)
    storage:Test_Animation
    desc:=test_animation(&storage)
    path:=fmt.tprintf("%s/lift.anim",base.test_folder(t,"asset"))
    testing.expect_value(t,animation_save(path,&types,desc),Error.None)

    a:Asset
    testing.expect_value(t,asset_load(&a,path),Error.None)
    defer asset_close(&a)
    testing.expect(t,a.blob.header.kind==KIND_ANIMATION && a.blob.header.kind_version==ANIMATION_VERSION && a.blob.header.id==desc.id)
    // The track targets are mostly zeros: their table goes in LZ.
    packed:=false
    for i in 0..<int(a.blob.header.chunk_count) {packed||=blob_chunk(&a.blob,i).compression==.LZ}
    testing.expect(t,packed,"the tables of an animation are compressed")
    view,error:=animation_view(&a,&types)
    testing.expect_value(t,error,Error.None)
    testing.expect(t,len(view.clips)==2 && len(view.tracks)==3 && len(view.keys)==7 && len(view.markers)==2)
    testing.expect(t,serial.text_field(view.clips[1].name[:])=="pulse" && view.clips[1].first_track==2 && view.clips[1].track_count==1 && view.clips[1].marker_count==0)
    testing.expect(t,serial.text_field(view.tracks[0].target[:])=="platform" && view.tracks[1].property==.Rotation && view.tracks[1].first_key==3)
    testing.expect(t,view.keys[2].interpolation==.Cubic && view.keys[4].ease==.Quad_Out && view.keys[6].value==[4]f32{2,2,2,0})
    testing.expect(t,serial.text_field(view.markers[1].name[:])=="top" && view.markers[1].time==1)

    lib:anim.Library
    testing.expect(t,anim.library_init(&lib,animation_library_desc(view)))
    defer anim.library_destroy(&lib)
    first:=animation_clips_add(view,&lib,.Loop)
    testing.expect_value(t,first,anim.Clip(1))
    testing.expect_value(t,anim.clip_find(&lib,base.name_hash("pulse")),anim.Clip(2))
    testing.expect_value(t,anim.clip_duration(&lib,1),f32(2))
    testing.expect_value(t,anim.clip_data(&lib,1).loop,anim.Loop.Loop)
    tracks:=anim.clip_tracks(&lib,1)
    testing.expect(t,len(tracks)==2 && tracks[0].target==base.name_hash("platform") && tracks[1].target==0)
    testing.expect_value(t,anim.clip_evaluate(&lib,tracks[0],0.5),[4]f32{0,1,0,0})
    // Markers come sorted by time and name their row.
    markers:=anim.clip_markers(&lib,1)
    testing.expect(t,len(markers)==2 && markers[0]==anim.Marker{1,1,0} && markers[1]==anim.Marker{2,0,0})
    testing.expect_value(t,animation_clips_add(view,&lib),anim.Clip(0))

    doc:Document
    testing.expect_value(t,document_from_asset(&doc,&a),Error.None)
    defer document_destroy(&doc)
    same_through_text(t,&doc)
    // A value edited by its path, as `mirai asset set` does.
    _,set_error:=document_set(&doc,"tracks[2].target","beacon")
    testing.expect_value(t,set_error,Locate_Error.None)
    value,_,get_error:=document_get(&doc,"tracks[2].target")
    testing.expect(t,get_error==.None && value.(string)=="beacon")
}

@(test)
animation_refuses_what_contradicts_itself :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    types:Types;types_init(&types);defer types_destroy(&types)
    doc:Document
    unordered:=[2]anim.Keyframe{{time=1},{time=0.5}}
    refuse :: proc(t:^testing.T,types:^Types,clips:[]Animation_Clip_Desc,what:string) {
        doc:Document
        testing.expect(t,animation_document(&doc,types,{id={1,1},clips=clips})==.Invalid && doc.tables==nil,what)
    }
    refuse(t,&types,{{name="",tracks={}}},"a clip without name")
    refuse(t,&types,{{name="a"},{name="a"}},"two clips of one name")
    refuse(t,&types,{{name="a",tracks={{property=.Position,keys=unordered[:]}}}},"keys out of order")
    refuse(t,&types,{{name="a",markers={{-1,"m",0}}}},"a marker before the start")
    refuse(t,&types,{{name="a",markers={{0,"",0}}}},"a marker without name")
    testing.expect_value(t,animation_document(&doc,&types,{id={1,1}}),Error.None)
    document_destroy(&doc)

    // A file whose rows point outside their tables.
    clips:=[1]Animation_Clip{{first_track=0,track_count=2}}
    text_set(clips[0].name[:],"a")
    tracks:=[1]Animation_Track{{first_key=4,key_count=1}}
    document_init(&doc,KIND_ANIMATION,{2,2})
    doc.kind_version=ANIMATION_VERSION
    defer document_destroy(&doc)
    document_put(&doc,&types,"clips",clips[:])
    document_put(&doc,&types,"tracks",tracks[:])
    w:serial.Writer;serial.writer_init(&w);defer serial.writer_destroy(&w)
    testing.expect_value(t,document_write(&doc,&w),Error.None)
    a:Asset
    testing.expect_value(t,asset_open(&a,serial.writer_bytes(&w)),Error.None)
    defer asset_close(&a)
    _,error:=animation_view(&a,&types)
    testing.expect_value(t,error,Error.Corrupt)
}

@(test)
animation_checks_cubic_tangents_and_adds_libraries_atomically :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    types:Types;types_init(&types);defer types_destroy(&types)
    storage:Test_Animation
    desc:=test_animation(&storage)
    doc:Document
    storage.rise[1].out_slope.x=transmute(f32)u32(0x7fc00000)
    testing.expect_value(t,animation_document(&doc,&types,desc),Error.Invalid)
    storage.rise[1].out_slope.x=0
    storage.rise[1].interpolation=.Cubic_Spline
    testing.expect_value(t,animation_document(&doc,&types,desc),Error.Invalid)
    storage.rise[1].tangents=true
    testing.expect_value(t,animation_document(&doc,&types,desc),Error.None)
    defer document_destroy(&doc)
    w:serial.Writer;serial.writer_init(&w);defer serial.writer_destroy(&w)
    testing.expect_value(t,document_write(&doc,&w),Error.None)
    a:Asset
    testing.expect_value(t,asset_open(&a,serial.writer_bytes(&w)),Error.None)
    defer asset_close(&a)
    view,error:=animation_view(&a,&types)
    if !testing.expect_value(t,error,Error.None) {return}
    lib:anim.Library
    limits:=animation_library_desc(view)
    limits.max_keys-=1
    testing.expect(t,anim.library_init(&lib,limits))
    defer anim.library_destroy(&lib)
    testing.expect_value(t,animation_clips_add(view,&lib),anim.Clip(0))
    testing.expect(t,lib.key_count==0 && lib.track_count==0 && lib.marker_count==0 && lib.clip_count==0)
}

@(test)
sound_round_trips_lossless_and_as_a_file :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    types:Types;types_init(&types);defer types_destroy(&types)
    // The bytes are the coding's own business: the asset checks its magic.
    lossless:=make([]u8,96);defer delete(lossless)
    copy(lossless,"MLPC")
    for &b,i in lossless[4:] {b=u8(i*37)}
    source:Import_Info
    text_set(source.source[:],"sounds/step.wav")
    text_set(source.importer[:],"sound")
    path:=fmt.tprintf("%s/step.sound",base.test_folder(t,"asset"))
    testing.expect_value(t,sound_save(path,&types,{id={0x50,1},channels=2,sample_rate=48000,frames=480,lossless=lossless,source=&source}),Error.None)
    a:Asset
    testing.expect_value(t,asset_load(&a,path),Error.None)
    defer asset_close(&a)
    testing.expect(t,a.blob.header.kind==KIND_SOUND && .Cooked in a.blob.header.flags)
    view,error:=sound_view(&a,&types)
    testing.expect_value(t,error,Error.None)
    testing.expect(t,view.info^==Sound_Info{2,48000,480,.Lossless,{}} && len(view.file)==0 && view.source!=nil)
    testing.expect(t,mem.compare(view.lossless,lossless)==0)
    // Stored without LZ, the coded samples are read from the file without a copy.
    testing.expect(t,uintptr(raw_data(view.lossless))>=uintptr(raw_data(a.file)) && uintptr(raw_data(view.lossless))%SOUND_BULK_ALIGNMENT==uintptr(raw_data(a.file))%SOUND_BULK_ALIGNMENT)
    doc:Document
    testing.expect_value(t,document_from_asset(&doc,&a),Error.None)
    same_through_text(t,&doc)
    document_destroy(&doc)

    file:=make([]u8,64);defer delete(file)
    copy(file,"RIFF\x38\x00\x00\x00WAVEfmt ")
    testing.expect_value(t,sound_document(&doc,&types,{id={0x51,1},channels=1,sample_rate=22050,frames=10,file=file,flags={.Stream},compression=.LZ}),Error.None)
    w:serial.Writer;serial.writer_init(&w);defer serial.writer_destroy(&w)
    testing.expect_value(t,document_write(&doc,&w),Error.None)
    same_through_text(t,&doc)
    document_destroy(&doc)
    b:Asset
    testing.expect_value(t,asset_open(&b,serial.writer_bytes(&w)),Error.None)
    defer asset_close(&b)
    view,error=sound_view(&b,&types)
    testing.expect_value(t,error,Error.None)
    testing.expect(t,view.info.encoding==.File && .Stream in view.info.flags && len(view.lossless)==0 && mem.compare(view.file,file)==0)

    refuse :: proc(t:^testing.T,types:^Types,desc:Sound_Desc,what:string) {
        doc:Document
        testing.expect(t,sound_document(&doc,types,desc)==.Invalid && doc.tables==nil,what)
    }
    refuse(t,&types,{channels=3,sample_rate=48000,frames=160,lossless=lossless},"three channels")
    refuse(t,&types,{channels=2,sample_rate=0,frames=480,lossless=lossless},"no sample rate")
    refuse(t,&types,{channels=2,sample_rate=48000,frames=480,lossless=lossless[1:]},"lossless data without its magic")
    refuse(t,&types,{channels=2,sample_rate=48000,frames=480,lossless=lossless,file=file},"both a file and lossless data")
    refuse(t,&types,{channels=1,sample_rate=48000,file=file[4:]},"a file that is neither WAV nor Ogg")

    kind,found:=kind_of_extension("hud/main.ui")
    testing.expect(t,found && kind==KIND_UI)
    kind,found=kind_of_extension("step.sound")
    testing.expect(t,found && kind==KIND_SOUND)
    info,known:=kind_info(KIND_ANIMATION)
    testing.expect(t,known && info.extension==".anim")
}

@(test)
animation_cooks_its_clips_into_samples_that_play_as_the_runtime_compresses_them :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    types:Types;types_init(&types);defer types_destroy(&types)
    storage:Test_Animation
    desc:=test_animation(&storage)
    COUNT :: 31
    hips,leg:[COUNT]anim.Keyframe
    for k in 0..<COUNT {
        phase:=f32(k)/30
        hips[k]={time=phase,value=anim.quat_vec4(math.quat_axis_angle({1,0,0},cmath.sin(phase*6)*.5))}
        leg[k]={time=phase,value={0,-.4,cmath.sin(phase*4)*.05,0}}
    }
    walk:=[2]Animation_Track_Desc{{target="hips",property=.Rotation,keys=hips[:]},{target="hips/leg",property=.Position,keys=leg[:]}}
    clips:=[3]Animation_Clip_Desc{storage.clips[0],storage.clips[1],{name="walk",tracks=walk[:]}}
    desc.clips=clips[:]
    doc:Document
    testing.expect_value(t,animation_document(&doc,&types,desc),Error.None)
    w:serial.Writer;serial.writer_init(&w);defer serial.writer_destroy(&w)
    testing.expect_value(t,document_write(&doc,&w),Error.None)
    document_destroy(&doc)
    a:Asset
    testing.expect_value(t,asset_open(&a,serial.writer_bytes(&w)),Error.None)
    defer asset_close(&a)
    view,_:=animation_view(&a,&types)
    parents,_:=animation_parents(view,context.temp_allocator)
    testing.expect(t,parents[0]==1 && parents[1]==-1 && parents[3]==-1 && parents[4]==3)
    lib:anim.Library
    testing.expect(t,anim.library_init(&lib,animation_library_desc(view)))
    defer anim.library_destroy(&lib)
    testing.expect_value(t,animation_clips_add(view,&lib),anim.Clip(1))
    stats,compressed:=animation_compress(view,&lib,&types)
    testing.expect(t,compressed==.None && stats.sampled_tracks>=2 && stats.error<=anim.COMPRESS_DEFAULT.precision)

    testing.expect_value(t,animation_cooked_document(&doc,&types,desc.id,{},view,&lib),Error.None)
    cooked_bytes:serial.Writer;serial.writer_init(&cooked_bytes);defer serial.writer_destroy(&cooked_bytes)
    testing.expect_value(t,document_write(&doc,&cooked_bytes),Error.None)
    document_destroy(&doc)
    cooked:Asset
    testing.expect_value(t,asset_open(&cooked,serial.writer_bytes(&cooked_bytes)),Error.None)
    defer asset_close(&cooked)
    cooked_view,error:=animation_view(&cooked,&types)
    testing.expect_value(t,error,Error.None)
    testing.expect(t,cooked_view.tracks[3].encoding==.Sampled && cooked_view.tracks[4].encoding==.Sampled && len(cooked_view.keys)<len(view.keys))
    _,editable:=animation_descs(cooked_view,context.temp_allocator)
    testing.expect(t,!editable)
    played:anim.Library
    testing.expect(t,anim.library_init(&played,animation_library_desc(cooked_view)))
    defer anim.library_destroy(&played)
    testing.expect_value(t,animation_clips_add(cooked_view,&played),anim.Clip(1))
    _,prepared:=animation_compress(cooked_view,&played,&types)
    testing.expect(t,prepared==.None && played.prepared)
    for clip in 1..=3 {
        testing.expect_value(t,anim.clip_duration(&played,anim.Clip(clip)),anim.clip_duration(&lib,anim.Clip(clip)))
        for track,i in anim.clip_tracks(&played,anim.Clip(clip)) {
            for step in 0..=90 {
                time:=f32(step)/45
                testing.expect_value(t,anim.clip_evaluate(&played,track,time),anim.clip_evaluate(&lib,anim.clip_tracks(&lib,anim.Clip(clip))[i],time))
            }
        }
    }
    // A stream that contradicts itself or lacks its padding does not open.
    streams:=slice.clone(cooked_view.streams,context.temp_allocator)
    rate:=transmute([4]u8)u32(0x7fc00000)
    copy(streams[cooked_view.clips[0].stream+8:],rate[:])
    broken:=cooked_view;broken.streams=streams
    testing.expect(t,!animation_check(broken))
    broken.streams=cooked_view.streams[:len(cooked_view.streams)-anim.STREAM_PADDING]
    testing.expect(t,!animation_check(broken))
}
