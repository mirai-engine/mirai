package editor

import "core:reflect"
import "core:strings"
import "mirai:asset"
import "mirai:cook/author"
import "mirai:core"
import "mirai:project"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:ui"

// What Create shows: a card places a recipe (author.Recipe), a scene of one
// entity of the engine or of a plugin. The editor has its cards and a plugin
// adds its own from its editor package, with a storage whose sole field is a
// Card_Provider and a default procedure, as the providers of the inspector
// and of the API.

CARD_CAPACITY :: 64
CARD_PROVIDER_CAPACITY :: 8
CARD_GROUP_CAPACITY :: 8

Card :: struct {
    recipe:string,           // the name of the recipe it places
    group:string,            // the section of Create that lists it: "Logic", "Shapes" or one of its own
    icon:ui.Icon,            // one of ui; None: its drawing
    drawing:ui.Icon_Drawing,
    color:ui.Color,
    component:typeid,        // an entity that has it is shown with the icon of the card
    chosen:bool,             // an empty Asset_Id field of what it places takes the asset of its kind chosen in the content browser
    facing:bool,             // what it places turns to whoever places it
    label:string,            // cards() gives it: the name of the entity of its recipe
}

Card_Provider :: struct {
    cards:[CARD_PROVIDER_CAPACITY]Card,
    count:int,
}

// The cards of the editor in the order of Create, its sections first.
EDITOR_CARDS :: [?]Card{
    {recipe="empty",group="Logic",icon=.Group,color=GROUP_COLOR},
    {recipe="point_light",group="Logic",icon=.Light,color=LIGHT_COLOR},
    {recipe="sun",group="Logic",icon=.Sun,color=LIGHT_COLOR},
    {recipe="spot_light",group="Logic",icon=.Spot,color=LIGHT_COLOR},
    {recipe="rect_light",group="Logic",icon=.Area_Light,color=LIGHT_COLOR},
    {recipe="sound",group="Logic",icon=.Sound,color=SOUND_COLOR},
    {recipe="reverb_zone",group="Logic",icon=.Collider,color=SOUND_COLOR},
    {recipe="cube",group="Shapes",icon=.Cube,color=MESH_COLOR},
    {recipe="sphere",group="Shapes",icon=.Sphere,color=MESH_COLOR},
    {recipe="cylinder",group="Shapes",icon=.Cylinder,color=MESH_COLOR},
    {recipe="cone",group="Shapes",icon=.Cone,color=MESH_COLOR},
    {recipe="prism",group="Shapes",icon=.Prism,color=MESH_COLOR},
    {recipe="pyramid",group="Shapes",icon=.Pyramid,color=MESH_COLOR},
    {recipe="camera",group="Cameras",icon=CAMERA_ICON,color=CAMERA_COLOR},
    {recipe="third_person_camera",group="Cameras",icon=CAMERA_ICON,color=CAMERA_COLOR},
    {recipe="aim_camera",group="Cameras",icon=CAMERA_ICON,color=CAMERA_COLOR},
    {recipe="first_person_camera",group="Cameras",icon=CAMERA_ICON,color=CAMERA_COLOR},
    {recipe="isometric_camera",group="Cameras",icon=CAMERA_ICON,color=CAMERA_COLOR},
    {recipe="top_down_camera",group="Cameras",icon=CAMERA_ICON,color=CAMERA_COLOR},
    {recipe="side_camera",group="Cameras",icon=CAMERA_ICON,color=CAMERA_COLOR},
}

// The recipes of the engine and of the active plugins of the project, read
// again when the library in use changes.
recipes :: proc(s:^Session) -> []author.Recipe {
    if s.recipes_library==s.library_generation+1 {return s.recipes}
    s.recipes_library=s.library_generation+1
    author.recipes_free(s.recipes)
    opened:=project.Project{engine_root=s.engine_root}
    if s.has_project {
        if found,error:=project.open(s.project_root,s.engine_root,context.temp_allocator);error.code==.None {opened=found}
    }
    s.recipes=author.recipes_read(project.recipe_folders(&opened,context.temp_allocator))
    return s.recipes
}

// The recipe a name means, as base.name_find takes it.
@(private)
recipe_of :: proc(s:^Session,name:string) -> (recipe:author.Recipe,found:bool) {
    all:=recipes(s)
    index:int
    if index,found=author.recipe_named(all,name);found {recipe=all[index]}
    return
}

// The cards of the editor, then those of the plugins of the library in use;
// one whose recipe is not there is left out.
cards :: proc(s:^Session) -> []Card {
    if s.cards_library==s.library_generation+1 {return s.cards[:s.card_count]}
    s.cards_library=s.library_generation+1
    s.card_count=0
    s.card_tables={}
    s.cards_editor=0
    add :: proc(s:^Session,card:Card) {
        recipe,found:=recipe_of(s,card.recipe)
        if !found || s.card_count>=len(s.cards) {return}
        added:=card
        added.label=recipe.label
        if own:=s.card_count;added.icon==.None && added.drawing.count>0 && s.gui!=nil && s.gui.ctx!=nil && ui.icon_custom_set(s.gui.ctx,own,added.drawing) {
            added.icon=ui.icon_custom(own)
        }
        if added.component!=nil && s.info!=nil {
            for &table in s.info.tables {
                if table.type==added.component && table.place==.World {s.card_tables[s.card_count]=&table;break}
            }
        }
        s.cards[s.card_count]=added
        s.card_count+=1
    }
    for card in EDITOR_CARDS {add(s,card)}
    s.cards_editor=s.card_count
    if s.info==nil {return s.cards[:s.card_count]}
    found:[PROVIDER_CAPACITY]Card_Provider
    for &provider in found[:provided_all(s,found[:])] {
        for card in provider.cards[:clamp(provider.count,0,len(provider.cards))] {add(s,card)}
    }
    return s.cards[:s.card_count]
}

// The card of a plugin an entity is shown as: that of a component it has.
@(private)
card_of_entity :: proc(s:^Session,w:core.World_Ref,e:core.Entity) -> (card:^Card,found:bool) {
    if w.place!=.World {return}
    all:=cards(s)
    for &candidate,index in all[s.cards_editor:] {
        table:=s.card_tables[s.cards_editor+index]
        if table!=nil && core.raw_find(core.world_table_at(w,table),table.info,e)!=nil {return &candidate,true}
    }
    return
}

// The card of a plugin whose component a table holds.
@(private)
card_of_table :: proc(s:^Session,t:^core.Table_Info) -> (card:^Card,found:bool) {
    all:=cards(s)
    for &candidate in all[s.cards_editor:] {
        if candidate.component==t.type {return &candidate,true}
    }
    return
}

// The card that places a recipe.
@(private)
card_of_recipe :: proc(s:^Session,name:string) -> (card:Card,found:bool) {
    for candidate in cards(s) {
        if candidate.recipe==name {return candidate,true}
    }
    return
}

// What a card does to the components and the place of the entity it makes
// besides its recipe: the asset chosen in the content browser goes in the
// empty Asset_Id fields of its kind, and it turns to the camera of the viewport.
@(private)
card_place :: proc(s:^Session,card:Card,parts:[]author.Part,transform:^core.Transform) {
    if card.chosen && s.content!=nil && s.app!=nil && s.app.assets!=nil {
        if record,found:=asset.registry_find(&s.app.assets.registry,s.content.selected);found {
            extension:=asset_create_extension(s,record.kind)
            for part in parts {
                for field in reflect.struct_fields_zipped(part.t.type) {
                    if field.type.id!=base.Asset_Id || int(field.offset)+size_of(base.Asset_Id)>len(part.value) {continue}
                    kinds:=field_tagged(string(field.tag)).asset_kinds
                    at:=(^base.Asset_Id)(&part.value[field.offset])
                    for kind in strings.fields(kinds,context.temp_allocator) {
                        if at^=={} && kind==extension {at^=record.id}
                    }
                }
            }
        }
    }
    if card.facing && s.viewport!=nil {
        toward:=orbit_position(s.viewport.orbit)-transform.position
        toward.y=0
        if toward!={} {transform.rotation=mm.quat_look(toward,{0,1,0})}
    }
}

// What is wrong with a name recipe_of does not take, with the nearest ones.
recipes_problem :: proc(s:^Session,name:string) -> string {
    return author.recipe_problem(recipes(s),name)
}
