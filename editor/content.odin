package editor

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/history"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import "mirai:editor/kit"
import "mirai:ui"

// The families of the kinds the filters of the browser take: those of the
// strip under the search first, then those of its menu.
Content_Category :: enum u8 {Prefab,Mesh,Material,Scene,Plugin,Texture,Animation,Sound,Ui}
Content_Categories :: bit_set[Content_Category;u16]

CONTENT_STRIP_CATEGORIES :: [?]Content_Category{.Prefab,.Mesh,.Material,.Scene,.Plugin}
CONTENT_MENU_CATEGORIES :: [?]Content_Category{.Texture,.Animation,.Sound,.Ui}
CONTENT_CATEGORY_LABELS :: [Content_Category]string{.Prefab="Prefab",.Mesh="Model",.Material="Material",.Scene="Scene",.Plugin="Plugins",.Texture="Texture",.Animation="Animation",.Sound="Sound",.Ui="UI"}
// The kind whose color a filter carries; the Plugins and Prefab filters have their own.
CONTENT_CATEGORY_KINDS :: [Content_Category]asset.Fourcc{.Prefab=0,.Mesh=asset.KIND_MESH,.Material=asset.KIND_MATERIAL,.Scene=asset.KIND_SCENE,.Plugin=0,.Texture=asset.KIND_TEXTURE,.Animation=asset.KIND_ANIMATION,.Sound=asset.KIND_SOUND,.Ui=asset.KIND_UI}
CONTENT_PLUGIN_COLOR :: ui.Color{214,107,255,255} // of every kind of a plugin
PREFAB_ASSET_COLOR :: ui.Color{63,126,255,255}    // of a .scene whose header says Prefab, as Unreal draws a Blueprint

CONTENT_ROW :: f32(28)        // a row of the list
CONTENT_CONTROL :: f32(28)    // the row of the search and its buttons
CONTENT_STRIP_ROW :: f32(22)  // the row of the filters of kinds and the zoom
CONTENT_STRIP_BAR :: f32(6)   // the bar of a filter inside its row
CONTENT_FILTERS_GAP :: f32(4) // around the button that clears them
CONTENT_FILTERS :: f32(22)    // the button of the menu of filters
CONTENT_FILTERS_CLEAR :: f32(22) // the room of the button that clears them
CONTENT_ZOOM_WIDTH :: f32(64)
CONTENT_RAIL_GAP :: f32(8)    // between the strip, the filters and the zoom
CONTENT_PANEL_GAP :: f32(6)   // between the rows of the browser
CONTENT_BACK_ROW :: f32(24)   // the back arrow and the breadcrumb
CONTENT_HEADER :: f32(26)     // the name of a folder the wall stays under
CONTENT_SUBHEADER :: f32(20)  // a thin name, and a section with no click
CONTENT_COVER :: f32(18)      // the cover of a folder beside its name
CONTENT_INSET :: f32(4)       // a row of the list from the edge
CONTENT_GAP :: f32(1)         // between two cells
CONTENT_NAME_GAP :: f32(4)    // from a thumbnail to its name
CONTENT_NAME_LINE :: f32(14)  // a line of the name of a cell
CONTENT_NAMED_ROW_GAP :: f32(6) // from a name to the thumbnails of the next row
CONTENT_GRID_BOTTOM :: f32(8)   // under a grid with names, a section or a shelf of Recent
CONTENT_DENSE_BOTTOM :: f32(2)  // under a grid without names
CONTENT_RECENT_BOTTOM :: f32(10) // under Recent in Cards
CONTENT_REVIEW_BADGE :: f32(9)   // side of the mark of an asset that waits for review
CONTENT_BAR :: f32(2)         // the line of the color of its type under a thumbnail
CONTENT_RING_WIDTH :: f32(1.5) // the ring of the keyboard
CONTENT_FRAME :: ui.Color{34,37,45,255}      // under a thumbnail
CONTENT_FRAME_EDGE :: ui.Color{46,49,59,255} // its border
CONTENT_COLUMNS_MIN :: 3
CONTENT_COLUMNS_MAX :: 10
CONTENT_LEVELS :: CONTENT_COLUMNS_MAX-CONTENT_COLUMNS_MIN+1 // the grids; the list is the step under them
CONTENT_NAMED_COLUMNS :: 5    // with more, names give way to a preview under the pointer
CONTENT_PREVIEW :: f32(126)   // the side of that preview
CONTENT_PREVIEW_ROOM :: f32(190) // of the list above a cell: the preview goes above it
CONTENT_WIDTH :: f32(304)     // of the browser in its panel by default
CONTENT_RECENT :: 12
CONTENT_FAVORITES :: 64
CONTENT_HISTORY :: 64         // places Back goes through
CONTENT_TAB :: f32(22)        // a chip of a folder
CONTENT_TAB_PADDING :: f32(8)
CONTENT_TAB_GAP :: f32(2)
CONTENT_TAB_ROW_GAP :: f32(3)
CONTENT_TAB_ROW_MAX :: f32(74) // of a row of chips that wraps: more scrolls
CONTENT_TAB_ROWS :: 8         // rows that scroll on their own
CONTENT_COVER_NAME :: "cover" // a texture of this name is the cover of its folder, not an asset of the browser
STAR_COLOR :: ui.Color{243,196,90,255}

// What tells the same asset apart on the sections of the virtual folders, and
// the ids of those and of All.
CONTENT_ALL_GROUP :: u64(1)
CONTENT_RECENT_GROUP :: u64(2)
CONTENT_SCENE_GROUP :: u64(3)
CONTENT_FAVORITES_GROUP :: u64(4)
CONTENT_USES_GROUP :: u64(5)
CONTENT_USERS_GROUP :: u64(6)

// The color of each type of asset, as Unreal draws its own: the border and the
// line under its thumbnail, its filter and its fields in Details.
asset_color :: proc "contextless" (kind:asset.Fourcc) -> ui.Color {
    switch kind {
    case asset.KIND_MESH:          return {0,255,255,255}   // Static Mesh
    case asset.KIND_SKELETON:      return {105,181,205,255} // Skeleton
    case asset.KIND_MATERIAL:      return {64,192,64,255}   // Material
    case asset.KIND_TEXTURE:       return {192,64,64,255}   // Texture
    case asset.KIND_ANIMATION:     return {80,123,72,255}   // Animation Sequence
    case asset.KIND_SCENE:         return {255,156,0,255}   // Level
    case asset.KIND_SOUND:         return {97,85,212,255}   // Sound Wave
    case asset.KIND_SOUND_SET:     return {120,105,230,255} // Sound Cue
    case asset.KIND_UI:            return {44,89,180,255}   // Widget Blueprint
    case asset.KIND_FONT:          return {176,120,80,255}  // Font
    case asset.KIND_STRINGS:       return {148,129,224,255} // String Table
    case asset.KIND_PROMPTS:       return {220,96,140,255}
    case asset.KIND_RECORDS:       return {130,170,100,255} // Data Table
    }
    return {128,131,143,255}
}

// The color of a kind of the engine or of a plugin.
asset_kind_color :: proc(s:^Session,kind:asset.Fourcc) -> ui.Color {
    if asset_plugin_kind(s,kind)!=nil {return CONTENT_PLUGIN_COLOR}
    return asset_color(kind)
}

// The color of an asset of the registry: that of its type, that of a
// Skeletal Mesh for a mesh on a skeleton, and its own for a prefab.
asset_file_color :: proc(s:^Session,file:^asset.Registry_File) -> ui.Color {
    if file.kind==asset.KIND_MESH && asset.registry_skeleton(&s.app.assets.registry,file)!={} {return {241,163,241,255}}
    if asset.registry_prefab(file) {return PREFAB_ASSET_COLOR}
    return asset_kind_color(s,file.kind)
}

// The icon of an asset of the registry, with the color of its type.
asset_file_icon :: proc(s:^Session,file:^asset.Registry_File) -> (icon:ui.Icon,color:ui.Color) {
    if asset.registry_prefab(file) {return .Prefab,PREFAB_ASSET_COLOR}
    return asset_icon(s,file.kind)
}

// The type of an asset of the registry as a tooltip says it.
asset_file_label :: proc(s:^Session,file:^asset.Registry_File) -> string {
    return "Prefab" if asset.registry_prefab(file) else asset_kind_label(s,file.kind)
}

// The family of an asset of the registry, as the filters of the browser take it.
content_file_category :: proc "contextless" (file:^asset.Registry_File) -> Content_Category {
    if asset.registry_prefab(file) {return .Prefab}
    category,_:=content_category(file.kind)
    return category
}

// The icon of a kind of the engine or of a plugin, with its color.
asset_icon :: proc(s:^Session,kind:asset.Fourcc) -> (icon:ui.Icon,color:ui.Color) {
    color=asset_kind_color(s,kind)
    if declared:=asset_plugin_kind(s,kind);declared!=nil {return declared.icon,color}
    switch kind {
    case asset.KIND_MESH:          icon=.Mesh
    case asset.KIND_MATERIAL:      icon=.Sphere
    case asset.KIND_TEXTURE:       icon=.Texture
    case asset.KIND_SCENE:         icon=.Scene
    case asset.KIND_ANIMATION:     icon=.Rotate
    case asset.KIND_SOUND,asset.KIND_SOUND_SET: icon=.Sound
    case asset.KIND_SKELETON:      icon=.Axis
    case asset.KIND_UI:            icon=.Layers
    case asset.KIND_FONT:          icon=.Edit
    case asset.KIND_STRINGS:       icon=.Split
    case asset.KIND_PROMPTS:       icon=.Target
    case asset.KIND_RECORDS:       icon=.Rows
    case:                          icon=.Cube
    }
    return
}

// The type of an asset as a tooltip says it, of the engine or of a plugin.
asset_kind_label :: proc(s:^Session,kind:asset.Fourcc) -> string {
    if declared:=asset_plugin_kind(s,kind);declared!=nil {return declared.label}
    return asset_type_label(kind)
}

asset_type_label :: proc(kind:asset.Fourcc) -> string {
    switch kind {
    case asset.KIND_MESH:          return "Mesh"
    case asset.KIND_MATERIAL:      return "Material"
    case asset.KIND_TEXTURE:       return "Texture"
    case asset.KIND_SCENE:         return "Scene"
    case asset.KIND_ANIMATION:     return "Animation"
    case asset.KIND_SKELETON:      return "Skeleton"
    case asset.KIND_SOUND:         return "Sound"
    case asset.KIND_SOUND_SET:     return "Sound set"
    case asset.KIND_UI:            return "UI"
    case asset.KIND_FONT:          return "Font"
    case asset.KIND_STRINGS:       return "Texts"
    case asset.KIND_PROMPTS:       return "Prompts"
    case asset.KIND_RECORDS:       return "Records"
    }
    return "Asset"
}

// The family of a kind; engine is false for a kind of a plugin.
content_category :: proc "contextless" (kind:asset.Fourcc) -> (category:Content_Category,engine:bool) {
    switch kind {
    case asset.KIND_MESH,asset.KIND_SKELETON: return .Mesh,true
    case asset.KIND_MATERIAL: return .Material,true
    case asset.KIND_TEXTURE:  return .Texture,true
    case asset.KIND_ANIMATION:return .Animation,true
    case asset.KIND_SCENE:    return .Scene,true
    case asset.KIND_SOUND,asset.KIND_SOUND_SET: return .Sound,true
    case asset.KIND_UI,asset.KIND_FONT,asset.KIND_STRINGS,asset.KIND_PROMPTS: return .Ui,true
    }
    return .Plugin,false
}

Content_Mode :: enum u8 {Grid,List}
// Names: the assets under the names of their folders in one continuous wall.
// Tabs: chips of the folders over a grid of what the chosen one holds. Cards:
// the folders as cells among the assets.
Content_Arrangement :: enum u8 {Names,Tabs,Cards}

// How the content browser shows the assets, as the editor keeps it between
// sessions (preferences.odin).
Content_View :: struct {
    mode:Content_Mode, // the size decides it: past the most columns the grid is the list
    columns:int,       // of the grid
    show_parts:bool,   // the parts of imports show in their folders too (content_part)
    arrangement:Content_Arrangement,
}

CONTENT_VIEW_DEFAULT :: Content_View{columns=4}

// What a user marks in the browser of a project, kept in its .mirai folder
// (preferences.odin), by id: a file that moves keeps its marks.
Content_Marks :: struct {
    recent:[CONTENT_RECENT]base.Asset_Id,      // the last used first; a zero ends them
    favorites:[CONTENT_FAVORITES]base.Asset_Id,
}

// The folders the browser enters that the registry does not have.
Content_Virtual :: enum u8 {None,Recent,Scene,Favorites}
CONTENT_VIRTUAL_LABELS :: [Content_Virtual]string{.None="",.Recent="Recent",.Scene="Current scene",.Favorites="Favorites"}

// Where the browser is: a folder of the assets, "" for the root, or a virtual one.
Content_At :: struct {
    virtual:Content_Virtual,
    length:int,
    folder:[API_PATH_BYTES]u8,
}

// Where the browser of a project was left, as the file of its marks keeps it
// (preferences.odin): written from Content and read back into it. The search
// is not kept: it is what is being looked for now.
CONTENT_FOLDED_KEPT :: 256
Content_Navigation :: struct {
    place:[API_PATH_BYTES]u8 `mirai:"text"`, // Content.place
    at:[API_PATH_BYTES]u8 `mirai:"text"`,    // Content.at
    virtual:Content_Virtual,
    categories:Content_Categories,
    unused:bool,
    folded:[CONTENT_FOLDED_KEPT]u64, // Content.folded; a zero ends them
}

// A clip of a library: an .anim and the name of one of its clips in Content.clip_text.
Content_Clip :: struct {
    library:base.Asset_Id,
    start,length:u32,
}

// A part of an import (owner) as Registry.files has it (file), sorted by owner.
@(private)
Content_Part :: struct {
    owner:base.Asset_Id,
    file:i32,
}

// A cell of the grid or a row of the list: an asset, or a folder in Cards.
@(private)
Content_Card :: struct {
    file:i32,     // of Registry.files; -1: a folder
    clip:i32,     // of Content.clips +1: a clip of the library of file; 0: the file itself
    name:string,  // inside a path of the registry or Content.clip_text: valid until either changes
    holds:bool,   // an .anim with clips or the owner of parts: an arrow shows them (open)
    open:bool,
    part:bool,    // shown after its owner
    folder:string,          // a folder: its path under the assets
    virtual:Content_Virtual, // a folder that is a virtual one
    cover:i32,    // a folder: its cover in Registry.files +1; 0: none
}

@(private)
Content_Line_Kind :: enum u8 {Header,Subheader,Label,Cards,Create}

// A line of the browser, of a height of Content.heights.
@(private)
Content_Line :: struct {
    kind:Content_Line_Kind,
    group:u64,       // a name: what its id is made from; cards: what tells them from those of a folder, or 0
    name:string,     // a name or a label
    path:string,     // a name of a folder: its path under the assets
    virtual:Content_Virtual, // a name of a virtual folder
    first,count:i32, // cards: of Content.cards
    after:f32,       // cards: the room under the row
    cover:i32,       // a header: its cover in Registry.files +1; 0: none
    names:u8,        // cards of a grid with names: the lines the longest name of the row takes, 1 or 2; 0: 2
    parent:i32,      // the header it scrolls under, which stays on top meanwhile; -1: none
}

// A file of the registry, or a folder of it (index -1, its path with the slash at its end).
@(private)
Content_Entry :: struct {path:string,index:i32}

// A chip of a folder in Tabs: row 0 are the first-level folders and each one
// after them the folders of the one chosen above it.
@(private)
Content_Tab :: struct {row:int,name,path:string}

// What the lines of the browser build from, besides the Content they go into.
@(private)
Content_Build :: struct {
    registry:^asset.Registry,
    opened,scene_kinds:[]asset.Fourcc,
    filter:string,
    columns:int,
}

@(storage)
Content :: struct {
    filter:[64]u8,
    filter_length:int,
    categories:Content_Categories, // none: all of them
    unused:bool,                   // only the assets nothing references
    selection_only:bool,           // only what the selection of the viewport uses
    view:Content_View,
    marks:Content_Marks,
    selected:base.Asset_Id,        // the last clicked
    selected_clip:i32,             // of selected, as Content_Card.clip
    picked:[dynamic]base.Asset_Id, // selected too, with Ctrl or Shift
    scroll:f32,
    at:Content_At,                 // the folder shown
    history:[dynamic]Content_At,   // where Back goes, the last first out
    trail:[dynamic]base.Asset_Id,  // the assets the relations go through; empty: the folder shown
    lines:[dynamic]Content_Line,
    heights:[dynamic]f32,
    cards:[dynamic]Content_Card,
    tabs:[dynamic]Content_Tab,
    tab_scroll:[CONTENT_TAB_ROWS][2]f32,
    key:[9]u64,
    revision:u64,
    referenced:[dynamic]base.Asset_Id, // sorted: what an asset depends on
    registry_key:[3]u64,
    parts:[dynamic]Content_Part,   // of the registry, read with what is referenced
    variants:[dynamic]Content_Part, // of the prefabs of the registry: a prefab whose base is the owner
    clips:[dynamic]Content_Clip,   // of the libraries of the registry
    clip_text:[dynamic]u8,
    clips_key:[2]u64,              // revisions of the registry and of the assets they were read at
    scene_used:[dynamic]u32,       // sorted, of Registry.files: what the open scene references, transitively
    scene_key:[4]u64,
    selection_used:[dynamic]u32,   // sorted, of Registry.files: what the selection uses and what that uses
    selection_key:[4]u64,
    folded:[dynamic]u64,             // the groups of the folders Names shows only the name of
    unfolded:[dynamic]base.Asset_Id, // libraries whose clips show and owners whose parts show
    focus_search:bool,             // the search takes the keyboard on the next frame
    card_focus:ui.Id,              // the card that had the keyboard when the browser was last built
    focus_asset:base.Asset_Id,     // the asset of card_focus; zero for a clip of a library
    reveal:base.Asset_Id,          // shown, selected and focused on the next frame
    menu:base.Asset_Id,            // the asset whose card opened the menu
    place:[API_PATH_BYTES]u8,      // the folder of what was clicked last: where the + of Create makes what it makes
    place_length:int,
    create_into:[API_PATH_BYTES]u8, // the folder the menu of Create makes in
    create_into_length:int,
    create_on_folder:bool,         // the menu of Create opened on the folder create_into: it also renames, copies and moves it
    creating:bool,                 // a line names what Create makes in create_folder
    create_kind:asset.Fourcc,
    create_record:int,             // of a .records: its type, in World_Info.records
    create_folder:[API_PATH_BYTES]u8,
    create_folder_length:int,
    create_name:[ASSET_CREATE_NAME]u8,
    create_name_length:int,
    create_edit:bool,              // the name takes the keyboard on the next frame
    created:base.Asset_Id,         // made by Create: selected and opened once the registry has it
    rename:[API_PATH_BYTES]u8,     // the asset or folder the line renames instead of making one; empty: it makes one
    rename_length:int,
    renaming:base.Asset_Id,        // of the asset it renames; zero for a folder
    restore:bool,                  // the registry changed or the navigation was read: checked against the registry when the browser is built
}

CONTENT_DEFAULT :: Content{view=CONTENT_VIEW_DEFAULT}

// The columns a view asks for, whatever the file of the preferences says.
@(private)
content_columns :: proc "contextless" (view:Content_View) -> int {return clamp(view.columns,CONTENT_COLUMNS_MIN,CONTENT_COLUMNS_MAX)}

// Whether the cells of a view carry their names.
@(private)
content_shows_names :: proc "contextless" (view:Content_View) -> bool {return view.mode==.List || content_columns(view)<=CONTENT_NAMED_COLUMNS}

// The step of the zoom of a view: 0 the list, then one for each count of
// columns from the most to the fewest.
@(private)
content_level :: proc "contextless" (view:Content_View) -> int {
    if view.mode==.List {return 0}
    return CONTENT_COLUMNS_MAX-content_columns(view)+1
}

@(private)
content_level_set :: proc "contextless" (view:^Content_View,level:int) {
    if level<=0 {
        view.mode=.List
        return
    }
    view.mode,view.columns=.Grid,clamp(CONTENT_COLUMNS_MAX-level+1,CONTENT_COLUMNS_MIN,CONTENT_COLUMNS_MAX)
}

// notches of Ctrl+wheel: each one a step of content_level, up to fewer and
// larger cells; the list is the smallest.
content_zoom :: proc(view:^Content_View,notches:f32) {
    if notches==0 {return}
    steps:=int(math.round(notches))
    if steps==0 {steps=1 if notches>0 else -1}
    content_level_set(view,clamp(content_level(view^)+steps,0,CONTENT_LEVELS))
}

// The columns of the cells in a width and the side of each.
@(private)
content_cells :: proc(view:Content_View,width:f32) -> (columns:int,cell:f32) {
    room:=max(width,1)
    if view.mode==.List {return 1,room}
    columns=content_columns(view)
    cell=max((room-f32(columns-1)*CONTENT_GAP)/f32(columns),1)
    return
}

// The height of a cell: its thumbnail and the lines of the name under it.
@(private)
content_card_height :: proc(view:Content_View,cell:f32,names:u8=2) -> f32 {
    if view.mode==.List {return CONTENT_ROW}
    if content_shows_names(view) {return cell+CONTENT_NAME_GAP+f32(names if names>0 else 2)*CONTENT_NAME_LINE}
    return cell
}

@(private)
content_line_height :: proc(view:Content_View,line:Content_Line,width:f32) -> f32 {
    switch line.kind {
    case .Header:           return CONTENT_HEADER
    case .Subheader,.Label: return CONTENT_SUBHEADER
    case .Create:           return CONTENT_ROW+2
    case .Cards:
        if view.mode==.List {return CONTENT_ROW+2}
        _,cell:=content_cells(view,width)
        return content_card_height(view,cell,line.names)+line.after
    }
    return 0
}

// Whether an asset is selected: the last clicked, or one Ctrl or Shift added.
content_selected :: proc(c:^Content,id:base.Asset_Id) -> bool {
    return id!={} && (c.selected==id || slice.contains(c.picked[:],id))
}

content_selected_count :: proc(c:^Content) -> int {return len(c.picked)+(1 if c.selected!={} else 0)}

// A click on an asset selects it alone; with add (Ctrl or Shift) it joins
// the selection, or leaves it if it was there.
@(private)
content_select :: proc(c:^Content,id:base.Asset_Id,add:bool) {
    if !add {
        clear(&c.picked)
        c.selected,c.selected_clip=id,0
        return
    }
    if c.selected==id && c.selected_clip==0 {
        c.selected={}
        if len(c.picked)>0 {c.selected=pop(&c.picked)}
        return
    }
    if at,found:=slice.linear_search(c.picked[:],id);found {
        ordered_remove(&c.picked,at)
        return
    }
    if c.selected!={} && c.selected_clip==0 {append(&c.picked,c.selected)}
    c.selected,c.selected_clip=id,0
}

@(private)
content_select_clear :: proc(c:^Content) {
    clear(&c.picked)
    c.selected,c.selected_clip={},0
}

// An asset left the registry: it leaves the selection.
content_unselect :: proc(c:^Content,id:base.Asset_Id) {
    if at,found:=slice.linear_search(c.picked[:],id);found {ordered_remove(&c.picked,at)}
    if c.selected!=id {return}
    c.selected,c.selected_clip={},0
    if len(c.picked)>0 {c.selected=pop(&c.picked)}
}

// An asset was used: placed, opened or assigned. Recent shows it first.
content_used :: proc(s:^Session,id:base.Asset_Id) {
    if s.content==nil || id=={} {return}
    m:=&s.content.marks
    at:=len(m.recent)-1
    for other,i in m.recent {
        if other==id || other=={} {at=i;break}
    }
    copy(m.recent[1:at+1],m.recent[:at])
    m.recent[0]=id
    s.content.revision+=1
}

content_favorite :: proc(m:^Content_Marks,id:base.Asset_Id) -> bool {
    if id=={} {return false}
    _,found:=slice.linear_search(m.favorites[:],id)
    return found
}

// Stars an asset or takes its star away; the list keeps its order and has no
// holes.
content_favorite_toggle :: proc(c:^Content,id:base.Asset_Id) {
    m:=&c.marks
    c.revision+=1
    if at,found:=slice.linear_search(m.favorites[:],id);found {
        copy(m.favorites[at:],m.favorites[at+1:])
        m.favorites[len(m.favorites)-1]={}
        return
    }
    for &slot in m.favorites {
        if slot=={} {slot=id;return}
    }
}

@(private)
content_has_prefix_fold :: proc(text,prefix:string) -> bool {
    return len(prefix)<=len(text) && strings.equal_fold(text[:len(prefix)],prefix)
}

// How well a token of the search names a file; -1 when it does not. Whatever
// starts its name comes first, then a word of its name, a part of it, its
// folder, and last the name of one of its clips.
@(private)
content_token_score :: proc(c:^Content,file:^asset.Registry_File,name,token:string) -> int {
    if content_has_prefix_fold(name,token) {return 4}
    for i in 0..<len(name) {
        if name[i]=='_' && content_has_prefix_fold(name[i+1:],token) {return 3}
    }
    if base.contains_fold(name,token) {return 2}
    if base.contains_fold(content_folder_of(file.path),token) {return 1}
    if content_clip_matches(c,file.id,token) {return 1}
    return -1
}

// What a search scores a file: -1 unless every token names it.
@(private)
content_score :: proc(c:^Content,file:^asset.Registry_File,filter:string) -> int {
    name:=asset_name(file.path)
    total:=0
    rest:=filter
    for token in strings.fields_iterator(&rest) {
        score:=content_token_score(c,file,name,token)
        if score<0 {return -1}
        total+=score
    }
    return total
}

// Whether a token of a search is in the name of a clip.
@(private)
content_clip_found :: proc(name,filter:string) -> bool {
    rest:=filter
    for token in strings.fields_iterator(&rest) {
        if base.contains_fold(name,token) {return true}
    }
    return false
}

// Whether the filters of kinds take a file.
@(private)
content_file_taken :: proc(c:^Content,file:^asset.Registry_File) -> bool {
    return c.categories=={} || content_file_category(file) in c.categories
}

// Whether the browser lists a file: an asset of a kind of the engine, or of a
// plugin that opens it as a document or declares it (opened). The other
// kinds of a plugin are edited by its API. A skeleton comes with the mesh on
// it, which stands for it.
@(private)
content_shown :: proc(file:^asset.Registry_File,opened:[]asset.Fourcc) -> bool {
    if file.state!=.Asset || file.kind==asset.KIND_SKELETON || !asset.registry_listed(file) || content_cover(file) {return false}
    _,engine:=content_category(file.kind)
    return engine || slice.contains(opened,file.kind)
}

// Whether a file is the cover of its folder.
@(private)
content_cover :: proc(file:^asset.Registry_File) -> bool {
    return file.kind==asset.KIND_TEXTURE && asset_name(file.path)==CONTENT_COVER_NAME
}

// The cover of the folder of prefix (its path with the slash at its end), as
// Content_Line.cover.
@(private)
content_cover_of :: proc(registry:^asset.Registry,prefix:string) -> i32 {
    file,found:=asset.registry_find_path(registry,fmt.tprintf("%s%s.tex",prefix,CONTENT_COVER_NAME))
    if !found || !content_cover(file) {return 0}
    return content_file_index(registry,file)+1
}

// Whether the browser lists a file under the filters of kinds.
@(private)
content_listed :: proc(c:^Content,file:^asset.Registry_File,opened:[]asset.Fourcc) -> bool {
    return content_shown(file,opened) && content_file_taken(c,file)
}

// Whether a file is a part of an import: its header names an owner
// (asset.Header.owner), which the importer gives only to what is surely of
// that model alone, and the owner is in the registry. The browser shows a part
// after its owner and hides it from its folder.
@(private)
content_part :: proc(registry:^asset.Registry,file:^asset.Registry_File) -> bool {
    if file.state!=.Asset || file.owner=={} || file.owner==file.id {return false}
    owner,found:=asset.registry_find(registry,file.owner)
    return found && owner.state==.Asset
}

// What the registry has, read again when it changes: what some asset depends
// on and the parts of each owner.
@(private)
content_registry_read :: proc(c:^Content,registry:^asset.Registry,opened:[]asset.Fourcc,types:^asset.Types=nil) {
    key:=[3]u64{u64(uintptr(raw_data(registry.files))),registry.revision,u64(len(registry.files))|u64(len(opened))<<32}
    if key==c.registry_key {return}
    c.registry_key=key
    clear(&c.referenced)
    clear(&c.parts)
    clear(&c.variants)
    for &file,at in registry.files {
        append(&c.referenced,..asset.registry_dependencies(registry,&file))
        if file.kind!=asset.KIND_SKELETON && content_part(registry,&file) {append(&c.parts,Content_Part{file.owner,i32(at)})}
        if base_id:=content_variant_base(registry,types,&file);base_id!={} {append(&c.variants,Content_Part{base_id,i32(at)})}
    }
    slice.sort_by(c.referenced[:],proc(a,b:base.Asset_Id) -> bool {return a[0]<b[0] || a[0]==b[0] && a[1]<b[1]})
    // The parts of an owner keep the order of their paths.
    by_owner :: proc(a,b:Content_Part) -> bool {return a.owner[0]<b.owner[0] || a.owner[0]==b.owner[0] && (a.owner[1]<b.owner[1] || a.owner[1]==b.owner[1] && a.file<b.file)}
    slice.sort_by(c.parts[:],by_owner)
    slice.sort_by(c.variants[:],by_owner)
    c.restore=true
    c.revision+=1
}

// What the open scene references, read again when the registry or the scene
// changes.
@(private)
content_scene_read :: proc(c:^Content,registry:^asset.Registry,scene:base.Asset_Id) {
    key:=[4]u64{u64(uintptr(raw_data(registry.files))),registry.revision,u64(scene[0]),u64(scene[1])}
    if key==c.scene_key {return}
    c.scene_key=key
    asset.registry_closure(registry,scene,&c.scene_used)
    c.revision+=1
}

// The assets the selection of the viewport holds and what they use, in the
// files of the registry.
@(private)
content_selection_set :: proc(c:^Content,registry:^asset.Registry,ids:[]base.Asset_Id) {
    clear(&c.selection_used)
    closure:=make([dynamic]u32,context.temp_allocator)
    for id in ids {
        at,known:=registry.by_id[id]
        if !known {continue}
        append(&c.selection_used,at)
        asset.registry_closure(registry,id,&closure)
        append(&c.selection_used,..closure[:])
    }
    slice.sort(c.selection_used[:])
    resize(&c.selection_used,len(slice.unique(c.selection_used[:])))
    c.revision+=1
}

// What the selection of the viewport uses, read again when it, the registry or
// the document changes, and only while its toggle is on.
@(private)
content_selection_read :: proc(s:^Session,c:^Content,w:core.World_Ref,registry:^asset.Registry) {
    if !c.selection_only || s.selection==nil {return}
    key:=[4]u64{u64(uintptr(raw_data(registry.files))),registry.revision,s.selection.serial,history.edits_state(s.edits) if s.edits!=nil else 0}
    if key==c.selection_key {return}
    c.selection_key=key
    ids:=make([dynamic]base.Asset_Id,context.temp_allocator)
    if w.info!=nil {
        for e in s.selection.entities {
            host.entity_asset_ids(w,e,&ids)
            if link,found:=prefab_link_of(w,e);found {append(&ids,link.asset)}
        }
    }
    content_selection_set(c,registry,ids[:])
}

// Whether the selection of the viewport uses a file.
@(private)
content_selection_uses :: proc(c:^Content,registry:^asset.Registry,file:^asset.Registry_File) -> bool {
    _,found:=slice.binary_search(c.selection_used[:],u32(content_file_index(registry,file)))
    return found
}

// The parts of an owner, in the order of their paths.
@(private)
content_parts_of :: proc(c:^Content,owner:base.Asset_Id) -> []Content_Part {return content_owned(c.parts[:],owner)}

@(private)
content_owned :: proc(list:[]Content_Part,owner:base.Asset_Id) -> []Content_Part {
    first,_:=slice.binary_search_by(list,owner,proc(part:Content_Part,owner:base.Asset_Id) -> slice.Ordering {
        a:=part.owner
        if a[0]<owner[0] || a[0]==owner[0] && a[1]<owner[1] {return .Less}
        return .Greater
    })
    last:=first
    for last<len(list) && list[last].owner==owner {last+=1}
    return list[first:last]
}

// The base of a prefab that is a variant; zero for any other file. Only a
// prefab that needs another is read, once per change of the registry.
@(private)
content_variant_base :: proc(registry:^asset.Registry,types:^asset.Types,file:^asset.Registry_File) -> base.Asset_Id {
    if types==nil || !asset.registry_prefab(file) {return {}}
    nests:=false
    for id in asset.registry_dependencies(registry,file) {
        if dependency,found:=asset.registry_find(registry,id);found && asset.registry_prefab(dependency) {nests=true;break}
    }
    if !nests {return {}}
    scene:asset.Scene
    if asset.scene_load(&scene,types,asset.registry_file_path(registry,file.path,context.temp_allocator),context.temp_allocator)!=.None {return {}}
    base_id,_:=asset.prefab_variant_base(&scene)
    return base_id
}

// Whether an asset is used by another. A scene that is no prefab is never unused: nothing holds it.
@(private)
content_referenced :: proc(c:^Content,file:^asset.Registry_File) -> bool {
    if file.kind==asset.KIND_SCENE && !asset.registry_prefab(file) {return true}
    _,found:=slice.binary_search_by(c.referenced[:],file.id,proc(a,b:base.Asset_Id) -> slice.Ordering {
        if a==b {return .Equal}
        return .Less if a[0]<b[0] || a[0]==b[0] && a[1]<b[1] else .Greater
    })
    return found
}

@(private)
content_clip_name :: proc(c:^Content,clip:int) -> string {
    at:=c.clips[clip]
    return string(c.clip_text[at.start:][:at.length])
}

// Reads the names of the clips of every library again when the registry or
// the assets changed.
@(private)
content_clips_read :: proc(c:^Content,a:^host.Assets) {
    key:=[2]u64{a.registry.revision,a.revision}
    if key==c.clips_key {return}
    c.clips_key=key
    clear(&c.clips)
    clear(&c.clip_text)
    for &file in a.registry.files {
        if file.state!=.Asset || file.kind!=asset.KIND_ANIMATION {continue}
        data:asset.Asset
        if host.assets_file(a,file.id,asset.KIND_ANIMATION,&data)!=.None {continue}
        if view,error:=asset.animation_view(&data,&a.types);error==.None {
            for &clip in view.clips {
                name:=base.text_get(clip.name[:])
                append(&c.clips,Content_Clip{file.id,u32(len(c.clip_text)),u32(len(name))})
                append(&c.clip_text,..transmute([]u8)name)
            }
        }
        asset.asset_close(&data)
    }
    c.revision+=1
}

// Shows or hides the clips of a library or the parts of an owner.
@(private)
content_unfold :: proc(c:^Content,id:base.Asset_Id) {
    if at,found:=slice.linear_search(c.unfolded[:],id);found {unordered_remove(&c.unfolded,at)} else {append(&c.unfolded,id)}
    c.revision+=1
}

// Whether a search finds a library by one of its clips.
@(private)
content_clip_matches :: proc(c:^Content,library:base.Asset_Id,filter:string) -> bool {
    if filter=="" {return false}
    for clip,k in c.clips {
        if clip.library==library && base.contains_fold(content_clip_name(c,k),filter) {return true}
    }
    return false
}

// Whether a file is listed under the search, the filters and Only unused. A
// part of an import shows in its folder only while a search finds it, Show
// parts of imports is on, the filters of kinds leave its owner out or what
// the selection of the viewport uses is shown; marked: what a virtual folder
// or the relations of an asset name, which show it always. What a scene
// makes of itself shows with the Plugins filter or a search.
@(private)
content_matches :: proc(c:^Content,b:^Content_Build,file:^asset.Registry_File,marked:bool=false) -> bool {
    if !content_listed(c,file,b.opened) || c.unused && content_referenced(c,file) {return false}
    if b.filter=="" && .Plugin not_in c.categories && slice.contains(b.scene_kinds,file.kind) {return false}
    if c.selection_only && !content_selection_uses(c,b.registry,file) {return false}
    if b.filter=="" {
        if marked || c.selection_only || c.view.show_parts || !content_part(b.registry,file) {return true}
        owner,_:=asset.registry_find(b.registry,file.owner)
        return !content_file_taken(c,owner)
    }
    return content_score(c,file,b.filter)>=0
}

@(private)
content_file_index :: proc(registry:^asset.Registry,file:^asset.Registry_File) -> i32 {
    return i32((uintptr(file)-uintptr(raw_data(registry.files)))/size_of(asset.Registry_File))
}

// The cards of files, each library followed by its clips while it is open or
// a search finds them, and each owner by its parts while it is open.
@(private)
content_cards_add :: proc(c:^Content,b:^Content_Build,files:[]i32) {
    registry:=b.registry
    for index in files {
        file:=&registry.files[index]
        at:=len(c.cards)
        append(&c.cards,Content_Card{file=index,name=asset_name(file.path)})
        open:=slice.contains(c.unfolded[:],file.id)
        // A prefab opens to its variants; the parts of its import show in their folders.
        parts:=content_owned(c.variants[:],file.id) if asset.registry_prefab(file) else content_parts_of(c,file.id)
        if len(parts)>0 {
            c.cards[at].holds,c.cards[at].open=true,open
            if open {
                for part in parts {append(&c.cards,Content_Card{file=part.file,name=asset_name(registry.files[part.file].path),part=true})}
            }
        }
        if file.kind!=asset.KIND_ANIMATION {continue}
        for clip,k in c.clips {
            if clip.library!=file.id {continue}
            c.cards[at].holds,c.cards[at].open=true,open
            clip_name:=content_clip_name(c,k)
            if b.filter!="" ? !content_clip_found(clip_name,b.filter) : !open {continue}
            append(&c.cards,Content_Card{file=index,clip=i32(k+1),name=clip_name})
        }
    }
}

// The cards from first on, in rows of the columns. after: the room under
// their last row; below 0, that of a grid of the view.
@(private)
content_rows_add :: proc(c:^Content,first:int,columns:int,group:u64=0,parent:i32=-1,after:f32=-1) {
    named:=content_shows_names(c.view)
    between:=CONTENT_NAMED_ROW_GAP if named else CONTENT_GAP
    last:=after if after>=0 else (CONTENT_GRID_BOTTOM if named else CONTENT_DENSE_BOTTOM)
    end:=len(c.cards)
    for at:=first;at<end;at+=columns {
        append(&c.lines,Content_Line{kind=.Cards,group=group,first=i32(at),count=i32(min(columns,end-at)),after=last if at+columns>=end else between,parent=parent})
    }
}

// What a virtual folder holds that the filters take.
@(private)
content_virtual_files :: proc(c:^Content,b:^Content_Build,virtual:Content_Virtual) -> []i32 {
    registry:=b.registry
    files:=make([dynamic]i32,context.temp_allocator)
    add_marks :: proc(c:^Content,b:^Content_Build,ids:[]base.Asset_Id,files:^[dynamic]i32) {
        for id in ids {
            if id=={} {break}
            if file,found:=asset.registry_find(b.registry,id);found && content_matches(c,b,file,marked=true) {append(files,content_file_index(b.registry,file))}
        }
    }
    switch virtual {
    case .None:
    case .Recent:    add_marks(c,b,c.marks.recent[:],&files)
    case .Favorites: add_marks(c,b,c.marks.favorites[:],&files)
    case .Scene:
        for at in c.scene_used {
            if int(at)<len(registry.files) && content_matches(c,b,&registry.files[at],marked=true) {append(&files,i32(at))}
        }
    }
    return files[:]
}

@(private)
content_virtual_group :: proc "contextless" (virtual:Content_Virtual) -> u64 {
    switch virtual {
    case .None:      return 0
    case .Recent:    return CONTENT_RECENT_GROUP
    case .Scene:     return CONTENT_SCENE_GROUP
    case .Favorites: return CONTENT_FAVORITES_GROUP
    }
    return 0
}

// The entries from prefix on (a folder with the slash at its end, or "" for
// the root): a folder is a run of them, sorted by path.
@(private)
content_under :: proc(entries:[]Content_Entry,prefix:string) -> []Content_Entry {
    if prefix=="" {return entries}
    first:=0
    for first<len(entries) && !strings.has_prefix(entries[first].path,prefix) {first+=1}
    last:=first
    for last<len(entries) && strings.has_prefix(entries[last].path,prefix) {last+=1}
    return entries[first:last]
}

@(private)
Content_Child :: struct {name,path:string,entries:[]Content_Entry}

// The folders right under prefix, each with the entries under it.
@(private)
content_children :: proc(entries:[]Content_Entry,prefix:string) -> []Content_Child {
    children:=make([dynamic]Content_Child,context.temp_allocator)
    for i:=0;i<len(entries); {
        rest:=entries[i].path[len(prefix):]
        slash:=strings.index_byte(rest,'/')
        if slash<0 {
            i+=1
            continue
        }
        folder:=entries[i].path[:len(prefix)+slash+1]
        j:=i+1
        for j<len(entries) && strings.has_prefix(entries[j].path,folder) {j+=1}
        append(&children,Content_Child{name=rest[:slash],path=folder[:len(folder)-1],entries=entries[i:j]})
        i=j
    }
    return children[:]
}

// The files right under prefix.
@(private)
content_direct_files :: proc(entries:[]Content_Entry,prefix:string) -> []i32 {
    files:=make([dynamic]i32,context.temp_allocator)
    for entry in entries {
        if entry.index>=0 && strings.index_byte(entry.path[len(prefix):],'/')<0 {append(&files,entry.index)}
    }
    return files[:]
}

// A label over files, as Recent in Cards and the relations of an asset have.
@(private)
content_section_add :: proc(c:^Content,b:^Content_Build,name:string,group:u64,files:[]i32,after:f32) {
    if len(files)==0 {return}
    append(&c.lines,Content_Line{kind=.Label,name=name,parent=-1})
    first:=len(c.cards)
    content_cards_add(c,b,files)
    content_rows_add(c,first,b.columns,group,after=after)
}

// The wall of Names: at the root, one row of each virtual folder; what the
// folder holds right in it; then each folder under it with what it holds:
// a subfolder of at least a row has a thin name, and the smaller ones flow
// together with no label.
@(private)
content_wall_add :: proc(c:^Content,b:^Content_Build,entries:[]Content_Entry,prefix:string) {
    registry:=b.registry
    if prefix=="" {
        labels:=CONTENT_VIRTUAL_LABELS
        for virtual in ([3]Content_Virtual{.Recent,.Scene,.Favorites}) {
            files:=content_virtual_files(c,b,virtual)
            if len(files)==0 {continue}
            group:=content_virtual_group(virtual)
            header:=i32(len(c.lines))
            append(&c.lines,Content_Line{kind=.Header,group=group,name=labels[virtual],virtual=virtual,parent=-1})
            if content_folded(c,group) {continue}
            first:=len(c.cards)
            content_cards_add(c,b,files[:min(b.columns,len(files))])
            content_rows_add(c,first,b.columns,group,header)
        }
    }
    under:=content_under(entries,prefix)
    first:=len(c.cards)
    content_cards_add(c,b,content_direct_files(under,prefix))
    content_rows_add(c,first,b.columns)
    Held :: struct {folder:string,file:i32}
    held:=make([dynamic]Held,context.temp_allocator)
    loose:=make([dynamic]i32,context.temp_allocator)
    flush :: proc(c:^Content,b:^Content_Build,loose:^[dynamic]i32,parent:i32) {
        if len(loose)==0 {return}
        first:=len(c.cards)
        content_cards_add(c,b,loose[:])
        content_rows_add(c,first,b.columns,parent=parent)
        clear(loose)
    }
    for child in content_children(under,prefix) {
        header:=i32(len(c.lines))
        append(&c.lines,Content_Line{kind=.Header,group=base.hash64(transmute([]u8)child.path),name=child.name,path=child.path,cover=content_cover_of(registry,fmt.tprintf("%s/",child.path)),parent=-1})
        if content_folded(c,base.hash64(transmute([]u8)child.path)) {continue}
        clear(&held)
        for entry in child.entries {
            if entry.index>=0 {append(&held,Held{content_folder_of(entry.path),entry.index})}
        }
        slice.sort_by(held[:],proc(a,b:Held) -> bool {return a.folder<b.folder if a.folder!=b.folder else a.file<b.file})
        for i:=0;i<len(held); {
            j:=i+1
            for j<len(held) && held[j].folder==held[i].folder {j+=1}
            folder:=held[i].folder
            if j-i>=b.columns {
                flush(c,b,&loose,header)
                if folder!=child.path {append(&c.lines,Content_Line{kind=.Subheader,group=base.hash64(transmute([]u8)folder),name=folder[len(child.path)+1:],path=folder,parent=header})}
                if folder!=child.path && content_folded(c,base.hash64(transmute([]u8)folder)) {
                    i=j
                    continue
                }
                files:=make([]i32,j-i,context.temp_allocator)
                for k in i..<j {files[k-i]=held[k].file}
                start:=len(c.cards)
                content_cards_add(c,b,files)
                content_rows_add(c,start,b.columns,parent=header)
            } else {
                for k in i..<j {append(&loose,held[k].file)}
            }
            i=j
        }
        flush(c,b,&loose,header)
    }
}

// The chips of Tabs: the first-level folders, and for the folder chosen the
// folders of each one on its way down.
@(private)
content_tabs_add :: proc(c:^Content,entries:[]Content_Entry) {
    for child in content_children(entries,"") {append(&c.tabs,Content_Tab{row=0,name=child.name,path=child.path})}
    if c.at.virtual!=.None {return}
    folder:=string(c.at.folder[:c.at.length])
    row:=1
    for i in 1..=len(folder) {
        if i<len(folder) && folder[i]!='/' {continue}
        prefix:=fmt.tprintf("%s/",folder[:i])
        kids:=content_children(content_under(entries,prefix),prefix)
        if len(kids)==0 {continue}
        for kid in kids {append(&c.tabs,Content_Tab{row=row,name=kid.name,path=kid.path})}
        row+=1
    }
}

// Cards: Recent open at the top of the root, then the folders as cells of an
// asset and the files of the folder after them.
@(private)
content_folder_cells_add :: proc(c:^Content,b:^Content_Build,entries:[]Content_Entry,prefix:string) {
    registry:=b.registry
    root:=prefix==""
    if root {content_section_add(c,b,"Recent",CONTENT_RECENT_GROUP,content_virtual_files(c,b,.Recent),CONTENT_RECENT_BOTTOM)}
    under:=content_under(entries,prefix)
    first:=len(c.cards)
    if root {
        labels:=CONTENT_VIRTUAL_LABELS
        for virtual in ([2]Content_Virtual{.Scene,.Favorites}) {
            if len(content_virtual_files(c,b,virtual))>0 {append(&c.cards,Content_Card{file=-1,name=labels[virtual],virtual=virtual})}
        }
    }
    for child in content_children(under,prefix) {append(&c.cards,Content_Card{file=-1,name=child.name,folder=child.path,cover=content_cover_of(registry,fmt.tprintf("%s/",child.path))})}
    content_cards_add(c,b,content_direct_files(under,prefix))
    content_rows_add(c,first,b.columns)
}

// The results of a search of the folder shown and what is under it, best first.
@(private)
content_search_add :: proc(c:^Content,b:^Content_Build,entries:[]Content_Entry,prefix:string) {
    Hit :: struct {file:i32,score:int,name:string}
    hits:=make([dynamic]Hit,context.temp_allocator)
    add :: proc(c:^Content,b:^Content_Build,hits:^[dynamic]Hit,index:i32) {
        file:=&b.registry.files[index]
        append(hits,Hit{index,content_score(c,file,b.filter),asset_name(file.path)})
    }
    if c.at.virtual!=.None {
        for index in content_virtual_files(c,b,c.at.virtual) {add(c,b,&hits,index)}
    } else {
        for entry in content_under(entries,prefix) {
            if entry.index>=0 {add(c,b,&hits,entry.index)}
        }
    }
    slice.sort_by(hits[:],proc(x,y:Hit) -> bool {return x.score>y.score if x.score!=y.score else x.name<y.name})
    files:=make([]i32,len(hits),context.temp_allocator)
    for hit,i in hits {files[i]=hit.file}
    first:=len(c.cards)
    content_cards_add(c,b,files)
    content_rows_add(c,first,b.columns)
}

// What the last asset of the trail uses and what uses it; files that left the
// registry take their place in the trail with them.
@(private)
content_relations_add :: proc(c:^Content,b:^Content_Build) {
    registry:=b.registry
    for len(c.trail)>0 {
        if _,found:=asset.registry_find(registry,c.trail[len(c.trail)-1]);found {break}
        pop(&c.trail)
        c.revision+=1
    }
    if len(c.trail)==0 {return}
    file,_:=asset.registry_find(registry,c.trail[len(c.trail)-1])
    id:=file.id
    uses:=make([dynamic]i32,context.temp_allocator)
    for dependency in asset.registry_dependencies(registry,file) {
        if found,known:=asset.registry_find(registry,dependency);known && content_matches(c,b,found,marked=true) {append(&uses,content_file_index(registry,found))}
    }
    users:=make([dynamic]i32,context.temp_allocator)
    for at in asset.registry_dependents(registry,id) {
        if int(at)<len(registry.files) && content_matches(c,b,&registry.files[at],marked=true) {append(&users,i32(at))}
    }
    slice.sort(uses[:])
    slice.sort(users[:])
    content_section_add(c,b,"Uses",CONTENT_USES_GROUP,slice.unique(uses[:]),CONTENT_GRID_BOTTOM)
    content_section_add(c,b,"Used by",CONTENT_USERS_GROUP,slice.unique(users[:]),CONTENT_GRID_BOTTOM)
}

// The lines of the browser in a width for where it is. Built again only when
// the registry, the filters, the marks or the place change.
@(private)
content_lines :: proc(c:^Content,registry:^asset.Registry,width:f32,opened:[]asset.Fourcc=nil,scene_kinds:[]asset.Fourcc=nil,font:^ui.Font=nil,name_size:f32=0) -> []Content_Line {
    filter:=strings.trim_space(string(c.filter[:c.filter_length]))
    v:=c.view
    key:=[9]u64{u64(uintptr(raw_data(registry.files))),u64(len(registry.files)),registry.revision,base.hash64(transmute([]u8)filter),u64(transmute(u16)c.categories)|u64(c.unused)<<16|u64(c.selection_only)<<17|u64(v.arrangement)<<18|u64(v.mode)<<20|u64(v.show_parts)<<21,c.revision,u64(content_columns(v)),u64(transmute(u32)width),u64(len(opened))|u64(len(scene_kinds))<<32}
    if key==c.key {return c.lines[:]}
    c.key=key
    clear(&c.lines)
    clear(&c.cards)
    clear(&c.heights)
    clear(&c.tabs)
    columns,cell:=content_cells(v,width)
    build:=Content_Build{registry,opened,scene_kinds,filter,columns}
    b:=&build
    // The registry keeps its files sorted by path: a folder is a run of them.
    entries:=make([dynamic]Content_Entry,context.temp_allocator)
    for &file,index in registry.files {
        if content_matches(c,b,&file) {append(&entries,Content_Entry{file.path,i32(index)})}
    }
    filtering:=filter!="" || c.categories!={} || c.unused || c.selection_only
    // The folders of the project show also without files, not while filtering.
    if !filtering && len(registry.folders)>0 {
        for folder in registry.folders {
            if folder[0]!='.' && !content_mounted(registry,folder) {append(&entries,Content_Entry{folder,-1})}
        }
        slice.sort_by(entries[:],proc(a,b:Content_Entry) -> bool {return a.path<b.path})
    }
    if c.creating {append(&c.lines,Content_Line{kind=.Create,parent=-1})}
    folder:=string(c.at.folder[:c.at.length])
    prefix:=fmt.tprintf("%s/",folder) if folder!="" else ""
    if v.arrangement==.Tabs && len(c.trail)==0 {content_tabs_add(c,entries[:])}
    switch {
    case len(c.trail)>0:         content_relations_add(c,b)
    case filter!="":             content_search_add(c,b,entries[:],prefix)
    case c.at.virtual!=.None:
        first:=len(c.cards)
        content_cards_add(c,b,content_virtual_files(c,b,c.at.virtual))
        content_rows_add(c,first,b.columns,content_virtual_group(c.at.virtual))
    case v.arrangement==.Names:  content_wall_add(c,b,entries[:],prefix)
    case v.arrangement==.Cards:  content_folder_cells_add(c,b,entries[:],prefix)
    case:
        files:=make([dynamic]i32,context.temp_allocator)
        for entry in content_under(entries[:],prefix) {
            if entry.index>=0 {append(&files,entry.index)}
        }
        first:=len(c.cards)
        content_cards_add(c,b,files[:])
        content_rows_add(c,first,b.columns)
    }
    // A row whose names all fit in one line keeps the room of one.
    if font!=nil && v.mode==.Grid && content_shows_names(v) {
        for &line in c.lines {
            if line.kind!=.Cards {continue}
            line.names=1
            for card in c.cards[line.first:][:line.count] {
                if ui.text_width(font,card.name,name_size)>cell-2 {line.names=2;break}
            }
        }
    }
    for line in c.lines {append(&c.heights,content_line_height(v,line,width))}
    return c.lines[:]
}

// The folder a path of the assets is in; "" for the root.
@(private)
content_folder_of :: proc(path:string) -> string {return path[:max(strings.last_index_byte(path,'/'),0)]}

// Whether the view of the browser shows the assets of a folder right where
// it is.
@(private)
content_folder_shown :: proc(c:^Content,folder:string) -> bool {
    if c.at.virtual!=.None || len(c.trail)>0 {return false}
    at:=string(c.at.folder[:c.at.length])
    if c.view.arrangement==.Cards {return folder==at}
    return folder==at || asset_path_inside(folder,at)
}

// Comes to where an asset is, if it is not in sight. A part its folder hides
// shows after its owner.
@(private)
content_reveal_open :: proc(c:^Content,registry:^asset.Registry) {
    file,found:=asset.registry_find(registry,c.reveal)
    if !found {
        c.reveal={}
        return
    }
    if content_part(registry,file) && !c.view.show_parts {
        // A prefab opens to its variants, not its parts: they show in their folder.
        if owner,_:=asset.registry_find(registry,file.owner);asset.registry_prefab(owner) {
            c.view.show_parts=true
        } else {
            file=owner
            if !slice.contains(c.unfolded[:],file.id) {append(&c.unfolded,file.id)}
        }
    }
    clear(&c.trail)
    c.revision+=1
    if folder:=content_folder_of(file.path);!content_folder_shown(c,folder) {content_enter(c,.None,folder)}
}

// Whether a folder of the registry belongs to a plugin, the engine or the
// editor: its files are listed, the folder is not.
@(private)
content_mounted :: proc(registry:^asset.Registry,folder:string) -> bool {
    for mount in registry.mounts {
        if len(folder)>len(mount.prefix) && folder[len(mount.prefix)]=='/' && strings.has_prefix(folder,mount.prefix) {return true}
    }
    return false
}

@(private)
content_place_set :: proc(c:^Content,folder:string) {c.place_length=copy(c.place[:],folder)}

@(private)
content_at_is :: proc(a,b:^Content_At) -> bool {
    return a.virtual==b.virtual && string(a.folder[:a.length])==string(b.folder[:b.length])
}

// Enters a folder or a virtual one. reset: it forgets where the browser was,
// as the root of the breadcrumb and a chip do.
content_enter :: proc(c:^Content,virtual:Content_Virtual,folder:="",reset:=false) {
    next:Content_At
    next.virtual=virtual
    next.length=copy(next.folder[:],folder)
    if reset {
        clear(&c.history)
    } else if !content_at_is(&c.at,&next) {
        if len(c.history)>=CONTENT_HISTORY {ordered_remove(&c.history,0)}
        append(&c.history,c.at)
    }
    if virtual==.None {content_place_set(c,folder)}
    clear(&c.trail)
    c.at=next
    c.scroll=0
    c.revision+=1
}

// One step back: along the relations of an asset, then the folders it was
// entered through, and last to the root.
content_back :: proc(c:^Content) {
    c.scroll=0
    c.revision+=1
    if len(c.trail)>0 {
        pop(&c.trail)
        return
    }
    if len(c.history)>0 {
        c.at=pop(&c.history)
    } else if c.at.length>0 || c.at.virtual!=.None {
        c.at={}
    }
    if c.at.virtual==.None {content_place_set(c,string(c.at.folder[:c.at.length]))}
}

// Enters the relations of an asset: what it uses and what uses it.
content_relations_open :: proc(c:^Content,id:base.Asset_Id) {
    if len(c.trail)>0 && c.trail[len(c.trail)-1]==id {return}
    append(&c.trail,id)
    c.scroll=0
    c.revision+=1
}

// What the file of the project keeps of where the browser was left.
content_navigation :: proc(c:^Content) -> (n:Content_Navigation) {
    copy(n.place[:],c.place[:c.place_length])
    copy(n.at[:],c.at.folder[:c.at.length])
    n.virtual,n.categories,n.unused=c.at.virtual,c.categories,c.unused
    copy(n.folded[:],c.folded[:])
    return
}

// Puts the browser where the file of the project says it was left; the
// first build checks it against the registry (content_navigation_restore).
content_navigation_set :: proc(c:^Content,n:^Content_Navigation) {
    content_place_set(c,base.text_get(n.place[:]))
    c.at.virtual=n.virtual
    c.at.length=copy(c.at.folder[:],base.text_get(n.at[:]))
    c.categories,c.unused=n.categories,n.unused
    clear(&c.folded)
    for group in n.folded {
        if group==0 {break}
        append(&c.folded,group)
    }
    clear(&c.history)
    clear(&c.trail)
    c.restore=true
    c.revision+=1
}

// Whether the registry has a folder: empty, or holding files.
@(private)
content_folder_exists :: proc(registry:^asset.Registry,folder:string) -> bool {
    for path in registry.folders {
        if len(path)==len(folder)+1 && strings.has_prefix(path,folder) {return true}
    }
    for &file in registry.files {
        if len(file.path)>len(folder) && file.path[len(folder)]=='/' && strings.has_prefix(file.path,folder) {return true}
    }
    return false
}

// What was read of the project, or was there before the registry changed, as
// the registry has it now: a folder that is gone gives its place to the
// nearest one above it that is there, or to the root.
@(private)
content_navigation_restore :: proc(c:^Content,registry:^asset.Registry) {
    c.restore=false
    place:=string(c.place[:c.place_length])
    for place!="" && !content_folder_exists(registry,place) {place=content_folder_of(place)}
    c.place_length=len(place)
    at:=string(c.at.folder[:c.at.length])
    for at!="" && !content_folder_exists(registry,at) {at=content_folder_of(at)}
    c.at.length=len(at)
    for i:=len(c.history)-1;i>=0;i-=1 {
        if c.history[i].virtual==.None && !content_folder_exists(registry,string(c.history[i].folder[:c.history[i].length])) {ordered_remove(&c.history,i)}
    }
    c.revision+=1
}

// ---------------------------------------------------------------- Create

@(private)
content_create_id :: proc(g:^Editor_Ui) -> ui.Id {return shell_id(g,"content_create")}

@(private)
content_create_icon :: proc(s:^Session,kind:asset.Fourcc) -> (icon:ui.Icon,color:ui.Color) {
    if kind==ASSET_CREATE_FOLDER {return ui.icon_user(u8(User_Icon.Folder)),ui.tone(s.gui.ctx,"text_muted")}
    if kind==ASSET_CREATE_PREFAB {return .Prefab,PREFAB_ASSET_COLOR}
    return asset_icon(s,kind)
}

// Opens the menu of Create at anchor, to make in folder; on_folder: it was
// opened on that folder, which it also renames, copies and moves.
@(private)
content_create_open :: proc(s:^Session,folder:string,anchor:ui.Rect,on_folder:=false) {
    c:=s.content
    c.create_into_length=copy(c.create_into[:],folder)
    c.create_on_folder=on_folder && folder!=""
    ui.popup_open(s.gui.ctx,content_create_id(s.gui),anchor)
}

// The +: the menu of Create, to make in the folder of what was clicked last.
@(private)
content_create_button :: proc(s:^Session,id:ui.Id,height:f32=22) {
    ctx:=s.gui.ctx
    popup:=content_create_id(s.gui)
    if ui.button(ctx,id,{icon=.Plus,icon_color=ui.tone(ctx,"text_muted"),tip="Create",variant="toggle",width=height,height=height,disabled=s.content==nil || files_registry(s)==nil,active=ui.popup_is_open(ctx,popup)}).clicked && !ui.popup_is_open(ctx,popup) {
        anchor,_:=ui.widget_rect(ctx,id)
        content_create_open(s,string(s.content.place[:s.content.place_length]),anchor)
    }
}

// The entries of Create, one for each kind it makes, into folder.
@(private)
content_create_items :: proc(s:^Session,folder:string) {
    ctx:=s.gui.ctx
    disabled:=asset_create_refusal(s)!=""
    for kind,i in asset_create_kinds(s) {
        icon,color:=content_create_icon(s,kind)
        // A table of game data is of a type of the code: one entry for each.
        if kind==asset.KIND_RECORDS {
            records:[]core.Record_Info
            if s.app.info!=nil {records=s.app.info.records}
            for &r,at in records {
                if ui.menu_item(ctx,ui.id(ctx,"create_records",at+1),fmt.tprintf("Records: %s",r.name),{icon=icon,icon_color=color,disabled=disabled}) {
                    s.content.create_record=at
                    content_create_begin(s,kind,folder)
                }
            }
            continue
        }
        if ui.menu_item(ctx,ui.id(ctx,"create",i+1),asset_create_label(s,kind),{icon=icon,icon_color=color,disabled=disabled}) {content_create_begin(s,kind,folder)}
    }
}

@(private)
content_create_menu :: proc(s:^Session) {
    c:=s.content
    ctx:=s.gui.ctx
    popup:=content_create_id(s.gui)
    if ui.popup(ctx,popup,{min_width=180}) {
        ui.id_push(ctx,popup)
        defer ui.id_pop(ctx)
        folder:=string(c.create_into[:c.create_into_length])
        ui.menu_header(ctx,fmt.tprintf("Create in %s",asset_name(folder) if folder!="" else "Assets"))
        content_create_items(s,folder)
        if c.create_on_folder {
            ui.menu_separator(ctx)
            off:=asset_create_refusal(s)!=""
            if ui.menu_item(ctx,ui.id(ctx,"rename"),command_label(s,"asset_rename"),{icon=command_icon(s,"asset_rename"),disabled=off}) {content_rename_begin(s,{},folder)}
            if ui.menu_item(ctx,ui.id(ctx,"duplicate"),command_label(s,"asset_duplicate"),{icon=command_icon(s,"asset_duplicate"),disabled=off}) {
                if _,message:=asset_folder_duplicate(s,folder);message!="" {notify(s,message)}
            }
            if ui.submenu(ctx,ui.id(ctx,"move"),"Move to",{icon=ui.icon_user(u8(User_Icon.Folder)),disabled=off}) {content_move_items(s,{},folder)}
        }
    }
}

// The folders of the project an asset, or the folder from, can go to, as
// entries of a menu: the root first.
@(private)
content_move_items :: proc(s:^Session,id:base.Asset_Id,from:string) {
    ctx:=s.gui.ctx
    r:=files_registry(s)
    if r==nil {return}
    here:=content_folder_of(from)
    if id!={} {
        file,found:=asset.registry_find(r,id)
        if !found {return}
        here=content_folder_of(file.path)
    }
    folders:=make([dynamic]string,context.temp_allocator)
    append(&folders,"")
    for folder in r.folders {
        if folder[0]!='.' && !content_mounted(r,folder) {append(&folders,folder[:len(folder)-1])}
    }
    for folder,i in folders {
        if ui.menu_item(ctx,ui.id(ctx,"move",i+1),folder if folder!="" else "Assets",{icon=ui.icon_user(u8(User_Icon.Folder)),icon_color=ui.tone(ctx,"text_muted"),disabled=folder==here || from!="" && (folder==from || asset_path_inside(folder,from))}) {
            message:string
            if id!={} {_,message=asset_move(s,id,folder,"")} else {_,message=asset_folder_move(s,from,folder,"")}
            if message!="" {notify(s,message)}
            // The names of the folders went with the scan.
            return
        }
    }
}

// An asset dropped on the name of a folder moves there with its parts.
@(private)
content_drop :: proc(s:^Session,folder:string) {
    g:=s.gui
    if g.drag.kind!=.Asset || base.text_get(g.drag.part[:])!="" {return}
    r:=files_registry(s)
    if r==nil {return}
    file,found:=asset.registry_find(r,g.drag.asset_id)
    if !found || content_folder_of(file.path)==folder {return}
    if _,message:=asset_move(s,file.id,folder,"");message!="" {notify(s,message)}
}

// Copies an asset beside itself, and selects the copy.
@(private)
content_duplicate :: proc(s:^Session,id:base.Asset_Id) {
    if _,_,message:=asset_duplicate(s,id);message!="" {notify(s,message)}
}

// The line of Create names the asset id, or the folder when id is zero, to
// type its new name over the one it has: Enter or a click elsewhere renames
// it, Escape leaves it.
content_rename_begin :: proc(s:^Session,id:base.Asset_Id,folder:="") {
    c:=s.content
    r:=files_registry(s)
    if c==nil || r==nil {return}
    path,kind,name:=folder,ASSET_CREATE_FOLDER,asset_path_base(folder)
    refusal:=asset_create_refusal(s)
    if id!={} {
        file,found:=asset.registry_find(r,id)
        if !found {return}
        path,kind,name=file.path,file.kind,asset_name(file.path)
        if refusal=="" {refusal=asset_move_refusal(s,r,file)}
    }
    if refusal!="" || path=="" {
        if refusal!="" {notify(s,refusal)}
        return
    }
    parent:=content_folder_of(path)
    c.create_name_length=copy(c.create_name[:],name)
    c.create_folder_length=copy(c.create_folder[:],parent)
    c.creating,c.create_kind,c.create_edit=true,kind,true
    c.rename_length,c.renaming=copy(c.rename[:],path),id
    c.filter_length,c.categories,c.unused=0,{},false
    c.revision+=1
    content_place_set(c,parent)
}

// Renames what the line of Create names. A name that cannot be, or is
// taken, keeps the line to type another.
@(private)
content_rename_finish :: proc(s:^Session) {
    c:=s.content
    path:=strings.clone(string(c.rename[:c.rename_length]),context.temp_allocator)
    name:=strings.trim_space(string(c.create_name[:c.create_name_length]))
    message:=asset_name_refusal(name)
    if message=="" {
        if c.renaming!={} {_,message=asset_move(s,c.renaming,content_folder_of(path),name)} else {_,message=asset_folder_move(s,path,content_folder_of(path),name)}
    }
    if message!="" {
        notify(s,message)
        c.create_edit=true
        return
    }
    content_create_end(c)
}

// A line names what Create makes of kind, with a free name to type over:
// Enter or a click elsewhere makes it, Escape leaves it.
content_create_begin :: proc(s:^Session,kind:asset.Fourcc,folder:string) {
    c:=s.content
    r:=files_registry(s)
    if c==nil || r==nil || asset_create_refusal(s)!="" {return}
    extension:=asset_create_extension(s,kind)
    path:=asset_create_path(r,folder,asset_create_default(s,kind),extension)
    c.create_name_length=copy(c.create_name[:],path[len(folder)+(1 if folder!="" else 0):len(path)-len(extension)])
    c.create_folder_length=copy(c.create_folder[:],folder)
    c.creating,c.create_kind,c.create_edit=true,kind,true
    c.rename_length,c.renaming=0,{}
    c.filter_length,c.categories,c.unused=0,{},false
    c.revision+=1
    content_place_set(c,folder)
}

@(private)
content_create_end :: proc(c:^Content) {
    c.creating,c.create_edit=false,false
    c.rename_length,c.renaming=0,{}
    c.revision+=1
}

// Makes what the line of Create names. A name that cannot be, or is taken,
// keeps the line to type another.
@(private)
content_create_finish :: proc(s:^Session) {
    c:=s.content
    r:=files_registry(s)
    if r==nil {content_create_end(c);return}
    if c.rename_length>0 {content_rename_finish(s);return}
    kind:=c.create_kind
    folder:=string(c.create_folder[:c.create_folder_length])
    extension:=asset_create_extension(s,kind)
    name:=strings.trim_space(string(c.create_name[:c.create_name_length]))
    if extension!="" && strings.has_suffix(name,extension) {name=name[:len(name)-len(extension)]}
    if refused:=asset_name_refusal(name);refused!="" {
        notify(s,refused)
        c.create_edit=true
        return
    }
    path:=asset_create_join(folder,name,extension)
    if asset_path_taken(r,path) {
        notify(s,fmt.tprintf("%s already exists: give another name",path))
        c.create_edit=true
        return
    }
    id:base.Asset_Id
    if kind!=ASSET_CREATE_FOLDER {id=asset_id_new(s)}
    content_create_end(c)
    if problem:=asset_create(s,kind,path,id);problem!="" {
        notify(s,problem)
        return
    }
    if kind==ASSET_CREATE_FOLDER {
        content_place_set(c,path)
        return
    }
    c.created=id
}

// The line of Create: the icon of its kind and the field of its name. Returns
// whether to make or rename what it names, once the lines are built: that
// changes the registry their names are in.
@(private)
content_create_line :: proc(s:^Session) -> (finish:bool) {
    c:=s.content
    ctx:=s.gui.ctx
    field:=ui.id(ctx,"content_create_name")
    icon,color:=content_create_icon(s,c.create_kind)
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(CONTENT_ROW),padding={CONTENT_INSET,2,CONTENT_INSET,2},gap=7,align_y=.Center}) {
        ui.icon(ctx,icon,color,14)
        if c.create_edit {
            ui.edit_request(ctx,field)
            c.create_edit=false
        }
        r:=ui.text_field(ctx,field,c.create_name[:],&c.create_name_length,{height=CONTENT_ROW-4})
        switch {
        case r.cancelled: content_create_end(c)
        case r.committed || !r.editing && !r.began && ctx.edit.id!=field: finish=true
        }
    }
    return
}

// What Create made comes into sight once the registry has it: selected, with
// the keyboard, and open in its document when its kind has one. What its
// plugin was asked for and did not write is told.
@(private)
content_created :: proc(s:^Session,registry:^asset.Registry) {
    c:=s.content
    file,found:=asset.registry_find(registry,c.created)
    if !found {
        notify(s,"The new asset could not be made")
        c.created={}
        return
    }
    c.created={}
    c.selected,c.selected_clip,c.reveal=file.id,0,file.id
    content_used(s,file.id)
    switch {
    case file.kind==asset.KIND_SCENE: if s.mode==.Edit {file_open_path(s,file.path)}
    case asset_document_opens(s,file.kind): asset_document_open(s,file.id)
    }
}

@(private)
content_settings_popup :: proc(g:^Editor_Ui) -> ui.Id {return shell_id(g,"content_settings")}

@(private)
content_settings_button :: proc(s:^Session,id:ui.Id,height:f32=22) {
    ctx:=s.gui.ctx
    popup:=content_settings_popup(s.gui)
    if ui.button(ctx,id,{icon=ui.icon_user(u8(User_Icon.Gear)),icon_color=ui.tone(ctx,"text_muted"),variant="toggle",width=height,height=height,disabled=s.content==nil,active=ui.popup_is_open(ctx,popup)}).clicked && !ui.popup_is_open(ctx,popup) {
        anchor,_:=ui.widget_rect(ctx,id)
        ui.popup_open(ctx,popup,anchor)
    }
}

// The gear of the panel. content_view: Content Browser is shown, not Editor.
@(private)
content_settings_build :: proc(s:^Session,content_view:bool) {
    c:=s.content
    if c==nil {return}
    ctx:=s.gui.ctx
    popup:=content_settings_popup(s.gui)
    if ui.popup(ctx,popup,{width=230}) {
        ui.id_push(ctx,popup)
        if content_view {
            ui.menu_header(ctx,"Layout")
            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,padding=ui.padding_all(2),gap=2,fill=ui.tone(ctx,"field"),radius=4}) {
                labels:=[Content_Arrangement]string{.Names="Names",.Tabs="Tabs",.Cards="Cards"}
                for arrangement in Content_Arrangement {
                    if !ui.button(ctx,ui.id(ctx,"layout",int(arrangement)+1),{label=labels[arrangement],variant="tab",active=c.view.arrangement==arrangement,width=-1,height=24,size=ui.metric(ctx,"font_small"),padding=4,center=true}).clicked {continue}
                    c.view.arrangement=arrangement
                    c.scroll=0
                }
            }
            if ui.menu_item(ctx,ui.id(ctx,"unused"),"Only unused assets",{icon=.Filter,checked=c.unused}) {
                c.unused=!c.unused
                c.scroll=0
            }
            if ui.menu_item(ctx,ui.id(ctx,"parts"),"Show parts of imports",{icon=.Layers,checked=c.view.show_parts}) {
                c.view.show_parts=!c.view.show_parts
                c.scroll=0
            }
        } else {
            // The browser has its own slider, under its search.
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"control")),padding={6,0,6,0},gap=7,align_y=.Center}) {
                ui.label(ctx,"Size",ui.metric(ctx,"font_small"),ui.tone(ctx,"text"),32)
                level:=f64(content_level(c.view))
                if kit.slider_field(ctx,ui.id(ctx,"size"),&level,{min=0,max=CONTENT_LEVELS,has_min=true,has_max=true,integer=true,height=22}).changed {
                    content_level_set(&c.view,int(level))
                    c.scroll=0
                }
            }
        }
        ui.menu_separator(ctx)
        if ui.menu_item(ctx,ui.id(ctx,"reload"),"Refresh assets",{icon=.Refresh,disabled=s.app.assets==nil}) {
            if asset.registry_scan(&s.app.assets.registry)!=.None {notify(s,"The asset folder could not be read")}
        }
        command_menu_item(s,ui.id(ctx,"import"),"import","Import")
        ui.id_pop(ctx)
    }
}

@(private)
// points: the side it is shown at. clip: of an animation, from 1; 0: the asset.
content_preview :: proc(s:^Session,file:^asset.Registry_File,points:f32,clip:u32=0) -> (icon:ui.Icon,color:ui.Color,quad:ui.Quad) {
    icon,color=asset_file_icon(s,file)
    a:=s.app.assets
    if a.renderer==nil {return}
    switch file.kind {
    case asset.KIND_MATERIAL:  quad=ui.quad_whole(host.UI_QUAD_MATERIAL_PREVIEW,host.assets_material_row(a,file.id))
    case asset.KIND_MESH:      quad=preview_geometry(s,.None,file.id,points)
    case asset.KIND_TEXTURE:   quad=texture_quad(s,file.id)
    case asset.KIND_SCENE:     quad=preview_document(s,file.id,points) if asset.registry_prefab(file) else preview_scene(s,file.id,points)
    case:                      quad=preview_provided(s,file,clip,points)
    }
    if quad.kind!=.Solid {icon=.None}
    return
}

// A row of a list of a panel that names an asset, as the list of the browser
// shows one: its thumbnail and its label, with the color of its kind while it
// is selected. What follows the label goes before asset_list_row_end; what a
// click on it does is the caller's.
asset_list_row_begin :: proc(s:^Session,id:ui.Id,value:base.Asset_Id,kind:asset.Fourcc,label:string,selected:bool) -> (it:ui.Interaction) {
    ctx:=s.gui.ctx
    it=ui.interact(ctx,id,{.Focusable})
    file:^asset.Registry_File
    if value!={} && s.app!=nil && s.app.assets!=nil {file,_=asset.registry_find(&s.app.assets.registry,value)}
    color:=file!=nil?asset_file_color(s,file):asset_kind_color(s,kind)
    ui.box_begin(ctx,asset_row_box(ctx,id,4,selected,it.hot,content_keyboard(ctx,it)))
    if file!=nil {
        asset_thumbnail(s,file,20)
    } else {
        icon,_:=asset_icon(s,kind)
        asset_frame(s,20,color,CONTENT_FRAME_EDGE,1,{},icon,color,kind)
    }
    ui.label(ctx,label,ui.metric(ctx,"font"),ui.tone(ctx,"text"),0,font=ui.FONT_MEDIUM if selected else 0)
    return
}

// The box of a row of a list of assets: the fill of a selected row of the
// editor while it is selected, the field under the pointer, and the ring of
// the keyboard, the only light one, while the keys moved to it.
@(private)
asset_row_box :: proc(ctx:^ui.Context,id:ui.Id,indent:f32,selected,hot,keyboard:bool) -> ui.Box {
    fill:=ui.tone(ctx,"accent_soft") if selected else (ui.tone(ctx,"field") if hot else {})
    return {id=id,width=ui.GROW,height=ui.fixed(CONTENT_ROW),padding={indent,3,4,3},gap=7,align_y=.Center,fill=fill,stroke=ui.tone(ctx,"text") if keyboard else {},stroke_width=CONTENT_RING_WIDTH,radius=3}
}

// Whether the keys moved to a card or a row: it shows the ring of the
// keyboard, apart from its selection.
@(private)
content_keyboard :: proc(ctx:^ui.Context,it:ui.Interaction) -> bool {return it.focused && ctx.focus_ring}

// The box of a cell of the grid: filled while it is selected, and the ring
// of the keyboard while the keys moved to it.
@(private)
asset_card_box :: proc(ctx:^ui.Context,id:ui.Id,view:Content_View,cell:f32,selected,keyboard:bool,names:u8=2) -> ui.Box {
    return {id=id,width=ui.fixed(cell),height=ui.fixed(content_card_height(view,cell,names)),direction=.Column,gap=CONTENT_NAME_GAP,fill=ui.tone(ctx,"accent_soft") if selected else {},stroke=ui.tone(ctx,"text") if keyboard else {},stroke_width=CONTENT_RING_WIDTH}
}
asset_list_row_end :: proc(s:^Session) {ui.box_end(s.gui.ctx,{})}

// The columns of a grid of asset cells of a panel in a width and the side of
// each, at the zoom and in the mode the content browser has: one column in
// its list.
asset_cards :: proc(s:^Session,width:f32) -> (columns:int,cell:f32) {
    return content_cells(asset_cards_view(s),width)
}

@(private)
asset_cards_view :: proc(s:^Session) -> Content_View {
    return s.content.view if s.content!=nil else CONTENT_VIEW_DEFAULT
}

// A cell of a panel that names an asset as the browser shows one: a row of
// its list, or a thumbnail of side cell with the label under it while the
// browser shows names. What follows goes before asset_card_end: after the
// label of a row, floating over a cell (asset_card_float). What a click on
// it does is the caller's.
asset_card_begin :: proc(s:^Session,id:ui.Id,value:base.Asset_Id,kind:asset.Fourcc,label:string,selected:bool,cell:f32) -> (it:ui.Interaction) {
    view:=asset_cards_view(s)
    if view.mode==.List {return asset_list_row_begin(s,id,value,kind,label,selected)}
    ctx:=s.gui.ctx
    it=ui.interact(ctx,id,{.Focusable})
    file:^asset.Registry_File
    if value!={} && s.app!=nil && s.app.assets!=nil {file,_=asset.registry_find(&s.app.assets.registry,value)}
    ui.box_begin(ctx,asset_card_box(ctx,id,view,cell,selected,content_keyboard(ctx,it)))
    if file!=nil {
        asset_thumbnail(s,file,cell,it.hot,selected=selected)
    } else {
        color:=asset_kind_color(s,kind)
        icon,_:=asset_icon(s,kind)
        edge,width:=asset_frame_edge(ctx,it.hot,selected)
        asset_frame(s,cell,color,edge,width,{},icon,color,kind)
    }
    names:=content_shows_names(view)
    if names {content_name(ctx,label,selected,cell)}
    if it.hot && (!names || content_name_cut(ctx,label,cell)) {ui.tooltip(ctx,label)}
    return
}

asset_card_end :: proc(s:^Session) {ui.box_end(s.gui.ctx,{})}

// Where what goes over a cell of the grid floats: the top left corner of its
// thumbnail. In the list it follows the label.
asset_card_float :: proc(s:^Session) -> ui.Float {
    if asset_cards_view(s).mode==.List {return {}}
    return {to=.Parent,anchor=.Top_Left,pivot=.Top_Left,offset={3,3}}
}

// Whether the name under a cell takes more than its names lines: then it is
// cut and the pointer on the cell shows it whole.
@(private)
content_name_cut :: proc(ctx:^ui.Context,name:string,cell:f32,names:u8=2) -> bool {
    lines:=ui.text_lines(&ctx.font,name,ui.metric(ctx,"font_small"),cell-2,.Words)
    count:=0
    for {
        _,_,ok:=ui.text_lines_next(&lines)
        if !ok {break}
        count+=1
        if count>int(names if names>0 else 2) {return true}
    }
    return false
}

// The name under the thumbnail of a cell, in up to names lines as wide as it,
// the last ending in an ellipsis when more does not fit.
@(private)
content_name :: proc(ctx:^ui.Context,name:string,selected:bool,cell:f32,names:u8=2,ink:ui.Color={}) {
    color:=ink
    if color=={} {color=ui.tone(ctx,"text") if selected else ui.tone(ctx,"text_muted")}
    if ui.box(ctx,{width=ui.fixed(cell),height=ui.fixed(f32(names if names>0 else 2)*CONTENT_NAME_LINE),padding={1,0,1,0}}) {
        style:=ui.Text_Style{font=ui.FONT_MEDIUM if selected else 0,size=ui.metric(ctx,"font_small"),color=color,wrap=.Words,ellipsis=true,line_height=CONTENT_NAME_LINE/ui.metric(ctx,"font_small")}
        ui.text(ctx,name,style,ui.GROW,ui.GROW)
    }
}

// The border of a thumbnail and its width: faint, lighter under the
// pointer, and violet while it is selected.
@(private)
asset_frame_edge :: proc(ctx:^ui.Context,hot,selected:bool) -> (ui.Color,f32) {
    if selected {return ui.tone(ctx,"toggle_on_stroke"),1}
    return ui.tone(ctx,"border") if hot else CONTENT_FRAME_EDGE,1
}

// The thumbnail of an asset of a card, a row or a field: its preview over a
// dark square with a faint border and the line of the color of its type
// under it. clip: a clip of an animation, from 1, which shows Play until its
// preview is there.
@(private)
asset_thumbnail :: proc(s:^Session,file:^asset.Registry_File,side:f32,hot:bool=false,clip:u32=0,selected:bool=false) {
    ctx:=s.gui.ctx
    color:=asset_file_color(s,file)
    icon,_,quad:=content_preview(s,file,side,clip)
    if clip>0 && quad.kind==.Solid {icon=.Play}
    edge,width:=asset_frame_edge(ctx,hot,selected)
    asset_frame(s,side,color,edge,width,quad,icon,ui.tone(ctx,"accent") if clip>0 else color,file.kind)
}

// The thumbnail of a cell of the browser: square at its corners, with no
// border unless something marks it: the asset placement carries, the first
// result of a search, the selection or the pointer.
@(private)
content_thumbnail :: proc(s:^Session,file:^asset.Registry_File,side:f32,hot:bool,clip:u32,selected,armed,first:bool) {
    ctx:=s.gui.ctx
    color:=asset_file_color(s,file)
    icon,_,quad:=content_preview(s,file,side,clip)
    if clip>0 && quad.kind==.Solid {icon=.Play}
    edge:ui.Color
    width:=f32(1)
    switch {
    case armed:    edge,width=ui.tone(ctx,"text"),2
    case selected: edge=ui.tone(ctx,"toggle_on_stroke")
    case first:    edge=ui.tone(ctx,"text_muted")
    case hot:      edge=ui.tone(ctx,"border")
    }
    asset_frame(s,side,color,edge,width,quad,icon,ui.tone(ctx,"accent") if clip>0 else color,file.kind,radius=0)
}

// The clip a card of a clip is in its animation, from 1; 0 for the card of a file.
@(private)
content_clip_index :: proc(c:^Content,card:Content_Card) -> u32 {
    if card.clip<=0 || int(card.clip)>len(c.clips) {return 0}
    at:=int(card.clip)-1
    library:=c.clips[at].library
    first:=at
    for first>0 && c.clips[first-1].library==library {first-=1}
    return u32(at-first+1)
}

// A square of side points with the border of stroke, a preview or an icon in
// the middle and the line of color along its bottom. The line is part of the
// layout, not a float, so a list that clips the square clips it too. radius:
// below 0, that of a thumbnail of its size.
@(private)
asset_frame :: proc(s:^Session,side:f32,color,stroke:ui.Color,stroke_width:f32,quad:ui.Quad,icon:ui.Icon,icon_color:ui.Color,kind:asset.Fourcc,radius:f32=-1) {
    ctx:=s.gui.ctx
    if ui.box(ctx,{width=ui.fixed(side),height=ui.fixed(side),direction=.Column,padding={1,1,1,1},fill=CONTENT_FRAME,stroke=stroke,stroke_width=stroke_width,radius=radius if radius>=0 else (4 if side>24 else 3)}) {
        if ui.box(ctx,{width=ui.GROW,height=ui.GROW,align_x=.Center,align_y=.Center}) {
            if quad.kind!=.Solid {
                inner:=side-2 if kind==asset.KIND_TEXTURE || kind==asset.KIND_SCENE else side*(0.78 if kind==asset.KIND_MATERIAL else 0.86)
                ui.image(ctx,{quad=quad,width=ui.fixed(min(inner,side-2)),height=ui.fixed(min(inner,side-2-CONTENT_BAR))})
            } else if icon!=.None {ui.icon(ctx,icon,icon_color,side*0.42)}
        }
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(CONTENT_BAR),fill=color}) {}
    }
}

// The star that marks an asset as a favorite; small: on a cell with no name.
@(private)
content_star :: proc(s:^Session,id:ui.Id,asset_id:base.Asset_Id,favorite:bool,float:ui.Float={},small:=false) {
    ctx:=s.gui.ctx
    side:=f32(13) if small else 18
    if ui.box(ctx,{width=ui.FIT,height=ui.FIT,float=float,fill={20,22,27,217} if float.to!=.None else {},radius=3}) {
        if ui.button(ctx,id,{icon=ui.icon_user(u8(User_Icon.Star_Filled if favorite else User_Icon.Star)),icon_color=STAR_COLOR if favorite else ui.tone(ctx,"text_muted"),variant="ghost",width=side,height=side,icon_size=side*0.66,padding=-1,center=true}).clicked {
            content_favorite_toggle(s.content,asset_id)
        }
    }
}

// The arrow of a library or an owner that shows or hides its clips or parts.
@(private)
content_expander :: proc(s:^Session,card:Content_Card,key:u64,float:ui.Float) {
    ctx:=s.gui.ctx
    if ui.box(ctx,{width=ui.FIT,height=ui.FIT,float=float,fill={20,22,27,217} if float.to!=.None else {},radius=3}) {
        if ui.button(ctx,ui.id(ctx,"content_unfold",int(key)),{icon=.Chevron_Down if card.open else .Chevron_Right,icon_color=ui.tone(ctx,"text_muted"),variant="ghost",width=16,height=22,icon_size=12}).clicked {
            content_unfold(s.content,s.app.assets.registry.files[card.file].id)
        }
    }
}

// What tells a card from the others: its path, its clip, whether it shows after
// its owner and the section it is in, where an asset of a folder also is.
@(private)
content_card_key :: proc(path:string,card:Content_Card,group:u64) -> u64 {
    key:=base.hash64(transmute([]u8)path)~u64(card.clip)
    if card.part {key~=0xc2b2ae3d27d4eb4f}
    if group!=0 {key~=group*0x9e3779b97f4a7c15}
    return key
}

// Whether placement carries an asset.
@(private)
content_armed :: proc(s:^Session,id:base.Asset_Id) -> bool {
    g:=s.gui
    return g.placement.active && g.placement.kind==.Asset && g.placement.asset_id==id
}

@(private)
content_card_selected :: proc(s:^Session,file:^asset.Registry_File,clip:i32) -> bool {
    c:=s.content
    g:=s.gui
    if clip!=0 {return c.selected==file.id && c.selected_clip==clip}
    return c.selected==file.id && c.selected_clip==0 || slice.contains(c.picked[:],file.id) || g.drag.kind==.Asset && g.drag.asset_id==file.id || content_armed(s,file.id)
}

// What the pointer on a cell says of it, as its type shows nowhere else.
@(private)
content_item_tip :: proc(s:^Session,card:Content_Card,file:^asset.Registry_File) -> string {
    registry:=&s.app.assets.registry
    if card.clip>0 {return "Clip"}
    if content_part(registry,file) {
        owner,_:=asset.registry_find(registry,file.owner)
        return fmt.tprintf("%s, in %s",asset_file_label(s,file),asset_name(owner.path))
    }
    if agent:=ai_asset_mark(s,file.path);agent!=nil {return fmt.tprintf("%s · %s",asset_file_label(s,file),ai_chat_title(base.text_get(agent.title[:])))}
    return asset_file_label(s,file)
}

// The mark of an asset a unit changed and that waits for review, in the color of its agent.
@(private)
content_review_badge :: proc(ctx:^ui.Context,agent:^Ai_Task,float:ui.Float) {
    if ui.box(ctx,{width=ui.fixed(CONTENT_REVIEW_BADGE),height=ui.fixed(CONTENT_REVIEW_BADGE),fill=ai_agent_color(agent),stroke=CONTENT_FRAME,stroke_width=1,radius=CONTENT_REVIEW_BADGE*0.5,float=float}) {}
}

// A cell of the grid or a row of the list, with its star, the arrow of a
// library and the mark of unsaved changes.
@(private)
// whole: its line is all in sight; the buttons that float over a cell stay out
// of one the edge of the list cuts, as floats are not clipped. first: the first
// result of a search, which Enter takes.
content_item :: proc(s:^Session,card:Content_Card,group:u64,cell:f32,whole,first:bool,names:u8=2) -> (it:ui.Interaction,id:ui.Id) {
    c:=s.content
    ctx:=s.gui.ctx
    registry:=&s.app.assets.registry
    file:=&registry.files[card.file]
    key:=content_card_key(file.path,card,group)
    id=ui.id(ctx,"content_entry",int(key))
    it=ui.interact(ctx,id,{.Focusable})
    selected:=content_card_selected(s,file,card.clip)
    star:=ui.id(ctx,"content_star",int(key))
    favorite:=card.clip==0 && content_favorite(&c.marks,file.id)
    starred:=card.clip==0 && (favorite || it.hot || ctx.hot==star)
    unsaved:=card.clip==0 && asset_unsaved(s,file.id)
    reviewed:=ai_asset_mark(s,file.path) if card.clip==0 else nil
    shown:=content_shows_names(c.view)
    if c.view.mode==.List {
        if ui.box(ctx,asset_row_box(ctx,id,CONTENT_INSET,selected,it.hot,content_keyboard(ctx,it))) {
            asset_thumbnail(s,file,20,clip=content_clip_index(c,card))
            ui.label(ctx,card.name,ui.metric(ctx,"font"),ui.tone(ctx,"text"),0,font=ui.FONT_MEDIUM if selected else 0)
            if unsaved {
                if ui.box(ctx,{width=ui.fixed(5),height=ui.fixed(5),fill=UNSAVED_COLOR,radius=2.5}) {}
            }
            if reviewed!=nil {content_review_badge(ctx,reviewed,{})}
            if card.holds {content_expander(s,card,key,{})}
            if starred {content_star(s,star,file.id,favorite)} else {ui.spacer(ctx,18,18)}
        }
        if it.hot {ui.tooltip(ctx,content_item_tip(s,card,file))}
        return
    }
    if ui.box(ctx,asset_card_box(ctx,id,c.view,cell,selected,content_keyboard(ctx,it),names)) {
        content_thumbnail(s,file,cell,it.hot,content_clip_index(c,card),selected,card.clip==0 && content_armed(s,file.id),first)
        if shown {content_name(ctx,card.name,selected,cell,names)}
        inset:=f32(3)
        if starred && whole {content_star(s,star,file.id,favorite,{to=.Parent,anchor=.Top_Left,pivot=.Top_Left,offset={inset,inset}},small=!shown)}
        if card.holds && whole && (shown || it.hot || card.open) {content_expander(s,card,key,{to=.Parent,anchor=.Top_Right,pivot=.Center_Right,offset={-2,cell*0.5}})}
        if unsaved && whole {
            if ui.box(ctx,{width=ui.fixed(5),height=ui.fixed(5),fill=UNSAVED_COLOR,radius=2.5,float={to=.Parent,anchor=.Top_Right,pivot=.Top_Right,offset={-inset-2,inset+2}}}) {}
        }
        if reviewed!=nil && whole {content_review_badge(ctx,reviewed,{to=.Parent,anchor=.Top_Left,pivot=.Bottom_Left,offset={inset,cell-inset-CONTENT_BAR}})}
    }
    if it.hot && (shown || reviewed!=nil) {
        tip:=content_item_tip(s,card,file)
        if content_name_cut(ctx,card.name,cell,names) {tip=fmt.tprintf("%s: %s",card.name,tip)}
        ui.tooltip(ctx,tip)
    }
    return
}

// The icon of a folder of the assets or of a virtual one.
@(private)
content_folder_icon :: proc(virtual:Content_Virtual) -> ui.Icon {
    switch virtual {
    case .None:      return ui.icon_user(u8(User_Icon.Folder))
    case .Recent:    return .History
    case .Scene:     return .Scene
    case .Favorites: return ui.icon_user(u8(User_Icon.Star))
    }
    return .None
}

// A folder as a cell of an asset: square, with its cover or its icon and its
// name under it, or inside the square when cells carry no names.
@(private)
content_folder_cell :: proc(s:^Session,card:Content_Card,id:ui.Id,cell:f32,names:u8,marked:bool) -> (it:ui.Interaction) {
    c:=s.content
    ctx:=s.gui.ctx
    it=ui.interact(ctx,id,{.Focusable})
    icon:=content_folder_icon(card.virtual)
    keyboard:=content_keyboard(ctx,it)
    if c.view.mode==.List {
        if ui.box(ctx,asset_row_box(ctx,id,CONTENT_INSET,marked,it.hot,keyboard)) {
            ui.icon(ctx,icon,ui.tone(ctx,"text_muted"),16)
            ui.label(ctx,card.name,ui.metric(ctx,"font"),ui.tone(ctx,"text"),0)
        }
        return
    }
    shown:=content_shows_names(c.view)
    if ui.box(ctx,{id=id,width=ui.fixed(cell),height=ui.fixed(content_card_height(c.view,cell,names)),direction=.Column,gap=CONTENT_NAME_GAP,stroke=ui.tone(ctx,"text") if keyboard else {},stroke_width=CONTENT_RING_WIDTH}) {
        fill:=ui.tone(ctx,"accent_soft") if marked else (ui.tone(ctx,"field_hover") if it.hot else ui.tone(ctx,"field"))
        if ui.box(ctx,{width=ui.fixed(cell),height=ui.fixed(cell),direction=.Column,align_x=.Center,align_y=.Center,gap=2,fill=fill,clip_x=true,clip_y=true}) {
            cover:ui.Quad
            if card.cover>0 {cover=texture_quad(s,s.app.assets.registry.files[card.cover-1].id)}
            if cover.kind!=.Solid {
                ui.image(ctx,{quad=cover,width=ui.GROW,height=ui.GROW})
            } else {
                ui.icon(ctx,icon,ui.tone(ctx,"text_muted"),cell*0.44)
            }
            if !shown {ui.label(ctx,card.name,ui.metric(ctx,"font_caption"),ui.tone(ctx,"text"),cell-4,center=true)}
        }
        if shown {content_name(ctx,card.name,false,cell,names,ink=ui.tone(ctx,"text"))}
    }
    if it.hot && (!shown || content_name_cut(ctx,card.name,cell,names)) {ui.tooltip(ctx,card.folder if card.virtual==.None else card.name)}
    return
}

// The name of a folder in the wall, which enters it; of a subfolder under a
// folder, the way down to it. marked: the folder an asset goes to.
@(private)
content_header :: proc(s:^Session,line:Content_Line,id:ui.Id,width:f32,marked:bool=false) -> ui.Interaction {
    ctx:=s.gui.ctx
    it:=ui.interact(ctx,id,{.Focusable})
    header:=line.kind==.Header
    height:=CONTENT_HEADER if header else CONTENT_SUBHEADER
    fill:=ui.tone(ctx,"accent_soft") if marked else (ui.tone(ctx,"field") if it.hot else (ui.tone(ctx,"panel") if header else {}))
    icon,color:=ui.icon_user(u8(User_Icon.Folder)),ui.tone(ctx,"text_faint")
    #partial switch line.virtual {
    case .Recent:    icon,color=.History,ui.tone(ctx,"text_muted")
    case .Scene:     icon,color=ui.icon_user(u8(User_Icon.Scene)),ui.tone(ctx,"text_muted")
    case .Favorites: icon,color=ui.icon_user(u8(User_Icon.Star_Filled)),STAR_COLOR
    }
    folded:=content_folded(s.content,line.group)
    if ui.box(ctx,{id=id,width=ui.fixed(width),height=ui.fixed(height),padding={2,0,2,0},gap=6,align_y=.Center,fill=fill}) {
        if ui.button(ctx,ui.id_derive(ctx,id,"fold"),{icon=folded?.Chevron_Right:.Chevron_Down,icon_color=ui.tone(ctx,"text_faint"),icon_size=10,variant="ghost",width=16,height=height-4}).clicked {content_fold_flip(s.content,line.group)}
        ui.icon(ctx,icon,color,14)
        if line.cover>0 {
            cover:=texture_quad(s,s.app.assets.registry.files[line.cover-1].id)
            if ui.box(ctx,{width=ui.fixed(CONTENT_COVER),height=ui.fixed(CONTENT_COVER),fill=ui.tone(ctx,"field"),radius=2,clip_x=true,clip_y=true}) {
                if cover.kind!=.Solid {ui.image(ctx,{quad=cover,width=ui.GROW,height=ui.GROW})}
            }
        }
        name:=line.name if header else strings.join(strings.split(line.name,"/",context.temp_allocator)," / ",context.temp_allocator)
        ui.label(ctx,name,ui.metric(ctx,"font") if header else ui.metric(ctx,"font_small"),ui.tone(ctx,"text") if header || it.hot else ui.tone(ctx,"text_muted"),0,font=ui.FONT_MEDIUM if header else 0)
    }
    if it.hot {ui.tooltip(ctx,line.path if line.virtual==.None else line.name)}
    return it
}

// What the name that stays on top covers past the edge of the list: at a
// fractional density the two round to different pixels.
CONTENT_PIN_BLEED :: f32(4)

// Whether Names shows only the name of a folder.
@(private)
content_folded :: proc(c:^Content,group:u64) -> bool {return slice.contains(c.folded[:],group)}

@(private)
content_fold_flip :: proc(c:^Content,group:u64) {
    if at,found:=slice.linear_search(c.folded[:],group);found {unordered_remove(&c.folded,at)} else {append(&c.folded,group)}
    c.revision+=1
}

// What the lines of a frame ask for, done once they are built: their names
// are in the registry the scan that moves or makes files replaces.
@(private)
Content_Actions :: struct {
    enter,reset:bool,        // go to folder or virtual; reset: forgetting where it was
    virtual:Content_Virtual,
    folder:string,
    back:bool,
    cut:int,                 // the trail keeps this many assets; 0: as it is
    finish:bool,             // make what the line of Create names
    dropped:bool,            // the asset carried goes to drop
    drop:string,
    open:string,             // a scene or prefab to open
}

// Whether a folder shows as the one an asset goes to: the one Create makes
// in, or the one a card carried is over.
@(private)
content_folder_marked :: proc(s:^Session,id:ui.Id,virtual:Content_Virtual,folder:string) -> bool {
    g:=s.gui
    ctx:=g.ctx
    if virtual!=.None {return false}
    if ui.popup_is_open(ctx,content_create_id(g)) && string(s.content.create_into[:s.content.create_into_length])==folder {return true}
    rect,built:=ui.widget_rect(ctx,id)
    return built && g.drag.kind==.Asset && drag_over(g,rect)
}

// What a name, a chip or a cell of a folder does: a click enters it, the right
// button opens Create in it and a card let go on it moves there. A virtual
// folder is only entered.
@(private)
content_folder_take :: proc(s:^Session,act:^Content_Actions,id:ui.Id,it:ui.Interaction,virtual:Content_Virtual,folder:string,reset:=false) {
    g:=s.gui
    ctx:=g.ctx
    if it.clicked {act.enter,act.reset,act.virtual,act.folder=true,reset,virtual,folder}
    if virtual!=.None {return}
    if g.drag.kind==.Asset {
        if rect,built:=ui.widget_rect(ctx,id);built && drag_dropped(g,rect) {act.dropped,act.drop=true,strings.clone(folder,context.temp_allocator)}
    }
    if it.right {
        content_place_set(s.content,folder)
        content_create_open(s,folder,{ctx.pointer.x,ctx.pointer.y,0,0},true)
    }
}

@(private)
content_more_popup :: proc(g:^Editor_Ui) -> ui.Id {return shell_id(g,"content_more")}

// The kinds the strip has no room for: its swatch, its name and a check. A
// click keeps the menu open.
@(private)
content_more_menu :: proc(s:^Session) {
    c:=s.content
    ctx:=s.gui.ctx
    popup:=content_more_popup(s.gui)
    if ui.popup(ctx,popup,{min_width=150}) {
        ui.id_push(ctx,popup)
        defer ui.id_pop(ctx)
        labels:=CONTENT_CATEGORY_LABELS
        for category in CONTENT_MENU_CATEGORIES {
            id:=ui.id(ctx,"category",int(category)+1)
            it:=ui.interact(ctx,id,{.Focusable})
            if ui.box(ctx,{id=id,width=ui.GROW,height=ui.fixed(ui.metric(ctx,"control")),padding={8,0,8,0},gap=8,align_y=.Center,fill=ui.color_hover(ctx) if it.hot else {},radius=ui.metric(ctx,"radius_control")}) {
                if ui.box(ctx,{width=ui.fixed(10),height=ui.fixed(10),fill=content_category_color(category)}) {}
                ui.label(ctx,labels[category],ui.metric(ctx,"font"),ui.tone(ctx,"text"),0)
                if category in c.categories {ui.icon(ctx,.Check,ui.tone(ctx,"text_muted"),10)}
            }
            if it.clicked {
                c.categories~={category}
                c.scroll=0
            }
        }
    }
}

@(private)
content_category_color :: proc "contextless" (category:Content_Category) -> ui.Color {
    kinds:=CONTENT_CATEGORY_KINDS
    #partial switch category {
    case .Plugin: return CONTENT_PLUGIN_COLOR
    case .Prefab: return PREFAB_ASSET_COLOR
    }
    return asset_color(kinds[category])
}

// The search, what the selection of the viewport uses, Create and the gear.
// Returns whether Enter took the first result of the search.
@(private)
content_search_row :: proc(s:^Session,filter_id:ui.Id) -> (take_first:bool) {
    c:=s.content
    ctx:=s.gui.ctx
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(CONTENT_CONTROL),gap=4,align_y=.Center}) {
        editing:=ctx.edit.id==filter_id
        if search_field(s,filter_id,c.filter[:],&c.filter_length,"Search assets") {
            c.scroll=0
            if c.filter_length>0 && len(c.trail)>0 {
                clear(&c.trail)
                c.revision+=1
            }
        }
        take_first=editing && .Enter in ctx.input.keys_pressed && c.filter_length>0
        if ui.button(ctx,ui.id(ctx,"content_selection"),{icon=.Target,icon_color=ui.tone(ctx,"text_muted"),tip="Selection in the viewport",variant="toggle",active=c.selection_only,width=CONTENT_CONTROL,height=CONTENT_CONTROL}).clicked {
            c.selection_only=!c.selection_only
            c.scroll=0
            c.revision+=1
        }
        content_create_button(s,ui.id(ctx,"content_create_open"),CONTENT_CONTROL)
        content_settings_button(s,ui.id(ctx,"content_settings_open"),CONTENT_CONTROL)
    }
    return
}

// Takes off the filters of kinds and that of the selection of the viewport.
@(private)
content_filters_clear :: proc(c:^Content) {
    c.categories,c.selection_only={},false
    c.scroll=0
    c.revision+=1
}

// The strip of the filters of kinds, the menu of the others and the zoom.
@(private)
content_strip_row :: proc(s:^Session) {
    c:=s.content
    ctx:=s.gui.ctx
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(CONTENT_STRIP_ROW),gap=CONTENT_RAIL_GAP,align_y=.Center}) {
        labels:=CONTENT_CATEGORY_LABELS
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(CONTENT_STRIP_ROW),gap=CONTENT_GAP}) {
            for category in CONTENT_STRIP_CATEGORIES {
                id:=ui.id(ctx,"content_category",int(category)+1)
                it:=ui.interact(ctx,id,{.Focusable})
                on:=category in c.categories
                alpha:=u8(235) if c.categories=={} else (u8(255) if on else u8(46))
                if ui.box(ctx,{id=id,width=ui.GROW,height=ui.fixed(CONTENT_STRIP_ROW),align_y=.Center}) {
                    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(CONTENT_STRIP_BAR),fill=ui.color_alpha(content_category_color(category),alpha)}) {}
                }
                if it.hot {ui.tooltip(ctx,labels[category])}
                if it.clicked {
                    c.categories~={category}
                    c.scroll=0
                }
            }
        }
        popup:=content_more_popup(s.gui)
        opened:=ui.popup_is_open(ctx,popup)
        id:=ui.id(ctx,"content_more_open")
        it:=ui.interact(ctx,id,{.Focusable})
        lit:=c.categories&{.Texture,.Animation,.Sound,.Ui}!={}
        if ui.box(ctx,{width=ui.fixed(CONTENT_FILTERS+CONTENT_FILTERS_CLEAR+2*CONTENT_FILTERS_GAP),height=ui.fixed(CONTENT_STRIP_ROW),padding={0,0,CONTENT_FILTERS_GAP,0},gap=CONTENT_FILTERS_GAP}) {
            if ui.box(ctx,{id=id,width=ui.fixed(CONTENT_FILTERS),height=ui.fixed(CONTENT_STRIP_ROW),align_x=.Center,align_y=.Center,fill=ui.tone(ctx,"text") if lit else (ui.tone(ctx,"field") if it.hot || opened else {}),radius=2}) {
                ui.icon(ctx,.Filter,ui.tone(ctx,"panel") if lit else ui.tone(ctx,"text_muted"),12)
            }
            if c.categories!={} || c.selection_only {
                if ui.button(ctx,ui.id(ctx,"content_filters_clear"),{icon=.Cross,icon_size=12,icon_color=ui.tone(ctx,"text_muted"),tip="Clear filters",variant="ghost",width=CONTENT_FILTERS_CLEAR,height=CONTENT_STRIP_ROW}).clicked {content_filters_clear(c)}
            }
        }
        if it.hot {ui.tooltip(ctx,"More filters")}
        if it.clicked && !opened {
            anchor,_:=ui.widget_rect(ctx,id)
            ui.popup_open(ctx,popup,anchor)
        }
        level:=f64(content_level(c.view))
        zoom:=ui.id(ctx,"content_size")
        if kit.slider_field(ctx,zoom,&level,{width=ui.fixed(CONTENT_ZOOM_WIDTH),height=CONTENT_STRIP_ROW,min=0,max=CONTENT_LEVELS,has_min=true,has_max=true,integer=true,bare=true}).changed {
            content_level_set(&c.view,int(level))
            c.scroll=0
        }
    }
}

// The chips of Tabs: All, the virtual folders and the first-level folders, and
// rows under them with the folders of the one chosen. Returns their height.
@(private)
content_tabs_build :: proc(s:^Session,act:^Content_Actions,width:f32) -> (height:f32) {
    c:=s.content
    ctx:=s.gui.ctx
    Chip :: struct {virtual:Content_Virtual,label,path:string,row:int}
    chips:=make([dynamic]Chip,context.temp_allocator)
    labels:=CONTENT_VIRTUAL_LABELS
    append(&chips,Chip{label="All"})
    for virtual in ([3]Content_Virtual{.Recent,.Scene,.Favorites}) {append(&chips,Chip{virtual=virtual,label=labels[virtual]})}
    for tab in c.tabs {append(&chips,Chip{label=tab.name,path=tab.path,row=tab.row})}
    at:=string(c.at.folder[:c.at.length])
    chip_width :: proc(ctx:^ui.Context,text:string) -> f32 {return ui.text_width(&ctx.font,text,ui.metric(ctx,"font"))+2*CONTENT_TAB_PADDING+1}
    rows:=0
    for i:=0;i<len(chips); {
        row:=chips[i].row
        j:=i
        for j<len(chips) && chips[j].row==row {j+=1}
        // Where each line of the row ends: as many as fit in the width.
        ends:=make([dynamic]int,context.temp_allocator)
        for at_chip:=i;at_chip<j; {
            used:=f32(0)
            for at_chip<j {
                w:=chip_width(ctx,chips[at_chip].label)
                if used>0 && used+CONTENT_TAB_GAP+w>width {break}
                used+=(CONTENT_TAB_GAP if used>0 else 0)+w
                at_chip+=1
            }
            append(&ends,at_chip)
        }
        whole:=f32(len(ends))*CONTENT_TAB+f32(len(ends)-1)*CONTENT_TAB_GAP
        shown:=min(whole,CONTENT_TAB_ROW_MAX)
        scrolls:=whole>CONTENT_TAB_ROW_MAX
        area:=ui.id(ctx,"content_tabs",row+1)
        offset:=&c.tab_scroll[min(row,CONTENT_TAB_ROWS-1)]
        if scrolls {ui.scroll_begin(ctx,area,offset,{height=ui.fixed(shown),gap=CONTENT_TAB_GAP})} else {ui.box_begin(ctx,{id=area,width=ui.GROW,height=ui.fixed(shown),direction=.Column,gap=CONTENT_TAB_GAP})}
        first:=i
        for end in ends {
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(CONTENT_TAB),gap=CONTENT_TAB_GAP}) {
                for chip in chips[first:end] {
                    group:=content_virtual_group(chip.virtual)
                    if chip.virtual==.None && chip.path=="" {group=CONTENT_ALL_GROUP}
                    if chip.path!="" {group=base.hash64(transmute([]u8)chip.path)}
                    id:=ui.id(ctx,"content_folder",int(group))
                    it:=ui.interact(ctx,id,{.Focusable})
                    switch {
                    case chip.virtual!=.None: on:=c.at.virtual==chip.virtual;content_tab_draw(ctx,id,chip.label,on,it,false)
                    case chip.path=="":       content_tab_draw(ctx,id,chip.label,c.at.virtual==.None && at=="",it,content_folder_marked(s,id,.None,""))
                    case:                     content_tab_draw(ctx,id,chip.label,c.at.virtual==.None && (at==chip.path || asset_path_inside(at,chip.path)),it,content_folder_marked(s,id,.None,chip.path))
                    }
                    if it.hot && chip.path!="" {ui.tooltip(ctx,chip.path)}
                    content_folder_take(s,act,id,it,chip.virtual,chip.path,reset=true)
                }
            }
            first=end
        }
        if scrolls {ui.scroll_end(ctx,area,offset)} else {ui.box_end(ctx,{id=area})}
        height+=shown
        rows+=1
        i=j
    }
    if rows>1 {height+=f32(rows-1)*CONTENT_TAB_ROW_GAP}
    return
}

@(private)
content_tab_draw :: proc(ctx:^ui.Context,id:ui.Id,label:string,on:bool,it:ui.Interaction,marked:bool) {
    fill:=ui.tone(ctx,"accent_soft") if marked else (ui.tone(ctx,"text") if on else (ui.tone(ctx,"field_hover") if it.hot else ui.tone(ctx,"field")))
    if ui.box(ctx,{id=id,width=ui.FIT,height=ui.fixed(CONTENT_TAB),padding={CONTENT_TAB_PADDING,0,CONTENT_TAB_PADDING,0},align_y=.Center,fill=fill,radius=3}) {
        ui.label(ctx,label,ui.metric(ctx,"font"),ui.tone(ctx,"panel") if on else ui.tone(ctx,"text_muted"))
    }
}

// A name of the breadcrumb, after a slash unless it is the first.
@(private)
content_crumb :: proc(ctx:^ui.Context,id:ui.Id,name:string,last,slash,marked:bool) -> (it:ui.Interaction) {
    it=ui.interact(ctx,id,{.Focusable})
    if slash {ui.label(ctx,"/",ui.metric(ctx,"font"),ui.tone(ctx,"text_faint"))}
    if ui.box(ctx,{id=id,width=ui.FIT,height=ui.GROW,align_y=.Center,fill=ui.tone(ctx,"accent_soft") if marked else {}}) {
        ui.label(ctx,name,ui.metric(ctx,"font"),ui.tone(ctx,"text") if last || it.hot else ui.tone(ctx,"text_muted"))
    }
    return
}

// Whether the row of the back arrow shows: in the relations of an asset, and
// inside a folder but in Tabs, whose chips say where it is.
@(private)
content_back_shown :: proc(c:^Content) -> bool {
    return len(c.trail)>0 || c.view.arrangement!=.Tabs && (c.at.length>0 || c.at.virtual!=.None)
}

// The back arrow and the breadcrumb: Project and the folders on the way down,
// or the assets the relations went through.
@(private)
content_crumbs_build :: proc(s:^Session,act:^Content_Actions) {
    c:=s.content
    ctx:=s.gui.ctx
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(CONTENT_BACK_ROW),gap=4,align_y=.Center,clip_x=true}) {
        if ui.button(ctx,ui.id(ctx,"content_back"),{icon=ui.icon_user(u8(User_Icon.Back)),icon_color=ui.tone(ctx,"text"),icon_size=13,tip="Back",variant="ghost",width=CONTENT_BACK_ROW,height=CONTENT_BACK_ROW}).clicked {act.back=true}
        registry:=&s.app.assets.registry
        if len(c.trail)>0 {
            for id,i in c.trail {
                file,found:=asset.registry_find(registry,id)
                if content_crumb(ctx,ui.id(ctx,"content_trail",i+1),asset_name(file.path) if found else "?",i==len(c.trail)-1,i>0,false).clicked {act.cut=i+1}
            }
        } else {
            root:=ui.id(ctx,"content_crumb",0)
            folder:=string(c.at.folder[:c.at.length])
            content_folder_take(s,act,root,content_crumb(ctx,root,"Project",c.at.length==0 && c.at.virtual==.None,false,content_folder_marked(s,root,.None,"")),.None,"",reset=true)
            if c.at.virtual!=.None {
                labels:=CONTENT_VIRTUAL_LABELS
                ui.label(ctx,"/",ui.metric(ctx,"font"),ui.tone(ctx,"text_faint"))
                ui.label(ctx,labels[c.at.virtual],ui.metric(ctx,"font"),ui.tone(ctx,"text"))
            } else {
                start,index:=0,1
                for i in 0..=len(folder) {
                    if i<len(folder) && folder[i]!='/' {continue}
                    id:=ui.id(ctx,"content_crumb",index)
                    last:=i==len(folder)
                    it:=content_crumb(ctx,id,folder[start:i],last,true,!last && content_folder_marked(s,id,.None,folder[:i]))
                    if !last {content_folder_take(s,act,id,it,.None,folder[:i])}
                    start,index=i+1,index+1
                }
            }
        }
    }
}

// Placement carries an asset from now on, as a click on its card does, or
// lets go of it.
@(private)
content_arm :: proc(s:^Session,file:^asset.Registry_File,name:string) {
    g:=s.gui
    d:=Drag{kind=.Asset,asset_id=file.id,asset_kind=file.kind}
    d.label_length=copy(d.label[:],name)
    if s.mode==.Play || !placement_subject(d) || play_viewed(s) || watching(s) || scene_covered(s) {return}
    tool_leave(s)
    g.placement={active=!(g.placement.active && placement_same(g.placement.subject,d)),subject=d}
}

@(private)
content_asset_action :: proc(s:^Session,w:core.World_Ref,card:Content_Card,it:ui.Interaction) -> string {
    c:=s.content
    g:=s.gui
    file:=&s.app.assets.registry.files[card.file]
    if .Alt in g.ctx.input.modifiers && !it.right {
        if it.clicked {content_relations_open(c,file.id)}
        return ""
    }
    if card.clip>0 {
        // A clip of a library: it opens in the document of the library, and
        // what it is let go on plays it (asset_drop_take).
        if it.pressed {
            d:=Drag{kind=.Asset,asset_id=file.id,asset_kind=file.kind}
            base.text_set(d.part[:],card.name)
            drag_begin(g,d,card.name)
        }
        if it.clicked {
            clear(&c.picked)
            c.selected,c.selected_clip=file.id,card.clip
        }
        if it.double && s.mode!=.Play && asset_document_opens(s,file.kind) {
            g.drag,g.placement={},{}
            content_used(s,file.id)
            asset_document_open(s,file.id,card.name)
        }
        return ""
    }
    // Ctrl or Shift adds to the selection or takes from it, and does nothing else.
    if .Primary in g.ctx.input.modifiers || .Shift in g.ctx.input.modifiers {
        if it.clicked {
            content_place_set(c,content_folder_of(file.path))
            content_select(c,file.id,true)
        }
        return ""
    }
    if it.pressed {drag_begin(g,{kind=.Asset,asset_id=file.id,asset_kind=file.kind},card.name)}
    if it.clicked || it.right {content_place_set(c,content_folder_of(file.path))}
    if it.clicked {content_select(c,file.id,false)}
    if it.right {
        if !content_selected(c,file.id) {content_select(c,file.id,false)}
        c.menu=file.id
        ui.popup_open(g.ctx,content_menu_id(g),{g.ctx.pointer.x,g.ctx.pointer.y,0,0})
    }
    // While an asset document covers the scene, a click does nothing to it.
    scene:=!scene_covered(s)
    switch {
    case it.double && s.mode!=.Play && file.kind!=asset.KIND_SCENE && asset_document_opens(s,file.kind):
        g.drag,g.placement={},{}
        content_used(s,file.id)
        asset_document_open(s,file.id)
    case file.kind==asset.KIND_MATERIAL && it.clicked && s.mode!=.Play && scene:
        if meshes:=selected_meshes(s,w);len(meshes)>0 {
            content_used(s,file.id)
            material_assign(s,w,meshes[:],file.id)
        }
    case it.clicked && s.mode!=.Play && scene && asset_kind_click(s,w,file):
    case file.kind==asset.KIND_SCENE && it.double && s.mode==.Edit:
        g.drag,g.placement={},{}
        content_used(s,file.id)
        return file.path
    }
    return ""
}

// The selected entities that show a mesh, which a material is assigned to.
@(private)
selected_meshes :: proc(s:^Session,w:core.World_Ref) -> []core.Entity {
    meshes:=make([dynamic]core.Entity,context.temp_allocator)
    for e in s.selection.entities {
        if entity_has(w,e,erender.Mesh_Renderer) {append(&meshes,e)}
    }
    return meshes[:]
}

@(private)
content_menu_id :: proc(g:^Editor_Ui) -> ui.Id {return shell_id(g,"content_menu")}

// The menu of a card: open the asset, walk its relations, show it in its
// folder, assign a material to the selection, star it, and take what a scene
// open in a tab shows as its thumbnail. Returns the path of a scene or prefab
// to open.
@(private)
content_menu :: proc(s:^Session,w:core.World_Ref) -> (open:string) {
    c:=s.content
    g:=s.gui
    ctx:=g.ctx
    popup:=content_menu_id(g)
    a:=s.app.assets
    file:^asset.Registry_File
    found:=false
    if a!=nil {file,found=asset.registry_find(&a.registry,c.menu)}
    if !found {
        if ui.popup_is_open(ctx,popup) {ui.popup_close(ctx,popup)}
        return
    }
    if ui.popup(ctx,popup,{min_width=200}) {
        ui.id_push(ctx,popup)
        defer ui.id_pop(ctx)
        document:=file.kind==asset.KIND_SCENE
        opens:=document?s.mode==.Edit:s.mode!=.Play && asset_document_opens(s,file.kind)
        icon,_:=asset_file_icon(s,file)
        if ui.menu_item(ctx,ui.id(ctx,"open"),"Open",{icon=icon,disabled=!opens}) {
            g.drag,g.placement={},{}
            content_used(s,file.id)
            if document {open=file.path} else {asset_document_open(s,file.id)}
        }
        if ui.menu_item(ctx,ui.id(ctx,"relations"),"Uses / Used by",{icon=.Link,shortcut="Alt+click"}) {content_relations_open(c,file.id)}
        if ui.menu_item(ctx,ui.id(ctx,"show_in_folder"),"Show in folder",{icon=ui.icon_user(u8(User_Icon.Folder))}) {
            content_reveal_begin(c,file.id)
            content_enter(c,.None,content_folder_of(file.path))
        }
        if file.kind==asset.KIND_MATERIAL {
            meshes:=selected_meshes(s,w)
            if ui.menu_item(ctx,ui.id(ctx,"apply"),"Apply to selection",{icon=.Sphere,disabled=len(meshes)==0 || s.mode==.Play || watching(s) || scene_covered(s)}) {
                content_used(s,file.id)
                material_assign(s,w,meshes,file.id)
            }
        }
        if file.kind==asset.KIND_SOUND || file.kind==asset.KIND_SOUND_SET {
            heard:=sound_heard(s,file.id)
            if ui.menu_item(ctx,ui.id(ctx,"listen"),"Stop sound" if heard else "Play sound",{icon=heard?.Stop:.Play,disabled=s.app.mixer==nil}) {
                if heard {sound_hear_stop(s)} else {sound_hear(s,file.id)}
            }
        }
        if asset.registry_prefab(file) {
            if ui.menu_item(ctx,ui.id(ctx,"variant"),"Create variant",{icon=.Prefab,disabled=s.mode!=.Edit || watching(s)}) {
                path:=prefab_variant_path(s,file.id)
                _,error:=prefab_variant_create(s,file.id,path)
                notify(s,error==.None?fmt.tprintf("Prefab variant %s created",path):prefab_error_text(error))
                return // writing the file may move the entries of the registry
            }
        }
        if file.kind==asset.KIND_SCENE && scene_tab(s,file.id)>=0 {
            if ui.menu_item(ctx,ui.id(ctx,"thumbnail"),"Update thumbnail",{icon=command_icon(s,"scene_thumbnail"),disabled=s.mode!=.Edit || !scene_thumbnails_kept(s)}) {scene_thumbnail_update(s,file.id)}
        }
        asset_plugin_menus(s,file)
        if ui.menu_item(ctx,ui.id(ctx,"ask"),"Ask agent",{icon=.Sparkle,disabled=!s.has_project}) {
            asked:=make([dynamic]base.Asset_Id,context.temp_allocator)
            append(&asked,file.id,c.selected)
            append(&asked,..c.picked[:])
            ai_ask(s,asked[:])
        }
        favorite:=content_favorite(&c.marks,file.id)
        if ui.menu_item(ctx,ui.id(ctx,"favorite"),"Remove from favorites" if favorite else "Add to favorites",{icon=ui.icon_user(u8(User_Icon.Star))}) {content_favorite_toggle(c,file.id)}
        // What Create makes, beside it in its folder.
        if ui.submenu(ctx,ui.id(ctx,"new"),"Create",{icon=.Plus}) {content_create_items(s,content_folder_of(file.path))}
        ui.menu_separator(ctx)
        // Duplicating and moving scan the registry again: what follows names the asset by its id.
        id:=file.id
        off:=asset_create_refusal(s)!=""
        if ui.menu_item(ctx,ui.id(ctx,"rename"),command_label(s,"asset_rename"),{icon=command_icon(s,"asset_rename"),shortcut=command_shortcut_text(s,"asset_rename"),disabled=off}) {content_rename_begin(s,id)}
        if ui.menu_item(ctx,ui.id(ctx,"duplicate"),command_label(s,"asset_duplicate"),{icon=command_icon(s,"asset_duplicate"),shortcut=command_shortcut_text(s,"asset_duplicate"),disabled=off}) {content_duplicate(s,id)}
        if ui.submenu(ctx,ui.id(ctx,"move"),"Move to",{icon=ui.icon_user(u8(User_Icon.Folder)),disabled=off}) {content_move_items(s,id,"")}
        if ui.menu_item(ctx,ui.id(ctx,"delete"),command_label(s,"asset_delete"),{icon=command_icon(s,"asset_delete"),shortcut=command_shortcut_text(s,"asset_delete"),danger=true,disabled=s.mode!=.Edit || watching(s)}) {asset_delete_ask(s,id)}
    }
    return
}

// The asset whose card has the keyboard, as content_typing tells it; zero for none.
content_focused :: proc(c:^Content,ctx:^ui.Context) -> base.Asset_Id {
    if c==nil || c.card_focus==0 || ctx.focus!=c.card_focus || ctx.edit.id!=0 {return {}}
    if _,built:=ui.widget_rect(ctx,c.card_focus);!built {return {}}
    return c.focus_asset
}

// What is typed while a card of the browser has the keyboard searches: the
// card focused when the browser was built in the last frame still has it.
content_typing :: proc(c:^Content,ctx:^ui.Context) -> bool {
    if c==nil || c.card_focus==0 || ctx.focus!=c.card_focus || ctx.edit.id!=0 || ctx.input.text_count==0 || ctx.input.modifiers-{.Shift}!={} {return false}
    _,built:=ui.widget_rect(ctx,c.card_focus)
    return built
}

// The filters that could hide an asset go, and it is shown on the next frame.
@(private)
content_reveal_begin :: proc(c:^Content,id:base.Asset_Id) {
    c.reveal=id
    c.filter_length,c.categories,c.unused,c.selection_only=0,{},false,false
    c.revision+=1
    clear(&c.picked)
}

// Shows an asset in the browser: Find in Content Browser of a field of Details.
// The filters that could hide it go before the search is shown again.
content_reveal :: proc(s:^Session,id:base.Asset_Id) {
    c:=s.content
    if c==nil || id=={} {return}
    content_reveal_begin(c,id)
    library_select(s,.Content)
}

// The larger preview of a cell without a name, above it or under it, inside
// the list: its thumbnail, its name and its folder.
@(private)
content_preview_float :: proc(s:^Session,card:Content_Card,rect,area:ui.Rect) {
    c:=s.content
    ctx:=s.gui.ctx
    file:=&s.app.assets.registry.files[card.file]
    side:=CONTENT_PREVIEW+10
    x:=clamp(rect.x+rect.w*0.5-side*0.5-area.x,0,max(area.w-side,0))
    top:=rect.y-area.y
    above:=top>CONTENT_PREVIEW_ROOM
    float:=ui.Float{to=.Parent,anchor=.Top_Left,pivot=.Bottom_Left if above else .Top_Left,offset={x,top-4 if above else top+rect.h+4}}
    if ui.box(ctx,{width=ui.fixed(side),height=ui.FIT,direction=.Column,padding=ui.padding_all(4),float=float,fill=ui.tone(ctx,"field"),stroke=ui.tone(ctx,"border"),stroke_width=1,radius=4}) {
        asset_thumbnail(s,file,CONTENT_PREVIEW,clip=content_clip_index(c,card))
        ui.text(ctx,card.name,{size=ui.metric(ctx,"font"),color=ui.tone(ctx,"text"),wrap=.Words},ui.GROW,ui.FIT)
        ui.text(ctx,content_folder_of(file.path),{size=ui.metric(ctx,"font_caption"),color=ui.tone(ctx,"text_muted"),wrap=.Words},ui.GROW,ui.FIT)
    }
}

@(private)
content_build :: proc(s:^Session,w:core.World_Ref,height:f32,width:f32=CONTENT_WIDTH) {
    c:=s.content
    g:=s.gui
    ctx:=g.ctx
    a:=s.app.assets
    filter_id:=ui.id(ctx,"content_filter")
    if content_typing(c,ctx) {
        typed:=string(ctx.input.text[:ctx.input.text_count])
        c.filter_length+=copy(c.filter[c.filter_length:],typed)
        c.scroll=0
        ui.edit_request(ctx,filter_id)
    }
    c.card_focus=0
    if c.focus_search {
        ui.edit_request(ctx,filter_id)
        c.focus_search=false
    }
    act:Content_Actions
    root:=ui.id(ctx,"content_root")
    if ui.box(ctx,{id=root,width=ui.GROW,height=ui.fixed(height),direction=.Column,gap=CONTENT_PANEL_GAP,track=true}) {
        used:=CONTENT_CONTROL+CONTENT_PANEL_GAP+CONTENT_STRIP_ROW
        take_first:=content_search_row(s,filter_id)
        content_strip_row(s)
        if import_working(s) {used+=ui.metric(ctx,"row")+CONTENT_PANEL_GAP}
        if a==nil {
            ui.label(ctx,"No assets folder",ui.metric(ctx,"font_small"),ui.tone(ctx,"text_faint"))
            return
        }
        if !a.indexed && len(a.registry.files)==0 && a.registry.revision==0 {
            _=asset.registry_scan(&a.registry)
        }
        opened:=content_plugin_kinds(s)
        scene_kinds:=make([dynamic]asset.Fourcc,context.temp_allocator)
        for each in asset_plugin_kinds(s) {
            if each.scene_data {append(&scene_kinds,each.kind)}
        }
        content_clips_read(c,a)
        content_registry_read(c,&a.registry,opened,&a.types)
        if c.restore {content_navigation_restore(c,&a.registry)}
        content_scene_read(c,&a.registry,s.document.id if s.document!=nil else {})
        content_selection_read(s,c,w,&a.registry)
        if c.creating && asset_create_refusal(s)!="" {content_create_end(c)}
        if c.created!={} {content_created(s,&a.registry)}
        if c.reveal!={} {content_reveal_open(c,&a.registry)}
        lines:=content_lines(c,&a.registry,width,opened,scene_kinds[:],&ctx.font,ui.metric(ctx,"font_small"))
        searching:=strings.trim_space(string(c.filter[:c.filter_length]))!="" && len(c.trail)==0
        if take_first && searching && len(c.cards)>0 && c.cards[0].file>=0 {content_arm(s,&a.registry.files[c.cards[0].file],c.cards[0].name)}
        if c.view.arrangement==.Tabs && len(c.trail)==0 {used+=CONTENT_PANEL_GAP+content_tabs_build(s,&act,width)}
        if content_back_shown(c) {
            content_crumbs_build(s,&act)
            used+=CONTENT_PANEL_GAP+CONTENT_BACK_ROW
        }
        room:=max(height-used-CONTENT_PANEL_GAP,CONTENT_ROW)
        list:=ui.id(ctx,"content_list")
        // Ctrl+wheel resizes the cells and keeps the first one in sight.
        if notches:=ui.zoom(ctx,list);notches!=0 {
            top:f32
            anchor:=Content_Card{file=-1}
            for h,i in c.heights {
                if top+h>c.scroll {
                    if lines[i].kind==.Cards {anchor=c.cards[lines[i].first]}
                    break
                }
                top+=h
            }
            content_zoom(&c.view,notches)
            lines=content_lines(c,&a.registry,width,opened,scene_kinds[:],&ctx.font,ui.metric(ctx,"font_small"))
            c.scroll,top=0,0
            search: for line,i in lines {
                if line.kind==.Cards && anchor.file>=0 {
                    for card in c.cards[line.first:][:line.count] {
                        if card.file==anchor.file && card.clip==anchor.clip {
                            c.scroll=top
                            break search
                        }
                    }
                }
                top+=c.heights[i]
            }
        }
        // The asset to show: in the middle of the list, selected, with the keyboard.
        if c.reveal!={} {
            top:f32
            for line,i in lines {
                if line.kind==.Cards {
                    for card in c.cards[line.first:][:line.count] {
                        if card.file<0 || card.clip!=0 || a.registry.files[card.file].id!=c.reveal {continue}
                        c.scroll=max(top-room*0.5+c.heights[i]*0.5,0)
                        content_select(c,c.reveal,false)
                        ui.focus_set(ctx,ui.id(ctx,"content_entry",int(content_card_key(a.registry.files[card.file].path,card,line.group))))
                    }
                }
                top+=c.heights[i]
            }
            c.reveal={}
        }
        // The line of Create in sight when its name takes the keyboard.
        if c.create_edit {
            top:f32
            for line,i in lines {
                if line.kind==.Create {
                    if top<c.scroll || top+c.heights[i]>c.scroll+room {c.scroll=max(top-room*0.5,0)}
                    break
                }
                top+=c.heights[i]
            }
        }
        // Where no card or folder is, a right click opens Create and a click
        // clears the selection.
        area:=ui.id(ctx,"content_area")
        background:=ui.interact(ctx,area)
        if background.right {content_create_open(s,string(c.place[:c.place_length]),{ctx.pointer.x,ctx.pointer.y,0,0})}
        if background.clicked && ctx.input.modifiers&{.Primary,.Shift}=={} {content_select_clear(c)}
        ui.box_begin(ctx,{id=area,width=ui.GROW,height=ui.fixed(room),direction=.Column})
        first,last:=ui.rows_begin(ctx,list,&c.scroll,c.heights[:],ui.GROW,room)
        top:f32
        for h in c.heights[:first] {top+=h}
        if len(lines)==0 {ui.label(ctx,"No results",ui.metric(ctx,"font_small"),ui.tone(ctx,"text_faint"))}
        hovered:=Content_Card{file=-1}
        hovered_id:ui.Id
        first_card:=searching && len(c.cards)>0 && c.cards[0].file>=0
        for index in first..<last {
            line:=lines[index]
            whole_line:=top>=c.scroll-0.5 && top+c.heights[index]<=c.scroll+room+0.5
            top+=c.heights[index]
            switch line.kind {
            case .Header,.Subheader:
                id:=ui.id(ctx,"content_folder",int(line.group))
                marked:=content_folder_marked(s,id,line.virtual,line.path)
                it:=content_header(s,line,id,width,marked)
                content_folder_take(s,&act,id,it,line.virtual,line.path)
            case .Label:
                if ui.box(ctx,{width=ui.fixed(width),height=ui.fixed(CONTENT_SUBHEADER),padding={2,0,2,0},align_y=.Center}) {
                    ui.label(ctx,line.name,ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"),0)
                }
            case .Create:
                act.finish|=content_create_line(s)
            case .Cards:
                _,cell:=content_cells(c.view,width)
                if ui.box(ctx,{width=ui.fixed(width),height=ui.fixed(c.heights[index]),gap=CONTENT_GAP if c.view.mode==.Grid else 0}) {
                    for card,at in c.cards[line.first:][:line.count] {
                        if card.file<0 {
                            group:=content_virtual_group(card.virtual)
                            if card.virtual==.None {group=base.hash64(transmute([]u8)card.folder)}
                            id:=ui.id(ctx,"content_folder",int(group))
                            marked:=content_folder_marked(s,id,card.virtual,card.folder)
                            it:=content_folder_cell(s,card,id,cell,line.names,marked)
                            content_folder_take(s,&act,id,it,card.virtual,card.folder)
                            continue
                        }
                        it,id:=content_item(s,card,line.group,cell,whole_line,first_card && line.first==0 && at==0,line.names)
                        if it.focused {c.card_focus,c.focus_asset=id,card.clip>0?base.Asset_Id{}:a.registry.files[card.file].id}
                        if path:=content_asset_action(s,w,card,it);path!="" {act.open=path}
                        if it.hot {hovered,hovered_id=card,id}
                    }
                }
            }
        }
        // The name the first line scrolls under stays on top.
        if first<len(lines) {
            header:=int(lines[first].parent)
            if lines[first].kind==.Header {header=first}
            head_top:f32
            if header>=0 {
                for h in c.heights[:header] {head_top+=h}
            }
            if header>=0 && head_top<c.scroll {
                if ui.box(ctx,{width=ui.fixed(width),height=ui.FIT,direction=.Column,fill=ui.tone(ctx,"panel"),float={to=.Parent,anchor=.Top_Left,pivot=.Top_Left,offset={0,c.scroll-CONTENT_PIN_BLEED}}}) {
                    ui.spacer(ctx,-1,CONTENT_PIN_BLEED)
                    pinned:=lines[header]
                    pin:=ui.id(ctx,"content_sticky")
                    it:=content_header(s,pinned,pin,width,content_folder_marked(s,pin,pinned.virtual,pinned.path))
                    content_folder_take(s,&act,pin,it,pinned.virtual,pinned.path)
                }
            }
        }
        ui.rows_end(ctx,list,&c.scroll,c.heights[:],last)
        if !content_shows_names(c.view) && hovered.file>=0 && !(g.drag.kind!=.None && g.drag.moved) {
            cell_rect,built:=ui.widget_rect(ctx,hovered_id)
            area_rect,placed:=ui.widget_rect(ctx,area)
            if built && placed {content_preview_float(s,hovered,cell_rect,area_rect)}
        }
        ui.box_end(ctx,{id=area})
        if .Back in ctx.input.released {
            if rect,found:=ui.widget_rect(ctx,root);found && ui.rect_contains(rect,ctx.pointer) {act.back=true}
        }
        if act.cut>0 {
            resize(&c.trail,act.cut)
            c.scroll=0
            c.revision+=1
        }
        if act.back {content_back(c)}
        if act.enter {content_enter(c,act.virtual,act.folder,act.reset)}
        if act.finish {content_create_finish(s)}
        if act.dropped {content_drop(s,act.drop)}
        if path:=content_menu(s,w);path!="" {act.open=path}
        content_create_menu(s)
        content_more_menu(s)
        if act.open!="" {file_open_path(s,act.open)}
        host.assets_commit(a)
    }
}
