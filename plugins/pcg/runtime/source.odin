package pcg

import "base:runtime"
import "core:math"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"
import pcg_lib "mirai:std/pcg"

// The .pcg asset: a flat ordered list of layers, each one kind of thing placed
// (a tree, a bush, a fence module), and the cells a brush painted, each with
// how much of the density of the layers it keeps and the weights of its
// ecotopes. A layer is named by its id, which is never given twice, so the
// points it places keep their ids (stable_id) when other layers come and go.
// Its field expression (std/pcg field_compile) says how viable it is where,
// from 0 to 1; a Grammar layer splits the spans of splines by its grammar
// (std/pcg grammar_compile). Both compile when the source is read; a source
// whose expressions do not compile is not valid.

CELL_SIZE_DEFAULT :: f32(32)
CELL_SIZE_MIN :: f32(4)  // m across a cell
CELL_SIZE_MAX :: f32(256)
LAYERS_MAX :: 256
SYMBOLS_MAX :: 64        // of a Grammar layer
CELLS_MAX :: 1 << 20     // painted cells of a source
ECOTOPES_MAX :: 8        // painted channels of a cell, which ecotope(i) reads
PAINT_SAMPLES :: 17      // per side of what a cell paints: its corners and borders included
POSITION_MAX :: f32(1e6) // m from the origin of the frame along each axis
COORD_MAX :: i32(POSITION_MAX/CELL_SIZE_MIN) // of a cell, in cells from the origin
DENSITY_MAX :: f32(1000) // points per m2 of a Scatter layer
DITHER_MEMBERS_MAX :: 8  // Scatter layers of a tier in one dither group
CASCADE_CHILDREN_MAX :: 16 // children per parent of a Cascade layer
GROUND_RULE_LAYERS :: 4
TEXT_MAX :: pcg_lib.MAX_SOURCE // bytes of an expression

Pcg_Info :: struct {
    seed:u32,
    cell_size:f32 `mirai:"min=4,max=256,unit=m"`,
    next_layer:u32, // the id the next layer takes, from 1: an id is never given twice
    ecotopes:u32 `mirai:"max=8"`, // painted channels of each painted cell
    revision:u32,   // of the saved data
}

// When a layer is placed. Macro layers are placed first and keep their
// places; Meso layers keep apart from them; Micro layers are not placed on
// the CPU: a renderer scatters them on the ground (plugins/foliage).
Pcg_Tier :: enum u8 {Macro,Meso,Micro}

Pcg_Layer_Kind :: enum u8 {
    Scatter, // points over the cells at its density, kept apart by its radius
    Cascade, // children around each point of parent_layer that stands: density children per parent
    Grammar, // the modules of its grammar along each span of the Splines of the Pcg_Zones of its channel
}

// Where a layer stands: the slope and height of the ground in their ranges,
// and the layers of the ground under it with at least weight of them. A
// layer of the ground is named by its material.
Pcg_Ground_Rule :: struct {
    enabled:bool,
    slope:[2]f32 `mirai:"angle"`,   // from horizontal: lowest and highest
    height:[2]f32 `mirai:"unit=m"`, // of the ground in the frame: lowest and highest
    layers:[GROUND_RULE_LAYERS]base.Asset_Id, // the materials it stands on; none: any
    weight:f32 `mirai:"min=0,max=1"`, // of those layers together, at least
}

// A symbol of a grammar and what its module places.
Grammar_Symbol_Def :: struct {
    name:[32]u8 `mirai:"text"`,
    unit_size:f32 `mirai:"min=0,unit=m"`, // length of one module before stretching
    scalable:bool,
    asset:base.Asset_Id,
}

// What a layer is, but for its texts.
Pcg_Layer_Params :: struct {
    id:u32,               // from 1, stable: the ids of its points start with it
    tier:Pcg_Tier,
    kind:Pcg_Layer_Kind,
    parent_layer:u32,     // of a Cascade: the id of the Scatter layer before it whose points it grows around
    channel:u32 `mirai:"max=7"`, // of a Grammar: the Pcg_Zone channel whose Splines it runs along
    asset:base.Asset_Id,  // what it places: a prefab, which promoting a point spawns, or a mesh
    density:f32 `mirai:"min=0"`, // Scatter: points per m2; Cascade: children per parent
    radius:f32 `mirai:"min=0,unit=m"`, // at scale 1: no point stands nearer to another of a layer with a radius than both radii
    scale:[2]f32 `mirai:"min=0"`,  // across x and z: lowest and highest
    height:[2]f32 `mirai:"min=0"`, // along y, times the scale across: lowest and highest
    yaw:f32 `mirai:"angle"`,       // a turn around y of up to this, at random
    tilt:f32 `mirai:"angle"`,      // a lean of up to this, at random
    align:f32 `mirai:"min=0,max=1"`, // how much it leans with the ground under it
    offset:[2]f32 `mirai:"unit=m"`, // along its y, at random: lowest and highest
    cull_distance:f32 `mirai:"min=0,unit=m"`,     // from the sources, where it is gone; 0: never
    fade_distance:f32 `mirai:"min=0,unit=m"`,     // where it starts to fade out
    impostor_distance:f32 `mirai:"min=0,unit=m"`, // where its mesh gives way to its impostor; 0: none
    filler:bool,          // what a lower quality thins first
    collides:bool,
    dither_group:u16,     // Scatter layers of a tier with the same group above 0 share one set of points, each to one of them
    ground_rule:Pcg_Ground_Rule,
}

Pcg_Layer :: struct {
    using params:Pcg_Layer_Params,
    field_expr:string,   // its viability from 0 to 1; empty: 1 everywhere
    grammar_expr:string, // of a Grammar layer
    grammar_symbols:[]Grammar_Symbol_Def,
}

PCG_LAYER_DEFAULT :: Pcg_Layer_Params{density=0.05,scale={0.8,1.2},height={1,1},yaw=6.2831855,align=1,cull_distance=200,fade_distance=180,ground_rule={slope={0,math.PI/2},height={-POSITION_MAX,POSITION_MAX},weight=0.5}}

// A painted cell: how much of the density of the layers it keeps, from 0 to
// 255 on PAINT_SAMPLES by PAINT_SAMPLES points over it, x first (none: all of
// it), and the weights of its ecotopes, Pcg_Info.ecotopes blocks of as many
// (none: 0 everywhere).
Pcg_Cell :: struct {
    coord:[2]i32,
    density:[dynamic]u8,
    ecotopes:[dynamic]u8,
}

// The programs of a layer: what its texts compile to.
Pcg_Compiled :: struct {
    field:pcg_lib.Field_Program,
    grammar:pcg_lib.Grammar_Program,
    has_field,has_grammar:bool,
    masks:u8, // the channels its field reads (mask(i)), a bit each
}

// A .pcg in memory. The texts, the symbols and the programs come from allocator.
Pcg_Source :: struct {
    info:Pcg_Info,
    layers:[dynamic]Pcg_Layer,
    cells:[dynamic]Pcg_Cell, // in the order of their coordinates, z then x
    compiled:[dynamic]Pcg_Compiled, // by layer, once source_compile succeeds; empty before
    units:[dynamic]Pcg_Unit,  // made with compiled: the Scatter layers placed together, in their order
    members:[dynamic]u16,     // the layers of the units, by their index
    allocator:runtime.Allocator,
}

source_init :: proc(s:^Pcg_Source,allocator:=context.allocator) {
    s^={info={cell_size=CELL_SIZE_DEFAULT,next_layer=1},allocator=allocator}
    s.layers=make([dynamic]Pcg_Layer,allocator)
    s.cells=make([dynamic]Pcg_Cell,allocator)
    s.compiled=make([dynamic]Pcg_Compiled,allocator)
    s.units=make([dynamic]Pcg_Unit,allocator)
    s.members=make([dynamic]u16,allocator)
}

@(private)
layer_texts_free :: proc(s:^Pcg_Source,l:^Pcg_Layer) {
    delete(l.field_expr,s.allocator);delete(l.grammar_expr,s.allocator);delete(l.grammar_symbols,s.allocator)
    l.field_expr,l.grammar_expr,l.grammar_symbols="","",nil
}

source_compiled_free :: proc(s:^Pcg_Source) {
    for &c in s.compiled {
        if c.has_field {pcg_lib.field_program_destroy(&c.field)}
        if c.has_grammar {pcg_lib.grammar_destroy(&c.grammar)}
    }
    clear(&s.compiled);clear(&s.units);clear(&s.members)
}

source_destroy :: proc(s:^Pcg_Source) {
    source_compiled_free(s)
    for &l in s.layers {layer_texts_free(s,&l)}
    for &cell in s.cells {delete(cell.density);delete(cell.ecotopes)}
    delete(s.layers);delete(s.cells);delete(s.compiled);delete(s.units);delete(s.members)
    s^={}
}

source_layer :: proc "contextless" (s:^Pcg_Source,id:u32) -> (^Pcg_Layer,int) {
    if id==0 {return nil,-1}
    for &l,i in s.layers {if l.id==id {return &l,i}}
    return nil,-1
}

// A new layer at the end with the next id and PCG_LAYER_DEFAULT; nil without
// memory or room, with the source as it was. The programs are compiled again
// by source_compile.
source_layer_add :: proc(s:^Pcg_Source,kind:Pcg_Layer_Kind,tier:=Pcg_Tier.Macro) -> ^Pcg_Layer {
    if len(s.layers)>=LAYERS_MAX || s.info.next_layer==max(u32) || s.info.next_layer==0 {return nil}
    l:Pcg_Layer
    l.params=PCG_LAYER_DEFAULT
    l.id,l.kind,l.tier=s.info.next_layer,kind,tier
    if _,error:=append(&s.layers,l);error!=nil {return nil}
    s.info.next_layer+=1
    source_compiled_free(s)
    return &s.layers[len(s.layers)-1]
}

// Takes a layer out; the cascades of it go with it. False when there is none.
source_layer_remove :: proc(s:^Pcg_Source,id:u32) -> bool {
    _,index:=source_layer(s,id)
    if index<0 {return false}
    source_compiled_free(s)
    layer_texts_free(s,&s.layers[index])
    ordered_remove(&s.layers,index)
    for i:=len(s.layers)-1;i>=0;i-=1 {
        if s.layers[i].kind==.Cascade && s.layers[i].parent_layer==id {source_layer_remove(s,s.layers[i].id)}
    }
    return true
}

// Gives a layer its texts and symbols, copied: false without memory, with the
// layer as it was. The programs are compiled again by source_compile.
source_layer_texts :: proc(s:^Pcg_Source,id:u32,field_expr:string,grammar_expr:="",symbols:[]Grammar_Symbol_Def=nil) -> bool {
    l,_:=source_layer(s,id)
    if l==nil {return false}
    field,e0:=clone_text(field_expr,s.allocator)
    grammar,e1:=clone_text(grammar_expr,s.allocator)
    defs:[]Grammar_Symbol_Def
    e2:runtime.Allocator_Error
    if len(symbols)>0 {
        defs,e2=make([]Grammar_Symbol_Def,len(symbols),s.allocator)
        if e2==nil {copy(defs,symbols)}
    }
    if e0!=nil || e1!=nil || e2!=nil {
        delete(field,s.allocator);delete(grammar,s.allocator);delete(defs,s.allocator)
        return false
    }
    source_compiled_free(s)
    layer_texts_free(s,l)
    l.field_expr,l.grammar_expr,l.grammar_symbols=field,grammar,defs
    return true
}

@(private)
clone_text :: proc(text:string,allocator:runtime.Allocator) -> (string,runtime.Allocator_Error) {
    if len(text)==0 {return "",nil}
    bytes,error:=make([]u8,len(text),allocator)
    if error!=nil {return "",error}
    copy(bytes,text)
    return string(bytes),nil
}

grammar_symbol :: proc(name:string,unit_size:f32,scalable:=false,what:=base.Asset_Id{}) -> (def:Grammar_Symbol_Def) {
    base.text_set(def.name[:],name)
    def.unit_size,def.scalable,def.asset=unit_size,scalable,what
    return
}

@(private)
coord_before :: proc "contextless" (a,b:[2]i32) -> bool {return a.y<b.y || a.y==b.y && a.x<b.x}

// The first of items (in the order of their coord) at or after coord.
coord_lower :: proc "contextless" (items:[]$T,coord:[2]i32) -> int {
    low,high:=0,len(items)
    for low<high {
        mid:=(low+high)/2
        if coord_before(items[mid].coord,coord) {low=mid+1} else {high=mid}
    }
    return low
}

// The painted cell of a coordinate, made when it is not there and make_it;
// nil without memory.
source_cell :: proc(s:^Pcg_Source,coord:[2]i32,make_it:=false) -> ^Pcg_Cell {
    at:=coord_lower(s.cells[:],coord)
    if at<len(s.cells) && s.cells[at].coord==coord {return &s.cells[at]}
    if !make_it {return nil}
    cell:=Pcg_Cell{coord=coord,density=make([dynamic]u8,s.allocator),ecotopes=make([dynamic]u8,s.allocator)}
    if _,error:=inject_at(&s.cells,at,cell);error!=nil {return nil}
    return &s.cells[at]
}

@(private)
finite :: proc "contextless" (v:f32) -> bool {return v-v==0}

// What makes a source not valid, and where.
Pcg_Issue_Kind :: enum u8 {
    None,
    Unread,  // the file is missing, of another kind or version, or damaged
    Info,    // its cell size, next id or ecotopes
    Layer,   // a value of a layer out of its range, an id given twice, a parent that is not a Scatter layer before it
    Field,   // a field expression that does not compile
    Grammar, // a grammar that does not compile, or a Grammar layer without one
    Cell,    // a painted cell out of order, out of range or of another size
    Memory,
}
Pcg_Issue :: struct {
    kind:Pcg_Issue_Kind,
    layer:u32, // its id, for the issues of a layer
    field:pcg_lib.Field_Error,
    grammar:pcg_lib.Grammar_Error,
}

@(private)
params_valid :: proc "contextless" (s:^Pcg_Source,l:Pcg_Layer_Params,index:int) -> bool {
    values:=[?]f32{l.density,l.radius,l.scale[0],l.scale[1],l.height[0],l.height[1],l.yaw,l.tilt,l.align,l.cull_distance,l.fade_distance,l.impostor_distance}
    for v in values {if !finite(v) || v<0 {return false}}
    if l.id==0 || l.id>=s.info.next_layer || l.id>=DITHER_KEY || l.tier>max(Pcg_Tier) || l.kind>max(Pcg_Layer_Kind) || l.channel>=MASKS_MAX {return false}
    if l.scale[0]<=0 || l.scale[1]<l.scale[0] || l.scale[1]>1000 || l.height[0]<=0 || l.height[1]<l.height[0] || l.height[1]>1000 || l.align>1 {return false}
    if l.radius*l.scale[1]>s.info.cell_size/4 {return false}
    if !finite(l.offset.x) || !finite(l.offset.y) || l.offset.x>l.offset.y || abs(l.offset.x)>POSITION_MAX || abs(l.offset.y)>POSITION_MAX {return false}
    r:=l.ground_rule
    for v in ([5]f32{r.slope.x,r.slope.y,r.height.x,r.height.y,r.weight}) {if !finite(v) {return false}}
    if r.slope.x<0 || r.slope.x>r.slope.y || r.slope.y>math.PI/2+1e-4 || r.height.x>r.height.y || abs(r.height.x)>POSITION_MAX || abs(r.height.y)>POSITION_MAX || r.weight<0 || r.weight>1 {return false}
    switch l.kind {
    case .Scatter:
        if l.density>DENSITY_MAX || l.parent_layer!=0 {return false}
    case .Cascade:
        if l.density>CASCADE_CHILDREN_MAX || l.dither_group!=0 {return false}
        parent:=-1
        for other,k in s.layers[:index] {if other.id==l.parent_layer {parent=k}}
        if parent<0 || s.layers[parent].kind!=.Scatter || s.layers[parent].tier>l.tier {return false}
    case .Grammar:
        if l.parent_layer!=0 || l.dither_group!=0 {return false}
    }
    return true
}

// Why a source is not valid, without compiling its texts.
@(private)
source_shape_issue :: proc(s:^Pcg_Source) -> Pcg_Issue {
    i:=s.info
    if !finite(i.cell_size) || i.cell_size<CELL_SIZE_MIN || i.cell_size>CELL_SIZE_MAX || i.next_layer==0 || i.ecotopes>ECOTOPES_MAX {return {kind=.Info}}
    if len(s.layers)>LAYERS_MAX || len(s.cells)>CELLS_MAX {return {kind=.Info}}
    for &l,k in s.layers {
        if !params_valid(s,l.params,k) || len(l.field_expr)>TEXT_MAX || len(l.grammar_expr)>TEXT_MAX || len(l.grammar_symbols)>SYMBOLS_MAX {return {kind=.Layer,layer=l.id}}
        for other in s.layers[:k] {if other.id==l.id {return {kind=.Layer,layer=l.id}}}
        if l.kind==.Scatter && l.dither_group!=0 {
            members:=0
            for other in s.layers {members+=int(other.kind==.Scatter && other.tier==l.tier && other.dither_group==l.dither_group)}
            if members>DITHER_MEMBERS_MAX {return {kind=.Layer,layer=l.id}}
        }
        if l.kind!=.Grammar && (len(l.grammar_expr)>0 || len(l.grammar_symbols)>0) {return {kind=.Layer,layer=l.id}}
        if l.kind==.Grammar && (len(l.grammar_expr)==0 || len(l.grammar_symbols)==0) {return {kind=.Grammar,layer=l.id,grammar={kind=.Unexpected_End,symbol=-1}}}
        for &def in l.grammar_symbols {
            if len(serial.text_field(def.name[:]))>=len(def.name) {return {kind=.Layer,layer=l.id}}
        }
    }
    side:=PAINT_SAMPLES*PAINT_SAMPLES
    for &cell,k in s.cells {
        if abs(cell.coord.x)>COORD_MAX || abs(cell.coord.y)>COORD_MAX {return {kind=.Cell}}
        if k>0 && !coord_before(s.cells[k-1].coord,cell.coord) {return {kind=.Cell}}
        if len(cell.density)!=0 && len(cell.density)!=side {return {kind=.Cell}}
        if len(cell.ecotopes)!=0 && len(cell.ecotopes)!=int(i.ecotopes)*side {return {kind=.Cell}}
    }
    return {}
}

// The programs of the texts of each layer, in s.compiled; on an issue none
// are kept. The programs come from the allocator of the source.
source_compile :: proc(s:^Pcg_Source) -> Pcg_Issue {
    source_compiled_free(s)
    if issue:=source_shape_issue(s);issue.kind!=.None {return issue}
    if resize(&s.compiled,len(s.layers))!=nil {return {kind=.Memory}}
    for &c in s.compiled {c={}}
    symbols:[SYMBOLS_MAX]pcg_lib.Grammar_Symbol
    for &l,k in s.layers {
        c:=&s.compiled[k]
        if len(l.field_expr)>0 {
            program,err:=pcg_lib.field_compile(l.field_expr,s.allocator)
            if err.kind!=.None {
                source_compiled_free(s)
                return {kind=Pcg_Issue_Kind.Memory if err.kind==.Out_Of_Memory else .Field,layer=l.id,field=err}
            }
            c.field,c.has_field=program,true
            for instr in program.code {
                if instr.op==.Input && instr.input==.Mask && instr.index<MASKS_MAX {c.masks|=1<<instr.index}
            }
        }
        if l.kind==.Grammar {
            for &def,i in l.grammar_symbols {symbols[i]={name=base.text_get(def.name[:]),unit_size=def.unit_size,scalable=def.scalable}}
            program,err:=pcg_lib.grammar_compile(l.grammar_expr,symbols[:len(l.grammar_symbols)],s.allocator)
            if err.kind!=.None {
                source_compiled_free(s)
                return {kind=Pcg_Issue_Kind.Memory if err.kind==.Out_Of_Memory else .Grammar,layer=l.id,grammar=err}
            }
            c.grammar,c.has_grammar=program,true
        }
    }
    if !source_units(s) {
        source_compiled_free(s)
        return {kind=.Memory}
    }
    return {}
}

// Why a source cannot be saved and shown; kind None when it can. Its texts
// are compiled to see that they do, and the programs are kept.
source_issue :: proc(s:^Pcg_Source) -> Pcg_Issue {
    return source_compile(s)
}

source_valid :: proc(s:^Pcg_Source) -> bool {return source_issue(s).kind==.None}

// A copy of src in dst, its programs compiled again, from allocator. False
// without memory, with dst empty.
source_copy :: proc(dst,src:^Pcg_Source,allocator:=context.allocator) -> bool {
    if dst==src {return true}
    source_destroy(dst)
    source_init(dst,allocator)
    dst.info=src.info
    ok:=reserve(&dst.layers,len(src.layers))==nil && reserve(&dst.cells,len(src.cells))==nil
    for &l in src.layers {
        if !ok {break}
        held:Pcg_Layer
        held.params=l.params
        if _,error:=append(&dst.layers,held);error!=nil {ok=false;break}
        ok=source_layer_texts(dst,l.id,l.field_expr,l.grammar_expr,l.grammar_symbols)
    }
    for &cell in src.cells {
        if !ok {break}
        held:=Pcg_Cell{coord=cell.coord,density=make([dynamic]u8,allocator),ecotopes=make([dynamic]u8,allocator)}
        _,e0:=append(&held.density,..cell.density[:])
        _,e1:=append(&held.ecotopes,..cell.ecotopes[:])
        _,e2:=append(&dst.cells,held)
        if e0!=nil || e1!=nil || e2!=nil {delete(held.density);delete(held.ecotopes);ok=false}
    }
    // A source that did not compile is copied as it was: its issue stays.
    if ok && len(src.compiled)>0 {ok=source_compile(dst).kind==.None}
    if !ok {source_destroy(dst);source_init(dst,allocator)}
    return ok
}

// The rows of a layer and of a cell in the file: their texts, symbols and
// paint are ranges of the tables after them.
Pcg_Layer_Row :: struct {
    params:Pcg_Layer_Params,
    field_first,field_count:u32,
    grammar_first,grammar_count:u32,
    symbol_first,symbol_count:u32,
}
Pcg_Cell_Row :: struct {
    coord:[2]i32,
    density_first,density_count:u32,
    ecotope_first,ecotope_count:u32,
}

// The .pcg file of a source, as bytes from allocator; with import_info, the
// record of the import it comes from.
source_bytes :: proc(s:^Pcg_Source,id:base.Asset_Id,types:^asset.Types,allocator:=context.allocator,import_info:^asset.Import_Info=nil) -> (data:[]u8,error:asset.Error) {
    if !source_valid(s) {return nil,.Invalid}
    texts,symbols,paint:=0,0,0
    for l in s.layers {texts+=len(l.field_expr)+len(l.grammar_expr);symbols+=len(l.grammar_symbols)}
    for cell in s.cells {paint+=len(cell.density)+len(cell.ecotopes)}
    rows,e0:=make([]Pcg_Layer_Row,len(s.layers),context.temp_allocator)
    cells,e1:=make([]Pcg_Cell_Row,len(s.cells),context.temp_allocator)
    text,e2:=make([dynamic]u8,0,texts,context.temp_allocator)
    defs,e3:=make([dynamic]Grammar_Symbol_Def,0,symbols,context.temp_allocator)
    painted,e4:=make([dynamic]u8,0,paint,context.temp_allocator)
    if e0!=nil || e1!=nil || e2!=nil || e3!=nil || e4!=nil {return nil,.Out_Of_Memory}
    for l,k in s.layers {
        r:=&rows[k]
        r.params=l.params
        r.field_first,r.field_count=u32(len(text)),u32(len(l.field_expr))
        append(&text,l.field_expr)
        r.grammar_first,r.grammar_count=u32(len(text)),u32(len(l.grammar_expr))
        append(&text,l.grammar_expr)
        r.symbol_first,r.symbol_count=u32(len(defs)),u32(len(l.grammar_symbols))
        append(&defs,..l.grammar_symbols)
    }
    for cell,k in s.cells {
        c:=&cells[k]
        c.coord=cell.coord
        c.density_first,c.density_count=u32(len(painted)),u32(len(cell.density))
        append(&painted,..cell.density[:])
        c.ecotope_first,c.ecotope_count=u32(len(painted)),u32(len(cell.ecotopes))
        append(&painted,..cell.ecotopes[:])
    }
    document:asset.Document
    asset.document_init(&document,PCG_KIND,id,allocator)
    defer asset.document_destroy(&document)
    document.kind_version=PCG_VERSION
    info:=s.info
    asset.document_put_row(&document,types,"pcg",&info) or_return
    asset.document_put(&document,types,"layers",rows) or_return
    asset.document_put(&document,types,"symbols",defs[:]) or_return
    asset.document_put(&document,types,"cells",cells) or_return
    asset.document_put(&document,types,"text",text[:],{.Bulk},.Stream) or_return
    asset.document_put(&document,types,"paint",painted[:],{.Bulk},.Stream) or_return
    asset.import_put(&document,types,import_info) or_return
    return asset.document_bytes(&document,allocator)
}

@(private)
rows_or_none :: proc(file:^asset.Asset,types:^asset.Types,name:string,$T:typeid) -> (rows:[]T,ok:bool) {
    found,error:=asset.asset_rows(file,types,name,"",T)
    if error==.Not_Found {return nil,true}
    return found,error==.None
}

@(private)
range_in :: proc "contextless" (first,count:u32,length:int) -> bool {return u64(first)+u64(count)<=u64(length)}

// The source an open .pcg holds, checked whole and compiled: s is replaced
// only by a valid one, from allocator. Its id, or the issue.
source_read :: proc(s:^Pcg_Source,file:^asset.Asset,types:^asset.Types,allocator:=context.allocator) -> (id:base.Asset_Id,issue:Pcg_Issue) {
    unread:=Pcg_Issue{kind=.Unread}
    if asset.kind_check(file,PCG_KIND,PCG_VERSION)!=.None {return {},unread}
    info,error:=asset.asset_row(file,types,"pcg",Pcg_Info)
    if error!=.None || info==nil {return {},unread}
    rows,r0:=rows_or_none(file,types,"layers",Pcg_Layer_Row)
    defs,r1:=rows_or_none(file,types,"symbols",Grammar_Symbol_Def)
    cells,r2:=rows_or_none(file,types,"cells",Pcg_Cell_Row)
    text,r3:=rows_or_none(file,types,"text",u8)
    paint,r4:=rows_or_none(file,types,"paint",u8)
    if !r0 || !r1 || !r2 || !r3 || !r4 {return {},unread}
    if len(rows)>LAYERS_MAX || len(cells)>CELLS_MAX {return {},{kind=.Info}}
    // The ranges of the rows follow each other and cover every byte and symbol once.
    next_text,next_symbol,next_paint:=u32(0),u32(0),u32(0)
    for r in rows {
        if r.field_first!=next_text || r.grammar_first!=r.field_first+r.field_count || r.symbol_first!=next_symbol {return {},unread}
        if r.field_count>TEXT_MAX || r.grammar_count>TEXT_MAX || r.symbol_count>SYMBOLS_MAX {return {},{kind=.Layer,layer=r.params.id}}
        if !range_in(r.grammar_first,r.grammar_count,len(text)) || !range_in(r.symbol_first,r.symbol_count,len(defs)) {return {},unread}
        next_text=r.grammar_first+r.grammar_count
        next_symbol+=r.symbol_count
    }
    for c in cells {
        if c.density_first!=next_paint || c.ecotope_first!=c.density_first+c.density_count {return {},unread}
        if c.density_count>PAINT_SAMPLES*PAINT_SAMPLES || c.ecotope_count>ECOTOPES_MAX*PAINT_SAMPLES*PAINT_SAMPLES {return {},{kind=.Cell}}
        if !range_in(c.ecotope_first,c.ecotope_count,len(paint)) {return {},unread}
        next_paint=c.ecotope_first+c.ecotope_count
    }
    if int(next_text)!=len(text) || int(next_symbol)!=len(defs) || int(next_paint)!=len(paint) {return {},unread}
    read:Pcg_Source
    source_init(&read,allocator)
    read.info=info^
    ok:=reserve(&read.layers,len(rows))==nil && reserve(&read.cells,len(cells))==nil
    for r in rows {
        if !ok {break}
        l:Pcg_Layer
        l.params=r.params
        if _,error:=append(&read.layers,l);error!=nil {ok=false;break}
        held:=&read.layers[len(read.layers)-1]
        field,e0:=clone_text(string(text[r.field_first:][:r.field_count]),allocator)
        grammar,e1:=clone_text(string(text[r.grammar_first:][:r.grammar_count]),allocator)
        symbols:[]Grammar_Symbol_Def
        e2:runtime.Allocator_Error
        if r.symbol_count>0 {
            symbols,e2=make([]Grammar_Symbol_Def,int(r.symbol_count),allocator)
            if e2==nil {copy(symbols,defs[r.symbol_first:][:r.symbol_count])}
        }
        held.field_expr,held.grammar_expr,held.grammar_symbols=field,grammar,symbols
        ok=e0==nil && e1==nil && e2==nil
    }
    for c in cells {
        if !ok {break}
        held:=Pcg_Cell{coord=c.coord,density=make([dynamic]u8,allocator),ecotopes=make([dynamic]u8,allocator)}
        _,e0:=append(&held.density,..paint[c.density_first:][:c.density_count])
        _,e1:=append(&held.ecotopes,..paint[c.ecotope_first:][:c.ecotope_count])
        _,e2:=append(&read.cells,held)
        if e0!=nil || e1!=nil || e2!=nil {delete(held.density);delete(held.ecotopes);ok=false}
    }
    if !ok {source_destroy(&read);return {},{kind=.Memory}}
    if issue=source_compile(&read);issue.kind!=.None {source_destroy(&read);return}
    source_destroy(s)
    s^=read
    return file.blob.header.id,{}
}

Pcg_File_Stamp :: struct {size,time:i64,found:bool}

// The sources the Pcg_Graph of the world show, as their files hold them.
@(storage,copy="pcg_data_copy",free="pcg_data_free")
Pcg_Data :: struct {
    entries:[dynamic]Pcg_Data_Entry,
    registry:u64, // the revision of the registry when the stamps were last compared
    made:u64,     // entries made: the epoch of the next
    stats:Pcg_Data_Stats,
}
Pcg_Data_Stats :: struct {loads:u64}
Pcg_Data_Entry :: struct {
    id:base.Asset_Id,
    stamp:Pcg_File_Stamp, // of the file it was read from
    epoch:u64,            // of this entry
    loads:u32,            // raised each time it is read: what is generated from it compares it
    issue:Pcg_Issue,      // of the last read; the source is the last valid one, or empty
    source:Pcg_Source,
}

data_find :: proc "contextless" (data:^Pcg_Data,id:base.Asset_Id) -> ^Pcg_Data_Entry {
    if data==nil || id=={} {return nil}
    for &entry in data.entries {if entry.id==id {return &entry}}
    return nil
}

pcg_data_free :: proc(data:^Pcg_Data) {
    for &entry in data.entries {source_destroy(&entry.source)}
    delete(data.entries)
    data^={}
}

// A copy of the sources, their programs compiled again: what a world copy
// gives the new world. False without memory.
pcg_data_copy :: proc(dst,src:^Pcg_Data) -> bool {
    if dst==src {return true}
    for &entry in dst.entries {source_destroy(&entry.source)}
    clear(&dst.entries)
    if reserve(&dst.entries,len(src.entries))!=nil {return false}
    for &entry in src.entries {
        held:=entry
        held.source={}
        if !source_copy(&held.source,&entry.source) {return false}
        append(&dst.entries,held)
    }
    dst.registry,dst.made,dst.stats=src.registry,src.made,src.stats
    return true
}

data_stamp :: proc(a:^host.Assets,id:base.Asset_Id) -> Pcg_File_Stamp {
    file,found:=asset.registry_find(&a.registry,id)
    if !found {return {}}
    return {file.size,file.time,true}
}

// Reads a source as the registry of the assets holds it.
data_read :: proc(s:^Pcg_Source,a:^host.Assets,id:base.Asset_Id,allocator:=context.allocator) -> Pcg_Issue {
    file:asset.Asset
    if host.assets_file(a,id,PCG_KIND,&file)!=.None {return {kind=.Unread}}
    defer asset.asset_close(&file)
    read,issue:=source_read(s,&file,&a.types,allocator)
    if issue.kind==.None && read!=id {return {kind=.Unread}}
    return issue
}

@(private)
source_problem :: proc(problems:^core.Problems,e:core.Entity,a:^host.Assets,id:base.Asset_Id,issue:Pcg_Issue) {
    name:[base.ASSET_ID_TEXT]u8
    named:=host.assets_name(a,id,&name)
    switch issue.kind {
    case .None:
    case .Unread:
        core.report(problems,e,"pcg.source_unread","pcg source %s cannot be read: it is missing, of another kind or version (%s, version %d), or damaged; give Pcg_Graph.source a .pcg asset",named,PCG_EXTENSION,PCG_VERSION)
    case .Memory:
        core.report(problems,e,"pcg.memory","out of memory reading pcg source %s; it is read again when its file changes: free memory, or give it fewer layers",named)
    case .Field:
        core.report(problems,e,"pcg.source_invalid","pcg source %s is not shown: the field expression of layer %d does not compile at byte %d (%s); fix the expression",named,issue.layer,issue.field.offset,issue.field.message)
    case .Grammar:
        core.report(problems,e,"pcg.source_invalid","pcg source %s is not shown: the grammar of layer %d does not compile at byte %d (%v); fix the grammar or its symbols",named,issue.layer,issue.grammar.offset,issue.grammar.kind)
    case .Info,.Layer,.Cell:
        core.report(problems,e,"pcg.source_invalid","pcg source %s is not shown: its %v (layer %d) holds a value out of its range; save it again from the editor",named,issue.kind,issue.layer)
    }
}

// Reads the sources the Pcg_Graph of the world name, again when their file
// changes on disk or in the memory of the registry, and drops those no graph
// names. A source that cannot be read keeps the one read before; a graph of
// one never read shows nothing, and both are problems.
@(step="fixed frame",loops="game editor",stage="simulate")
pcg_load :: proc(data:^Pcg_Data,graphs:^core.Table(Pcg_Graph,.Read),assets:^host.Assets,allocator:runtime.Allocator,problems:^core.Problems) {
    a:=assets
    if a==nil {return}
    context.allocator=allocator
    fresh:=data.registry!=a.registry.revision
    data.registry=a.registry.revision
    for &entry in data.entries {
        if !fresh {continue}
        stamp:=data_stamp(a,entry.id)
        if stamp==entry.stamp {continue}
        entry.stamp=stamp
        next:Pcg_Source
        entry.issue=data_read(&next,a,entry.id)
        if entry.issue.kind!=.None {
            for row in 0..<core.count(graphs) {if core.at(graphs,row).source==entry.id {source_problem(problems,core.entity_at(graphs,row),a,entry.id,entry.issue)}}
            continue
        }
        source_destroy(&entry.source)
        entry.source=next
        entry.loads+=1
        data.stats.loads+=1
    }
    for row in 0..<core.count(graphs) {
        g:=core.at(graphs,row)
        if g.source=={} || data_find(data,g.source)!=nil {continue}
        data.made+=1
        entry:=Pcg_Data_Entry{id=g.source,stamp=data_stamp(a,g.source),epoch=data.made,loads=1}
        entry.issue=data_read(&entry.source,a,g.source)
        if entry.issue.kind!=.None {
            // Kept empty, so that it is not read in each frame: a change of its file reads it again.
            source_problem(problems,core.entity_at(graphs,row),a,g.source,entry.issue)
            source_destroy(&entry.source)
        }
        if _,error:=append(&data.entries,entry);error!=nil {
            source_destroy(&entry.source)
            core.report(problems,core.entity_at(graphs,row),"pcg.memory","out of memory for the source of this Pcg_Graph; it is tried again: free memory")
            continue
        }
        data.stats.loads+=1
    }
    for i:=len(data.entries)-1;i>=0;i-=1 {
        used:=false
        for row in 0..<core.count(graphs) {if core.at(graphs,row).source==data.entries[i].id {used=true;break}}
        if used {continue}
        source_destroy(&data.entries[i].source)
        unordered_remove(&data.entries,i)
    }
}
