package abilities

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:testing"
import "mirai:core"
import inp "mirai:engine/input"
import "mirai:std/base"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"
import phys "plugins:physics/runtime"

// A blade with Mirai's own numbers, in the shape of a melee weapon with techniques, branches,
// hitboxes, a charged dash, charges and durability.

@(private="file") RATE :: 60
@(private="file") PRIMARY :: inp.Action(0)
@(private="file") SECONDARY :: inp.Action(1)
@(private="file") HEALTH :: Ability_Attribute(1)
@(private="file") CHARGES :: Ability_Attribute(2)
@(private="file") DURABILITY :: Ability_Attribute(3)
@(private="file") STUNNED :: Ability_Status(1)
@(private="file") CHARGING :: Ability_Status(2)
@(private="file") OPENER :: Ability_Tag(1)
@(private="file") FOLLOW :: Ability_Tag(2)
@(private="file") DASH :: Ability_Tag(3)
@(private="file") DASH_ATTACK :: Ability_Tag(4)
@(private="file") REACTION :: Ability_Tag(5)
@(private="file") SLASH :: Ability_Cue(1)
@(private="file") STRENGTH :: Ability_Attribute(4)
@(private="file") IMMUNE :: Ability_Status(3)
@(private="file") POISON :: Ability_Tag(6)

@(private="file") SLASH_1 :: 0
@(private="file") SLASH_2 :: 1
@(private="file") CHARGE :: 2
@(private="file") DASH_STRIKE :: 3
@(private="file") REACT :: 4
@(private="file") SHEETS :: 5

@(private="file") ABILITY_TABLE :: base.Asset_Id{1,1}
@(private="file") KIT_TABLE :: base.Asset_Id{2,2}

@(private="file")
ref :: proc(i:int) -> core.Record(Ability) {return {ABILITY_TABLE,core.Record_Id(i+1)}}

@(private="file")
Fixture :: struct {
    es:core.Entities,
    users:core.Table(Ability_User),
    seats:core.Table(inp.Seat),
    drivables:core.Table(inp.Drivable),
    characters:core.Table(phys.Character),
    worlds:core.Table(core.World_Transform),
    remotes:core.Table(core.Remote),
    paces:core.Table(core.Own_Pace),
    requests:Ability_Requests,
    events:Ability_Events,
    moves:phys.Locomotion_Requests,
    actions:anim.Action_Requests,
    animations:anim.Animation_Requests,
    problems:core.Problems,
    time:core.Time,
    sheets:[SHEETS]Ability,
    sheet_rows:[SHEETS]core.Record_Row,
    sheet_index:[SHEETS]u32,
    sheet_set:core.Record_Set,
    kit:[1]Ability_Kit,
    kit_rows:[1]core.Record_Row,
    kit_index:[1]u32,
    kit_set:core.Record_Set,
    player,seat,dummy:core.Entity,
    down,was:[2]bool,
    held:[2]u32,
    log:[dynamic]Ability_Event,
}

@(private="file")
blade :: proc(f:^Fixture) {
    s:=&f.sheets
    s[SLASH_1]={input={action=PRIMARY,on=.Pressed},tags=Ability_Tags(tag_bit(OPENER)),blocked_by=status_bit(STUNNED),duration=0.7}
    base.text_set(s[SLASH_1].action[:],"slash_1")
    s[SLASH_1].costs[0]={DURABILITY,2}
    s[SLASH_1].windows[0]={from=0.25,to=0.35,cue=SLASH,hitbox={shape=.Box,center={0,1,1.5},size={1,1,1},effect={attribute=HEALTH,amount=-35,knockback={0,4,8},knockback_seconds=0.1}}}
    s[SLASH_1].windows[1]={from=0.6,to=0.7,cancel_into=tag_bit(FOLLOW)|tag_bit(DASH)}
    s[SLASH_2]={input={action=PRIMARY,on=.Released},tags=tag_bit(FOLLOW),blocked_by=status_bit(STUNNED),duration=1}
    base.text_set(s[SLASH_2].action[:],"slash_2")
    s[SLASH_2].costs[0]={DURABILITY,2}
    s[SLASH_2].windows[0]={from=0.1,to=0.16,hitbox={shape=.Sphere,center={0,1,1.2},size={1.5,0,0},effect={attribute=HEALTH,amount=-35,statuses=status_bit(STUNNED),seconds=1,use=ref(REACT)}}}
    s[SLASH_2].windows[1]={from=0.9,to=1,cancel_into=tag_bit(OPENER)|tag_bit(DASH)}
    s[CHARGE]={input={action=SECONDARY,on=.Pressed},tags=tag_bit(DASH),blocked_by=status_bit(STUNNED),duration=1,hold=true,next=ref(DASH_STRIKE)}
    s[CHARGE].conditions[0]={attribute=CHARGES,at_least=1}
    s[CHARGE].windows[0]={from=0,to=1,statuses=status_bit(CHARGING),cancel_into=tag_bit(DASH_ATTACK)}
    s[DASH_STRIKE]={input={action=SECONDARY,on=.Released},tags=tag_bit(DASH_ATTACK),duration=0.4,cooldown=0.1}
    base.text_set(s[DASH_STRIKE].clip[:],"dash")
    s[DASH_STRIKE].costs[0]={CHARGES,1}
    s[DASH_STRIKE].costs[1]={DURABILITY,10}
    s[DASH_STRIKE].windows[0]={from=0,to=0.24,move={velocity={0,0,40},mix=.Override},hitbox={shape=.Box,center={0,1,1},size={0.5,1,1},effect={attribute=HEALTH,amount=-60}}}
    s[DASH_STRIKE].windows[1]={from=0.24,to=0.4,cancel_into=tag_bit(OPENER)|tag_bit(DASH)}
    s[REACT]={tags=tag_bit(REACTION),priority=10,duration=0.5}
    f.kit[0]={buffer=0.2,interrupts=tag_bit(REACTION)}
    for i in 0..<4 {f.kit[0].abilities[i]=ref(i)}
}

@(private="file")
fixture_make :: proc(f:^Fixture) {
    core.entities_init(&f.es)
    core.table_init(&f.users,"Ability_User")
    core.table_init(&f.seats,"Seat")
    core.table_init(&f.drivables,"Drivable")
    core.table_init(&f.characters,"Character")
    core.table_init(&f.worlds,"World_Transform")
    core.table_init(&f.remotes,"Remote")
    core.table_init(&f.paces,"Own_Pace")
    blade(f)
    for i in 0..<SHEETS {
        f.sheet_rows[i]={table=ABILITY_TABLE,row=core.Record_Id(i+1)}
        f.sheet_index[i]=u32(i)
    }
    f.sheet_set={size=size_of(Ability),rows=f.sheet_rows[:],index=f.sheet_index[:],values=mem.slice_to_bytes(f.sheets[:])}
    f.kit_rows[0]={table=KIT_TABLE,row=1}
    f.kit_set={size=size_of(Ability_Kit),rows=f.kit_rows[:],index=f.kit_index[:],values=mem.slice_to_bytes(f.kit[:])}
    f.player,f.seat,f.dummy=core.create(&f.es),core.create(&f.es),core.create(&f.es)
    player:=Ability_User{kit={KIT_TABLE,1}}
    player.attributes[0]={attribute=HEALTH,base=100,max=100}
    player.attributes[1]={attribute=CHARGES,base=3,max=3,regen=0.1}
    player.attributes[2]={attribute=DURABILITY,base=200,max=200}
    player.attributes[3]={attribute=STRENGTH,base=2}
    dummy:=Ability_User{}
    dummy.attributes[0]={attribute=HEALTH,base=100,max=100}
    core.add(&f.users,f.player,player)
    core.add(&f.users,f.dummy,dummy)
    core.add(&f.seats,f.seat,inp.Seat{})
    core.add(&f.drivables,f.player,inp.Drivable{seat=f.seat})
    core.add(&f.characters,f.player,phys.character_default())
    core.add(&f.characters,f.dummy,phys.character_default())
    // The player faces +X: its +Z is the world +X.
    turn:=mm.Quat(linalg.quaternion_angle_axis_f32(math.PI/2,{0,1,0}))
    core.add(&f.worlds,f.player,core.World_Transform{transform={rotation=turn,scale=1}})
    core.add(&f.worlds,f.dummy,core.World_Transform{transform={position={1.5,0,0},rotation=1,scale=1}})
    core.table_settle(&f.users,&f.es);core.table_settle(&f.seats,&f.es);core.table_settle(&f.drivables,&f.es)
    core.table_settle(&f.characters,&f.es);core.table_settle(&f.worlds,&f.es);core.table_settle(&f.remotes,&f.es)
    core.table_settle(&f.paces,&f.es)
    f.time={tick=1,dt=1.0/RATE,playing=true}
}

@(private="file")
fixture_destroy :: proc(f:^Fixture) {
    core.table_destroy(&f.users);core.table_destroy(&f.seats);core.table_destroy(&f.drivables)
    core.table_destroy(&f.characters);core.table_destroy(&f.worlds);core.table_destroy(&f.remotes)
    core.table_destroy(&f.paces)
    core.entities_destroy(&f.es)
    delete(f.requests.queue.items);delete(f.events.queue.items);delete(f.moves.queue.items)
    delete(f.actions.queue.items);delete(f.animations.match_plays.items);delete(f.log)
}

// Touches what has a World_Transform inside the hitbox: a box in the axes of the user, or a
// sphere or capsule by its radius.
@(private="file")
test_overlap :: proc(w:^Ability_World,hitbox:Ability_Hitbox,pose:mm.Transform,results:[]core.Entity) -> int {
    center:=pose.position+mm.quat_rotate(pose.rotation,hitbox.center)
    count:=0
    for row in 0..<core.count(w.worlds) {
        p:=core.at(w.worlds,row).position+{0,1,0}
        local:=mm.quat_rotate(conj(pose.rotation),p-center)
        inside:=false
        switch hitbox.shape {
        case .None:
        case .Box: inside=abs(local.x)<=hitbox.size.x && abs(local.y)<=hitbox.size.y && abs(local.z)<=hitbox.size.z
        case .Sphere, .Capsule: inside=local.x*local.x+local.y*local.y+local.z*local.z<=hitbox.size.x*hitbox.size.x
        }
        if inside && count<len(results) {results[count]=core.entity_at(w.worlds,row);count+=1}
    }
    return count
}

@(private="file")
world_of :: proc(f:^Fixture) -> Ability_World {
    return {time=f.time,seats=core.read(&f.seats),drivables=core.read(&f.drivables),characters=core.read(&f.characters),worlds=core.read(&f.worlds),remotes=core.read(&f.remotes),paces=core.read(&f.paces),clock=core.CLOCK_DEFAULT,moves=&f.moves,actions=&f.actions,animations=&f.animations,problems=&f.problems}
}

@(private="file")
step :: proc(f:^Fixture,ticks:=1) {
    for _ in 0..<ticks {
        seat:=core.get(&f.seats,f.seat)
        seat.actions.count=2
        for a in 0..<2 {
            st:=&seat.actions.states[a]
            st^={down=f.down[a],pressed=f.down[a] && !f.was[a],released=!f.down[a] && f.was[a]}
            if f.down[a] {f.held[a]+=1;st.held_ticks=f.held[a]} else {if f.was[a] {st.released_held=f.held[a]};f.held[a]=0}
            f.was[a]=f.down[a]
        }
        w:=world_of(f)
        abilities_tick(&f.users,{&f.sheet_set},{&f.kit_set},&f.requests,&f.events,&w,test_overlap)
        for e in f.events.queue.items {append(&f.log,e)}
        core.time_advance(&f.time)
    }
}

@(private="file")
user :: proc(f:^Fixture,e:core.Entity) -> Ability_User {
    u,_:=core.get(core.read(&f.users),e)
    return u
}

@(private="file")
logged :: proc(f:^Fixture,kind:Ability_Event_Kind,e:core.Entity,ability:int) -> int {
    n:=0
    for ev in f.log {if ev.kind==kind && ev.entity==e && (ability<0 || ev.ability==ref(ability)) {n+=1}}
    return n
}

@(private="file")
seconds :: proc(s:f32) -> int {return int(math.round(s*RATE))}

// Pressing starts the opener, whose hitbox hits the dummy once with damage and knockback; letting
// go inside its cancel window starts the follow-up, which interrupts it and stuns the dummy, whose
// kit-less hit reaction starts from the effect. Durability pays for each technique.
@(test)
a_blade_combo_hits_once_per_window_and_branches_only_inside_cancel_windows :: proc(t:^testing.T) {
    f:=new(Fixture);defer free(f)
    fixture_make(f);defer fixture_destroy(f)
    f.down[0]=true
    step(f)
    testing.expect_value(t,user(f,f.player).ability,ref(SLASH_1))
    testing.expect_value(t,logged(f,.Started,f.player,SLASH_1),1)
    testing.expect(t,len(f.actions.queue.items)==1 && base.text_get(f.actions.queue.items[0].action[:])=="slash_1")
    // Letting go too early leaves nothing: the buffer is shorter than the wait to the window.
    step(f,seconds(0.2))
    f.down[0]=false
    step(f,seconds(0.25))
    testing.expect_value(t,user(f,f.dummy).attributes[0].base,65)
    testing.expect_value(t,logged(f,.Hit,f.player,SLASH_1),1)
    knockback:=false
    for m in f.moves.queue.items {if m.entity==f.dummy && m.move.id==KNOCKBACK_ID && m.move.mix==.Override && m.move.velocity.x>7 {knockback=true}}
    testing.expect(t,knockback)
    testing.expect_value(t,logged(f,.Started,f.player,SLASH_2),0)
    testing.expect_value(t,user(f,f.player).ability,ref(SLASH_1))
    // Pressed again at 28 ticks, let go at 37, inside the window [36, 42): the release branches.
    f.down[0]=true
    step(f,9)
    f.down[0]=false
    step(f)
    testing.expect_value(t,user(f,f.player).ability,ref(SLASH_2))
    testing.expect_value(t,logged(f,.Interrupted,f.player,SLASH_1),1)
    // The opener's action is cancelled before the follow-up fires its own: on another layer it would
    // otherwise play on.
    asked:=f.actions.queue.items[:]
    testing.expectf(t,len(asked)==3 && asked[1].kind==.Cancel && base.text_get(asked[1].action[:])=="slash_1" && asked[2].kind==.Fire && base.text_get(asked[2].action[:])=="slash_2","%v",asked)
    step(f,seconds(0.2))
    testing.expect_value(t,user(f,f.dummy).attributes[0].base,30)
    testing.expect(t,ability_has(user(f,f.dummy),STUNNED))
    testing.expect_value(t,user(f,f.dummy).ability,ref(REACT))
    testing.expect_value(t,user(f,f.player).attributes[2].base,196)
    // The windows of the interrupted opener closed: every begin has its end.
    testing.expect_value(t,logged(f,.Window_Begin,f.player,SLASH_1),logged(f,.Window_End,f.player,SLASH_1))
    // The follow-up runs out: completed, idle, no status of its own left.
    step(f,seconds(1))
    testing.expect_value(t,logged(f,.Completed,f.player,SLASH_2),1)
    testing.expect_value(t,user(f,f.player).ability,core.Record(Ability){})
    testing.expect_value(t,user(f,f.player).statuses,0)
    testing.expect_value(t,f.problems.count,0)
}

// Holding charges; letting go dashes with a layered move along where the user faces and costs a
// charge; holding the whole charge dashes by itself (next). Without charges the charge does not
// start, and the charges come back over time.
@(test)
a_charged_dash_spends_charges_and_is_blocked_without_them :: proc(t:^testing.T) {
    f:=new(Fixture);defer free(f)
    fixture_make(f);defer fixture_destroy(f)
    f.down[1]=true
    step(f,seconds(0.3))
    testing.expect_value(t,user(f,f.player).ability,ref(CHARGE))
    testing.expect(t,ability_has(user(f,f.player),CHARGING))
    f.down[1]=false
    step(f)
    testing.expect_value(t,user(f,f.player).ability,ref(DASH_STRIKE))
    testing.expect_value(t,logged(f,.Completed,f.player,CHARGE),1)
    testing.expect(t,!ability_has(user(f,f.player),CHARGING))
    dash:=false
    for m in f.moves.queue.items {if m.entity==f.player && m.kind==.Add_Move && m.move.id==MOVE_ID && m.move.velocity.x>39 && m.move.ticks==u32(seconds(0.24)) {dash=true}}
    testing.expect(t,dash)
    testing.expect(t,len(f.animations.match_plays.items)==1)
    charges,_:=ability_value(user(f,f.player),CHARGES)
    testing.expect(t,charges>1.9 && charges<2.1)
    // Holding through the whole charge dashes when it ends.
    step(f,seconds(0.5))
    f.down[1]=true
    step(f,seconds(1)+1)
    testing.expect_value(t,logged(f,.Started,f.player,DASH_STRIKE),2)
    f.down[1]=false
    step(f,seconds(0.5))
    f.down[1]=true
    step(f,2)
    f.down[1]=false
    step(f,seconds(0.5))
    testing.expect_value(t,logged(f,.Started,f.player,DASH_STRIKE),3)
    // No charge left: the charge is blocked by its condition.
    f.down[1]=true
    step(f,2)
    testing.expect_value(t,user(f,f.player).ability,core.Record(Ability){})
    u:=user(f,f.player)
    kit:=kit_sheet({&f.kit_set},u.kit)
    w:=world_of(f)
    testing.expect_value(t,start_block(&w,f.time.tick,f.time.dt,f.player,&u,kit,nil,{},&f.sheets[CHARGE],ref(CHARGE)),Ability_Block.Condition)
    f.down[1]=false
    step(f,seconds(10))
    f.down[1]=true
    step(f)
    testing.expect_value(t,user(f,f.player).ability,ref(CHARGE))
    testing.expect_value(t,f.problems.count,0)
}

// Copying the state halfway and running both copies with the same input gives the same states
// and events: the sheet is outside the world and the rest is plain rows. Cancelling midway
// leaves no status, window or move behind.
@(test)
a_copy_of_the_state_halfway_runs_the_same_future_and_a_cancel_leaves_nothing :: proc(t:^testing.T) {
    a,b:=new(Fixture),new(Fixture);defer free(a);defer free(b)
    fixture_make(a);defer fixture_destroy(a)
    fixture_make(b);defer fixture_destroy(b)
    a.down[1]=true
    step(a,10)
    // b takes a's world as a rollback would: tables, queues, clock and input edges.
    testing.expect(t,core.table_copy(&b.users,&a.users))
    testing.expect(t,core.table_copy(&b.seats,&a.seats))
    clear(&b.requests.queue.items);append(&b.requests.queue.items,..a.requests.queue.items[:])
    b.time,b.down,b.was,b.held=a.time,a.down,a.was,a.held
    clear(&a.log);clear(&b.log)
    for f in ([]^Fixture{a,b}) {
        f.down[1]=false
        step(f,3)
        f.down[0]=true
        step(f,seconds(0.4))
    }
    testing.expect_value(t,len(a.log),len(b.log))
    for e,i in a.log {if i<len(b.log) {testing.expect_value(t,b.log[i],e)}}
    ua,ub:=user(a,a.player),user(b,b.player)
    testing.expect(t,mem.compare_ptrs(&ua,&ub,size_of(Ability_User))==0)
    // A cancel inside the dash's move window closes it and removes its move.
    a.down={false,false}
    step(a,seconds(1))
    clear(&a.moves.queue.items)
    a.down[1]=true
    step(a,seconds(1)+3)
    testing.expect_value(t,user(a,a.player).ability,ref(DASH_STRIKE))
    ability_cancel(&a.requests,a.player)
    step(a)
    u:=user(a,a.player)
    testing.expect(t,u.ability=={} && u.statuses==0 && u.hit_count==0)
    removed:=false
    for m in a.moves.queue.items {if m.kind==.Remove_Moves && m.move.id==MOVE_ID {removed=true}}
    testing.expect(t,removed)
    testing.expect_value(t,logged(a,.Window_Begin,a.player,DASH_STRIKE),logged(a,.Window_End,a.player,DASH_STRIKE))
    // A replica derives its statuses but neither starts nor hits.
    core.add(&a.remotes,a.dummy,core.Remote{});core.table_settle(&a.remotes,&a.es)
    ability_use(&a.requests,a.dummy,ref(REACT))
    step(a,2)
    testing.expect_value(t,user(a,a.dummy).ability,core.Record(Ability){})
}

// Sheets, kits, attributes and requests that are not valid are problems that say what to fix,
// and nothing starts from them; nothing crashes.
@(test)
invalid_sheets_and_requests_are_problems_and_never_run :: proc(t:^testing.T) {
    nan:=math.nan_f32()
    out:[512]u8
    Case :: struct {edit:proc(a:^Ability,nan:f32),wanted:string}
    cases:=[]Case{
        {proc(a:^Ability,nan:f32) {a.duration=nan},"duration"},
        {proc(a:^Ability,nan:f32) {a.duration=0},"duration"},
        {proc(a:^Ability,nan:f32) {a.input.hold=-1},"input.hold"},
        {proc(a:^Ability,nan:f32) {a.input.on=Ability_Trigger(200)},"input.on"},
        {proc(a:^Ability,nan:f32) {a.windows[0].to=a.duration+1},"after the duration"},
        {proc(a:^Ability,nan:f32) {a.windows[0].from=a.windows[0].to},"below to"},
        {proc(a:^Ability,nan:f32) {a.windows[0].hitbox.size.y=nan},"hitbox.size"},
        {proc(a:^Ability,nan:f32) {a.windows[0].hitbox.shape=Hitbox_Shape(9)},"hitbox.shape"},
        {proc(a:^Ability,nan:f32) {a.windows[0].hitbox.effect.knockback.x=nan},"knockback"},
        {proc(a:^Ability,nan:f32) {a.windows[0].hitbox.effect.knockback_seconds=0},"knockback for 0 seconds"},
        {proc(a:^Ability,nan:f32) {a.windows[1].modify={attribute=HEALTH,more=-2}},"more"},
        {proc(a:^Ability,nan:f32) {a.windows[1].move.velocity.z=nan},"move.velocity"},
        {proc(a:^Ability,nan:f32) {a.windows[5].cue=SLASH},"to is 0"},
        {proc(a:^Ability,nan:f32) {a.costs[1]={ATTRIBUTE_NONE,4}},"costs[1]"},
        {proc(a:^Ability,nan:f32) {a.conditions[0]={HEALTH,10,5}},"conditions[0]"},
        {proc(a:^Ability,nan:f32) {base.text_set(a.clip[:],"also")},"both"},
        {proc(a:^Ability,nan:f32) {a.windows[0].hitbox.effect.period=nan},"period"},
        {proc(a:^Ability,nan:f32) {a.windows[0].hitbox.effect.max_stacks=3},"stacks but has no tags"},
        {proc(a:^Ability,nan:f32) {a.windows[0].hitbox.effect.cue=SLASH},"lasts 0 seconds"},
        {proc(a:^Ability,nan:f32) {a.input.after=-0.1},"input.after"},
        {proc(a:^Ability,nan:f32) {a.input.wait=Ability_Wait(7)},"input.wait"},
        {proc(a:^Ability,nan:f32) {a.windows[1].clock=Ability_Clock(5)},"clock"},
    }
    for c in cases {
        f:=new(Fixture)
        fixture_make(f)
        c.edit(&f.sheets[SLASH_1],nan)
        text:=ability_check(&f.sheets[SLASH_1],out[:])
        testing.expectf(t,text!="" && contains(text,c.wanted),"%q does not say %q",text,c.wanted)
        f.down[0]=true
        step(f,2)
        testing.expect_value(t,user(f,f.player).ability,core.Record(Ability){})
        testing.expect(t,core.problem_find(&f.problems,f.player,"abilities.invalid")!=nil)
        fixture_destroy(f)
        free(f)
    }
    // A sheet no input fires is checked too, though it never runs by input.
    {
        quiet:=Ability{duration=1,input={on=.None,wait=.Running}}
        text:=ability_check(&quiet,out[:])
        testing.expectf(t,contains(text,"no input fires"),"%q",text)
    }
    f:=new(Fixture);defer free(f)
    fixture_make(f);defer fixture_destroy(f)
    // A kit row that is missing, a buffer that is not a number, attributes that are not numbers.
    f.kit[0].buffer=nan
    step(f)
    testing.expect(t,core.problem_find(&f.problems,f.player,"abilities.kit")!=nil)
    f.kit[0].buffer=0.2
    p:=core.get(&f.users,f.player)
    p.kit={KIT_TABLE,99}
    step(f)
    testing.expect(t,core.problem_find(&f.problems,f.player,"records.missing")!=nil)
    p=core.get(&f.users,f.player)
    p.attributes[1].regen=math.inf_f32(1)
    step(f)
    testing.expect(t,core.problem_find(&f.problems,f.player,"abilities.attributes")!=nil)
    // Requests that name nothing, stale entities, rows of no table and a full queue.
    testing.expect(t,!ability_use(&f.requests,core.NONE,ref(SLASH_1)))
    testing.expect(t,!ability_use(&f.requests,f.dummy,{}))
    testing.expect(t,ability_use(&f.requests,f.seat,ref(SLASH_1)))
    testing.expect(t,ability_use(&f.requests,f.dummy,{ABILITY_TABLE,77}))
    testing.expect(t,ability_effect(&f.requests,f.dummy,{attribute=HEALTH,amount=nan}))
    testing.expect(t,ability_effect(&f.requests,core.Entity(0xdead_0000_0042),{attribute=HEALTH,amount=-1}))
    step(f,2)
    testing.expect(t,core.problem_find(&f.problems,f.dummy,"abilities.effect")!=nil)
    testing.expect(t,core.problem_find(&f.problems,f.dummy,"records.missing")!=nil)
    testing.expect_value(t,user(f,f.dummy).attributes[0].base,100)
    for _ in 0..<REQUEST_CAPACITY {ability_cancel(&f.requests,f.dummy)}
    testing.expect(t,!ability_cancel(&f.requests,f.dummy))
    step(f)
    // A clock that does not run, or runs by no number, does nothing.
    f.time.dt=nan
    step(f)
    f.time.dt=0
    step(f)
}

// After the first ticks reserve the queues, a tick of a running combo allocates nothing.
@(test)
a_stable_tick_allocates_nothing :: proc(t:^testing.T) {
    f:=new(Fixture);defer free(f)
    fixture_make(f);defer fixture_destroy(f)
    reserve(&f.log,4096)
    reserve(&f.moves.queue.items,64);reserve(&f.actions.queue.items,64);reserve(&f.animations.match_plays.items,64)
    reserve(&f.requests.queue.items,REQUEST_CAPACITY)
    f.down[0]=true
    step(f,2)
    calls:=0
    {
    context.allocator=runtime.Allocator{procedure=proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
        if mode==.Query_Features || mode==.Query_Info {return nil,.Mode_Not_Implemented}
        (^int)(data)^+=1
        return nil,.Out_Of_Memory
    },data=&calls}
    f.down[0]=false
    step(f,seconds(0.3))
    }
    testing.expect_value(t,calls,0)
    testing.expect_value(t,logged(f,.Hit,f.player,SLASH_1),1)
}

// Has u an entry of the ability i in its buffer?
@(private="file")
buffered :: proc(u:Ability_User,i:int) -> bool {
    for b in u.buffer {if b.ability==ref(i) {return true}}
    return false
}

// Mantis-style input rules as data. The follow-up's release counts only from after seconds into
// the opener, so the release of the opener's own press does not fire it; a release past that
// waits for the opener's cancel window however far it is (wait running), while the kit's buffer
// alone would have let it go; and a waiting input leaves with the run it waited for.
@(test)
an_input_counts_from_its_delay_and_waits_for_the_branch_of_the_running_ability :: proc(t:^testing.T) {
    f:=new(Fixture);defer free(f)
    fixture_make(f);defer fixture_destroy(f)
    f.sheets[SLASH_2].input.after=0.3
    f.sheets[SLASH_2].input.wait=.Running
    started:=f.time.tick
    f.down[0]=true
    step(f)
    testing.expect_value(t,user(f,f.player).ability,ref(SLASH_1))
    // Let go at 0.1 s: before after, so not even buffered.
    step(f,seconds(0.1)-1)
    f.down[0]=false
    step(f)
    testing.expect(t,!buffered(user(f,f.player),SLASH_2))
    // Pressed again and let go at 0.32 s: buffered, and kept past the kit's 0.2 s.
    step(f,seconds(0.3)-seconds(0.1)-1)
    f.down[0]=true
    step(f,seconds(0.02))
    f.down[0]=false
    step(f)
    testing.expect(t,buffered(user(f,f.player),SLASH_2))
    step(f,seconds(0.25))
    testing.expect(t,buffered(user(f,f.player),SLASH_2))
    testing.expect_value(t,user(f,f.player).ability,ref(SLASH_1))
    // It starts on the first tick of the opener's cancel window [0.6, 0.7).
    for user(f,f.player).ability==ref(SLASH_1) && f.time.tick<started+u64(seconds(1)) {step(f)}
    testing.expect_value(t,user(f,f.player).ability,ref(SLASH_2))
    testing.expect_value(t,user(f,f.player).start,started+u64(seconds(0.6)))
    testing.expect_value(t,logged(f,.Interrupted,f.player,SLASH_1),1)
    // Again, but the opener is cancelled before its window: the waiting release leaves with it.
    step(f,seconds(1.5))
    f.down[0]=true
    step(f)
    testing.expect_value(t,user(f,f.player).ability,ref(SLASH_1))
    step(f,seconds(0.32))
    f.down[0]=false
    step(f)
    testing.expect(t,buffered(user(f,f.player),SLASH_2))
    step(f,seconds(0.25))
    ability_cancel(&f.requests,f.player)
    step(f)
    testing.expect(t,!buffered(user(f,f.player),SLASH_2))
    step(f,seconds(0.5))
    testing.expect_value(t,logged(f,.Started,f.player,SLASH_2),1)
    testing.expect_value(t,f.problems.count,0)
}

// A window on the Own clock counts the user's own time (core.Own_Pace), as the clip it follows
// plays: at half pace the charge's branch at 0.5 s opens after 1 s of the world, while its
// duration keeps the world's clock. The dash let go early waits for that branch.
@(test)
a_window_on_the_own_clock_follows_the_pace_of_the_user :: proc(t:^testing.T) {
    f:=new(Fixture);defer free(f)
    fixture_make(f);defer fixture_destroy(f)
    c:=&f.sheets[CHARGE]
    c.hold,c.duration=false,2
    c.windows[0]={from=0,to=2,statuses=status_bit(CHARGING)}
    c.windows[1]={from=0.5,to=10,clock=.Own,cancel_into=tag_bit(DASH_ATTACK),cue=SLASH}
    d:=&f.sheets[DASH_STRIKE]
    d.requires=status_bit(CHARGING)
    d.input.wait=.Running
    core.add(&f.paces,f.player,core.Own_Pace{rate=0.5});core.table_settle(&f.paces,&f.es)
    started:=f.time.tick
    f.down[1]=true
    step(f)
    testing.expect_value(t,user(f,f.player).ability,ref(CHARGE))
    step(f,seconds(0.1))
    f.down[1]=false
    step(f)
    testing.expect(t,buffered(user(f,f.player),DASH_STRIKE))
    // At 0.6 s of the world the charge has lived 0.3 s of its own: no branch yet.
    step(f,seconds(0.6)-seconds(0.1)-2)
    u:=user(f,f.player)
    testing.expect_value(t,u.ability,ref(CHARGE))
    testing.expect(t,abs(u.own-0.5*f32(f.time.tick-1-u.start))<1e-3)
    // The branch opens at 0.5 s of its own: 60 ticks of the world at half pace.
    for user(f,f.player).ability==ref(CHARGE) && f.time.tick<started+u64(seconds(3)) {step(f)}
    testing.expect_value(t,user(f,f.player).ability,ref(DASH_STRIKE))
    testing.expect_value(t,user(f,f.player).start,started+u64(seconds(1)))
    begins:=0
    for e in f.log {if e.kind==.Window_Begin && e.ability==ref(CHARGE) && e.window==1 {begins+=1}}
    testing.expect_value(t,begins,1)
    // Its windows closed with it, the open one on its own clock too.
    testing.expect_value(t,logged(f,.Window_Begin,f.player,CHARGE),logged(f,.Window_End,f.player,CHARGE))
    // Pressed and let go while stunned (the charge cannot start): the dash requires the charge's
    // status, so nothing starts.
    step(f,seconds(1))
    ability_effect(&f.requests,f.player,{statuses=status_bit(STUNNED),seconds=0.5})
    step(f)
    f.down[1]=true
    step(f,2)
    f.down[1]=false
    step(f,seconds(0.2))
    testing.expect_value(t,user(f,f.player).ability,core.Record(Ability){})
    testing.expect_value(t,logged(f,.Started,f.player,DASH_STRIKE),1)
    step(f,seconds(0.5))
    // Held through the whole charge: its next dashes at its end, in the charging status the
    // charge had on its last tick.
    started=f.time.tick
    f.down[1]=true
    step(f)
    for user(f,f.player).ability==ref(CHARGE) && f.time.tick<started+u64(seconds(3)) {step(f)}
    testing.expect_value(t,user(f,f.player).ability,ref(DASH_STRIKE))
    testing.expect_value(t,user(f,f.player).start,started+u64(seconds(2)))
    f.down[1]=false
    step(f,seconds(1))
    // A request waits as its input would (wait running): asked for early, it starts at the branch.
    // Secondary stays held, so only the request asks for the dash.
    started=f.time.tick
    f.down[1]=true
    step(f,seconds(0.1))
    ability_use(&f.requests,f.player,ref(DASH_STRIKE))
    for user(f,f.player).ability==ref(CHARGE) && f.time.tick<started+u64(seconds(3)) {step(f)}
    testing.expect_value(t,user(f,f.player).ability,ref(DASH_STRIKE))
    testing.expect_value(t,user(f,f.player).start,started+u64(seconds(1)))
    testing.expect_value(t,f.problems.count,0)
}

@(private="file")
contains :: proc(s,sub:string) -> bool {
    for i in 0..=len(s)-len(sub) {if s[i:i+len(sub)]==sub {return true}}
    return false
}

// A lasting effect takes its amount every period and counts once per stack while applied again
// with the same tags; a cleanse by tag ends it, a target in a status that blocks an effect takes
// nothing from it, and an amount scaled by an attribute of the source takes its value.
@(test)
lasting_effects_stack_by_tags_end_by_cleanse_and_skip_blocked_targets :: proc(t:^testing.T) {
    f:=new(Fixture);defer free(f)
    fixture_make(f);defer fixture_destroy(f)
    health :: proc(f:^Fixture) -> f32 {return user(f,f.dummy).attributes[0].base}
    poison:=Ability_Effect{attribute=HEALTH,amount=-1,period=0.5,seconds=2,tags=tag_bit(POISON),max_stacks=3,cue=SLASH}
    testing.expect(t,ability_effect(&f.requests,f.dummy,poison,f.player))
    step(f)
    testing.expect_value(t,logged(f,.Effect_Begin,f.dummy,-1),1)
    step(f,29)
    testing.expect_value(t,health(f),100)
    step(f)
    testing.expect_value(t,health(f),99)
    ability_effect(&f.requests,f.dummy,poison,f.player)
    step(f,30)
    testing.expect_value(t,health(f),97)
    testing.expect_value(t,logged(f,.Effect_Begin,f.dummy,-1),1)
    ability_effect(&f.requests,f.dummy,{remove=tag_bit(POISON)})
    step(f,61)
    testing.expect_value(t,health(f),97)
    testing.expect_value(t,logged(f,.Effect_End,f.dummy,-1),1)
    ability_effect(&f.requests,f.dummy,{statuses=status_bit(IMMUNE),seconds=1})
    step(f,2)
    strike:=Ability_Effect{attribute=HEALTH,amount=-10,blocked_by=status_bit(IMMUNE)}
    ability_effect(&f.requests,f.dummy,strike)
    step(f)
    testing.expect_value(t,health(f),97)
    step(f,seconds(1))
    ability_effect(&f.requests,f.dummy,strike)
    step(f)
    testing.expect_value(t,health(f),87)
    ability_effect(&f.requests,f.dummy,{attribute=HEALTH,amount=-5,scale_by=STRENGTH},f.player)
    step(f)
    testing.expect_value(t,health(f),77)
    testing.expect_value(t,f.problems.count,0)
    ability_effect(&f.requests,f.dummy,{attribute=HEALTH,amount=-5,scale_by=STRENGTH})
    step(f)
    testing.expect(t,core.problem_find(&f.problems,f.dummy,"abilities.effect")!=nil)
}
