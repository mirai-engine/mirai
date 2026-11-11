package build

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:project"
import "mirai:std/base"

@(private="file")
stages_project :: proc(t:^testing.T,folder,core_source,game_source:string) -> (p:project.Project,ok:bool) {
    engine:=project.path(folder,"engine",allocator=context.temp_allocator)
    game:=project.path(folder,"project",allocator=context.temp_allocator)
    for path in ([]string{project.path(engine,"core",allocator=context.temp_allocator),project.path(game,"game",allocator=context.temp_allocator)}) {
        if !testing.expect(t,os.make_directory_all(path)==nil) {return}
    }
    if !testing.expect(t,os.write_entire_file(project.path(engine,"core","data.odin",allocator=context.temp_allocator),core_source)==nil) {return}
    if !testing.expect(t,os.write_entire_file(project.path(game,"game","game.odin",allocator=context.temp_allocator),game_source)==nil) {return}
    return project.Project{root=game,engine_root=engine},true
}

// The steps a loop and phase of the generated world calls, in order.
@(private="file")
calls_of :: proc(text,loop_phase:string) -> []string {
    calls:=make([dynamic]string,context.temp_allocator)
    at:=strings.index(text,strings.concatenate({loop_phase," :: proc("},context.temp_allocator))
    if at<0 {return nil}
    body:=text[at:]
    body=body[:strings.index(body,"\n}")]
    for line in strings.split_lines(body,context.temp_allocator) {
        trimmed:=strings.trim_space(line)
        if !strings.has_prefix(trimmed,"call_") {continue}
        append(&calls,trimmed[len("call_"):strings.index_byte(trimmed,'(')])
    }
    return calls[:]
}

@(private="file")
errors_have :: proc(errors:[]string,parts:..string) -> bool {
    for message in errors {
        all:=true
        for part in parts {all &&= strings.contains(message,part)}
        if all {return true}
    }
    return false
}

// A phase runs its steps one after another: its stages in their order, and
// inside a stage the steps in the order of the libraries, where what a step
// waits for runs right before it: its after, and the before that name it,
// separated by spaces or commas. The order is the same every time the world
// is generated, and it is all the world says of how its steps run. A step
// that makes entities settles the World before the next one runs.
@(test)
stages_run_in_order_and_after_and_before_order_a_stage :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"stages")
    if folder=="" {return}
    core_source:=`package core
@(storage) Clock :: struct {tick:u64}
@(component) Thing :: struct {value:f32}
@(step="fixed",stage="end") core_last :: proc(clock:Ref(Clock)) {}
@(step="fixed") core_middle :: proc(clock:Ref(Clock)) {}
@(step="fixed",stage="begin") core_first :: proc(clock:Ref(Clock)) {}
@(step="fixed",stage="react") core_react :: proc(clock:Ref(Clock)) {}
@(step="fixed",stage="react",after="game_react, core_react") core_after :: proc(clock:Ref(Clock)) {}
@(step="fixed",stage="simulate",after="core_middle") core_simulate :: proc(clock:Ref(Clock)) {}
`
    game_source:=`package game
import "mirai:core"
@(step="fixed") game_logic :: proc(clock:core.Ref(core.Clock)) {}
@(step="fixed",stage="react",before="core_react") game_react :: proc(clock:core.Ref(core.Clock)) {}
@(step="fixed",stage="react") game_late :: proc(clock:core.Ref(core.Clock)) {}
@(step="fixed",stage="apply") game_apply :: proc(clock:core.Ref(core.Clock)) {}
@(step="fixed",stage="apply") game_count :: proc(things:core.Read(core.Thing)) {}
@(step="fixed",stage="apply",before="game_count") game_spawn :: proc(commands:core.Commands) {}
`
    p,ok:=stages_project(t,folder,core_source,game_source)
    if !ok {return}
    output:=world_generate(&p,context.temp_allocator)
    if !testing.expectf(t,len(output.errors)==0,"%v",output.errors) {return}
    want:=[]string{"core_first","core_middle","game_logic","game_apply","game_spawn","game_count","core_simulate","game_react","core_react","core_after","game_late","core_last"}
    again:=world_generate(&p,context.temp_allocator)
    testing.expect(t,again.game_world==output.game_world && again.editor_world==output.editor_world,"two generations of the same sources differ")
    for text in ([]string{output.game_world,output.editor_world}) {
        got:=calls_of(text,"game_fixed")
        testing.expectf(t,slice_equal(got,want),"%v",got)
        // info.order lists them as the phase calls them, by their index in info.steps.
        testing.expect(t,strings.contains(text,"@(rodata) order_game_fixed:=[12]i32{2,1,6,9,11,10,5,7,3,4,8,0}"),text)
        // The steps of a phase run in that order and no other way: the world says nothing of which could run at once.
        for gone in ([]string{"Step_Edge","info.edges","info.parallel","worker"}) {
            testing.expectf(t,!strings.contains(text,gone),"the generated world still says %s",gone)
        }
        testing.expect(t,strings.contains(text,"steps[0]={\"core_last\",\"core\",{.Fixed,},{.Game,},call_core_last}"),text)
        // What game_spawn made is settled inside its call, before game_count is called.
        _,_,rest:=strings.partition(text,"call_game_spawn :: proc(world,shared,editor:rawptr,app_data:rawptr) {")
        body,_,_:=strings.partition(rest,"\n}\n")
        _,ran,after:=strings.partition(body,"p_game.game_spawn(p_core.commands(w,app.info))")
        testing.expectf(t,ran!="" && strings.contains(after,"p_core.settle(app.info,w,e)"),"%s",body)
    }
}

@(private="file")
slice_equal :: proc(a,b:[]string) -> bool {
    if len(a)!=len(b) {return false}
    for value,i in a {
        if value!=b[i] {return false}
    }
    return true
}

// Steps have no number: order= is an error that says what to use. A stage
// that does not exist, a name no step has, a cycle of names and an after or
// before against the order of the stages are errors that name the steps.
@(test)
order_names_cycles_and_stages_that_cannot_be_are_errors :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"stages")
    if folder=="" {return}
    core_source:=`package core
@(step="fixed",order=5) numbered :: proc() {}
@(step="fixed",stage="later") staged :: proc() {}
@(step="fixed",after="missing") lonely :: proc() {}
@(step="fixed",before="nowhere") lost :: proc() {}
@(step="fixed late",after="ring_b") ring_a :: proc() {}
@(step="fixed late",after="ring_a") ring_b :: proc() {}
@(step="fixed",stage="begin",after="lonely") early :: proc() {}
@(step="fixed",stage="end",before="lost") late :: proc() {}
@(step="late",after="numbered") elsewhere :: proc() {}
`
    p,ok:=stages_project(t,folder,core_source,"package game\n")
    if !ok {return}
    output:=world_generate(&p,context.temp_allocator)
    testing.expectf(t,errors_have(output.errors,"numbered has order=5","stage (begin input intent apply simulate react end","after=\"step\" or before=\"step\""),"%v",output.errors)
    testing.expectf(t,errors_have(output.errors,"staged has the stage \"later\"","the stages are begin input intent apply simulate react end"),"%v",output.errors)
    testing.expectf(t,errors_have(output.errors,"lonely runs after missing, and no step has that name"),"%v",output.errors)
    testing.expectf(t,errors_have(output.errors,"lost runs before nowhere, and no step has that name"),"%v",output.errors)
    testing.expectf(t,errors_have(output.errors,"early is in the stage begin and runs after lonely, which is in the stage intent"),"%v",output.errors)
    testing.expectf(t,errors_have(output.errors,"late is in the stage end and runs before lost, which is in the stage intent"),"%v",output.errors)
    cycles:=0
    for message in output.errors {
        if strings.contains(message,"ring_a runs after ring_b by after or before; ring_b runs after ring_a by after or before. take one of those names out of after or before") {cycles+=1}
    }
    testing.expectf(t,cycles==1,"a cycle in two phases is one error: %v",output.errors)
    // An after towards a step of another phase orders nothing and is no error.
    testing.expectf(t,!errors_have(output.errors,"elsewhere"),"%v",output.errors)
}

// Inside a stage the data orders the steps: the ones that push to a queue run
// before the step of its library that takes it, and the writer of a table, of
// a storage or of events before the ones that read it. A step that pushes a
// request to the writer of what it reads runs before it, and so does one that
// names it: it reads what the last tick left. What several write (shared) is
// not ordered. A name that says what the data says changes nothing.
@(test)
the_data_of_a_stage_orders_its_steps :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"stages")
    if folder=="" {return}
    core_source:=`package core
@(storage,queue) Orders :: struct {count:int}
@(storage) News :: struct {log:Events(int)}
@(storage) Board :: struct {value:int}
@(component) Score :: struct {value:f32}
@(component,shared) Place :: struct {value:f32}
@(step="fixed") core_serve :: proc(orders:^Orders,news:^News,board:^Board) {}
`
    game_source:=`package game
import "mirai:core"
@(component) Mark :: struct {{value:f32}}
@(step="fixed"%s) game_show :: proc(scores:core.Read(core.Score),news:core.Ref(core.News),board:core.Ref(core.Board)) {{}}
@(step="fixed") game_count :: proc(scores:^core.Table(core.Score),marks:core.Read(Mark)) {{}}
@(step="fixed") game_mark :: proc(marks:^core.Table(Mark),orders:^core.Orders) {{}}
@(step="fixed") game_look :: proc(places:core.Read(core.Place)) {{}}
@(step="fixed") game_move :: proc(places:^core.Table(core.Place)) {{}}
@(step="fixed") game_ask :: proc(board:core.Ref(core.Board),orders:^core.Orders) {{}}
@(step="fixed",before="game_count") game_peek :: proc(scores:core.Read(core.Score)) {{}}
`
    want:=[]string{"game_mark","game_ask","core_serve","game_peek","game_count","game_show","game_look","game_move"}
    worlds:[2]string
    for name,i in ([]string{"",`,after="core_serve game_count"`}) {
        p,ok:=stages_project(t,folder,core_source,fmt.tprintf(game_source,name))
        if !ok {return}
        output:=world_generate(&p,context.temp_allocator)
        if !testing.expectf(t,len(output.errors)==0,"%v",output.errors) {return}
        got:=calls_of(output.game_world,"game_fixed")
        testing.expectf(t,slice_equal(got,want),"%v",got)
        again:=world_generate(&p,context.temp_allocator)
        testing.expect(t,again.game_world==output.game_world && again.editor_world==output.editor_world,"two generations of the same sources differ")
        worlds[i]=output.game_world
    }
    testing.expect(t,worlds[0]==worlds[1],"a name that says what the data says changed the world")
}

// Steps that wait for each other through what they read, write, push and take
// are an error that names them, what makes each wait and the name that
// settles it; with that name the world is generated.
@(test)
a_cycle_of_the_data_is_an_error_one_name_settles :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"stages")
    if folder=="" {return}
    core_source:=`package core
@(storage,queue) Orders :: struct {count:int}
@(component) Stock :: struct {value:f32}
@(component) Price :: struct {value:f32}
@(component) Sale :: struct {value:f32}
@(step="fixed late") core_orders :: proc(orders:^Orders,sales:^Table(Sale)) {}
`
    game_source:=`package game
import "mirai:core"
@(step="fixed"%s) game_stock :: proc(stock:^core.Table(core.Stock),prices:core.Read(core.Price)) {{}}
@(step="fixed") game_price :: proc(prices:^core.Table(core.Price),stock:core.Read(core.Stock)) {{}}
@(step="late"%s) game_buy :: proc(orders:^core.Orders,shelf:core.Read(Shelf)) {{}}
@(step="late") game_sold :: proc(shelf:^core.Table(Shelf),sales:core.Read(core.Sale)) {{}}
@(component) Shelf :: struct {{value:f32}}
`
    cases:=[]struct{stock,buy:string,errors:[]string,fixed,late:[]string}{
        {"",`,before="game_sold"`,{
            "steps of the stage intent of fixed in the game loop wait for each other: game_stock runs after game_price, which writes Price, which game_stock reads; game_price runs after game_stock, which writes Stock, which game_price reads. a name wins over what the data says, so one name settles it: write before=\"game_price\" on game_stock, or after=\"game_stock\" on game_price, and game_stock reads Price as the last tick left it",
        },nil,nil},
        // A cycle through a request: the name it proposes is on what is read, which costs a request no tick.
        {`,before="game_price"`,"",{
            "core_orders runs after game_buy, which pushes to Orders, a queue core_orders takes; game_buy runs after game_sold, which writes Shelf, which game_buy reads; game_sold runs after core_orders, which writes Sale, which game_sold reads",
            "write before=\"game_sold\" on game_buy, or after=\"game_buy\" on game_sold, and game_buy reads Shelf as the last tick left it",
        },nil,nil},
        {`,before="game_price"`,`,before="game_sold"`,nil,{"core_orders","game_stock","game_price"},{"game_buy","core_orders","game_sold"}},
    }
    for c in cases {
        p,ok:=stages_project(t,folder,core_source,fmt.tprintf(game_source,c.stock,c.buy))
        if !ok {return}
        output:=world_generate(&p,context.temp_allocator)
        for part in c.errors {testing.expectf(t,errors_have(output.errors,part),"%s is missing in %v",part,output.errors)}
        if len(c.errors)>0 {
            testing.expectf(t,len(output.errors)==1,"%v",output.errors)
            continue
        }
        if !testing.expectf(t,len(output.errors)==0,"%v",output.errors) {continue}
        fixed,late:=calls_of(output.game_world,"game_fixed"),calls_of(output.game_world,"game_late")
        testing.expectf(t,slice_equal(fixed,c.fixed) && slice_equal(late,c.late),"%v %v",fixed,late)
    }
}

// In the world of the demo a seat's camera is settled with who drives what, before the seat's
// Move_Input: what a cinematic that ends releases, its input block and its camera override, is
// in force in the same tick, so its seat never walks through the camera it let go.
@(test)
a_seat_camera_is_settled_with_its_driving_before_its_move :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    root:=slashes(project.path_absolute(#directory+"../.."),context.temp_allocator)
    p,error:=project.open(project.path(root,"demo"),root)
    defer project.close(&p)
    if !testing.expectf(t,error.code==.None,"the demo opens: %v",error) {return}
    output:=world_generate(&p)
    if !testing.expectf(t,len(output.errors)==0,"%v",output.errors) {return}
    calls:=calls_of(output.game_world,"game_fixed")
    order:=[]string{"input_drive","camera_select","camera_drive"}
    at:=make([]int,len(order))
    for name,i in order {
        at[i]=-1
        for call,j in calls {if call==name {at[i]=j}}
        if !testing.expectf(t,at[i]>=0,"the fixed phase of the demo calls no %s: %v",name,calls) {return}
    }
    testing.expectf(t,at[0]<at[1] && at[1]<at[2],"%v run at %v of %v",order,at,calls)
}

// A server step runs only where the rules are decided: the generated call
// returns before it on a client, also when a correction resimulates.
@(test)
a_server_step_is_skipped_on_a_client :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"stages")
    if folder=="" {return}
    core_source:=`package core
Network_Role :: enum u8 {Standalone,Server,Client}
@(storage,keep) Network :: struct {role:Network_Role}
@(storage) Clock :: struct {tick:u64}
`
    game_source:=`package game
import "mirai:core"
@(step="fixed",server) game_decide :: proc(clock:^core.Clock) {}
@(step="fixed") game_count :: proc(clock:core.Ref(core.Clock)) {}
`
    p,ok:=stages_project(t,folder,core_source,game_source)
    if !ok {return}
    output:=world_generate(&p,context.temp_allocator)
    if !testing.expectf(t,len(output.errors)==0,"%v",output.errors) {return}
    for text in ([]string{output.game_world,output.editor_world}) {
        decide:=text[strings.index(text,"call_game_decide :: proc"):]
        decide=decide[:strings.index(decide,"\n}")]
        gate:=strings.index(decide,"    if w.network.role==.Client {return}\n")
        testing.expectf(t,gate>=0 && gate<strings.index(decide,"p_game.game_decide("),"%s",decide)
        count:=text[strings.index(text,"call_game_count :: proc"):]
        count=count[:strings.index(count,"\n}")]
        testing.expect(t,!strings.contains(count,"role==.Client"),count)
        testing.expect(t,slice_equal(calls_of(text,"game_fixed"),{"game_decide","game_count"}))
    }
    // Without core.Network the generator cannot know the role.
    testing.expect(t,os.write_entire_file(project.path(p.engine_root,"core","data.odin",allocator=context.temp_allocator),"package core\n@(storage) Clock :: struct {tick:u64}\n")==nil)
    output=world_generate(&p,context.temp_allocator)
    testing.expectf(t,errors_have(output.errors,"game_decide is server, and the world has no core.Network"),"%v",output.errors)
}
