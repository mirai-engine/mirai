package sources

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:strings"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:std/base"

// A source cut at any length, or with any byte changed, is either imported or
// refused: never a crash and never a leak (the runner checks the memory). A
// large source is cut at a thousand lengths, as it is changed at a thousand bytes.
@(private="file")
survives :: proc(t:^testing.T,source:string,extension:string,options:importer.Import_Options,formats:[]importer.Format=nil,every_length:=true) {
    formats:=formats if formats!=nil else FORMATS[:]
    bytes,error:=os.read_entire_file(source,context.temp_allocator)
    if !testing.expectf(t,error==nil,"%s cannot be read",source) {return}
    _,folder:=test_project(t,fmt.tprintf("fuzz-%s",filepath.stem(source)))
    if folder=="" {return}
    path:=fmt.tprintf("%s/subject%s",folder,extension)
    imported,refused:=0,0
    attempt :: proc(path:string,data:[]u8,options:importer.Import_Options,formats:[]importer.Format,imported,refused:^int) {
        if os.write_entire_file(path,data)!=nil {return}
        model,error:=importer.import_model(path,formats,options)
        if error.code==.None {
            importer.model_destroy(&model)
            imported^+=1
        } else {refused^+=1}
    }
    for length:=0;length<len(bytes);length+=1 if every_length else 1+len(bytes)/1000 {attempt(path,bytes[:length],options,formats,&imported,&refused)}
    mutated:=make([]u8,len(bytes),context.temp_allocator)
    for position:=0;position<len(bytes);position+=1+len(bytes)/1000 {
        copy(mutated,bytes)
        mutated[position]~=0xff
        attempt(path,mutated,options,formats,&imported,&refused)
        copy(mutated,bytes)
        mutated[position]=0
        attempt(path,mutated,options,formats,&imported,&refused)
    }
    testing.expectf(t,refused>0,"%s: some of the %d damaged files are refused",source,imported+refused)
}

@(test)
damaged_glb_files_are_imported_or_refused :: proc(t:^testing.T) {
    survives(t,FIXTURES+"hierarchy.glb",".glb",{})
    survives(t,FIXTURES+"skeletal-analytic.glb",".glb",{})
    survives(t,FIXTURES+"mesh2motion-human/walk.glb",".glb",{},every_length=false)
}

@(test)
damaged_fbx_files_are_imported_or_refused :: proc(t:^testing.T) {
    survives(t,FIXTURES+"hierarchy.fbx",".fbx",{})
    survives(t,FIXTURES+"hierarchy-ascii.fbx",".fbx",{})
    survives(t,FIXTURES+"skinned.fbx",".fbx",{})
    survives(t,FIXTURES+"inherit.fbx",".fbx",{})
}

@(test)
damaged_obj_and_usda_files_are_imported_or_refused :: proc(t:^testing.T) {
    survives(t,FIXTURES+"concave.obj",".obj",{})
    text:=text_formats()
    survives(t,FIXTURES+"hierarchy.usda",".usda",{},text[:])
}

@(test)
damaged_gltf_text_is_imported_or_refused :: proc(t:^testing.T) {
    survives(t,FIXTURES+"hierarchy.gltf",".gltf",{})
    survives(t,FIXTURES+"animation.gltf",".gltf",{})
}

// Sounds and images, by the bytes of their file: a WAV, an Ogg Vorbis and a
// PNG cut at lengths spread over them, or with bytes changed, are built or
// refused. What is built is checked as the asset it would be.
@(private="file")
sound_survives :: proc(t:^testing.T,name:string,bytes:[]u8) {
    built,refused:=0,0
    attempt :: proc(data:[]u8,built,refused:^int) {
        for storage in ([]importer.Sound_Storage{.Decoded,.Stream}) {
            // The file kept is the one decoded: what it accepts is the same.
            desc,error:=importer.sound_build(data,{storage=storage},.File if storage==.Stream else .Lossless)
            if error!=.None {
                refused^+=1
                continue
            }
            built^+=1
            delete(desc.lossless)
        }
    }
    attempt(bytes,&built,&refused)
    testing.expectf(t,built==2,"%s: the sound as it is is built, decoded and as a stream",name)
    step:=max(len(bytes)/400,1)
    for length:=0;length<len(bytes);length+=step {attempt(bytes[:length],&built,&refused)}
    changed:=make([]u8,len(bytes))
    defer delete(changed)
    state:=u64(0xa4093822299f31d0)
    for round in 0..<400 {
        copy(changed,bytes)
        // Half the rounds change the head, where the format is described.
        span:=round%2==0?min(len(bytes),256):len(bytes)
        for _ in 0..<1+round%3 {
            state=state*6364136223846793005+1442695040888963407
            changed[int((state>>33)%u64(span))]=round%5==0?0xff:u8(state>>24)
        }
        attempt(changed,&built,&refused)
    }
    testing.expectf(t,refused>0,"%s: some of the %d damaged sounds are refused",name,built+refused)
}

@(test)
damaged_wav_and_ogg_files_are_built_or_refused :: proc(t:^testing.T) {
    wav,read_error:=os.read_entire_file(DEMO+"showcase/hum.wav",context.allocator)
    if testing.expect(t,read_error==nil,"the WAV of the demo is read") {
        // Its head and its first samples: the rest is more of the same.
        sound_survives(t,"hum.wav",wav[:min(len(wav),8192)])
        delete(wav)
    }
    sound_survives(t,"sine.ogg",#load("../../../audio/testdata/sine_mono.ogg"))
}

@(test)
damaged_images_and_settings_are_imported_or_refused :: proc(t:^testing.T) {
    root,folder:=test_project(t,"fuzz-image")
    if folder=="" {return}
    png:=png_bytes(8,8,{200,120,60},true)
    path:=fmt.tprintf("%s/subject.png",folder)
    imported,refused:=0,0
    options:=test_options(t,path,{root=root,image=.Color,ignore_stored=true})
    attempt :: proc(path:string,options:importer.Import_Options,data:[]u8,imported,refused:^int) {
        if os.write_entire_file(path,data)!=nil {return}
        report,error:=importer.import_texture(path,options)
        if error.code==.None {
            importer.report_destroy(&report)
            imported^+=1
        } else {refused^+=1}
    }
    attempt(path,options,png,&imported,&refused)
    testing.expect_value(t,imported,1)
    for length in 0..<len(png) {attempt(path,options,png[:length],&imported,&refused)}
    changed:=make([]u8,len(png),context.temp_allocator)
    for position in 0..<len(png) {
        copy(changed,png)
        changed[position]~=0xff
        attempt(path,options,changed,&imported,&refused)
    }
    testing.expectf(t,refused>len(png)/2,"%d of %d damaged images are refused",refused,imported+refused)
}

// Fonts and manifests of prompts, cut at lengths spread over them or with
// bytes changed, are imported or refused.
@(test)
damaged_fonts_and_prompts_are_imported_or_refused :: proc(t:^testing.T) {
    _,folder:=test_project(t,"fuzz-interface")
    if folder=="" {return}
    _=os.write_entire_file(fmt.tprintf("%s/a.png",folder),png_bytes(8,8,{200,120,60},true))
    Subject :: struct {file:string,data:[]u8}
    subjects:=[?]Subject{
        {"subject.otf",#load("../../../assets/fixtures/cff.otf")},
        {"subject.prompts.json",transmute([]u8)string(`{"entries": [{"family": "Xbox", "input": "South", "image": "a.png"}, {"family": "Keyboard", "input": "Key", "key": "Space", "image": "a.png"}]}`)},
    }
    for subject in subjects {
        path:=fmt.tprintf("%s/%s",folder,subject.file)
        imported,refused:=0,0
        options:=test_options(t,path)
        attempt :: proc(path:string,options:importer.Import_Options,data:[]u8,imported,refused:^int) {
            if os.write_entire_file(path,data)!=nil {return}
            report,error:=import_source(path,options)
            if error.code==.None {
                importer.report_destroy(&report)
                imported^+=1
            } else {refused^+=1}
        }
        attempt(path,options,subject.data,&imported,&refused)
        testing.expectf(t,imported==1,"%s as it is is imported",subject.file)
        step:=max(len(subject.data)/200,1)
        for length:=0;length<len(subject.data);length+=step {attempt(path,options,subject.data[:length],&imported,&refused)}
        changed:=make([]u8,len(subject.data),context.temp_allocator)
        for position:=0;position<len(subject.data);position+=step {
            copy(changed,subject.data)
            changed[position]~=0xff
            attempt(path,options,changed,&imported,&refused)
            copy(changed,subject.data)
            changed[position]=0
            attempt(path,options,changed,&imported,&refused)
        }
        testing.expectf(t,refused>0 && imported>1,"%s: %d damaged files imported and %d refused",subject.file,imported-1,refused)
    }
}
