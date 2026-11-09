package playtest_editor

import "base:runtime"
import "core:fmt"
import "core:math/linalg"
import "core:mem/virtual"
import "core:strings"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import input "mirai:engine/input"
import "mirai:std/base"
import "mirai:std/serial"

// A bot that plays with no model, for no tokens: the same seed on the same
// game plays the same ticks. In World it moves and jumps with the actions of
// the seat toward the cells of the world it has been in the least; in Ui it
// presses every button it sees and goes back through the pages that have some
// left. Both end at their ticks at the latest, and sooner when nothing is left
// to press. It reports what it covered and what the QA monitors saw.
//
// A button that asks the game to quit does not end the run: the request is
// held, listed in exits with the button and the tick, and the bot goes on
// with the rest. Only a run that really ends (the turn or the document) stops
// it, with stopped Run_Ended.

API_EXPLORE_TICKS :: 36000
@(private) API_EXPLORE_DEFAULT_SECONDS :: f32(30)
@(private) API_EXPLORE_REPROS :: 4
@(private) API_EXPLORE_NAMES :: 32
@(private) EXPLORE_CELLS :: 8192
@(private) EXPLORE_HOLD_TICKS :: 40
@(private) EXPLORE_WARM_TICKS :: 60    // for the seat and its body to appear
@(private) EXPLORE_BLOCKED_TICKS :: 20 // without moving: another way
@(private) EXPLORE_MOVED :: f32(0.1)
@(private) EXPLORE_UI_NODES :: 256
@(private) EXPLORE_UI_PAGES :: 64
@(private) EXPLORE_UI_EDGES :: 256
@(private) EXPLORE_UI_KEY :: 128
@(private) EXPLORE_UI_SETTLE :: 4
@(private) EXPLORE_UI_IDLE :: 3
@(private) EXPLORE_UI_BACKS :: 2

Api_Explore_Mode :: enum u8 {World,Ui}
Api_Explore_Stop :: enum u8 {Ticks,Run_Ended,No_Body,No_Ui,Ui_Covered,No_Progress,Blocked_By_Ui}

Api_Play_Explore_Params :: struct {
    mode:Api_Explore_Mode `mirai:"optional,label=World moves and jumps toward the least visited cells; Ui presses every visible button"`,
    seed:u64 `mirai:"optional,label=The same seed on the same game plays the same ticks"`,
    seconds:f32 `mirai:"optional,min=0,unit=s,label=Game time it plays at most"`,
    ticks:int `mirai:"optional,min=0,max=36000,label=Fixed ticks it plays at most in place of seconds"`,
    cell:f32 `mirai:"optional,min=0.25,max=1000,unit=m,label=Side of the cells of the world coverage"`,
    move:[64]u8 `mirai:"optional,text,label=The Axis2 action that moves; empty: the first bound to keys or to the left stick"`,
    jump:[64]u8 `mirai:"optional,text,label=The Button action that jumps; empty: the one bound to Space or to the South button"`,
}

Api_Play_Explore_Result :: struct {
    mode:Api_Explore_Mode,
    seed:u64,
    ran:int `mirai:"label=Ticks it played"`,
    stopped:Api_Explore_Stop `mirai:"label=Why it ended: Ticks its limit; Run_Ended the game ended; No_Body the seat drives nothing; No_Ui nothing to press; Ui_Covered every button it reached; No_Progress presses lead nowhere new; Blocked_By_Ui a modal screen nothing closes"`,
    cells:int `mirai:"label=Cells of the world it was in"`,
    pages:int `mirai:"label=Distinct sets of buttons it reached"`,
    activated:[1][EXPLORE_UI_KEY]u8 `mirai:"list,text,label=Buttons pressed as screen|name"`,
    activated_more:int `mirai:"optional,label=Those that did not fit"`,
    never:[1][EXPLORE_UI_KEY]u8 `mirai:"list,text,label=Buttons seen or laid out and never pressed"`,
    never_more:int `mirai:"optional,label=Those that did not fit"`,
    exits:[1]Api_Play_Explore_Exit `mirai:"list,label=Each time the game asked to quit: the run went on"`,
    passed:bool `mirai:"label=No violation"`,
    violations:[1]Api_Play_Qa_Violation `mirai:"list,label=As play.qa.report gives them"`,
    repros:[1][editor.API_PATH_BYTES]u8 `mirai:"list,text,label=A scenario per kind of violation"`,
    repro_error:[256]u8 `mirai:"optional,text,label=Why some repro could not be written"`,
}
Api_Play_Explore_Exit :: struct {
    node:[EXPLORE_UI_KEY]u8 `mirai:"text,label=The button pressed last; empty when none was"`,
    tick:u64,
}

@(private)
Explore_Cells :: struct {
    keys:[][2]i32,
    visits:[]u16, // 0: the slot is free
    count:int,
}

@(private)
Explore_Exit :: struct {node:string,tick:u64}

// What the UI part knows: a page is a distinct set of pressable buttons and an
// edge says which button went from one page to another.
@(private)
Explore_Ui_Node :: struct {
    key:[EXPLORE_UI_KEY]u8,
    activated:bool,
}
@(private)
Explore_Ui_Page :: struct {
    hash:u64,
    buttons:[32]int, // in nodes
    count,backs:int,
}
@(private)
Explore_Ui_Edge :: struct {from,to,node:int}

@(private)
Explore_Ui :: struct {
    nodes:[]Explore_Ui_Node,
    pages:[]Explore_Ui_Page,
    edges:[]Explore_Ui_Edge,
    node_count,page_count,edge_count:int,
    routes:int, // presses in a row that reached no button left to press
}

@(private)
Explore_Ui_Button :: struct {key:string,enabled:bool}

@(private)
Explore_Ui_Choice_Kind :: enum u8 {Press,Back,Done}
@(private)
Explore_Ui_Choice :: struct {kind:Explore_Ui_Choice_Kind,button:int,progress_lost:bool}

@(private)
Explore_Run :: struct {
    s:^editor.Session,
    owner:int,
    r:^editor.Run,
    ran,total:int,
    stopped:Api_Explore_Stop,
    rng:base.Rng,
    exits:[dynamic]Explore_Exit,
    last_node:int, // in the nodes of ui; -1: none pressed
    ui:Explore_Ui,
    cells:Explore_Cells,
    arena:virtual.Arena,
    allocator:runtime.Allocator,
}

@(private)
explore_api_register :: proc(s:^editor.Session) {
    defaults:=Api_Play_Explore_Params{seed=1,cell=2}
    editor.api_method_register(s,{name="play.explore",summary="A bot with no model that plays the game of the caller, deterministic by seed and bounded by ticks: World moves and jumps toward the least visited cells, Ui presses every visible button. Says what it covered and the violations of the QA monitors with their repros; a button that asks to quit is listed and does not end the run.",params=Api_Play_Explore_Params,params_info=type_info_of(Api_Play_Explore_Params),result=Api_Play_Explore_Result,result_info=type_info_of(Api_Play_Explore_Result),writes_result=true,defaults=&defaults,run=api_play_explore})
}

// ---------------------------------------------------------------- cells

@(private)
explore_cell_of :: proc(position:[3]f32,size:f32) -> [2]i32 {
    return {i32(position.x/size+(position.x<0?-1:0)),i32(position.z/size+(position.z<0?-1:0))}
}

@(private)
explore_cell_slot :: proc(cells:^Explore_Cells,cell:[2]i32) -> int {
    mask:=len(cells.keys)-1
    at:=int((u32(cell.x)*73856093~u32(cell.y)*19349663)&u32(mask))
    for _ in 0..<len(cells.keys) {
        if cells.visits[at]==0 || cells.keys[at]==cell {return at}
        at=(at+1)&mask
    }
    return -1
}

// The times a cell was entered; 0 when never.
@(private)
explore_cell_visits :: proc(cells:^Explore_Cells,cell:[2]i32) -> u16 {
    at:=explore_cell_slot(cells,cell)
    return at<0 || cells.visits[at]==0?0:cells.visits[at]
}

@(private)
explore_cell_enter :: proc(cells:^Explore_Cells,cell:[2]i32) {
    at:=explore_cell_slot(cells,cell)
    if at<0 {return}
    if cells.visits[at]==0 {
        cells.keys[at]=cell
        cells.count+=1
    }
    if cells.visits[at]<max(u16) {cells.visits[at]+=1}
}

@(private)
EXPLORE_DIRECTIONS :: [8][2]f32{{0,1},{0.7071,0.7071},{1,0},{0.7071,-0.7071},{0,-1},{-0.7071,-0.7071},{-1,0},{-0.7071,0.7071}}

// The direction (an index of EXPLORE_DIRECTIONS, in the axes of the camera)
// toward the least visited cells ahead, ties broken by the seed; those in
// avoid only when nothing else is left.
@(private)
explore_direction :: proc(cells:^Explore_Cells,position,right,forward:[3]f32,size:f32,avoid:bit_set[0..<8],rng:^base.Rng) -> int {
    directions:=EXPLORE_DIRECTIONS
    best:=0
    best_score:=min(f32)
    for d,i in directions {
        world:=right*d.x+forward*d.y
        score:f32
        if i in avoid {score-=100}
        for step in 1..=3 {
            at:=position+world*size*f32(step)
            visits:=explore_cell_visits(cells,explore_cell_of(at,size))
            score+=visits==0?f32(4-step):-f32(min(visits,8))*0.25
        }
        score+=f32(base.rng_u32(rng))/f32(max(u32))*0.5
        if score>best_score {best,best_score=i,score}
    }
    return best
}

// ---------------------------------------------------------------- ui

@(private)
explore_ui_node_of :: proc(u:^Explore_Ui,key:string) -> int {
    for &node,i in u.nodes[:u.node_count] {
        if base.text_get(node.key[:])==key {return i}
    }
    if u.node_count==len(u.nodes) {return -1}
    at:=u.node_count
    base.text_set(u.nodes[at].key[:],key)
    u.node_count+=1
    return at
}

// The page of a set of buttons, made when it is new; -1 when no more fit.
@(private)
explore_ui_page_of :: proc(u:^Explore_Ui,buttons:[]Explore_Ui_Button) -> int {
    hash:=u64(14695981039346656037)
    for b in buttons {
        hash=(hash~base.name_hash(b.key))*1099511628211
        hash=(hash~u64(b.enabled))*1099511628211
    }
    for &page,i in u.pages[:u.page_count] {
        if page.hash==hash {return i}
    }
    if u.page_count==len(u.pages) {return -1}
    page:=&u.pages[u.page_count]
    page^={hash=hash}
    u.page_count+=1
    for b in buttons {
        node:=explore_ui_node_of(u,b.key)
        if node>=0 && page.count<len(page.buttons) {
            page.buttons[page.count]=node
            page.count+=1
        }
    }
    return u.page_count-1
}

// Remembers that pressing node on the page from led to the page to.
@(private)
explore_ui_edge_note :: proc(u:^Explore_Ui,from,to,node:int) {
    for &edge in u.edges[:u.edge_count] {
        if edge.from==from && edge.node==node {edge.to=to;return}
    }
    if u.edge_count<len(u.edges) {
        u.edges[u.edge_count]={from,to,node}
        u.edge_count+=1
    }
}

@(private)
explore_ui_page_pending :: proc(u:^Explore_Ui,page:int) -> bool {
    p:=&u.pages[page]
    for node in p.buttons[:p.count] {if !u.nodes[node].activated {return true}}
    return false
}

// What to press on a page: first a button it never pressed; then the button
// of the shortest way to a page with one left; then going back; then nothing.
@(private)
explore_ui_choose :: proc(u:^Explore_Ui,page:int,buttons:[]Explore_Ui_Button) -> Explore_Ui_Choice {
    if page<0 {return {kind=.Done}}
    for b,i in buttons {
        if !b.enabled {continue}
        if node:=explore_ui_node_of(u,b.key);node>=0 && !u.nodes[node].activated {
            u.routes=0
            return {kind=.Press,button=i}
        }
    }
    if route:=explore_ui_route(u,page);route>=0 {
        u.routes+=1
        if u.routes>u.page_count*2+8 {return {kind=.Done,progress_lost=true}}
        key:=base.text_get(u.nodes[route].key[:])
        for b,i in buttons {
            if b.key==key && b.enabled {return {kind=.Press,button=i}}
        }
    }
    p:=&u.pages[page]
    if p.backs<EXPLORE_UI_BACKS {
        p.backs+=1
        return {kind=.Back}
    }
    return {kind=.Done}
}

// The first button (a node) on the way from a page to the nearest with a
// button left; -1 when none can be reached by what was pressed so far.
@(private)
explore_ui_route :: proc(u:^Explore_Ui,start:int) -> int {
    queue:[EXPLORE_UI_PAGES]int
    first:[EXPLORE_UI_PAGES]int
    seen:[EXPLORE_UI_PAGES]bool
    head,tail:=0,1
    queue[0],seen[start],first[start]=start,true,-1
    for head<tail {
        at:=queue[head]
        head+=1
        if at!=start && explore_ui_page_pending(u,at) {return first[at]}
        for &edge in u.edges[:u.edge_count] {
            if edge.from!=at || edge.to<0 || seen[edge.to] {continue}
            seen[edge.to]=true
            first[edge.to]=at==start?edge.node:first[at]
            queue[tail]=edge.to
            tail+=1
        }
    }
    return -1
}

// ---------------------------------------------------------------- the bot

@(private)
explore_ended :: proc(x:^Explore_Run) -> bool {
    x.stopped=.Run_Ended
    return false
}

// One tick with this input; false when the bot ends.
@(private)
explore_tick :: proc(x:^Explore_Run,step:editor.Api_Step_Input) -> bool {
    if x.ran>=x.total {
        x.stopped=.Ticks
        return false
    }
    step:=step
    step.ticks=1
    if !editor.play_tick(x.s,x.r,&step) {return explore_ended(x)}
    x.r=editor.run_find(x.s,x.owner)
    x.ran+=1
    if x.r.quit_asked {
        x.r.quit_asked=false
        tick:u64
        if t:=core.world_storage_of(editor.run_ref(x.s,x.r),core.Time);t!=nil {tick=t.tick}
        node:=x.last_node>=0?base.text_get(x.ui.nodes[x.last_node].key[:]):""
        append(&x.exits,Explore_Exit{strings.clone(node,x.allocator),tick})
    }
    return true
}

@(private)
explore_idle :: proc(x:^Explore_Run,ticks:int) -> bool {
    for _ in 0..<ticks {
        if !explore_tick(x,{}) {return false}
    }
    return true
}

// The buttons of the screen on top, with a key each; found false without one.
@(private)
explore_ui_read :: proc(x:^Explore_Run,buttons:^[dynamic]Explore_Ui_Button,rects:^[dynamic][4]f32,modal:^bool) -> bool {
    virtual.arena_free_all(&x.arena)
    allocator:=virtual.arena_allocator(&x.arena)
    top,found:=editor.play_ui_screen(x.s,x.r,true,allocator)
    if !found {return false}
    modal^=top.modal
    clear(buttons);clear(rects)
    for &b in top.buttons {
        key:=b.name!=""?fmt.aprintf("%s|%s",top.screen,b.name,allocator=allocator):fmt.aprintf("%s#%d",top.screen,b.row,allocator=allocator)
        if !b.shown {
            explore_ui_node_of(&x.ui,key)
            continue
        }
        append(buttons,Explore_Ui_Button{key,!b.disabled && b.laid})
        append(rects,b.rect)
    }
    return true
}

// A click of a person on the middle of a rect: over it, down and up, and the ticks it takes to answer.
@(private)
explore_press :: proc(x:^Explore_Run,rect:[4]f32) -> bool {
    center:=[2]f32{rect[0]+rect[2]*0.5,rect[1]+rect[3]*0.5}
    if !explore_tick(x,{placed=true,mouse_position=center}) {return false}
    for _ in 0..<2 {if !explore_tick(x,{buttons={.Left}}) {return false}}
    return explore_idle(x,EXPLORE_UI_SETTLE)
}

@(private)
explore_back :: proc(x:^Explore_Run) -> bool {
    if !explore_tick(x,{tap_keys={.Escape}}) {return false}
    return explore_idle(x,EXPLORE_UI_SETTLE)
}

// One press on the top screen; false when the bot ends. Without a screen or
// a button left to press there, done says so.
@(private)
explore_ui_step :: proc(x:^Explore_Run,previous,previous_node:^int) -> (going,done:bool) {
    buttons:=make([dynamic]Explore_Ui_Button,context.temp_allocator)
    rects:=make([dynamic][4]f32,context.temp_allocator)
    modal:bool
    if !explore_ui_read(x,&buttons,&rects,&modal) || len(buttons)==0 {
        return true,true
    }
    page:=explore_ui_page_of(&x.ui,buttons[:])
    if previous^>=0 && page>=0 {explore_ui_edge_note(&x.ui,previous^,page,previous_node^)}
    previous^,previous_node^=-1,-1
    choice:=explore_ui_choose(&x.ui,page,buttons[:])
    switch choice.kind {
    case .Press:
        node:=explore_ui_node_of(&x.ui,buttons[choice.button].key)
        if node>=0 {x.ui.nodes[node].activated=true}
        x.last_node=node
        previous^,previous_node^=page,node
        return explore_press(x,rects[choice.button]),false
    case .Back:
        return explore_back(x),false
    case .Done:
        x.stopped=choice.progress_lost?.No_Progress:.Ui_Covered
        return false,true
    }
    return true,false
}

@(private)
explore_ui_play :: proc(x:^Explore_Run) {
    previous,previous_node:=-1,-1
    idle:=0
    if !explore_idle(x,min(EXPLORE_WARM_TICKS/4,x.total)) {return}
    for x.ran<x.total {
        going,done:=explore_ui_step(x,&previous,&previous_node)
        if !going {return}
        if done {
            // Nothing to press: a screen a key opens, or the end of the menus.
            idle+=1
            if idle>EXPLORE_UI_IDLE {
                x.stopped=x.ui.node_count==0?.No_Ui:.Ui_Covered
                return
            }
            if !explore_back(x) {return}
            continue
        }
        idle=0
    }
    x.stopped=.Ticks
}

// The actions of the bot, named or found in the bindings of the map.
@(private)
explore_actions :: proc(s:^editor.Session,m:^input.Input_Map,move_name,jump_name:string) -> (move,jump:input.Action,can_jump:bool,problem:string) {
    named :: proc(s:^editor.Session,m:^input.Input_Map,name:string,kind:input.Action_Kind,what:string) -> (action:input.Action,problem:string) {
        found,declared:=core.name_value(s.info,input.Action,name)
        if !declared || m.kinds[found]!=kind || m.declared&input.action_bit(input.Action(found))==0 {return 0,fmt.tprintf("%s %q is not a %v action: input.get lists them",what,name,kind)}
        return input.Action(found),""
    }
    has_move:=false
    if move_name!="" {
        if move,problem=named(s,m,move_name,.Axis2,"move");problem!="" {return}
        has_move=true
    }
    if jump_name!="" {
        if jump,problem=named(s,m,jump_name,.Button,"jump");problem!="" {return}
        can_jump=true
    }
    for &b in m.bindings[:m.binding_count] {
        kind:=m.kinds[b.action]
        if !has_move && kind==.Axis2 && b.count>0 && b.codes[0].device==.Key {move,has_move=b.action,true}
        if !can_jump && kind==.Button && b.count==1 {
            code:=b.codes[0]
            if code.device==.Key && core.Key(code.code)==.Space || code.device==.Gamepad_Button && core.Gamepad_Button(code.code)==.South {jump,can_jump=b.action,true}
        }
    }
    if !has_move {
        for &b in m.bindings[:m.binding_count] {
            if m.kinds[b.action]==.Axis2 && b.count==2 && b.codes[0].device==.Gamepad_Axis && core.Gamepad_Axis(b.codes[0].code)==.Left_X {move,has_move=b.action,true;break}
        }
    }
    if !has_move {problem="The game binds no Axis2 action to keys or to the left stick: give the one that moves with move; input.get lists them"}
    return
}

@(private)
explore_world_play :: proc(x:^Explore_Run,p:^Api_Play_Explore_Params) -> (problem:string) {
    s:=x.s
    w:=editor.run_ref(s,x.r)
    m,requests:=core.world_storage_of(w,input.Input_Map),core.world_storage_of(w,input.Hold_Requests)
    if m==nil || requests==nil {return "This game has no input actions: its world does not take engine/input"}
    move,jump:input.Action
    can_jump:bool
    move,jump,can_jump,problem=explore_actions(s,m,base.text_get(p.move[:]),base.text_get(p.jump[:]))
    if problem!="" {return}
    if !explore_idle(x,min(2,x.total)) {return}
    seat,body:=play_focused(editor.run_ref(s,x.r))
    for wait:=0;body==core.NONE;wait+=1 {
        if wait>=EXPLORE_WARM_TICKS {
            x.stopped=.No_Body
            return
        }
        if !explore_tick(x,{}) {return}
        seat,body=play_focused(editor.run_ref(s,x.r))
    }
    directions:=EXPLORE_DIRECTIONS
    avoid:bit_set[0..<8]
    chosen:=0
    previous:=editor.entity_world(editor.run_ref(s,x.r),body).position
    still,next:=0,0
    ui_previous,ui_node:=-1,-1
    for x.ran<x.total {
        w=editor.run_ref(s,x.r)
        requests=core.world_storage_of(w,input.Hold_Requests)
        seat,body=play_focused(w)
        if body==core.NONE {
            if !explore_tick(x,{}) {return}
            continue
        }
        at:=editor.entity_world(w,body).position
        explore_cell_enter(&x.cells,explore_cell_of(at,p.cell))
        if linalg.length(at-previous)>=EXPLORE_MOVED {still=0} else {still+=1}
        previous=at
        blocked:=still>=EXPLORE_BLOCKED_TICKS
        if x.ran>=next || blocked {
            // A screen that takes the seat is pressed through before moving on.
            if explore_modal_on_top(x) {
                going,done:=explore_ui_step(x,&ui_previous,&ui_node)
                if !going {
                    x.stopped=x.stopped==.Ui_Covered?.Blocked_By_Ui:x.stopped
                    return
                }
                if !done {continue}
            }
            if blocked {
                avoid+={chosen}
                still=0
            } else {avoid={}}
            right,forward:=explore_axes(w)
            chosen=explore_direction(&x.cells,at,right,forward,p.cell,avoid,&x.rng)
            hold:=u32(EXPLORE_HOLD_TICKS)
            input.hold(requests,seat,move,directions[chosen],hold)
            if can_jump && (blocked || base.rng_u32(&x.rng)%4==0) {input.hold(requests,seat,jump,{1,0},2)}
            next=x.ran+int(hold)
        }
        if !explore_tick(x,{}) {return}
    }
    x.stopped=.Ticks
    return
}

// Whether a modal screen takes the input of the focused player.
@(private)
explore_modal_on_top :: proc(x:^Explore_Run) -> bool {
    buttons:=make([dynamic]Explore_Ui_Button,context.temp_allocator)
    rects:=make([dynamic][4]f32,context.temp_allocator)
    modal:bool
    return explore_ui_read(x,&buttons,&rects,&modal) && modal
}

// The axes of the camera along the ground: where a Move_Input of y and x goes.
@(private)
explore_axes :: proc(w:core.World_Ref) -> (right,forward:[3]f32) {
    forward={0,0,-1}
    if view:=core.world_storage_of(w,core.View);view!=nil {
        look:=core.view_forward(view^)
        look.y=0
        if linalg.length(look)>0.001 {forward=linalg.normalize(look)}
    }
    right=linalg.cross(forward,[3]f32{0,1,0})
    return
}

@(private)
api_play_explore :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Api_Play_Explore_Params)
    r,own:=editor.api_play_own_run(s,call,0)
    if !own {return}
    if r.owner==0 && editor.simulating(s) {api.call_fail(call,api.INVALID_PARAMS,"A simulation takes no player input");return}
    if problem:=editor.run_script_blocks(s,r);problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem);return}
    values:[2]string
    api.object_values(call.allocator,call.raw,{"seconds","ticks"},values[:])
    if values[0]!="" && values[1]!="" {api.call_fail(call,api.INVALID_PARAMS,"seconds and ticks both say how long it plays: give one");return}
    tick_dt:=f64(max(s.app.tick_dt,1e-6))
    total:=int(f64(API_EXPLORE_DEFAULT_SECONDS)/tick_dt+0.5)
    if values[0]!="" {total=int(f64(p.seconds)/tick_dt+0.5)}
    if values[1]!="" {total=p.ticks}
    if total<1 || total>API_EXPLORE_TICKS {api.call_failf(call,api.INVALID_PARAMS,"it plays from 1 to %d ticks: give ticks or seconds in that range",API_EXPLORE_TICKS);return}
    if q:=qa_of(s,r);q==nil || !q.armed {
        height,known:=qa_fall_default(s)
        if qa_arm(s,r,{stuck_seconds=3,fall_below=height,falls=known,non_finite=true,problems=true})==nil {api.call_fail(call,api.SERVER_ERROR,"No memory for the monitors");return}
    }
    if r.owner==0 && !editor.play_paused(s) {editor.play_pause(s,true,stepped=true)}
    x:=new(Explore_Run,call.allocator)
    x.s,x.owner,x.r,x.total,x.last_node=s,r.owner,r,total,-1
    x.rng=base.rng_make(p.seed)
    x.allocator=call.allocator
    x.exits.allocator=call.allocator
    x.cells.keys=make([][2]i32,EXPLORE_CELLS,call.allocator)
    x.cells.visits=make([]u16,EXPLORE_CELLS,call.allocator)
    x.ui.nodes=make([]Explore_Ui_Node,EXPLORE_UI_NODES,call.allocator)
    x.ui.pages=make([]Explore_Ui_Page,EXPLORE_UI_PAGES,call.allocator)
    x.ui.edges=make([]Explore_Ui_Edge,EXPLORE_UI_EDGES,call.allocator)
    if x.cells.keys==nil || x.cells.visits==nil || x.ui.nodes==nil || x.ui.pages==nil || x.ui.edges==nil || virtual.arena_init_growing(&x.arena)!=nil {
        api.call_fail(call,api.SERVER_ERROR,"No memory for the state of the bot")
        return
    }
    defer virtual.arena_destroy(&x.arena)
    r.quit_held=true
    defer if still:=editor.run_find(s,x.owner);still!=nil {still.quit_held,still.quit_asked=false,false}
    switch p.mode {
    case .World:
        if problem:=explore_world_play(x,p);problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem);return}
    case .Ui:
        explore_ui_play(x)
    }
    r=editor.run_find(s,x.owner)
    api_play_explore_write(s,call,x,p,r)
}

@(private)
api_play_explore_write :: proc(s:^editor.Session,call:^api.Call,x:^Explore_Run,p:^Api_Play_Explore_Params,r:^editor.Run) {
    out:=call.out
    serial.write_u8(out,'{')
    api.write_text(out,"mode",fmt.tprint(p.mode),true)
    api.write_uint(out,"seed",p.seed)
    api.write_int(out,"ran",i64(x.ran))
    api.write_text(out,"stopped",fmt.tprint(x.stopped))
    api.write_int(out,"cells",i64(x.cells.count))
    api.write_int(out,"pages",i64(x.ui.page_count))
    activated,never:=make([dynamic]string,context.temp_allocator),make([dynamic]string,context.temp_allocator)
    for &node in x.ui.nodes[:x.ui.node_count] {append(node.activated?&activated:&never,base.text_get(node.key[:]))}
    explore_names_write(out,"activated",activated[:])
    explore_names_write(out,"never",never[:])
    api.write_key(out,"exits");serial.write_u8(out,'[')
    for e,i in x.exits {
        if i>0 {serial.write_u8(out,',')}
        serial.write_u8(out,'{')
        api.write_text(out,"node",e.node,true)
        api.write_uint(out,"tick",e.tick)
        serial.write_u8(out,'}')
    }
    serial.write_u8(out,']')
    q:^Run_Qa
    if r!=nil {q=qa_of(s,r)}
    passed:=q==nil || q.violation_count==0 && q.dropped==0
    api.write_bool(out,"passed",passed)
    if q==nil {
        api.write_key(out,"violations");serial.text_write_raw(out,"[]")
        api.write_key(out,"repros");serial.text_write_raw(out,"[]")
        serial.write_u8(out,'}')
        return
    }
    qa_violations_write(s,out,q)
    api.write_key(out,"repros");serial.write_u8(out,'[')
    written:=0
    failed:string
    kinds:bit_set[Api_Qa_Kind]
    for &v in q.violations[:q.violation_count] {
        if v.kind in kinds || written==API_EXPLORE_REPROS {continue}
        kinds+={v.kind}
        file,problem:=qa_repro_write(s,call,r,&v,call.allocator)
        if problem!="" {
            if failed=="" {failed=problem}
            continue
        }
        if written>0 {serial.write_u8(out,',')}
        serial.text_write_string(out,file)
        written+=1
    }
    serial.write_u8(out,']')
    if failed!="" {api.write_text(out,"repro_error",failed)}
    serial.write_u8(out,'}')
}

@(private)
explore_names_write :: proc(out:^serial.Writer,key:string,names:[]string) {
    api.write_key(out,key);serial.write_u8(out,'[')
    for name,i in names[:min(len(names),API_EXPLORE_NAMES)] {
        if i>0 {serial.write_u8(out,',')}
        serial.text_write_string(out,name)
    }
    serial.write_u8(out,']')
    if len(names)>API_EXPLORE_NAMES {api.write_int(out,fmt.tprintf("%s_more",key),i64(len(names)-API_EXPLORE_NAMES))}
}
