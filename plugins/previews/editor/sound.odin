package previews_editor

import "core:fmt"
import "mirai:asset"
import mixer "mirai:audio"
import "mirai:editor"
import "mirai:host"
import "mirai:std/base"
import "mirai:ui"

// The documents of sounds. That of a .sound shows the shape of its wave and
// what it is: its length, its channels, its sample rate and whether it is
// decoded while it plays. That of a .sound_set shows its sounds with their
// weights and the ranges of volume and pitch it draws from, as rows of
// Details; what they change is written into the .sound_set, in memory and
// unsaved, once the UI lets go of it: a step of the history of the document
// each time. Play, in the toolbar of both, plays it to be heard, and a set
// chooses one of its sounds each time.

WAVE_WIDTH :: 1024
WAVE_HEIGHT :: 256
WAVE_WINDOW :: f32(0.02) // s
SOUND_WIDTH :: f32(320)
SCOPE_SOUND :: ui.Id(0x736f756e)
KEY_SOUND_SET :: u64(0x736f756e64736574)

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
    p.scroll=0
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
    th:=&s.gui.ctx.theme
    field,wave,middle:=th.field,editor.asset_color(asset.KIND_SOUND),th.border
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
    g:=s.gui;ctx:=g.ctx;th:=&ctx.theme
    rect,found:=editor.asset_toolbar(g)
    if !found || rect.w<=0 {return}
    if ui.box(ctx,{width=ui.fixed(rect.w),height=ui.fixed(rect.h),padding={12,0,0,0},gap=8,align_y=.Center,float={to=.Surface,offset={rect.x,rect.y},layer=ui.LAYER_BAR}}) {
        ui.id_push(ctx,ui.id_derive(ctx,DOCUMENT_SCOPE,"sound_bar"))
        defer ui.id_pop(ctx)
        if ui.box(ctx,{width=ui.fixed(1),height=ui.fixed(18),fill=th.border}) {}
        heard:=editor.sound_heard(s,p.id)
        if ui.button(ctx,ui.id(ctx,"play"),{icon=heard?.Stop:.Play,tip=heard?"Stop sound":"Play sound",style=.Tab,active=heard,width=26,height=th.control,disabled=m==nil || !p.read}).clicked {
            if heard {
                editor.sound_hear_stop(s)
            } else if !editor.sound_hear(s,p.id) {
                editor.notify(s,"It did not play: the sound does not load, or a set has no sound that does")
            }
        }
    }
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
                if editor.asset_column_begin(ctx,ui.GROW,"Chances") {
                    if p.read {sound_set_chances(s,assets,p)}
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
    th:=&ctx.theme
    stored:="Decoded while it plays" if .Stream in p.info.flags else "Decoded whole when it loads"
    facts:=[4][2]string{
        {"Length",fmt.tprintf("%.2f s",p.seconds)},
        {"Channels",p.info.channels==2?"Stereo":"Mono"},
        {"Sample rate",fmt.tprintf("%d Hz",p.info.sample_rate)},
        {"Stored",stored},
    }
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,gap=3,padding={8,8,10,8}}) {
        for fact in facts {
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.row),gap=8,align_y=.Center}) {
                ui.label(ctx,fact[0],th.font_small,th.text_muted,th.label_width)
                ui.label(ctx,fact[1],th.font_small,th.text)
            }
        }
    }
}

// How often each sound of the set plays, by the weights the rows hold.
@(private)
sound_set_chances :: proc(s:^editor.Session,assets:^host.Assets,p:^Sound) {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    total:=f32(0)
    for variation in p.held.sounds {
        if variation.sound!={} {total+=variation.weight>0?variation.weight:1}
    }
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,gap=3,padding={8,8,10,8}}) {
        for variation in p.held.sounds {
            if variation.sound=={} {continue}
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.row),gap=8,align_y=.Center}) {
                ui.icon(ctx,.Sound,editor.asset_color(asset.KIND_SOUND),13)
                ui.label(ctx,editor.asset_name_of(assets,variation.sound),th.font_small,th.text)
                ui.spacer(ctx)
                ui.label(ctx,fmt.tprintf("%.0f %%",100*(variation.weight>0?variation.weight:1)/total),th.font_small,th.text_muted)
            }
        }
    }
}

// The sounds of the set up to the last one it has and a free entry after it,
// each with its weight and the x that takes it out; then its ranges.
@(private)
sound_set_rows :: proc(s:^editor.Session,p:^Sound) {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    used:=0
    for variation,i in p.held.sounds {
        if variation!={} {used=i+1}
    }
    removed:=-1
    for i in 0..<min(used+1,asset.SOUND_SET_CAPACITY) {
        variation:=editor.Held_Values{key=KEY_SOUND_SET+u64(i+1),info=type_info_of(asset.Sound_Variation),value=&p.held.sounds[i],defaults=&p.base.sounds[i]}
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=2,align_y=.Start}) {
            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,gap=3}) {
                editor.held_field_row(s,variation,"sound",fmt.tprintf("Sound %d",i+1))
                if p.held.sounds[i].sound!={} {editor.held_field_row(s,variation,"weight")}
            }
            if i<used && ui.button(ctx,ui.id(ctx,"remove",i+1),{icon=.Cross,style=.Ghost,width=th.row,height=th.row}).clicked {removed=i}
        }
    }
    if removed>=0 {
        copy(p.held.sounds[removed:],p.held.sounds[removed+1:])
        p.held.sounds[asset.SOUND_SET_CAPACITY-1]={}
    }
    ui.spacer(ctx,1,6)
    values:=editor.Held_Values{key=KEY_SOUND_SET,info=type_info_of(asset.Sound_Set_Info),value=&p.held,defaults=&p.base}
    for field in ([5]string{"volume_min","volume_max","pitch_min","pitch_max","no_repeat"}) {editor.held_field_row(s,values,field)}
    hearing:=editor.Held_Values{key=KEY_SOUND_SET+asset.SOUND_SET_CAPACITY+1,info=type_info_of(asset.Sound_Hearing),value=&p.held.hearing,defaults=&p.base.hearing}
    for field in ([6]string{"attenuation","min_distance","max_distance","rolloff","reverb","priority"}) {editor.held_field_row(s,hearing,field)}
}
