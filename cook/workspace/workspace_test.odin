package workspace

import "core:fmt"
import "core:os"
import "core:testing"
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
    _,_,_,compiling:=measure_try(root,"measure")
    testing.expect(t,compiling,"a turn after the first keeps a measurement waiting")
    lock_release(&second)
    _,_,_,compiling=measure_try(root,"measure")
    testing.expect(t,compiling,"a generation of shaders keeps it waiting too")
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
    what:=fmt.tprintf("pid %d, mirai measure in %s",os.get_pid(),root)
    lock,ok:=lock_acquire(path,what)
    testing.expect(t,ok)
    holder:string
    since:time.Time
    held,holder,since=lock_holder(path,context.temp_allocator)
    testing.expect(t,held)
    testing.expect_value(t,holder,what)
    testing.expectf(t,abs(time.diff(since,time.now()))<time.Minute,"taken at %v",since)
    // Part of a measurement, a process sees none.
    if !measuring() {
        running,measurer:=measurement_running(root,context.temp_allocator)
        testing.expect(t,running)
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
