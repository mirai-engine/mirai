package physics

import "core:fmt"
import "mirai:core"
import sim "plugins:physics/runtime/sim"

// A collider belongs to categories and collides with categories. Two
// colliders meet when each belongs to a category the other collides with:
// they block each other, unless one is a sensor, which blocks nothing and
// reports what it overlaps. A collider takes what it is from a preset that
// colliders share, or from its own fields when its preset is Custom.
// Categories and presets are ids with names declared in code
// (core/names.odin): the engine declares those below and a game its own,
// CATEGORY_PLAYER :: physics.Collision_Category(1). Collision_Settings says
// what each preset is; colliders, queries and saved data keep the numbers.

COLLISION_CATEGORY_CAPACITY :: 32 // the bits of Collision_Layers
COLLISION_PRESET_CAPACITY :: 32   // presets with a setting
COLLISION_LAYERS_ALL :: Collision_Layers(0xffffffff)
COLLISION_LAYERS_NONE :: Collision_Layers(0)

// What a collider belongs to: its bit in Collision_Layers.
@(names="CATEGORY_")
Collision_Category :: distinct u8
CATEGORY_DEFAULT :: Collision_Category(0)

// What colliders share: whether they are sensors, what they belong to and
// what they collide with. Custom: what the collider itself says.
@(names="PRESET_")
Collision_Preset :: distinct u8
PRESET_DEFAULT :: Collision_Preset(0)
PRESET_TRIGGER :: Collision_Preset(1)
PRESET_CUSTOM :: Collision_Preset(255)

// Bit i is the category i.
@(name_bits="Collision_Category")
Collision_Layers :: sim.Collision_Layers

// What a preset is. A preset without one is the Default category, colliding with every category.
Collision_Preset_Setting :: struct {
    preset:Collision_Preset,
    sensor:bool,               // blocks nothing and reports what it overlaps
    belongs:Collision_Layers,
    collides:Collision_Layers, // a sensor: those it reports
}

COLLISION_PUSH_CAPACITY :: sim.PUSH_RULE_CAPACITY

// Two categories whose dynamic bodies yield to each other: a contact between
// them pushes with at most force, so teammates or a crowd pass through one
// another instead of blocking. A pair without one blocks rigidly.
Collision_Push :: struct {
    a,b:Collision_Category,
    force:f32 `mirai:"min=0,unit=N"`,
}

// One entry per preset that differs from the Default category colliding with everything, and per material
// that collides otherwise than its colliders (Collision_Surface); an entry of zeros says nothing.
@(storage,setting)
Collision_Settings :: struct {
    presets:[COLLISION_PRESET_CAPACITY]Collision_Preset_Setting `mirai:"trim"`,
    pushes:[COLLISION_PUSH_CAPACITY]Collision_Push `mirai:"trim"`,
    surfaces:[COLLISION_SURFACE_CAPACITY]Collision_Surface `mirai:"trim"`,
}

COLLISION_SETTINGS_DEFAULT :: Collision_Settings{
    presets={0={preset=PRESET_TRIGGER,sensor=true,belongs=1,collides=COLLISION_LAYERS_ALL}},
}

Collision_Error :: enum u8 {None,Invalid_Settings,Unknown_Category,Unknown_Preset,Invalid_Force,Full}

@(private,rodata) COLLISION_FALLBACK:=COLLISION_SETTINGS_DEFAULT

@(private)
settings_or_default :: proc "contextless" (settings:^Collision_Settings) -> ^Collision_Settings {
    return settings!=nil?settings:&COLLISION_FALLBACK
}

// What the settings say of a preset: its entry, or the Default category colliding with everything.
collision_preset_setting :: proc "contextless" (settings:^Collision_Settings,preset:Collision_Preset) -> Collision_Preset_Setting {
    for entry in settings_or_default(settings).presets {
        if entry!={} && entry.preset==preset {return entry}
    }
    return {preset=preset,belongs=1,collides=COLLISION_LAYERS_ALL}
}

// Writes what a preset is: in its entry, in a free one, or as no entry when it is the defaults; Custom has none.
collision_preset_setting_set :: proc "contextless" (settings:^Collision_Settings,setting:Collision_Preset_Setting) -> Collision_Error {
    if settings==nil {return .Invalid_Settings}
    if setting.preset==PRESET_CUSTOM {return .Unknown_Preset}
    next:=setting
    if next==(Collision_Preset_Setting{preset=setting.preset,belongs=1,collides=COLLISION_LAYERS_ALL}) {next={}}
    free:=-1
    for &entry,i in settings.presets {
        if entry!={} && entry.preset==setting.preset {entry=next;return .None}
        if entry=={} && free<0 {free=i}
    }
    if next=={} {return .None}
    if free<0 {return .Full}
    settings.presets[free]=next
    return .None
}

// One entry per preset and none for Custom; every push between two categories of Collision_Layers, finite
// and once per pair.
collision_settings_valid :: proc "contextless" (settings:^Collision_Settings) -> bool {
    s:=settings_or_default(settings)
    for entry,i in s.presets {
        if entry=={} {continue}
        if entry.preset==PRESET_CUSTOM {return false}
        for other in s.presets[:i] {if other!={} && other.preset==entry.preset {return false}}
    }
    for push,i in s.pushes {
        if push.force==0 {continue}
        if !(push.force>0 && push.force<=max(f32)) || int(push.a)>=COLLISION_CATEGORY_CAPACITY || int(push.b)>=COLLISION_CATEGORY_CAPACITY {return false}
        for other in s.pushes[:i] {
            if other.force!=0 && (other.a==push.a && other.b==push.b || other.a==push.b && other.b==push.a) {return false}
        }
    }
    return true
}

// Whether the code declares a value of Collision_Category or Collision_Preset; every value is, for a
// World without names (a test that makes its own).
collision_declared :: proc(info:^core.World_Info,type:typeid,value:i64) -> bool {
    if core.named_type_of(info,type)==nil {return true}
    _,found:=core.name_of(info,type,value)
    return found
}

// The name the code gives a value of Collision_Category or Collision_Preset, or its number.
collision_name :: proc(info:^core.World_Info,type:typeid,value:i64) -> string {
    if name,found:=core.name_of(info,type,value);found {return name}
    return fmt.tprintf("%d",value)
}

// Iterates the entries of the settings for values the code does not declare, from at: the field, its
// index and the value. Such an entry configures what no collider is meant to use.
collision_settings_undeclared :: proc(settings:^Collision_Settings,info:^core.World_Info,at:^int) -> (field:string,index:int,value:i64,found:bool) {
    s:=settings_or_default(settings)
    for at^<COLLISION_PRESET_CAPACITY+2*COLLISION_PUSH_CAPACITY {
        i:=at^
        at^+=1
        if i<COLLISION_PRESET_CAPACITY {
            entry:=s.presets[i]
            if entry!={} && !collision_declared(info,Collision_Preset,i64(entry.preset)) {return "presets",i,i64(entry.preset),true}
            continue
        }
        j:=i-COLLISION_PRESET_CAPACITY
        push:=s.pushes[j/2]
        category:=j%2==0?push.a:push.b
        if push.force!=0 && !collision_declared(info,Collision_Category,i64(category)) {return "pushes",j/2,i64(category),true}
    }
    return
}

// The force with which dynamic bodies of the two categories push each other; zero: they block.
collision_push :: proc "contextless" (settings:^Collision_Settings,a,b:Collision_Category) -> f32 {
    for push in settings_or_default(settings).pushes {
        if push.force!=0 && (push.a==a && push.b==b || push.a==b && push.b==a) {return push.force}
    }
    return 0
}

// Makes the dynamic bodies of two categories yield to each other with force N; zero makes them block again.
collision_push_set :: proc "contextless" (settings:^Collision_Settings,a,b:Collision_Category,force:f32) -> Collision_Error {
    if settings==nil || !collision_settings_valid(settings) {return .Invalid_Settings}
    if !(force>=0 && force<=max(f32)) {return .Invalid_Force}
    if int(a)>=COLLISION_CATEGORY_CAPACITY || int(b)>=COLLISION_CATEGORY_CAPACITY {return .Unknown_Category}
    free:=-1
    for &push,i in settings.pushes {
        if push.force!=0 && (push.a==a && push.b==b || push.a==b && push.b==a) {
            push=force>0?Collision_Push{a,b,force}:Collision_Push{}
            return .None
        }
        if push.force==0 && free<0 {free=i}
    }
    if force==0 {return .None}
    if free<0 {return .Full}
    settings.pushes[free]={a,b,force}
    return .None
}

// The push rules of the simulation for the valid pushes of the settings.
@(private)
collision_push_rules :: proc "contextless" (settings:^Collision_Settings,rules:^[COLLISION_PUSH_CAPACITY]sim.Push_Rule) -> (count:int) {
    for push in settings_or_default(settings).pushes {
        if !(push.force>0 && push.force<=max(f32)) || int(push.a)>=COLLISION_CATEGORY_CAPACITY || int(push.b)>=COLLISION_CATEGORY_CAPACITY {continue}
        rules[count]={Collision_Layers(1)<<uint(push.a),Collision_Layers(1)<<uint(push.b),push.force}
        count+=1
    }
    return
}

// What a collider is to the others: that of its preset, or its own when it is Custom.
collision_of_collider :: proc "contextless" (settings:^Collision_Settings,collider:Collider) -> Collision_Preset_Setting {
    if collider.preset==PRESET_CUSTOM {return {preset=PRESET_CUSTOM,sensor=collider.sensor,belongs=collider.belongs,collides=collider.collides}}
    return collision_preset_setting(settings,collider.preset)
}

// The filter of the simulation for a collider: what it is to the others, and its group.
collision_filter :: proc "contextless" (settings:^Collision_Settings,collider:Collider) -> (filter:Collision_Filter) {
    of:=collision_of_collider(settings,collider)
    filter.layers=of.belongs
    if of.sensor {filter.overlap=of.collides} else {filter.block=of.collides}
    filter.group=u64(collider.group)
    return
}

// The collider as it is, colliding with nothing: it meets no shape and queries pass through it, while its
// shape stays made. Giving back the collider it was turns it on again.
collision_off :: proc "contextless" (settings:^Collision_Settings,collider:Collider) -> Collider {
    off:=collider
    of:=collision_of_collider(settings,collider)
    off.preset,off.sensor,off.belongs,off.collides=PRESET_CUSTOM,of.sensor,of.belongs,COLLISION_LAYERS_NONE
    return off
}

// Gives the collider what it is of its own: Custom.
collision_custom :: proc "contextless" (collider:^Collider,belongs,collides:Collision_Layers,sensor:=false) {
    collider.preset,collider.sensor,collider.belongs,collider.collides=PRESET_CUSTOM,sensor,belongs,collides
}

// The bits of these categories.
collision_layers :: proc "contextless" (categories:..Collision_Category) -> (layers:Collision_Layers) {
    for category in categories {
        if int(category)<COLLISION_CATEGORY_CAPACITY {layers|=Collision_Layers(1)<<uint(category)}
    }
    return
}

// A query that hits the colliders of these categories that collide with something, as a collider of every
// category colliding with them would; sensors only with overlaps.
query_hits :: proc "contextless" (layers:Collision_Layers,overlaps:=false) -> Query_Filter {
    return {filter={layers=COLLISION_LAYERS_ALL,block=layers},overlaps=overlaps}
}

// What a query hits: the categories it blocks on, and whether it also reports the sensors and the shapes
// that only overlap it.
query_layers :: proc "contextless" (filter:Query_Filter) -> (layers:Collision_Layers,overlaps:bool) {
    return filter.filter.block|filter.objects,filter.overlaps
}

// How a query meets a collider of this filter, before its body is looked at: whether a field or a system
// of gameplay would see it.
query_meets :: proc "contextless" (filter:Query_Filter,target:Collision_Filter) -> sim.Response {
    return sim.query_filter_response(filter,target)
}
