package terrain_editor

import "core:fmt"
import "core:path/filepath"
import "mirai:core"
import "mirai:cook/textures"
import "mirai:editor"
import "mirai:host"
import "mirai:platform"
import terrain "plugins:terrain/runtime"
import "mirai:std/serial"
import "mirai:ui"

// The heightmap of a Heightfield after it is made: Import puts the heights of
// an image in it, scaled and offset as Create does, and Export writes its
// heights as a 16-bit PNG from the lowest to the highest, whose scale and
// offset the fields take, so that importing it again gives them back. Resize
// gives it other samples around its center: what it had stays in place.

@(private) REIMPORT_DIALOG :: u32(0x74657269)
@(private) EXPORT_DIALOG :: u32(0x74657265)

// The scale and offset a heightmap of 0 to 1 takes.
@(private)
heightmap_fields :: proc(s:^editor.Session,tool:^Terrain_Tool) {
    ctx:=s.gui.ctx
    scale,offset:=f64(tool.height_scale),f64(tool.height_offset)
    if ui.property(ctx,"Height scale") {if ui.number_field(ctx,ui.id(ctx,"height_scale"),&scale,{width=ui.fixed(FIELD_WIDTH),min=0,max=100000,has_min=true,has_max=true,speed=0.1,unit="m"}).changed {tool.height_scale=f32(scale)}}
    if ui.property(ctx,"Height offset") {if ui.number_field(ctx,ui.id(ctx,"height_offset"),&offset,{width=ui.fixed(FIELD_WIDTH),min= -100000,max=100000,has_min=true,has_max=true,speed=0.1,unit="m"}).changed {tool.height_offset=f32(offset)}}
}

@(private)
heightmap_dialog :: proc(s:^editor.Session,tool:^Terrain_Tool,app:^host.App,tag:u32) {
    kind:=tag==EXPORT_DIALOG?platform.Dialog_Kind.Save_File:.Open_File
    filters:=tag==EXPORT_DIALOG?[]platform.Dialog_Filter{{"PNG","png"}}:[]platform.Dialog_Filter{{"Heightmap","png;tga;bmp"}}
    if !platform.dialog_show(app.platform,{kind=kind,tag=tag,filters=filters,location=s.assets_root}) {editor.notify(s,"A file dialog is already open")}
}

// The answer of a dialog of the heightmap of the selected terrain, in the frame it arrives.
@(private)
terrain_heightmap_dialogs :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,app:^host.App) {
    if app.platform==nil {return}
    result:=platform.dialog_result(app.platform)
    if result.state!=.Accepted || result.path=="" || tool.stroke.id=={} || tool.stroke.active {return}
    switch result.tag {
    case REIMPORT_DIALOG: heightmap_import(s,tool,world,app.assets,result.path)
    case EXPORT_DIALOG:   heightmap_export(s,tool,result.path)
    }
}

// The heights of a heightmap in the Heightfield of the stroke as one step of undo:
// one of another size gives the terrain its size, with its layers and without
// what was painted or cut.
heightmap_import :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,assets:^host.Assets,path:string) -> bool {
    stroke:=&tool.stroke
    if stroke.id=={} || stroke.active || stroke.source.kind!=.Heightfield {return false}
    bytes,error:=serial.file_read(path,context.temp_allocator,limit=64*1024*1024)
    if error!=.None {editor.notify(s,fmt.tprintf("The heightmap %s could not be read: %v",path,error));return false}
    heightmap,decode:=textures.heightmap_decode(bytes,terrain.HEIGHT_SAMPLES_MAX,context.temp_allocator)
    if decode!=.None {editor.notify(s,fmt.tprintf("Heightmap: %v",decode));return false}
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
    if !terrain.grid_prepare(&next.heights,{},{heightmap.width-1,0,heightmap.height-1},next.allocator) {editor.notify(s,"There is not enough memory for the heightmap");return false}
    for value,i in heightmap.values {
        height:=value*tool.height_scale+tool.height_offset
        if abs(height)>terrain.HEIGHT_LIMIT {editor.notify(s,"Heightmap heights exceed the terrain limit");return false}
        terrain.grid_set(&next.heights,i%heightmap.width,i/heightmap.width,height)
    }
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

// The heights of the selected Heightfield as a 16-bit PNG, rows from its
// first z: the scale and offset fields take its range.
heightmap_export :: proc(s:^editor.Session,tool:^Terrain_Tool,path:string) -> bool {
    stroke:=&tool.stroke
    if stroke.id=={} || stroke.source.kind!=.Heightfield {return false}
    source:=&stroke.source
    width,height:=int(source.samples.x),int(source.samples.z)
    low,high:=f32(max(f32)),f32(-max(f32))
    for z in 0..<height {for x in 0..<width {h:=terrain.grid_get(&source.heights,x,z);low,high=min(low,h),max(high,h)}}
    span:=max(high-low,1e-6)
    values,error:=make([]f32,width*height,context.temp_allocator)
    if error!=nil {editor.notify(s,"There is not enough memory for the heightmap");return false}
    for z in 0..<height {for x in 0..<width {values[x+width*z]=(terrain.grid_get(&source.heights,x,z)-low)/span}}
    bytes,encode:=textures.heightmap_encode(values,width,height,context.temp_allocator)
    if encode!=.None {editor.notify(s,fmt.tprintf("Heightmap: %v",encode));return false}
    file:=path
    if filepath.ext(file)=="" {file=fmt.tprintf("%s.png",file)}
    if serial.file_write_atomic(file,bytes)!=.None {editor.notify(s,"The heightmap could not be written");return false}
    tool.height_scale,tool.height_offset=high-low,low
    editor.notify(s,fmt.tprintf("Heightmap written: %s, heights %.2f to %.2f m",filepath.base(file),low,high))
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
    if ui.property(ctx,"Samples X") {if ui.number_field(ctx,ui.id(ctx,"resize_x"),&x,{width=ui.fixed(FIELD_WIDTH),min=3,max=f64(terrain.HEIGHT_SAMPLES_MAX),has_min=true,has_max=true,speed=1,integer=true}).changed {tool.resize.x=resize_even(int(x),current.x)}}
    if ui.property(ctx,"Samples Z") {if ui.number_field(ctx,ui.id(ctx,"resize_z"),&z,{width=ui.fixed(FIELD_WIDTH),min=3,max=f64(terrain.HEIGHT_SAMPLES_MAX),has_min=true,has_max=true,speed=1,integer=true}).changed {tool.resize.y=resize_even(int(z),current.y)}}
    if tool.resize!=current && ui.button(ctx,ui.id(ctx,"resize"),{label="Resize",style=.Field,width=-1,center=true}).clicked {terrain_resize(s,tool,world,assets,tool.resize)}
}

@(private)
resize_even :: proc "contextless" (wanted,current:int) -> int {
    n:=clamp(wanted,3,terrain.HEIGHT_SAMPLES_MAX)
    if (n-current)%2!=0 {n+=n<terrain.HEIGHT_SAMPLES_MAX?1:-1}
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
