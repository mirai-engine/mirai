package editor

import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "mirai:cook/import/sources"
import "mirai:cook/textures"
import "mirai:editor/acp"
import "mirai:host"
import "mirai:platform"
import "mirai:std/base"
import "mirai:ui"

// The reference images of a message: images the user attaches to the next
// message to show what they want, dropped on the chat or chosen with the
// button of the composer. When the message is sent each one is written to
// the folder of its turn as reference-<n>.jpg, no larger than
// AI_REFERENCE_SIDE, and goes to the agent with the message itself, after
// its text.

// Whether a file is an image a message can take.
ai_reference_image :: proc(path:string) -> bool {
    extension:=strings.to_lower(filepath.ext(path),context.temp_allocator)
    for known in sources.IMAGE_EXTENSIONS {if known==extension {return true}}
    return false
}

// Attaches an image to the next message.
ai_reference_add :: proc(s:^Session,path:string) {
    m:=s.ai
    if m==nil {return}
    if !ai_reference_image(path) {notify(s,"A reference is an image: PNG, JPEG, TGA, BMP, GIF or PSD");return}
    if !os.is_file(path) {notify(s,"The image could not be found");return}
    for i in 0..<m.reference_count {if base.text_get(m.references[i][:])==path {return}}
    if m.reference_count>=AI_REFERENCES {notify(s,fmt.tprintf("A message takes at most %d reference images",AI_REFERENCES));return}
    if len(path)>=AI_PATH_BYTES {notify(s,"The path of the image is too long");return}
    base.text_set(m.references[m.reference_count][:],path)
    m.reference_count+=1
    m.focus=true
}

@(private)
ai_reference_remove :: proc(m:^Ai,index:int) {
    if index<0 || index>=m.reference_count {return}
    copy(m.references[index:m.reference_count-1],m.references[index+1:m.reference_count])
    m.reference_count-=1
}

// The dialog that asks for an image to attach.
@(private)
ai_reference_ask :: proc(s:^Session) {
    images:=strings.builder_make(context.temp_allocator)
    extensions:=sources.IMAGE_EXTENSIONS
    filters:=[?]platform.Dialog_Filter{{"Images",dialog_patterns(extensions[:],&images)}}
    if !platform.dialog_show(s.app.platform,{kind=.Open_File,tag=DIALOG_AI_REFERENCE,filters=filters[:]}) {notify(s,"A file dialog is already open")}
}

@(private)
ai_reference_rows :: proc(s:^Session,width:f32) -> int {
    m:=s.ai
    if m.reference_count==0 {return 0}
    ctx:=s.gui.ctx
    used:=f32(0);rows:=1
    for i in 0..<m.reference_count {
        size:=ai_chip_width(ctx,filepath.base(base.text_get(m.references[i][:])),width)
        if used>0 && used+size>width {rows+=1;used=0}
        used+=size+5
    }
    return rows
}

// The reference images of the next message as chips; taking one out detaches it.
@(private)
ai_references_build :: proc(s:^Session,width:f32,rows:int) {
    if rows<=0 {return}
    m:=s.ai;ctx:=s.gui.ctx
    remove:=-1
    used:=f32(0);row:=0
    for i in 0..<m.reference_count {
        path:=base.text_get(m.references[i][:])
        label:=filepath.base(path)
        size:=ai_chip_width(ctx,label,width)
        if used>0 && used+size>width {ui.box_end(ctx,{});row+=1;used=0}
        if row>=rows {break}
        if used==0 {ui.box_begin(ctx,{width=ui.GROW,height=ui.fixed(AI_CHIP_HEIGHT),gap=5,align_y=.Center})}
        if ui.box(ctx,{width=ui.fixed(size),height=ui.fixed(AI_CHIP_HEIGHT),padding={5,0,5,0},gap=4,align_y=.Center,fill=ui.tone(ctx,"field"),radius=ui.metric(ctx,"radius_control")}) {
            ui.icon(ctx,.Texture,ui.tone(ctx,"text_muted"),12)
            ui.label(ctx,ai_chat_menu_label(ctx,label,max(size-AI_CHIP_ROOM-AI_CHIP_PIN_ROOM,1),ui.metric(ctx,"font_small")),ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"),size-40-AI_CHIP_PIN_ROOM)
            ai_chip_pin(s,ui.id(ctx,"pin_reference",i+1),AI_PIN_IMAGE,path,label)
            if ui.button(ctx,ui.id(ctx,"remove_reference",i+1),{icon=.Cross,icon_color=ui.tone(ctx,"text_muted"),icon_size=10,padding=-1,variant="ghost",width=12,height=12}).clicked {remove=i}
        }
        used+=size+5
    }
    if used>0 {ui.box_end(ctx,{})}
    ai_reference_remove(m,remove)
}

// Writes the reference images of the next message to the folder of the
// task, each made smaller, keeping its proportion, until it fits a square of
// AI_REFERENCE_SIDE; a job compresses each one as a JPEG. Returns how many it
// started; one it cannot read is left out and said.
@(private)
ai_references_write :: proc(s:^Session,m:^Ai,task:^Ai_Task) -> int {
    written:=0
    for i in 0..<m.reference_count {
        path:=base.text_get(m.references[i][:])
        data,read:=os.read_entire_file(path,context.temp_allocator)
        if read!=nil {notify(s,fmt.tprintf("%s could not be read",filepath.base(path)));continue}
        image,error:=textures.image_decode(data,context.temp_allocator)
        if error!=.None {notify(s,fmt.tprintf("%s is not an image the editor reads",filepath.base(path)));continue}
        width,height:=ai_fit_size(image.width,image.height,AI_REFERENCE_SIDE)
        owned:=make([]u8,width*height*4,s.app.allocator)
        ai_fit_pixels(image.pixels,image.width,image.height,owned,width,height)
        write:=&task.reference_writes[written]
        host.app_png_write_wait(s.app,write)
        written+=1
        host.app_png_write_start(s.app,write,ai_task_path(s,task,ai_reference_file(written)),owned,width,height,AI_REFERENCE_QUALITY)
    }
    return written
}

// The size of an image of width by height made smaller, keeping its
// proportion, until it fits a square of side; never larger than it was.
ai_fit_size :: proc "contextless" (width,height,side:int) -> (w,h:int) {
    longest:=max(width,height)
    if longest<=side {return width,height}
    return max(width*side/longest,1),max(height*side/longest,1)
}

// An image of four bytes per pixel made smaller into out, of width by height:
// each pixel of out is the mean of the pixels of the image it covers.
ai_fit_pixels :: proc "contextless" (pixels:[]u8,source_width,source_height:int,out:[]u8,width,height:int) {
    for y in 0..<height {
        y0:=y*source_height/height
        y1:=max((y+1)*source_height/height,y0+1)
        for x in 0..<width {
            x0:=x*source_width/width
            x1:=max((x+1)*source_width/width,x0+1)
            sum:[4]int
            for sy in y0..<y1 {
                for sx in x0..<x1 {
                    at:=(sy*source_width+sx)*4
                    for c in 0..<4 {sum[c]+=int(pixels[at+c])}
                }
            }
            count:=(y1-y0)*(x1-x0)
            for c in 0..<4 {out[(y*width+x)*4+c]=u8((sum[c]+count/2)/count)}
        }
    }
}

// The file of the index-th reference image of a turn, from 1.
@(private)
ai_reference_file :: proc(index:int) -> string {return fmt.tprintf("reference-%d.jpg",index)}

// The reference images of a turn as blocks of its prompt, after its text:
// each one waits for its write. False with what failed when one cannot go.
@(private)
ai_references_content :: proc(s:^Session,task:^Ai_Task,content:^[dynamic]acp.Content) -> (problem:string,ok:bool) {
    for i in 0..<task.references {
        if error:=host.app_png_write_wait(s.app,&task.reference_writes[i]);error!=nil && !os.is_file(ai_task_path(s,task,ai_reference_file(i+1))) {return fmt.tprintf("A reference image could not be written: %s",os.error_string(error)),false}
        data,error:=os.read_entire_file(ai_task_path(s,task,ai_reference_file(i+1)),context.temp_allocator)
        if error!=nil {return "A reference image could not be read",false}
        encoded,encode_error:=base64.encode(data,allocator=context.temp_allocator)
        if encode_error!=.None {return "A reference image could not be encoded",false}
        append(content,acp.Content{kind=.Image,data=encoded,mime_type="image/jpeg"})
    }
    return "",true
}
