package workspace

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import "mirai:std/base"

// A compilation counts from when it takes its turn: while it holds it, and
// after it left it for a measurement that started before it took it.
@(test)
a_compilation_counts_from_when_it_takes_its_turn :: proc(t:^testing.T) {
    root:=base.test_folder(t,"workspace")
    if root=="" {return}
    before:=time.now()
    testing.expect(t,!builds_since(root,before))
    // File times can lag the precise clock by a tick of the system.
    time.sleep(50*time.Millisecond)
    lock,ok:=build_acquire(root,fmt.tprintf("pid %d, mirai test",os.get_pid()))
    testing.expect(t,ok)
    testing.expect(t,builds_since(root,before))
    lock_release(&lock)
    testing.expect(t,builds_since(root,before))
    time.sleep(50*time.Millisecond)
    testing.expect(t,!builds_since(root,time.now()))
}

// A compilation takes a turn after the first only with the memory of another
// one free, a generation of shaders waits for none of them, and a measurement
// waits for all of them.
@(test)
the_turns_of_the_compilations_follow_the_memory_and_a_measurement_waits_for_them :: proc(t:^testing.T) {
    if measuring() {return}
    root:=base.test_folder(t,"workspace")
    if root=="" {return}
    first,first_taken,_,_:=build_turn_try(root,"first",2,BUILD_TURN_MEMORY)
    testing.expect(t,first_taken)
    _,refused,holder,_:=build_turn_try(root,"short of memory",2,BUILD_TURN_MEMORY-1)
    testing.expect(t,!refused)
    testing.expect_value(t,holder,"first")
    second,second_taken,_,_:=build_turn_try(root,"second",2,BUILD_TURN_MEMORY)
    testing.expect(t,second_taken)
    _,third_taken,_,_:=build_turn_try(root,"third",2,BUILD_TURN_MEMORY)
    testing.expect(t,!third_taken,"there are no more turns than the machine has")
    shaders,shaders_ok:=shaders_acquire(root,"shaders")
    testing.expect(t,shaders_ok,"a generation of shaders waits for no compilation")
    lock_release(&first)
    _,_,_,why:=measure_try(root,"measure")
    testing.expect_value(t,why,Measure_Wait.Build)
    lock_release(&second)
    _,_,_,why=measure_try(root,"measure")
    testing.expect_value(t,why,Measure_Wait.Build)
    lock_release(&shaders)
    measure,started,_,_:=measure_try(root,"measure")
    testing.expect(t,started)
    lock_release(&measure)
}

// What runs for the measurement that holds the turn does not wait for it
// again; for another one, or for none, it waits.
@(test)
a_measurement_does_not_wait_for_its_own_turn :: proc(t:^testing.T) {
    if measuring() {return}
    root:=base.test_folder(t,"workspace")
    if root=="" {return}
    what:=measure_holder("mirai measure",context.temp_allocator)
    held,ok:=lock_acquire(lock_path(root,MEASURE_LOCK,context.temp_allocator),what)
    testing.expect(t,ok)
    own:=fmt.tprintf("%d",os.get_pid())
    part,started,_,_:=measure_try(root,"profile.capture",0,own)
    testing.expect(t,started && !part.held,"it runs as part of the measurement, without the lock")
    for other in ([]string{"",fmt.tprintf("%d",os.get_pid()+1),fmt.tprintf("%d0",os.get_pid())}) {
        _,taken,holder,_:=measure_try(root,"profile.capture",0,other)
        testing.expectf(t,!taken,"%q is not the measurement that holds the turn",other)
        testing.expect_value(t,holder,what)
    }
    lock_release(&held)
    alone,alone_started,_,_:=measure_try(root,"profile.capture",0,own)
    testing.expect(t,alone_started && alone.held,"a measurement that ended holds nothing: the turn is taken")
    lock_release(&alone)
}

// Two compilations of a checkout do not run at once, and what a compilation
// holds of its checkout goes with its turn.
@(test)
a_compilation_holds_its_checkout_and_the_project_it_builds :: proc(t:^testing.T) {
    root:=base.test_folder(t,"workspace")
    if root=="" {return}
    game:=join(root,"game")
    lock,ok:=build_acquire(root,"build",nil,{game})
    testing.expect(t,ok)
    paths:=[2]string{join(root,".mirai","build-turn.lock"),join(game,".mirai","build-turn.lock")}
    for path in paths {
        held,_,_:=lock_holder(path,context.temp_allocator)
        testing.expect(t,held,path)
    }
    lock_release(&lock)
    for path in paths {
        held,_,_:=lock_holder(path,context.temp_allocator)
        testing.expect(t,!held,path)
    }
}

// The holder of a lock is what it wrote when it took it, since then; a free
// lock has none.
@(test)
a_held_lock_says_who_holds_it_and_since_when :: proc(t:^testing.T) {
    root:=base.test_folder(t,"workspace")
    if root=="" {return}
    path:=lock_path(root,MEASURE_LOCK,context.temp_allocator)
    held,_,_:=lock_holder(path,context.temp_allocator)
    testing.expect(t,!held)
    what:=fmt.tprintf("pid %d, mirai measure in %s",os.get_pid()+1,root)
    lock,ok:=lock_acquire(path,what)
    testing.expect(t,ok)
    holder:string
    since:time.Time
    held,holder,since=lock_holder(path,context.temp_allocator)
    testing.expect(t,held)
    testing.expect_value(t,holder,what)
    testing.expectf(t,abs(time.diff(since,time.now()))<time.Minute,"taken at %v",since)
    if !measuring() {
        running,measurer:=measured(root,false,allocator=context.temp_allocator)
        testing.expect_value(t,running,Measured.Low)
        testing.expect_value(t,measurer,what)
    }
    lock_release(&lock)
    held,_,_=lock_holder(path,context.temp_allocator)
    testing.expect(t,!held)
    // The owner file of a process that ended, whose pid is this one's now, holds nothing.
    testing.expect(t,os.write_entire_file(fmt.tprintf("%s.owner",path),transmute([]u8)what)==nil)
    held,_,_=lock_holder(path,context.temp_allocator)
    testing.expect(t,!held)
}

// A GPU turn is given while the charges fit the card with its reserve; the
// first one always.
@(test)
a_gpu_turn_is_given_while_the_charges_fit_the_card :: proc(t:^testing.T) {
    GB :: i64(1)<<30
    Case :: struct {name:string,memory:i64,held:[]i64,charge:i64,admits:bool}
    cases:=[]Case{
        {name="the first one, larger than the card",memory=4*GB,charge=6*GB,admits=true},
        {name="two that fit beside the reserve",memory=8*GB,held={3*GB},charge=3*GB,admits=true},
        {name="the reserve is not given",memory=8*GB,held={3*GB,3*GB},charge=2*GB,admits=false},
        {name="what is left of the card exactly",memory=8*GB,held={3*GB,3*GB},charge=1*GB,admits=true},
    }
    for c in cases {testing.expectf(t,gpu_admits(c.memory,c.held,c.charge)==c.admits,"%s",c.name)}
}

// The turns follow the memory the card said: one that does not fit waits and
// names who holds them, a person takes one anyway and counts for the others,
// and a turn whose holder ended is free, whatever its owner file says.
@(test)
the_gpu_turns_follow_the_card_and_a_person_never_waits :: proc(t:^testing.T) {
    if measuring() {return}
    root:=base.test_folder(t,"workspace")
    if root=="" {return}
    GB :: i64(1)<<30
    gpu_card_write(root,{8*GB,true,"card"})
    first,first_taken,_:=gpu_try(root,"pid 1, mirai session in a",3*GB)
    second,second_taken,_:=gpu_try(root,"pid 2, mirai session in b",3*GB)
    testing.expect(t,first_taken && second_taken)
    // An editor that starts again as another hands it its turn, and its name.
    gpu_turn_follow(root,2,7)
    named:=false
    for holder in gpu_holders(root,context.temp_allocator) {named||=holder.holder==gpu_holder_text("pid 7, mirai session in b",3*GB)}
    testing.expect(t,named,"the turn names the editor that holds it now")
    _,third_taken,waiting:=gpu_try(root,"pid 3, mirai capture in c",3*GB)
    testing.expect(t,!third_taken,"a third one does not fit")
    testing.expect_value(t,len(waiting.holders),2)
    testing.expect_value(t,waiting.memory,8*GB)
    if len(waiting.holders)==2 {
        testing.expect_value(t,waiting.holders[0].holder,gpu_holder_text("pid 1, mirai session in a",3*GB))
        testing.expect_value(t,waiting.holders[0].charge,3*GB)
    }
    person,person_taken,_:=gpu_try(root,"pid 4, mirai edit in d",3*GB,person=true)
    testing.expect(t,person_taken,"a person takes a turn without the room for it")
    lock_release(&first)
    _,fits_taken,_:=gpu_try(root,"pid 5, mirai test rhi",2*GB)
    testing.expect(t,!fits_taken,"the turn of a person counts for the others")
    small,small_taken,_:=gpu_try(root,"pid 5, mirai test rhi",1*GB)
    testing.expect(t,small_taken,"the turn of one that ended is free")
    lock_release(&small)
    lock_release(&second)
    lock_release(&person)
    stale:=gpu_turn_path(root,3,context.temp_allocator)
    testing.expect(t,os.write_entire_file(fmt.tprintf("%s.owner",stale),transmute([]u8)gpu_holder_text("pid 6, ended",6*GB))==nil)
    testing.expect_value(t,len(gpu_holders(root,context.temp_allocator)),0)
}

// While another process measures, no GPU turn starts but those of a person
// and of the measurement itself.
@(test)
a_measurement_holds_the_new_gpu_turns_but_its_own :: proc(t:^testing.T) {
    if measuring() {return}
    root:=base.test_folder(t,"workspace")
    if root=="" {return}
    path:=lock_path(root,MEASURE_LOCK,context.temp_allocator)
    other:=fmt.tprintf("pid %d, mirai bench compare",os.get_pid()+1)
    measure,ok:=lock_acquire(path,other)
    testing.expect(t,ok)
    _,taken,waiting:=gpu_try(root,"pid 1, mirai session in a",GPU_CHARGE_DEFAULT)
    testing.expect(t,!taken)
    testing.expect_value(t,waiting.measurement,other)
    person,person_taken,_:=gpu_try(root,"pid 2, mirai edit in b",GPU_CHARGE_DEFAULT,person=true)
    testing.expect(t,person_taken,"a person does not wait for a measurement")
    lock_release(&person)
    lock_release(&measure)
    own,own_ok:=lock_acquire(path,measure_holder("mirai bench compare"))
    testing.expect(t,own_ok)
    editor,editor_taken,_:=gpu_try(root,"pid 3, mirai bench compare in c",GPU_CHARGE_DEFAULT)
    testing.expect(t,editor_taken,"the measurement opens its own editors")
    lock_release(&editor)
    lock_release(&own)
}

// While another process measures, what would put work on the GPU waits for
// it, what uses none runs at low priority, and what is part of it runs.
@(test)
what_would_use_the_gpu_waits_for_the_measurement_of_another_process :: proc(t:^testing.T) {
    if measuring() {return}
    root:=base.test_folder(t,"workspace")
    if root=="" {return}
    other:=fmt.tprintf("%d",os.get_pid()+1)
    holder:=fmt.tprintf("pid %s, mirai bench compare",other)
    Case :: struct {name:string,measuring:bool,gpu:bool,part_of:string,what:Measured}
    cases:=[]Case{
        {name="a GPU test",measuring=true,gpu=true,what=.Wait},
        {name="a test without the GPU",measuring=true,what=.Low},
        {name="a GPU test the measurement runs",measuring=true,gpu=true,part_of=other,what=.Run},
        {name="a GPU test of another measurement",measuring=true,gpu=true,part_of=fmt.tprintf("%s0",other),what=.Wait},
        {name="a GPU test while nothing measures",gpu=true,what=.Run},
    }
    for c in cases {
        measure:Lock
        if c.measuring {
            ok:bool
            measure,ok=lock_acquire(lock_path(root,MEASURE_LOCK,context.temp_allocator),holder)
            testing.expect(t,ok)
        }
        what,said:=measured(root,c.gpu,c.part_of,context.temp_allocator)
        testing.expectf(t,what==c.what,"%s: %v",c.name,what)
        testing.expectf(t,(said==holder)==(c.what!=.Run),"%s: says %q",c.name,said)
        if c.gpu {
            turn,taken,waiting:=gpu_try(root,"pid 1, mirai test rhi",GPU_CHARGE_DEVICE,part_of=c.part_of)
            testing.expectf(t,taken==(c.what==.Run) && (waiting.measurement==holder)==(c.what==.Wait),"%s: its GPU turn",c.name)
            lock_release(&turn)
            testing.expectf(t,measurement_wait(root,c.part_of,limit=time.Millisecond)==(c.what==.Run),"%s: waits",c.name)
        }
        lock_release(&measure)
    }
}

// A measurement starts once the GPU work of others in flight ends: a test, an
// editor that starts or a session while a call draws; not for a session open
// and idle, nor for what is part of it.
@(test)
a_measurement_waits_for_the_gpu_work_in_flight_and_not_for_an_open_session :: proc(t:^testing.T) {
    if measuring() {return}
    root:=base.test_folder(t,"workspace")
    if root=="" {return}
    own:=fmt.tprintf("%d",os.get_pid())
    Case :: struct {name,what,part_of:string,open,marked_open,marked_work,waits:bool}
    cases:=[]Case{
        {name="a GPU test",what="pid 11, mirai test rhi",waits=true},
        {name="an open session",what="pid 12, the session of a",open=true},
        {name="a session while a call draws",what="pid 13, the session of b",open=true,marked_work=true,waits=true},
        {name="a session once its call ended",what="pid 14, the session of c",marked_open=true},
        {name="the editor of a person",what="pid 15, mirai edit d",open=true},
        {name="an editor this measurement opened",what="pid 16, the editor of mirai bench, head",part_of=own},
        {name="an editor of another measurement that starts",what="pid 17, the editor of mirai bench, base",part_of="88",waits=true},
        {name="this process",what=fmt.tprintf("pid %s, profile.capture in e",own)},
    }
    for c in cases {
        turn,taken,_,_:=lock_take(gpu_turn_path(root,0,context.temp_allocator),gpu_holder_text(c.what,GPU_CHARGE_DEVICE,c.part_of,open=c.open))
        if !testing.expectf(t,taken,"%s: a turn",c.name) {continue}
        pid:=pid_of(c.what)
        if c.marked_open {testing.expect_value(t,gpu_turn_mark(root,pid,true),0)}
        if c.marked_work {testing.expect_value(t,gpu_turn_mark(root,pid,false,0),0)}
        measure,ok,holder,why:=measure_try(root,measure_holder("mirai bench compare"))
        testing.expectf(t,ok!=c.waits,"%s: the measurement started: %v",c.name,ok)
        if c.waits {
            testing.expect_value(t,why,Measure_Wait.Gpu)
            testing.expectf(t,strings.has_prefix(holder,c.what),"%s: waits for %q",c.name,holder)
        }
        testing.expect(t,measure.held==ok)
        lock_release(&measure)
        holders:=gpu_holders(root,context.temp_allocator)
        if len(holders)==1 {testing.expectf(t,gpu_holder_measurement(holders[0].holder)==c.part_of && strings.has_prefix(holders[0].holder,c.what),"%s: marking keeps who holds it: %s",c.name,holders[0].holder)}
        lock_release(&turn)
    }
}

// The GPU first, the measurement after it: what would hold the measurement
// never waits for room on the GPU, a wait for room that only what stays open
// holds fails at once, and what waits for the measurement says its GPU turn
// is idle meanwhile, so the measurement does not wait for it. The shapes: a
// test with a benchmark beside a session that holds the card and wants a
// capture, and two sessions that hold memory and both want a capture.
@(test)
a_measurement_and_the_memory_of_the_gpu_never_wait_for_each_other :: proc(t:^testing.T) {
    if measuring() {return}
    root:=base.test_folder(t,"workspace")
    if root=="" {return}
    GB :: i64(1)<<30
    gpu_card_write(root,{7*GB+800<<20,true,"card"})
    own:=fmt.tprintf("pid %d",os.get_pid())
    Staged :: struct {what:string,charge:i64,open:bool}
    Case :: struct {
        name:string,
        staged:[]Staged,
        measuring:string, // who holds the measurement; "" for none
        charge:i64,       // >0: this process asks for a GPU turn first, as a test does
        taken,stuck:bool,
        measure:bool,     // then it asks for the measurement, waiting a moment
        started:bool,
        why:Measure_Wait,
        idle_for:string,  // the measurer that sees no GPU work of this process while it waits
    }
    cases:=[]Case{
        {name="a test beside a session that holds the card fails at once, without the measurement",staged={{"pid 21, the session of cave",7*GB,true}},charge=GPU_CHARGE_DEVICE,stuck=true},
        {name="and the capture of that session starts",staged={{"pid 21, the session of cave",7*GB,true}},measure=true,started=true},
        {name="a test whose room a test in flight holds waits for it",staged={{"pid 22, mirai test rhi",6*GB,false}},charge=2*GB},
        {name="a test with its turn waits idle for the capture that measures",staged={{fmt.tprintf("%s, mirai test render",own),GPU_CHARGE_DEVICE,false},{"pid 21, the session of cave",5*GB,true}},measuring="pid 21, profile.capture in cave",measure=true,why=.Measurement,idle_for="21"},
        {name="a session waits idle for the capture of another session",staged={{fmt.tprintf("%s, the session of a",own),3*GB,false},{"pid 31, the session of b",3*GB,true}},measuring="pid 31, profile.capture in b",measure=true,why=.Measurement,idle_for="31"},
        {name="a session waits for another session to settle, which ends by itself",staged={{fmt.tprintf("%s, the session of a",own),3*GB,true},{"pid 31, the session of b",3*GB,false}},measure=true,why=.Gpu},
    }
    for c in cases {
        held:=make([dynamic]Lock,context.temp_allocator)
        for staged,i in c.staged {
            lock,taken,_,_:=lock_take(gpu_turn_path(root,i,context.temp_allocator),gpu_holder_text(staged.what,staged.charge,open=staged.open))
            testing.expectf(t,taken,"%s: staged %s",c.name,staged.what)
            append(&held,lock)
        }
        measure:Lock
        if c.measuring!="" {measure,_=lock_acquire(lock_path(root,MEASURE_LOCK,context.temp_allocator),c.measuring)}
        if c.charge>0 {
            turn,taken,waiting:=gpu_try(root,"pid 1, mirai test render",c.charge)
            testing.expectf(t,taken==c.taken && waiting.stuck==c.stuck,"%s: taken %v, stuck %v",c.name,taken,waiting.stuck)
            lock_release(&turn)
        }
        if c.measure {
            Try :: struct {root:string,ok:bool,why:Measure_Wait}
            try_:=new(Try)
            try_.root=root
            th:=thread.create_and_start_with_poly_data(try_,proc(try_:^Try) {
                lock,ok,_,why:=measure_try(try_.root,measure_holder("profile.capture"),600*time.Millisecond)
                lock_release(&lock)
                try_.ok,try_.why=ok,why
            })
            if c.idle_for!="" {
                time.sleep(250*time.Millisecond)
                testing.expectf(t,len(gpu_work(root,c.idle_for,context.temp_allocator))==0,"%s: its turn is idle while it waits",c.name)
            }
            thread.join(th)
            thread.destroy(th)
            testing.expectf(t,try_.ok==c.started && (c.started || try_.why==c.why),"%s: started %v, waited for %v",c.name,try_.ok,try_.why)
            if c.idle_for!="" {testing.expectf(t,len(gpu_work(root,c.idle_for,context.temp_allocator))==1,"%s: its turn works again when it gives up",c.name)}
            free(try_)
        }
        lock_release(&measure)
        for &lock in held {lock_release(&lock)}
    }
}

// An editor of a project is charged the peak of its last session, which a
// copy of the project shares; one never measured and one without a project
// are charged what is assumed of each.
@(test)
a_gpu_charge_is_the_last_peak_of_the_project :: proc(t:^testing.T) {
    root:=base.test_folder(t,"workspace")
    if root=="" {return}
    game:=join(root,"game")
    testing.expect_value(t,gpu_charge(root,game),GPU_CHARGE_DEFAULT)
    testing.expect_value(t,gpu_charge(root,""),GPU_CHARGE_DEVICE)
    testing.expect(t,!gpu_admits(i64(48)<<30,{GPU_CHARGE_DEVICE},gpu_charge(root,game)),"one never measured opens beside no other")
    testing.expect(t,gpu_admits(i64(8)<<30,nil,gpu_charge(root,game)),"and alone it opens")
    gpu_peak_write(root,join(game,".mirai","tmp","session-copy-1"),1500<<20)
    testing.expect_value(t,gpu_charge(root,game),i64(1500)<<20)
    gpu_peak_write(root,game,700<<20)
    testing.expect_value(t,gpu_charge(root,join(game,".mirai","tmp","session-copy-2")),i64(700)<<20)
    // A session the card pressed does not lower the charge; it raises it.
    gpu_peak_end(root,game,300<<20,pressed=true)
    testing.expect_value(t,gpu_charge(root,game),i64(700)<<20)
    gpu_peak_end(root,join(game,".mirai","tmp","session-copy-3"),900<<20,pressed=true)
    testing.expect_value(t,gpu_charge(root,game),i64(900)<<20)
    gpu_peak_end(root,game,400<<20,pressed=false)
    testing.expect_value(t,gpu_charge(root,game),i64(400)<<20)
    GB :: i64(1)<<30
    testing.expect(t,gpu_pressed(4*GB+GB/2,5*GB),"held within the reserve of the budget")
    testing.expect(t,gpu_pressed(6*GB,5*GB),"held beyond the budget")
    testing.expect(t,!gpu_pressed(4*GB,6*GB),"room left")
    testing.expect(t,!gpu_pressed(0,0),"a driver that says nothing")
    charge,charged:=gpu_holder_charge(gpu_holder_text("pid 1, mirai session in a, b",700<<20))
    testing.expect(t,charged)
    testing.expect_value(t,charge,i64(700)<<20)
}

// The card admission takes is the one the devices said, whatever said it
// last: a card of its own over memory shared with the system, and the
// smaller of two of the same kind; what is not kept is refused with why.
@(test)
the_card_is_the_smallest_of_its_own_whoever_said_it_last :: proc(t:^testing.T) {
    GB :: i64(1)<<30
    card:=Gpu_Card{7*GB+800<<20,true,"NVIDIA GeForce RTX 3070"}
    shared:=Gpu_Card{10*GB+600<<20,false,"AMD Radeon(TM) Graphics"}
    Case :: struct {name:string,kept:Gpu_Card,known:bool,said:Gpu_Card,card:Gpu_Card,refused:bool}
    cases:=[]Case{
        {name="the first one said",said=card,card=card},
        {name="the same again",kept=card,known=true,said=card,card=card},
        {name="memory shared with the system after the card",kept=card,known=true,said=shared,card=card,refused=true},
        {name="the card after memory shared with the system",kept=shared,known=true,said=card,card=card},
        {name="more than the card said",kept=card,known=true,said={11*GB,true,card.name},card=card,refused=true},
        {name="less than was said",kept={11*GB,true,card.name},known=true,said=card,card=card,refused=true},
        {name="a device that says no memory",kept=card,known=true,said={0,true,"lost"},card=card,refused=true},
        {name="nothing said yet and no memory",said={0,true,"lost"},card={},refused=true},
    }
    for c in cases {
        got,refused:=gpu_card_said(c.kept,c.known,c.said)
        testing.expectf(t,got.bytes==c.card.bytes && got.own==c.card.own && got.name==c.card.name,"%s: kept %v",c.name,got)
        testing.expectf(t,(refused!="")==c.refused,"%s: refused %q",c.name,refused)
    }
    root:=base.test_folder(t,"workspace")
    if root=="" {return}
    memory,known:=gpu_memory(root)
    testing.expect(t,!known && memory==GPU_MEMORY_ASSUMED,"assumed before any device says it")
    for order in ([2][3]Gpu_Card{{card,shared,{11*GB,true,card.name}},{shared,{11*GB,true,card.name},card}}) {
        _=os.remove(join(cache_folder(root,GPU_FOLDER,context.temp_allocator),GPU_CARD_FILE))
        for said in order {gpu_card_write(root,said)}
        kept,_:=gpu_card(root)
        testing.expectf(t,kept.bytes==card.bytes && kept.own && kept.name==card.name,"whatever the order: %v",kept)
    }
}

// A holder raises its charge to what it held while it runs and never lowers
// it; what the holders held beyond the card is told.
@(test)
a_holder_raises_its_charge_to_what_it_held :: proc(t:^testing.T) {
    if measuring() {return}
    root:=base.test_folder(t,"workspace")
    if root=="" {return}
    MIB :: i64(1)<<20
    Case :: struct {name:string,what:string,charge:i64,part_of:string,held:[]i64,charge_after:i64,held_after:i64}
    cases:=[]Case{
        {name="what it holds passes its charge",what="pid 41, the session of a",charge=1613*MIB,held={4096*MIB},charge_after=4096*MIB,held_after=4096*MIB},
        {name="less than its charge leaves it",what="pid 42, the session of b",charge=3000*MIB,held={1000*MIB},charge_after=3000*MIB,held_after=1000*MIB},
        {name="never lowered while it runs",what="pid 43, the session of c",charge=1000*MIB,held={2500*MIB,900*MIB},charge_after=2500*MIB,held_after=2500*MIB},
        {name="an unknown project keeps its charge",what="pid 44, the session of d",charge=GPU_CHARGE_DEFAULT,held={2000*MIB},charge_after=GPU_CHARGE_DEFAULT,held_after=2000*MIB},
        {name="the turn of a measurement stays one",what="pid 45, the editor of mirai bench, head",charge=500*MIB,part_of="77",held={800*MIB},charge_after=800*MIB,held_after=800*MIB},
    }
    for c in cases {
        lock,taken,_:=gpu_try(root,c.what,c.charge,person=true,part_of=c.part_of)
        if !testing.expectf(t,taken,"%s: a turn",c.name) {continue}
        before:=gpu_holders(root,context.temp_allocator)
        turn:=-1
        for held in c.held {turn=gpu_turn_raise(root,pid_of(c.what),held,turn)}
        testing.expectf(t,turn>=0,"%s: its turn is found by its pid",c.name)
        holders:=gpu_holders(root,context.temp_allocator)
        testing.expect_value(t,len(holders),1)
        if len(holders)==1 {
            testing.expectf(t,holders[0].charge==c.charge_after && holders[0].held==c.held_after,"%s: charged %d MiB holding %d",c.name,holders[0].charge>>20,holders[0].held>>20)
            testing.expectf(t,strings.has_prefix(holders[0].holder,c.what) && gpu_holder_measurement(holders[0].holder)==c.part_of,"%s: %s",c.name,holders[0].holder)
            testing.expectf(t,len(before)==1 && holders[0].since==before[0].since,"%s: held since when it was taken",c.name)
        }
        testing.expect_value(t,gpu_turn_raise(root,99999,c.charge,turn),-1)
        lock_release(&lock)
    }
    GB :: i64(1)<<30
    testing.expect_value(t,gpu_held_over(8*GB,{{held=3*GB},{held=3*GB}}),i64(0))
    testing.expect_value(t,gpu_held_over(8*GB,{{held=4*GB},{held=4*GB}}),GB)
}

// An unattended program runs on the card the turns account for, or on the
// adapter MIRAI_GPU names; before a card is known, on any.
@(test)
an_unattended_program_runs_on_the_card_of_the_turns :: proc(t:^testing.T) {
    card:=Gpu_Card{8406433792,true,"NVIDIA GeForce RTX 3070"}
    shared:=Gpu_Card{11343167488,false,"AMD Radeon(TM) Graphics"}
    Case :: struct {name:string,card:Gpu_Card,known:bool,device:string,preferred:string,refused:bool}
    cases:=[]Case{
        {name="on the card",card=card,known=true,device=card.name},
        {name="on the integrated adapter",card=card,known=true,device=shared.name,refused=true},
        {name="on the one MIRAI_GPU names",card=card,known=true,device=shared.name,preferred="amd"},
        {name="MIRAI_GPU names another",card=card,known=true,device=shared.name,preferred="nvidia",refused=true},
        {name="no card known yet",device=shared.name},
        {name="the turns know only shared memory",card=shared,known=true,device="Other"},
        {name="without a device",card=card,known=true},
    }
    for c in cases {
        problem:=gpu_off_card(c.card,c.known,c.device,c.preferred)
        testing.expectf(t,(problem!="")==c.refused,"%s: %q",c.name,problem)
    }
}

// The turns of one measurement run at once beyond the card while no one else
// holds a turn; beside another holder they need the room.
@(test)
the_turns_of_a_measurement_share_the_card_when_alone :: proc(t:^testing.T) {
    root:=base.test_folder(t,"workspace")
    if root=="" {return}
    GB :: i64(1)<<30
    gpu_card_write(root,{4*GB,true,"card"})
    head,head_taken,_:=gpu_try(root,"pid 1, the editor of mirai bench, head",3*GB,part_of="77")
    base_,base_taken,_:=gpu_try(root,"pid 2, the editor of mirai bench, base",3*GB,part_of="77")
    testing.expect(t,head_taken && base_taken,"what a measurement compares opens at once")
    holders:=gpu_holders(root,context.temp_allocator)
    testing.expect_value(t,len(holders),2)
    if len(holders)>0 {testing.expect_value(t,gpu_holder_measurement(holders[0].holder),"77")}
    lock_release(&head)
    lock_release(&base_)
    other,other_taken,_:=gpu_try(root,"pid 3, mirai session in a",3*GB)
    testing.expect(t,other_taken)
    _,refused,_:=gpu_try(root,"pid 1, the editor of mirai bench, head",3*GB,part_of="77")
    testing.expect(t,!refused,"beside another holder a measurement needs the room")
    lock_release(&other)
}

// The pid a holder's text names first.
@(private="file")
pid_of :: proc(what:string) -> int {
    rest:=strings.trim_prefix(what,"pid ")
    end:=strings.index(rest,",")
    pid,_:=strconv.parse_int(rest[:end] if end>=0 else rest,10)
    return pid
}
