package host

import "core:log"
import "core:mem"
import "core:strings"
import "mirai:core"
import "mirai:project"
import "mirai:rhi"
import "mirai:std/serial"

// The settings of the project into the storages that hold them: those of the
// Shared when the application starts, those of each World when it is made.
// They are the values of the code with the files of the layers over them: the
// one of the engine, when the application has one, with the settings of the
// machine, and the one of the project (project.settings_load). With a
// device, the values of the code are those for it (Storage_Info.for_device).

app_settings :: proc(info:^core.World_Info,data:rawptr,place:core.Place,device:^rhi.Device,allocator:=context.temp_allocator) -> []project.Setting {
    list:=make([dynamic]project.Setting,allocator)
    named:map[typeid]serial.Named
    if info.schema!=nil {named=info.schema.schema.named}
    for s in info.storages {
        if s.setting==.None || s.place!=place {continue}
        base:rawptr
        if s.for_device!=nil && device!=nil {
            if bytes,error:=mem.alloc_bytes(s.info.size,s.info.align,allocator);error==nil {
                base=raw_data(bytes)
                s.for_device(base,rhi.device_info(device))
            }
        }
        append(&list,project.Setting{s.name,s.info,rawptr(uintptr(data)+s.offset),s.default,s.setting==.Machine,base,named})
    }
    return list[:]
}

// The layers of the settings, with the options of the player (App.options)
// on top of those of the project.
@(private)
app_settings_load :: proc(app:^App,data:rawptr,place:core.Place) {
    if app.root=="" {return}
    settings:=app_settings(app.info,data,place,app.device)
    if len(settings)==0 {return}
    if error,layer:=project.settings_load(settings,app.root,app.engine_root,layers=project.settings_layers_of_process(),player=app.options);error.code!=.None {
        log.warnf("%s: %v, line %d",project.settings_file(layer,app.root,app.engine_root,context.temp_allocator,app.options),error.code,error.line)
    }
}

// A file of the options of the player; "" without them.
app_options_file :: proc(app:^App,name:string,allocator:=context.temp_allocator) -> string {
    if app.options=="" {return ""}
    return strings.concatenate({app.options,"/",name},allocator)
}

// Writes the settings of the machine of the application and of a world, as
// the player has them now, as the layer of the options of the player: the
// fields that differ from what the layers under it give. False without
// options or when the file could not be written.
app_options_save :: proc(app:^App,world:rawptr) -> bool {
    if app.options=="" || app.info==nil {return false}
    list:=make([dynamic]project.Setting,context.temp_allocator)
    for place in ([2]core.Place{.Shared,.World}) {
        data:=app.shared if place==.Shared else world
        if data!=nil {append(&list,..app_settings(app.info,data,place,app.device))}
    }
    error,_:=project.settings_save(list[:],.Player,app.root,app.engine_root,app.options)
    return error.code==.None
}
