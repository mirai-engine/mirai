package terrain_editor

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "mirai:core"
import "mirai:cook/textures"
import "mirai:editor"
import "mirai:host"
import "mirai:platform"
import terrain "plugins:terrain/runtime"
import "mirai:std/serial"
import "mirai:editor/kit"
import "mirai:ui"

// The heightmap of a Heightfield after it is made: Import puts the heights of
// a file in it, scaled and offset as Create does, and Export writes them,
// from the lowest to the highest as a 16-bit PNG or R16, or as they are as
// R32, whose scale and offset the fields take, so that importing it again
// gives them back. A weightmap is the weight of one layer, from 0 to 1, in
// the same formats. Resize gives it other samples around its center: what it
// had stays in place.

@(private) REIMPORT_DIALOG :: u32(0x74657269)
@(private) EXPORT_DIALOG :: u32(0x74657265)
@(private) WEIGHTS_IMPORT_DIALOG :: u32(0x74657769)
@(private) WEIGHTS_EXPORT_DIALOG :: u32(0x74657765)
@(private,rodata) HEIGHTMAP_FILTERS := [?]platform.Dialog_Filter{{"Heightmap","png;tga;bmp;r16;raw;r32"}}
@(private,rodata) EXPORT_FILTERS := [?]platform.Dialog_Filter{{"PNG","png"},{"R16","r16"},{"R32","r32"}}
@(private) HEIGHTMAP_FORMATS :: "a heightmap is a .png, .tga or .bmp image, a .r16 or .raw of 16 bits or a .r32 of 32-bit floats"

// The scale and offset a heightmap of 0 to 1 takes.
@(private)
heightmap_fields :: proc(s:^editor.Session,tool:^Terrain_Tool) {
    ctx:=s.gui.ctx
    scale,offset:=f64(tool.height_scale),f64(tool.height_offset)
    if kit.property(ctx,"Height scale") {if ui.number_field(ctx,ui.id(ctx,"height_scale"),&scale,{width=ui.fixed(FIELD_WIDTH),min=0,max=100000,has_min=true,has_max=true,speed=0.1,unit="m"}).changed {tool.height_scale=f32(scale)}}
    if kit.property(ctx,"Height offset") {if ui.number_field(ctx,ui.id(ctx,"height_offset"),&offset,{width=ui.fixed(FIELD_WIDTH),min= -100000,max=100000,has_min=true,has_max=true,speed=0.1,unit="m"}).changed {tool.height_offset=f32(offset)}}
}

@(private)
heightmap_dialog :: proc(s:^editor.Session,tool:^Terrain_Tool,app:^host.App,tag:u32) {
    saving:=tag==EXPORT_DIALOG || tag==WEIGHTS_EXPORT_DIALOG
    kind:=saving?platform.Dialog_Kind.Save_File:.Open_File
    filters:=saving?EXPORT_FILTERS[:]:HEIGHTMAP_FILTERS[:]
    if !platform.dialog_show(app.platform,{kind=kind,tag=tag,filters=filters,location=s.assets_root}) {editor.notify(s,"A file dialog is already open")}
}

// The answer of a dialog of the heightmap of the selected terrain, in the frame it arrives.
@(private)
terrain_heightmap_dialogs :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,app:^host.App) {
    if app.platform==nil {return}
    result:=platform.dialog_result(app.platform)
    if result.state!=.Accepted || result.path=="" || tool.stroke.id=={} || tool.stroke.active {return}
    switch result.tag {
    case REIMPORT_DIALOG:       heightmap_import(s,tool,world,app.assets,result.path)
    case EXPORT_DIALOG:         heightmap_export(s,tool,result.path)
    case WEIGHTS_IMPORT_DIALOG: weightmap_import(s,tool,world,app.assets,result.path,tool.layer)
    case WEIGHTS_EXPORT_DIALOG: weightmap_export(s,tool,result.path,tool.layer)
    }
}

// The values of a file of heights, in the format its extension names.
@(private)
heightmap_read :: proc(s:^editor.Session,path:string,allocator:=context.temp_allocator) -> (heightmap:textures.Heightmap,ok:bool) {
    format,known:=textures.heightmap_format(path)
    if !known {editor.notify(s,fmt.tprintf("%s: %s",filepath.base(path),HEIGHTMAP_FORMATS));return}
    bytes,error:=serial.file_read(path,context.temp_allocator,limit=i64(textures.heightmap_bytes_max(terrain.SAMPLES_MAX)))
    if error!=.None {editor.notify(s,fmt.tprintf("The heightmap %s could not be read: %v",path,error));return}
    decode:textures.Error
    heightmap,decode=textures.heightmap_decode(bytes,terrain.SAMPLES_MAX,allocator,format)
    switch decode {
    case .None: return heightmap,true
    case .Too_Large: editor.notify(s,fmt.tprintf("The heightmap %s has more than %d samples a side",filepath.base(path),terrain.SAMPLES_MAX))
    case .Invalid: editor.notify(s,fmt.tprintf("The heightmap %s is not a square of 16-bit or 32-bit values, or holds one that is not a number",filepath.base(path)))
    case .Out_Of_Memory: editor.notify(s,"There is not enough memory for the heightmap")
    case .Unsupported: editor.notify(s,fmt.tprintf("The heightmap %s is not an image it reads: %s",filepath.base(path),HEIGHTMAP_FORMATS))
    }
    return
}

// The heights of a heightmap scaled and offset into a Heightfield of its size.
@(private)
heights_take :: proc(s:^editor.Session,source:^terrain.Source,heightmap:^textures.Heightmap,scale,offset:f32) -> bool {
    if !terrain.grid_prepare(&source.field,{},{heightmap.width-1,0,heightmap.height-1},source.allocator) {editor.notify(s,"There is not enough memory for the heightmap");return false}
    for value,i in heightmap.values {
        height:=value*scale+offset
        if !(abs(height)<=terrain.HEIGHT_LIMIT) {editor.notify(s,"Heightmap heights exceed the terrain limit: give a smaller scale or offset");return false}
        terrain.grid_set(&source.field,i%heightmap.width,i/heightmap.width,height)
    }
    return true
}

// The heights of a heightmap in the Heightfield of the stroke as one step of undo:
// one of another size gives the terrain its size, with its layers and without
// what was painted or cut.
heightmap_import :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,assets:^host.Assets,path:string) -> bool {
    stroke:=&tool.stroke
    if stroke.id=={} || stroke.active || stroke.source.kind!=.Heightfield {return false}
    heightmap:=heightmap_read(s,path) or_return
    if !stroke_baseline(tool) {editor.notify(s,"The terrain history could not be stored");return false}
    next:terrain.Source
    defer terrain.source_destroy(&next)
    same:=int(stroke.source.samples.x)==heightmap.width && int(stroke.source.samples.z)==heightmap.height
    if same {
        if !terrain.source_clone(&next,&stroke.source,stroke.source.allocator) {editor.notify(s,"There is not enough memory for the heightmap");return false}
    } else {
        if !terrain.source_make(&next,.Heightfield,{heightmap.width,1,heightmap.height},stroke.source.cell,int(stroke.source.chunk_cells),stroke.source.allocator) {editor.notify(s,"The heightmap dimensions exceed their budget");return false}
        next.layers_material=stroke.source.layers_material
        for i in 0..<int(stroke.source.layer_count) {terrain.source_layer_set(&next,i,stroke.source.layers[i])}
        next.revision=stroke.source.revision
    }
    if !heights_take(s,&next,&heightmap,tool.height_scale,tool.height_offset) {return false}
    // A swap by single stores until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
    previous:=stroke.source
    stroke.source=next
    next=previous
    stroke.changed,stroke.dirty_all=true,true
    stroke_end(s,tool,world,assets,label="Import heightmap")
    // Another size: the previews are made again for it.
    if !same {stroke_free(tool)}
    return true
}

// Writes values of the selected Heightfield, rows from its first z, in the
// format of the extension of path (none: a PNG).
@(private)
heightmap_write :: proc(s:^editor.Session,path:string,values:[]f32,width,height:int,format:textures.Heightmap_Format) -> (file:string,ok:bool) {
    bytes,encode:=textures.heightmap_encode(values,width,height,context.temp_allocator,format)
    if encode==.Invalid {editor.notify(s,fmt.tprintf("A .r16 or .r32 is square and this terrain has %d by %d samples: export a .png",width,height));return}
    if encode!=.None {editor.notify(s,"There is not enough memory for the heightmap");return}
    file=path
    if filepath.ext(file)=="" {file=fmt.tprintf("%s.png",file)}
    if serial.file_write_atomic(file,bytes)!=.None {editor.notify(s,fmt.tprintf("The heightmap %s could not be written",file));return}
    return file,true
}

@(private)
export_format :: proc(s:^editor.Session,path:string) -> (format:textures.Heightmap_Format,ok:bool) {
    if filepath.ext(path)=="" {return .Image,true}
    format,ok=textures.heightmap_format(path)
    if !ok || format==.Image && !strings.equal_fold(filepath.ext(path),".png") {editor.notify(s,fmt.tprintf("%s: it writes a .png, .r16 or .r32",filepath.base(path)));return .Image,false}
    return
}

// The heights of the selected Heightfield: a PNG or R16 from its lowest to
// its highest, whose range the scale and offset fields take, or an R32 of the
// heights as they are, with a scale of 1 and no offset.
heightmap_export :: proc(s:^editor.Session,tool:^Terrain_Tool,path:string) -> bool {
    stroke:=&tool.stroke
    if stroke.id=={} || stroke.source.kind!=.Heightfield {return false}
    format:=export_format(s,path) or_return
    source:=&stroke.source
    width,height:=int(source.samples.x),int(source.samples.z)
    low,high:=f32(max(f32)),f32(-max(f32))
    for z in 0..<height {for x in 0..<width {h:=terrain.grid_get(&source.field,x,z);low,high=min(low,h),max(high,h)}}
    span:=max(high-low,1e-6)
    if format==.R32 {low,span=0,1}
    values,error:=make([]f32,width*height,context.temp_allocator)
    if error!=nil {editor.notify(s,"There is not enough memory for the heightmap");return false}
    for z in 0..<height {for x in 0..<width {values[x+width*z]=(terrain.grid_get(&source.field,x,z)-low)/span}}
    file:=heightmap_write(s,path,values,width,height,format) or_return
    tool.height_scale,tool.height_offset=format==.R32?1:high-low,low
    editor.notify(s,fmt.tprintf("Heightmap written: %s, heights %.2f to %.2f m",filepath.base(file),low,format==.R32?high:low+span))
    return true
}

// The weight of a layer of the selected Heightfield from 0 to 1, in the
// format of the extension of path.
weightmap_export :: proc(s:^editor.Session,tool:^Terrain_Tool,path:string,layer:int) -> bool {
    stroke:=&tool.stroke
    if stroke.id=={} || stroke.source.kind!=.Heightfield || layer<0 || layer>=int(stroke.source.layer_count) {return false}
    format:=export_format(s,path) or_return
    source:=&stroke.source
    width,height:=int(source.samples.x),int(source.samples.z)
    values,error:=make([]f32,width*height,context.temp_allocator)
    if error!=nil {editor.notify(s,"There is not enough memory for the weightmap");return false}
    for z in 0..<height {for x in 0..<width {values[x+width*z]=terrain.weights_float(terrain.grid_get(&source.weights,x,z))[layer]}}
    file:=heightmap_write(s,path,values,width,height,format) or_return
    editor.notify(s,fmt.tprintf("Weightmap written: %s",filepath.base(file)))
    return true
}

// Each sample of a layer takes the weight of a weightmap of the size of the
// terrain, from 0 to 1, as one step of undo: the other layers keep their
// shares of what is left.
weightmap_import :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,assets:^host.Assets,path:string,layer:int) -> bool {
    stroke:=&tool.stroke
    if stroke.id=={} || stroke.active || stroke.source.kind!=.Heightfield || layer<0 || layer>=int(stroke.source.layer_count) {return false}
    weightmap:=heightmap_read(s,path) or_return
    width,height:=int(stroke.source.samples.x),int(stroke.source.samples.z)
    if weightmap.width!=width || weightmap.height!=height {editor.notify(s,fmt.tprintf("A weightmap has the samples of its terrain, %d by %d, and this one has %d by %d",width,height,weightmap.width,weightmap.height));return false}
    if !stroke_baseline(tool) {editor.notify(s,"The terrain history could not be stored");return false}
    weights:=&stroke.source.weights
    if !terrain.grid_prepare(weights,{},{width-1,0,height-1},stroke.source.allocator) {editor.notify(s,"There is not enough memory for the weightmap");return false}
    count:=int(stroke.source.layer_count)
    for value,i in weightmap.values {
        x,z:=i%width,i/width
        old:=terrain.grid_get(weights,x,z)
        target:=clamp(value-value==0?value:0,0,1)
        current:=terrain.weights_float(old)[layer]
        amount:=target>current?(target-current)/max(1-current,1e-6):-(current-target)/max(current,1e-6)
        terrain.grid_set(weights,x,z,terrain.weights_paint(old,layer,amount,count))
    }
    stroke.changed,stroke.dirty_all=true,true
    stroke_end(s,tool,world,assets,label="Import weightmap")
    return true
}

// The samples Resize gives, on each side an even number more or less than
// the terrain has: its center stays a sample.
@(private)
resize_fields :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,assets:^host.Assets) {
    ctx:=s.gui.ctx
    stroke:=&tool.stroke
    current:=[2]int{int(stroke.source.samples.x),int(stroke.source.samples.z)}
    for &n,axis in tool.resize {if n<2 {n=current[axis]}}
    x,z:=f64(tool.resize.x),f64(tool.resize.y)
    if kit.property(ctx,"Samples X") {if ui.number_field(ctx,ui.id(ctx,"resize_x"),&x,{width=ui.fixed(FIELD_WIDTH),min=3,max=f64(terrain.SAMPLES_MAX),has_min=true,has_max=true,speed=1,integer=true}).changed {tool.resize.x=resize_even(int(x),current.x)}}
    if kit.property(ctx,"Samples Z") {if ui.number_field(ctx,ui.id(ctx,"resize_z"),&z,{width=ui.fixed(FIELD_WIDTH),min=3,max=f64(terrain.SAMPLES_MAX),has_min=true,has_max=true,speed=1,integer=true}).changed {tool.resize.y=resize_even(int(z),current.y)}}
    if tool.resize!=current && ui.button(ctx,ui.id(ctx,"resize"),{label="Resize",variant="field",width=-1,center=true}).clicked {terrain_resize(s,tool,world,assets,tool.resize)}
}

@(private)
resize_even :: proc "contextless" (wanted,current:int) -> int {
    n:=clamp(wanted,3,terrain.SAMPLES_MAX)
    if (n-current)%2!=0 {n+=n<terrain.SAMPLES_MAX?1:-1}
    return n
}

// Resize as one step of undo.
terrain_resize :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,assets:^host.Assets,samples:[2]int) -> bool {
    stroke:=&tool.stroke
    if stroke.id=={} || stroke.active || stroke.source.kind!=.Heightfield {return false}
    next:terrain.Source
    defer terrain.source_destroy(&next)
    if !terrain.source_resize(&next,&stroke.source,samples,stroke.source.allocator) {editor.notify(s,"The terrain cannot take that size: an even number of samples more or less on each side, within the budget");return false}
    if !stroke_baseline(tool) {editor.notify(s,"The terrain history could not be stored");return false}
    previous:=stroke.source
    stroke.source=next
    next=previous
    stroke.changed,stroke.dirty_all=true,true
    stroke_end(s,tool,world,assets,label="Resize terrain")
    stroke_free(tool)
    tool.resize={}
    return true
}
