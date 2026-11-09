package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "mirai:cook/image"
import "mirai:editor/api"
import "mirai:project"

CAPTURE_USAGE :: "capture [project] [--out x.png] [--scene S] [--camera-entity NAME | --position x,y,z --target x,y,z] [--fov F] [--size WxH] [--frames N] [--view MODE] [--reference ref.png] [--threshold SSIM] [--repeat] [--dev|--release]\n       capture [project] --plan [--views a,b] [--references DIR] [--write] [--repeat] [--dev|--release]"

// mirai capture: one image of the world of a project as the editor draws it,
// without its UI, from a camera of the scene or a pose, with the validation
// errors and the console of the editor, and the statistics of the image
// against a reference when there is one. It uses the session of the project
// (mirai session), or opens one for the capture and closes it. Exit 1 with
// validation errors or when the image does not reach --threshold (SSIM).
// Each capture starts the clock of the window at zero, so a scene loaded and
// captured again draws the same frames. --repeat loads the scene again and
// captures the same view as the first, and says how much the two differ: what
// is left is what two renderers do not share (the order in which the GI picks
// its probes), and a comparison with the image can trust what is above it.

// Two captures of the same view that differ more than this do not render alike:
// a threshold above their SSIM compares noise.
REPEAT_SSIM :: 0.999

// --plan: the views of CAPTURE_PLAN_FILE of the project, each captured from
// its scene loaded anew, with the validation errors it brought, against its
// reference in --references (bin/references of the project) by the SSIM of
// its threshold. --write makes the references of this build; --repeat
// captures each again from its scene loaded anew, and a threshold above what
// the two give is a problem. Exit 1 with validation errors, a view under its
// threshold or one without a reference.
CAPTURE_PLAN_FILE :: "captures.mirai"

Capture_Plan :: struct {
    size:[2]int,
    frames:int,
    views:[]Capture_View,
}

Capture_View :: struct {
    name,scene:string,
    position,target:[]f64, // none: the camera the scene opens with
    fov:f64,
    threshold:f64,         // SSIM against the reference under which the view fails: under what two captures of it give
}
cmd_capture :: proc(root:string,args:[]string) -> int {
    folder,out,scene,entity,view,reference:=".","","","","",""
    position,target:string
    fov,threshold:f64=0,-1
    width,height,frames:=0,0,64
    mode:Build_Mode=.Keep
    repeat,plan,write:=false,false,false
    views,references:string
    usage :: proc() -> int {fmt.eprintfln("Usage: mirai %s",CAPTURE_USAGE);return 2}
    value :: proc(args:[]string,i:^int) -> (string,bool) {
        if i^+1>=len(args) {return "",false}
        i^+=1
        return args[i^],true
    }
    for i:=0;i<len(args);i+=1 {
        ok:=true
        switch args[i] {
        case "--out":           out,ok=value(args,&i)
        case "--scene":         scene,ok=value(args,&i)
        case "--camera-entity": entity,ok=value(args,&i)
        case "--position":      position,ok=value(args,&i)
        case "--target":        target,ok=value(args,&i)
        case "--view":          view,ok=value(args,&i)
        case "--reference":     reference,ok=value(args,&i)
        case "--fov","--threshold":
            text:string
            text,ok=value(args,&i)
            number,valid:=strconv.parse_f64(text)
            ok&&=valid
            if args[i-1]=="--fov" {fov=number} else {threshold=number}
        case "--frames":
            text:string
            text,ok=value(args,&i)
            frames,ok=strconv.parse_int(text,10)
        case "--size":
            text:string
            text,ok=value(args,&i)
            cut:=strings.index_byte(text,'x')
            if ok && cut>0 {
                w,w_ok:=strconv.parse_int(text[:cut],10)
                h,h_ok:=strconv.parse_int(text[cut+1:],10)
                width,height,ok=w,h,w_ok && h_ok
            } else {ok=false}
        case "--repeat": repeat=true
        case "--plan": plan=true
        case "--write": write=true
        case "--views":      views,ok=value(args,&i)
        case "--references": references,ok=value(args,&i)
        case "--dev":  mode=.Dev
        case "--release": mode=.Release
        case:
            if strings.has_prefix(args[i],"-") || folder!="." {return usage()}
            folder=args[i]
        }
        if !ok {return usage()}
    }
    if plan {
        if out!="" || scene!="" || entity!="" || position!="" || reference!="" || view!="" {fmt.eprintln("mirai capture: --plan takes its views from captures.mirai: leave out --out, --scene, the camera, --view and --reference");return 2}
        return capture_plan(root,folder,mode,views,references,write,repeat)
    }
    if (position=="")!=(target=="") {fmt.eprintln("mirai capture: --position and --target go together");return 2}
    if entity!="" && position!="" {fmt.eprintln("mirai capture: --camera-entity or --position/--target, not both");return 2}
    if !os.is_file(project.path(folder,project.PROJECT_FILE,allocator=context.temp_allocator)) {
        fmt.eprintfln("mirai capture: %s is not a project (%s is missing)",folder,project.PROJECT_FILE)
        return 2
    }
    folder=project.path_absolute(folder)
    out=out!=""?project.path_absolute(out):project.path(folder,".mirai/captures/capture.png")

    file,alive:=session_find(folder)
    reused:=alive && session_answers(file.port)
    if reused && !session_reusable(root,folder,mode,file,"capture") {return 1}
    if !reused {
        code:int
        if file,code=session_open(root,folder,mode,false,180,{});code!=0 {return code}
    }
    defer if !reused {session_close(folder,file,true)}

    call :: proc(port:int,method:string,params:any) -> (result:string,ok:bool) {
        text,_:=json.marshal(params,allocator=context.temp_allocator)
        response,err,called:=api.rpc_call(port,method,string(text),1,600000,context.allocator)
        if !called {fmt.eprintfln("mirai capture: %s: %s",method,api.error_text(err,context.temp_allocator))}
        return response,called
    }
    // The document again, for the second capture of --repeat: its file, unless it has unsaved changes.
    Document :: struct {path:string,dirty:bool}
    document:Document
    if scene=="" && repeat {
        if text,ok:=call(file.port,"scene.inspect",struct{summary:bool,limit:int}{true,1});ok {_=json.unmarshal_string(text,&document,allocator=context.temp_allocator)}
    }
    reload:=scene if scene!="" else (document.dirty?"":document.path)
    if scene!="" {
        if _,ok:=call(file.port,"scene.load",struct{path:string}{scene});!ok {return 1}
    }
    camera:=make(json.Object)
    if entity!="" {camera["entity"]=entity}
    if position!="" {
        p,p_ok:=vector_parse(position)
        t,t_ok:=vector_parse(target)
        if !p_ok || !t_ok {fmt.eprintln("mirai capture: --position and --target are x,y,z");return 2}
        camera["position"]=p
        camera["target"]=t
    }
    if fov>0 {camera["fov"]=fov}
    if len(camera)>0 {
        if _,ok:=call(file.port,"camera.set",camera);!ok {return 1}
    } else if repeat && reload!="" {
        // The camera of the viewport, which the scene loaded again would not keep.
        Pose :: struct {position,target:[3]f64,fov_y:f64}
        pose:Pose
        text,ok:=call(file.port,"camera.set",struct{}{})
        if !ok || json.unmarshal_string(text,&pose,allocator=context.temp_allocator)!=nil {return 1}
        camera["position"]=vector_json(pose.position)
        camera["target"]=vector_json(pose.target)
        camera["fov"]=pose.fov_y
    }
    // The mode the viewport of a session in use showed comes back after the capture.
    Modes :: struct {current:string}
    shown:=Modes{current="lit"}
    if view!="" {
        if reused {
            if text,ok:=call(file.port,"editor.view_mode.list",struct{}{});ok {_=json.unmarshal_string(text,&shown,allocator=context.temp_allocator)}
        }
        if _,ok:=call(file.port,"editor.view_mode.set",struct{mode:string}{view});!ok {return 1}
    }
    Capture :: struct {path,of:string,ui:bool,width,height,frames:int,seconds:f64}
    captured,captured_ok:=call(file.port,"capture",Capture{out,"Scene",false,width,height,frames,0})
    again:=""
    if captured_ok && repeat {
        again=fmt.tprintf("%s.repeat.png",strings.trim_suffix(out,".png"))
        if reload!="" {
            _,captured_ok=call(file.port,"scene.load",struct{path:string}{reload})
            if captured_ok && len(camera)>0 {_,captured_ok=call(file.port,"camera.set",camera)}
        } else {
            fmt.eprintln("mirai capture: the document has unsaved changes or no file: the second capture goes on from the first, with what the GI gathered since")
        }
        if captured_ok {_,captured_ok=call(file.port,"capture",Capture{again,"Scene",false,width,height,frames,0})}
    }
    if view!="" && reused {_,_=call(file.port,"editor.view_mode.set",struct{mode:string}{shown.current})}
    if !captured_ok {return 1}

    Validation :: struct {errors,loader_errors:int,messages:[]string}
    Entry :: struct {level,text:string}
    Console :: struct {entries:[]Entry}
    Diagnostics :: struct {validation:Validation,console:Console}
    diagnostics:Diagnostics
    if text,ok:=call(file.port,"engine.diagnostics",struct{min_level:string,limit:int}{"Warning",20});ok {
        _=json.unmarshal_string(text,&diagnostics,allocator=context.temp_allocator)
    }
    Size :: struct {width,height,textures_pending,instances_drawn,instances_culled,instances_occluded:int}
    size:Size
    _=json.unmarshal_string(captured,&size,allocator=context.temp_allocator)

    Repeat :: struct {png:string,ssim,max_error:f64}
    Report :: struct {
        png:string,
        width,height:int,
        textures_pending,instances_drawn,instances_culled,instances_occluded:int,
        validation_errors,loader_errors:int,
        validation_messages:[]string,
        console:[]Entry,
        stats:image.Image_Stats,
        reference:string,
        diff:Maybe(image.Image_Diff),
        repeat:Maybe(Repeat),
    }
    report:=Report{png=out,width=size.width,height=size.height,textures_pending=size.textures_pending,instances_drawn=size.instances_drawn,instances_culled=size.instances_culled,instances_occluded=size.instances_occluded,validation_errors=diagnostics.validation.errors,loader_errors=diagnostics.validation.loader_errors,validation_messages=diagnostics.validation.messages,console=diagnostics.console.entries,reference=reference}
    picture,load_error:=image.image_load(out)
    if load_error!=nil {fmt.eprintfln("mirai capture: could not read %s: %s",out,image.error_message(load_error));return 1}
    report.stats,_=image.image_stats(picture,{})
    passed:=true
    if reference!="" {
        wanted,wanted_error:=image.image_load(reference)
        if wanted_error!=nil {fmt.eprintfln("mirai capture: could not read %s: %s",reference,image.error_message(wanted_error));return 2}
        diff,diff_error:=image.image_diff(picture,wanted,{})
        if diff_error!=nil {fmt.eprintfln("mirai capture: %s against %s: %s",out,reference,image.error_message(diff_error));return 2}
        report.diff=diff
        if threshold>=0 && diff.ssim<threshold {passed=false}
    }
    if repeat {
        second,second_error:=image.image_load(again)
        if second_error!=nil {fmt.eprintfln("mirai capture: could not read %s: %s",again,image.error_message(second_error));return 1}
        diff,diff_error:=image.image_diff(picture,second,{})
        if diff_error!=nil {fmt.eprintfln("mirai capture: %s against %s: %s",out,again,image.error_message(diff_error));return 1}
        report.repeat=Repeat{again,diff.ssim,diff.max_error}
        if diff.ssim<REPEAT_SSIM {
            fmt.eprintfln("mirai capture: two captures of the same view differ (SSIM %.4f, max error %.0f/255): a threshold above %.4f compares noise",diff.ssim,diff.max_error,diff.ssim)
        }
    }
    text,_:=json.marshal(report,{pretty=true},context.temp_allocator)
    fmt.println(string(text))
    return report.validation_errors>0 || !passed?1:0
}

@(private="file")
vector_json :: proc(v:[3]f64) -> json.Array {
    vector:=make(json.Array,3,context.temp_allocator)
    for value,i in v {vector[i]=value}
    return vector
}

@(private="file")
vector_parse :: proc(text:string) -> (vector:json.Array,ok:bool) {
    parts:=strings.split(text,",",context.temp_allocator)
    if len(parts)!=3 {return}
    vector=make(json.Array,3,context.temp_allocator)
    for part,i in parts {
        number,valid:=strconv.parse_f64(strings.trim_space(part))
        if !valid {return}
        vector[i]=number
    }
    return vector,true
}

// The views of the plan of a project, each against its reference (--plan).
@(private="file")
capture_plan :: proc(root,folder:string,mode:Build_Mode,views,references:string,write,repeat:bool) -> int {
    if !os.is_file(project.path(folder,project.PROJECT_FILE,allocator=context.temp_allocator)) {
        fmt.eprintfln("mirai capture: %s is not a project (%s is missing)",folder,project.PROJECT_FILE)
        return 2
    }
    folder:=project.path_absolute(folder)
    path:=project.path(folder,CAPTURE_PLAN_FILE,allocator=context.temp_allocator)
    data,read_error:=os.read_entire_file(path,context.allocator)
    if read_error!=nil {fmt.eprintfln("mirai capture: %s is missing: the views --plan captures",path);return 2}
    plan:Capture_Plan
    if json.unmarshal(data,&plan)!=nil {fmt.eprintfln("mirai capture: %s is not JSON with size, frames and views",path);return 2}
    if views!="" {
        kept:=make([dynamic]Capture_View)
        for name in strings.split(views,",",context.temp_allocator) {
            found:=false
            for v in plan.views {
                if v.name==name {append(&kept,v);found=true}
            }
            if !found {fmt.eprintfln("mirai capture: %s has no view '%s'",path,name);return 2}
        }
        plan.views=kept[:]
    }
    for v in plan.views {
        if v.name=="" || v.scene=="" || len(v.position)!=len(v.target) || len(v.position)!=0 && len(v.position)!=3 || !(v.threshold>0 && v.threshold<=1) {
            fmt.eprintfln("mirai capture: %s: each view has a name, a scene, a threshold above 0 up to 1, and position and target of three numbers each, or neither",path)
            return 2
        }
    }
    references:=references
    if references=="" {references=project.path(folder,"bin/references",allocator=context.temp_allocator)}
    references=project.path_absolute(references)
    if os.make_directory_all(references)!=nil && !os.is_dir(references) {fmt.eprintfln("mirai capture: %s could not be made",references);return 1}

    file,alive:=session_find(folder)
    reused:=alive && session_answers(file.port)
    if reused && !session_reusable(root,folder,mode,file,"capture") {return 1}
    if !reused {
        code:int
        if file,code=session_open(root,folder,mode,false,180,{});code!=0 {return code}
    }
    defer if !reused {session_close(folder,file,true)}
    call :: proc(port:int,method:string,params:any) -> (result:string,ok:bool) {
        text,_:=json.marshal(params,allocator=context.temp_allocator)
        response,err,called:=api.rpc_call(port,method,string(text),1,600000,context.allocator)
        if !called {fmt.eprintfln("mirai capture: %s: %s",method,api.error_text(err,context.temp_allocator))}
        return response,called
    }
    errors_now :: proc(port:int) -> (count:int,messages:[]string) {
        Validation :: struct {errors:int,messages:[]string}
        Diagnostics :: struct {validation:Validation}
        d:Diagnostics
        if text,ok:=call(port,"engine.diagnostics",struct{min_level:string,limit:int}{"Error",8});ok {_=json.unmarshal_string(text,&d,allocator=context.temp_allocator)}
        return d.validation.errors,d.validation.messages
    }
    // What the renderer counted of a capture.
    Counted :: struct {textures_pending,instances_drawn:int}
    // A capture of the view from its scene loaded anew, the clock at zero.
    shoot :: proc(port:int,plan:Capture_Plan,v:Capture_View,out:string,counted:^Counted=nil) -> bool {
        if _,ok:=call(port,"scene.load",struct{path:string}{v.scene});!ok {return false}
        if len(v.position)==3 {
            camera:=make(json.Object,context.temp_allocator)
            camera["position"]=vector_json({v.position[0],v.position[1],v.position[2]})
            camera["target"]=vector_json({v.target[0],v.target[1],v.target[2]})
            if v.fov>0 {camera["fov"]=v.fov}
            if _,ok:=call(port,"camera.set",camera);!ok {return false}
        }
        Capture :: struct {path,of:string,ui:bool,width,height,frames:int,seconds:f64}
        text,ok:=call(port,"capture",Capture{out,"Scene",false,plan.size.x,plan.size.y,max(plan.frames,1),0})
        if ok && counted!=nil {_=json.unmarshal_string(text,counted,allocator=context.temp_allocator)}
        return ok
    }
    Result :: struct {
        name,png,reference:string,
        validation_errors:int,
        validation_messages:[]string,
        ssim,max_error,threshold,repeat_ssim:f64,
        textures_pending,instances_drawn:int,
        written,passed:bool,
        problem:string,
    }
    results:=make([dynamic]Result)
    failed:=false
    before,_:=errors_now(file.port)
    for v in plan.views {
        r:=Result{name=v.name,threshold=v.threshold}
        r.png,_=strings.replace_all(join(references,fmt.tprintf("%s.capture.png",v.name)),"\\","/")
        r.reference,_=strings.replace_all(join(references,fmt.tprintf("%s.png",v.name)),"\\","/")
        counted:Counted
        if !shoot(file.port,plan,v,r.png,&counted) {return 1}
        r.textures_pending,r.instances_drawn=counted.textures_pending,counted.instances_drawn
        errors,messages:=errors_now(file.port)
        r.validation_errors,r.validation_messages=errors-before,messages
        before=errors
        picture,load_error:=image.image_load(r.png)
        if load_error!=nil {fmt.eprintfln("mirai capture: could not read %s: %s",r.png,image.error_message(load_error));return 1}
        if repeat {
            again:=fmt.tprintf("%s.repeat.png",strings.trim_suffix(r.png,".png"))
            if !shoot(file.port,plan,v,again) {return 1}
            before,_=errors_now(file.port)
            if second,second_error:=image.image_load(again);second_error==nil {
                if diff,diff_error:=image.image_diff(picture,second,{});diff_error==nil {r.repeat_ssim=diff.ssim}
            }
            if r.repeat_ssim>0 && r.repeat_ssim<v.threshold {r.problem=fmt.aprintf("two captures of it give SSIM %.4f, under its threshold %.4f: lower the threshold under what it repeats",r.repeat_ssim,v.threshold)}
        }
        switch {
        case write:
            bytes,_:=os.read_entire_file(r.png,context.temp_allocator)
            r.written=len(bytes)>0 && os.write_entire_file(r.reference,bytes)==nil
            r.passed=r.written && r.validation_errors==0 && r.problem==""
        case !os.is_file(r.reference):
            r.problem="it has no reference: make one with --write from a build whose image is good"
        case:
            wanted,wanted_error:=image.image_load(r.reference)
            if wanted_error!=nil {r.problem=fmt.aprintf("could not read %s: %s",r.reference,image.error_message(wanted_error));break}
            diff,diff_error:=image.image_diff(picture,wanted,{})
            if diff_error!=nil {r.problem=fmt.aprintf("against %s: %s",r.reference,image.error_message(diff_error));break}
            r.ssim,r.max_error=diff.ssim,diff.max_error
            r.passed=diff.ssim>=v.threshold && r.validation_errors==0 && r.problem==""
        }
        extra:=""
        if r.repeat_ssim>0 {extra=fmt.tprintf(", repeat %.4f",r.repeat_ssim)}
        if r.problem!="" {extra=fmt.tprintf("%s: %s",extra,r.problem)}
        against:=fmt.tprintf("SSIM %.4f (threshold %.4f)",r.ssim,v.threshold)
        if write {against=fmt.tprintf("reference written (threshold %.4f)",v.threshold)}
        fmt.eprintfln("mirai capture: %s: %s, %d validation errors, %s%s",v.name,r.passed?"passed":"FAILED",r.validation_errors,against,extra)
        failed||=!r.passed
        append(&results,r)
    }
    text,_:=json.marshal(results[:],{pretty=true},context.temp_allocator)
    fmt.println(string(text))
    return failed?1:0
}
