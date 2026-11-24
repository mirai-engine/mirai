package previews_editor

import "core:fmt"
import "mirai:asset"
import mixer "mirai:audio"
import "mirai:editor"
import eaudio "mirai:engine/audio"
import "mirai:host"
import "mirai:std/base"
import "mirai:ui"

// The documents of sounds. That of a .sound shows the shape of its wave and
// what it is: its length, its channels, its sample rate and whether it is
// decoded while it plays. That of a .sound_set shows its mode, its sounds
// with their weights, the ranges of volume and pitch it draws from, its
// parameters and the curves they move, as rows of Details; what they change
// is written into the .sound_set once the UI lets go of it: a step of the
// history of the document each time. Beside them, how often each sound plays
// (Random) or the gain of each layer (Layered) at the values of a slider per
// parameter. Play, in the toolbar of both, plays it to be heard: a set
// chooses one of its sounds each time, or plays its layers in step, and loops
// while it has parameters, so the sliders are heard as they move.

WAVE_WIDTH :: 1024
WAVE_HEIGHT :: 256
WAVE_WINDOW :: f32(0.02) // s
SOUND_WIDTH :: f32(320)
SCOPE_SOUND :: ui.Id(0x736f756e)
KEY_SOUND_SET :: u64(0x736f756e64736574)
KEY_PARAMETERS :: u64(64)   // after KEY_SOUND_SET: the keys of its parameters
KEY_CURVES :: u64(128)      // after KEY_SOUND_SET: 8 keys per curve, its own and those of its points
LAYER_BAR :: f32(96)        // of the gain of a layer

Sound :: struct {
    image:editor.Asset_Image,
    id:base.Asset_Id,
    kind:asset.Fourcc,
    read:bool,
    revision:u64,            // of the assets when it was read
    info:asset.Sound_Info,   // of a .sound
    seconds:f32,
    peaks:[WAVE_WIDTH][2]f32, // the lowest and the highest sample under each column of the wave
    file:asset.Sound_Set_Info, // of a .sound_set, as its file holds it
    held:asset.Sound_Set_Info, // file with the edits of the rows, until they are written
    base:asset.Sound_Set_Info, // what the file held when the document read it: the arrows of the rows give it back
    scroll:[2]f32,
    preview:[asset.SOUND_SET_PARAMETERS]f64, // the value of each parameter Play is heard at
    pixels:[dynamic]u8,
}

@(private)
sound_destroy :: proc(p:^Sound) {
    delete(p.pixels)
}

@(private)
sound_subject :: proc(p:^Sound,id:base.Asset_Id,kind:asset.Fourcc) {
    p.id,p.kind,p.read=id,kind,false
    p.info,p.seconds,p.peaks={},0,{}
    p.file,p.held,p.base={},{},{}
    p.scroll,p.preview=0,{}
    p.image.signature=0
}

// The lowest and the highest sample around each column, over at least
// WAVE_WINDOW seconds: a wave whose period is longer than a column is drawn
// as its envelope instead of the stripes of what each column caught of it.
@(private)
peaks_fill :: proc(peaks:^[WAVE_WIDTH][2]f32,samples:[]$T,channels,rate:int,scale:f32) {
    peaks^={}
    frames:=len(samples)/max(channels,1)
    if frames==0 {return}
    half:=max(frames/WAVE_WIDTH,int(f32(rate)*WAVE_WINDOW))/2+1
    for &peak,column in peaks {
        center:=(2*column+1)*frames/(2*WAVE_WIDTH)
        low,high:=f32(1),f32(-1)
        for frame in max(center-half,0)..<min(center+half,frames) {
            for channel in 0..<channels {
                v:=f32(samples[frame*channels+channel])*scale
                low,high=min(low,v),max(high,v)
            }
        }
        if low<=high {peak={clamp(low,-1,1),clamp(high,-1,1)}}
    }
}

// Reads the file of the subject again when the assets change. The edits of a
// set the rows hold stay over what its file says now.
@(private)
sound_sync :: proc(s:^editor.Session,assets:^host.Assets,p:^Sound) {
    a:=assets
    if p.id=={} || a==nil {return}
    record,found:=asset.registry_find(&a.registry,p.id)
    if !found || record.kind!=p.kind {
        sound_subject(p,{},0)
        return
    }
    if p.read && p.revision==a.revision {return}
    p.revision=a.revision
    file:asset.Asset
    if !editor.asset_read(s,record.path,&file) {return}
    defer asset.asset_close(&file)
    switch p.kind {
    case asset.KIND_SOUND:
        view,error:=asset.sound_view(&file,&a.types)
        if error!=.None {return}
        p.info=view.info^
        if pcm,decoded:=mixer.decode(view.lossless if view.info.encoding==.Lossless else view.file,context.allocator);decoded==.None {
            peaks_fill(&p.peaks,pcm.samples,pcm.channels,pcm.sample_rate,1)
            p.seconds=f32(len(pcm.samples)/max(pcm.channels,1))/f32(max(pcm.sample_rate,1))
            mixer.pcm_destroy(&pcm,context.allocator)
        }
        p.image.signature=0
    case asset.KIND_SOUND_SET:
        view,error:=asset.sound_set_view(&file,&a.types)
        if error!=.None {return}
        now:=view.info^
        if !p.read || p.held==p.file {p.held=now}
        if !p.read {p.base=now}
        p.file=now
    }
    p.read=true
}

// The wave on the CPU, in the color of a sound over that of a field.
@(private)
sound_wave :: proc(s:^editor.Session,p:^Sound) {
    if !p.read || p.kind!=asset.KIND_SOUND {return}
    signature:=signature_of({p.id[0],p.id[1],p.revision})
    if p.image.signature==signature {return}
    if len(p.pixels)!=WAVE_WIDTH*WAVE_HEIGHT*4 && resize(&p.pixels,WAVE_WIDTH*WAVE_HEIGHT*4)!=nil {return}
    field,wave,middle:=ui.tone(s.gui.ctx,"field"),editor.asset_color(asset.KIND_SOUND),ui.tone(s.gui.ctx,"border")
    for x in 0..<WAVE_WIDTH {
        peak:=p.peaks[x]
        top:=int((1-peak[1])*0.5*f32(WAVE_HEIGHT-1)+0.5)
        bottom:=int((1-peak[0])*0.5*f32(WAVE_HEIGHT-1)+0.5)
        for y in 0..<WAVE_HEIGHT {
            color:=field
            if y==WAVE_HEIGHT/2 {color=middle}
            if peak!={} && y>=top && y<=bottom {color=wave}
            pixel:=p.pixels[(y*WAVE_WIDTH+x)*4:][:4]
            pixel[0],pixel[1],pixel[2],pixel[3]=color.r,color.g,color.b,255
        }
    }
    editor.asset_image_pixels(s,&p.image,p.pixels[:],WAVE_WIDTH,WAVE_HEIGHT,signature)
}

// Play or stop, in the room the toolbar leaves the document.
@(private)
sound_bar :: proc(s:^editor.Session,m:^mixer.Mixer,p:^Sound) {
    g:=s.gui;ctx:=g.ctx
    rect,found:=editor.asset_toolbar(g)
    if !found || rect.w<=0 {return}
    if ui.box(ctx,{width=ui.fixed(rect.w),height=ui.fixed(rect.h),padding={12,0,0,0},gap=8,align_y=.Center,float={to=.Surface,offset={rect.x,rect.y},layer=ui.LAYER_BAR}}) {
        ui.id_push(ctx,ui.id_derive(ctx,DOCUMENT_SCOPE,"sound_bar"))
        defer ui.id_pop(ctx)
        if ui.box(ctx,{width=ui.fixed(1),height=ui.fixed(18),fill=ui.tone(s.gui.ctx,"border")}) {}
        heard:=editor.sound_heard(s,p.id)
        if ui.button(ctx,ui.id(ctx,"play"),{icon=heard?.Stop:.Play,tip=heard?"Stop sound":"Play sound",variant="tab",active=heard,width=26,height=ui.metric(s.gui.ctx,"control"),disabled=m==nil || !p.read}).clicked {
            if heard {
                editor.sound_hear_stop(s)
            } else if !editor.sound_hear_source(s,sound_heard_as(p)) {
                editor.notify(s,"It did not play: the sound does not load, or a set has no sound that does")
            }
        }
    }
}

// How Play hears the subject: on the master bus at the values of the
// sliders, looping a set that has parameters so they can be moved while it plays.
@(private)
sound_heard_as :: proc(p:^Sound) -> eaudio.Audio_Source {
    source:=eaudio.AUDIO_SOURCE_DEFAULT
    source.sound,source.bus=p.id,eaudio.BUS_MASTER
    if p.kind!=asset.KIND_SOUND_SET {return source}
    for value,i in p.preview {source.parameters[i]=f32(value)}
    source.loop=sound_set_named(&p.held)>0
    return source
}

// The parameters of a set that have a name.
@(private)
sound_set_named :: proc(info:^asset.Sound_Set_Info) -> (count:int) {
    for &parameter in info.parameters {
        if base.text_get(parameter.name[:])!="" {count+=1}
    }
    return
}

@(private)
sound_document :: proc(s:^editor.Session,previews:^Previews,assets:^host.Assets,m:^mixer.Mixer,d:^editor.Asset_Document) {
    p:=&previews.sound
    g:=s.gui
    ctx:=g.ctx
    if p.id!=d.id || p.kind!=d.kind {sound_subject(p,d.id,d.kind)}
    sound_sync(s,assets,p)
    sound_bar(s,m,p)
    id:=ui.id_derive(ctx,DOCUMENT_SCOPE,"sound")
    if ui.panel(ctx,id,editor.asset_workspace(g)) {
        ui.id_push(ctx,id)
        defer ui.id_pop(ctx)
        ui.id_push(ctx,SCOPE_SOUND)
        defer ui.id_pop(ctx)
        if ui.box(ctx,{width=ui.GROW,height=ui.GROW}) {
            if p.kind==asset.KIND_SOUND {
                if editor.asset_column_begin(ctx,ui.GROW,"Wave") {
                    editor.asset_image_show(s,&p.image)
                    editor.asset_column_end(ctx)
                }
                editor.asset_column_divider(ctx)
                if editor.asset_column_begin(ctx,ui.fixed(SOUND_WIDTH),"Sound") {
                    if p.read {sound_facts(s,p)}
                    editor.asset_column_end(ctx)
                }
            } else {
                if editor.asset_column_begin(ctx,ui.GROW,"Layers" if p.held.mode==.Layered else "Chances") {
                    if p.read {
                        if p.held.mode==.Layered {sound_set_layers(s,assets,p)} else {sound_set_chances(s,assets,p)}
                        sound_set_sliders(s,p)
                    }
                    editor.asset_column_end(ctx)
                }
                editor.asset_column_divider(ctx)
                if editor.asset_column_begin(ctx,ui.fixed(SOUND_WIDTH),"Sound set") {
                    if p.read {
                        if ui.scroll_area(ctx,ui.id(ctx,"rows"),&p.scroll,{width=ui.GROW,height=ui.GROW,direction=.Column,gap=3,padding={8,8,10,8}}) {sound_set_rows(s,p)}
                    }
                    editor.asset_column_end(ctx)
                }
            }
        }
    }
    // What the rows changed goes to the file once nothing holds it.
    if p.kind==asset.KIND_SOUND_SET && p.read && ctx.active==0 && ctx.edit.id==0 && ctx.popup.count==0 && p.held!=p.file {
        if editor.sound_set_write(s,p.id,p.held) {p.file=p.held} else {p.held=p.file}
    }
    sound_wave(s,p)
}

// What a .sound is, a line each.
@(private)
sound_facts :: proc(s:^editor.Session,p:^Sound) {
    ctx:=s.gui.ctx
    stored:="Decoded while it plays" if .Stream in p.info.flags else "Decoded whole when it loads"
    facts:=[4][2]string{
        {"Length",fmt.tprintf("%.2f s",p.seconds)},
        {"Channels",p.info.channels==2?"Stereo":"Mono"},
        {"Sample rate",fmt.tprintf("%d Hz",p.info.sample_rate)},
        {"Stored",stored},
    }
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,gap=3,padding={8,8,10,8}}) {
        for fact in facts {
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=8,align_y=.Center}) {
                ui.label(ctx,fact[0],ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"),ui.metric(ctx,"label_width"))
                ui.label(ctx,fact[1],ui.metric(ctx,"font_small"),ui.tone(ctx,"text"))
            }
        }
    }
}

// How often each sound of the set plays, by the weights the rows hold, or
// when each starts, of a set that plays all.
@(private)
sound_set_chances :: proc(s:^editor.Session,assets:^host.Assets,p:^Sound) {
    ctx:=s.gui.ctx
    total:=f32(0)
    for variation in p.held.sounds {
        if variation.sound!={} {total+=variation.weight>0?variation.weight:1}
    }
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,gap=3,padding={8,8,10,8}}) {
        for variation in p.held.sounds {
            if variation.sound=={} {continue}
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=8,align_y=.Center}) {
                ui.icon(ctx,.Sound,editor.asset_color(asset.KIND_SOUND),13)
                ui.label(ctx,editor.asset_name_of(assets,variation.sound),ui.metric(ctx,"font_small"),ui.tone(ctx,"text"))
                ui.spacer(ctx)
                chance:=fmt.tprintf("+%.0f ms",1000*variation.delay) if p.held.mode==.Layered else fmt.tprintf("%.0f %%",100*(variation.weight>0?variation.weight:1)/total)
                ui.label(ctx,chance,ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))
            }
        }
    }
}

// Each layer of a Layered set with its gain at the values of the sliders, and
// its low-pass when a curve gives it one.
@(private)
sound_set_layers :: proc(s:^editor.Session,assets:^host.Assets,p:^Sound) {
    ctx:=s.gui.ctx
    values:[asset.SOUND_SET_PARAMETERS]f32
    for value,i in p.preview {values[i]=f32(value)}
    small:=ui.metric(ctx,"font_small")
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,gap=3,padding={8,8,10,8}}) {
        for variation,i in p.held.sounds {
            if variation.sound=={} {continue}
            shape:=asset.sound_set_shape(&p.held,i,values)
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=8,align_y=.Center}) {
                ui.icon(ctx,.Sound,editor.asset_color(asset.KIND_SOUND),13)
                ui.label(ctx,editor.asset_name_of(assets,variation.sound),small,ui.tone(ctx,"text"))
                ui.spacer(ctx)
                if variation.delay>0 {ui.label(ctx,fmt.tprintf("+%.0f ms",1000*variation.delay),small,ui.tone(ctx,"text_muted"))}
                if shape.lowpass>0 {ui.label(ctx,fmt.tprintf("%.0f Hz",shape.lowpass),small,ui.tone(ctx,"text_muted"))}
                if shape.pitch!=1 {ui.label(ctx,fmt.tprintf("x%.2f",shape.pitch),small,ui.tone(ctx,"text_muted"))}
                gain:=clamp(shape.gain,0,1)
                if ui.box(ctx,{width=ui.fixed(LAYER_BAR),height=ui.fixed(4),fill=ui.tone(ctx,"field"),radius=1}) {
                    if gain>0 {
                        if ui.box(ctx,{width=ui.fixed(gain*LAYER_BAR),height=ui.GROW,fill=ui.tone(ctx,"accent"),radius=1}) {}
                    }
                }
                ui.label(ctx,fmt.tprintf("%.0f %%",100*shape.gain),small,ui.tone(ctx,"text_muted"),40)
            }
        }
    }
}

// A slider per parameter with a name, over the values its curves span (0 to 1
// without curves): what Play is heard at, retuned as it moves.
@(private)
sound_set_sliders :: proc(s:^editor.Session,p:^Sound) {
    ctx:=s.gui.ctx
    if sound_set_named(&p.held)==0 {return}
    small:=ui.metric(ctx,"font_small")
    moved:=false
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,gap=3,padding={8,4,10,8}}) {
        ui.label(ctx,"Parameters",small,ui.tone(ctx,"text_muted"))
        for &parameter,i in p.held.parameters {
            name:=base.text_get(parameter.name[:])
            if name=="" {continue}
            low,high:=f64(0),f64(1)
            first:=true
            for c in p.held.curves {
                if int(c.parameter)!=i+1 || c.count==0 {continue}
                a,b:=f64(c.points[0].at),f64(c.points[min(int(c.count),asset.SOUND_CURVE_POINTS)-1].at)
                low,high=(a if first else min(low,a)),(b if first else max(high,b))
                first=false
            }
            if high<=low {high=low+1}
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=8,align_y=.Center}) {
                ui.label(ctx,name,small,ui.tone(ctx,"text"),ui.metric(ctx,"label_width"))
                if ui.slider(ctx,ui.id(ctx,"preview",i),&p.preview[i],{min=low,max=high}).changed {moved=true}
                if ui.number_field(ctx,ui.id(ctx,"preview_value",i),&p.preview[i],{width=ui.fixed(64),decimals=2,speed=(high-low)/200}).changed {moved=true}
            }
        }
    }
    if moved && editor.sound_heard(s,p.id) {editor.sound_hear_tune(s,sound_heard_as(p))}
}

// The rows of the set: its mode; its sounds up to the last one it has and a
// free entry after it, each with its weight (Random) or delay (Layered), gain
// and pitch and the x that takes it out; its ranges and hearing; its
// parameters and its curves, each up to the last one it has and a free one
// after it.
@(private)
sound_set_rows :: proc(s:^editor.Session,p:^Sound) {
    ctx:=s.gui.ctx
    values:=editor.Held_Values{key=KEY_SOUND_SET,info=type_info_of(asset.Sound_Set_Info),value=&p.held,defaults=&p.base,width=SOUND_WIDTH}
    editor.held_field_row(s,values,"mode")
    random:=p.held.mode==.Random
    used:=0
    for variation,i in p.held.sounds {
        if variation!={} {used=i+1}
    }
    removed:=-1
    for i in 0..<min(used+1,asset.SOUND_SET_CAPACITY) {
        variation:=editor.Held_Values{key=KEY_SOUND_SET+u64(i+1),info=type_info_of(asset.Sound_Variation),value=&p.held.sounds[i],defaults=&p.base.sounds[i]}
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=2,align_y=.Start}) {
            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,gap=3}) {
                editor.held_field_row(s,variation,"sound",fmt.tprintf("Layer %d",i+1) if !random else fmt.tprintf("Sound %d",i+1))
                if p.held.sounds[i].sound!={} {
                    editor.held_field_row(s,variation,"weight" if random else "delay")
                    editor.held_field_row(s,variation,"gain")
                    editor.held_field_row(s,variation,"pitch")
                }
            }
            if i<used && ui.button(ctx,ui.id(ctx,"remove",i+1),{icon=.Cross,variant="ghost",width=ui.metric(ctx,"row"),height=ui.metric(ctx,"row")}).clicked {removed=i}
        }
    }
    if removed>=0 {
        copy(p.held.sounds[removed:],p.held.sounds[removed+1:])
        p.held.sounds[asset.SOUND_SET_CAPACITY-1]={}
        // The curves of the layers after it follow it; those of it go.
        for &c in p.held.curves {
            if int(c.layer)==removed+1 {c={}} else if int(c.layer)>removed+1 {c.layer-=1}
        }
    }
    ui.spacer(ctx,1,6)
    ranges:=[5]string{"volume_min","volume_max","pitch_min","pitch_max","no_repeat"}
    for field in ranges[:5 if random else 4] {editor.held_field_row(s,values,field)}
    hearing:=editor.Held_Values{key=KEY_SOUND_SET+asset.SOUND_SET_CAPACITY+1,info=type_info_of(asset.Sound_Hearing),value=&p.held.hearing,defaults=&p.base.hearing}
    for field in ([6]string{"attenuation","min_distance","max_distance","rolloff","reverb","priority"}) {editor.held_field_row(s,hearing,field)}
    ui.spacer(ctx,1,6)
    sound_set_parameter_rows(s,p)
    ui.spacer(ctx,1,6)
    sound_set_curve_rows(s,p)
}

// A parameter: its name and its glide.
@(private)
sound_set_parameter_rows :: proc(s:^editor.Session,p:^Sound) {
    ctx:=s.gui.ctx
    used:=0
    for parameter,i in p.held.parameters {
        if parameter!={} {used=i+1}
    }
    removed:=-1
    for i in 0..<min(used+1,asset.SOUND_SET_PARAMETERS) {
        values:=editor.Held_Values{key=KEY_SOUND_SET+KEY_PARAMETERS+u64(i),info=type_info_of(asset.Sound_Parameter),value=&p.held.parameters[i],defaults=&p.base.parameters[i]}
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=2,align_y=.Start}) {
            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,gap=3}) {
                editor.held_field_row(s,values,"name",fmt.tprintf("Parameter %d",i+1))
                if p.held.parameters[i]!={} {editor.held_field_row(s,values,"glide")}
            }
            if i<used && ui.button(ctx,ui.id(ctx,"remove_parameter",i+1),{icon=.Cross,variant="ghost",width=ui.metric(ctx,"row"),height=ui.metric(ctx,"row")}).clicked {removed=i}
        }
    }
    if removed>=0 {
        // Its curves go with it; there is no gap left for those of the others to follow.
        p.held.parameters[removed]={}
        p.preview[removed]=0
        for &c in p.held.curves {
            if int(c.parameter)==removed+1 {c={}}
        }
    }
}

// A curve: the parameter it follows, its target, the layer it shapes and its points.
@(private)
sound_set_curve_rows :: proc(s:^editor.Session,p:^Sound) {
    ctx:=s.gui.ctx
    used:=0
    for c,i in p.held.curves {
        if c!={} {used=i+1}
    }
    removed:=-1
    for i in 0..<min(used+1,asset.SOUND_SET_CURVES) {
        c:=&p.held.curves[i]
        values:=editor.Held_Values{key=KEY_SOUND_SET+KEY_CURVES+u64(i)*8,info=type_info_of(asset.Sound_Curve),value=c,defaults=&p.base.curves[i],width=SOUND_WIDTH}
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=2,align_y=.Start}) {
            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,gap=3}) {
                editor.held_field_row(s,values,"parameter",fmt.tprintf("Curve %d",i+1))
                if c.parameter!=0 {
                    // A curve that starts following a parameter starts flat at no change.
                    if c.count==0 {curve_flat(c)}
                    prev_target:=c.target
                    for field in ([3]string{"target","layer","count"}) {editor.held_field_row(s,values,field)}
                    if c.target!=prev_target {curve_clamp_target(c,p.held.mode)}
                    for k in 0..<clamp(int(c.count),0,asset.SOUND_CURVE_POINTS) {
                        point:=editor.Held_Values{key=KEY_SOUND_SET+KEY_CURVES+u64(i)*8+u64(k)+1,info=type_info_of(asset.Sound_Curve_Point),value=&c.points[k],defaults=&p.base.curves[i].points[k]}
                        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=4}) {
                            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,gap=3}) {
                                editor.held_field_row(s,point,"at",fmt.tprintf("Point %d at",k+1))
                                editor.held_field_row(s,point,"value",curve_value_label(c.target))
                            }
                        }
                    }
                }
            }
            if i<used && ui.button(ctx,ui.id(ctx,"remove_curve",i+1),{icon=.Cross,variant="ghost",width=ui.metric(ctx,"row"),height=ui.metric(ctx,"row")}).clicked {removed=i}
        }
    }
    if removed>=0 {
        copy(p.held.curves[removed:],p.held.curves[removed+1:])
        p.held.curves[asset.SOUND_SET_CURVES-1]={}
    }
}

// Two points that change nothing over 0 to 1.
@(private)
curve_flat :: proc(c:^asset.Sound_Curve) {
    unchanged:=asset.SOUND_LOWPASS_MAX if c.target==.Lowpass else 1
    c.count=2
    c.points[0],c.points[1]={0,unchanged},{1,unchanged}
}

// Brings points within what a target accepts after switching target.
@(private)
curve_clamp_target :: proc(c:^asset.Sound_Curve,mode:asset.Sound_Set_Mode) {
    if mode==.Layered && c.target==.Pitch {c.layer=0}
    for &p in c.points[:clamp(int(c.count),0,asset.SOUND_CURVE_POINTS)] {
        switch c.target {
        case .Gain:
            if p.value<0 {p.value=1}
        case .Pitch:
            if !(p.value>0) || p.value>asset.SOUND_SET_PITCH_MAX {p.value=1}
        case .Lowpass:
            if !(p.value>0) {p.value=asset.SOUND_LOWPASS_MAX}
        }
    }
}

@(private)
curve_value_label :: proc(target:asset.Sound_Curve_Target) -> string {
    switch target {
    case .Gain:return "Gain"
    case .Pitch:return "Pitch"
    case .Lowpass:return "Low-pass Hz"
    }
    return "Value"
}
