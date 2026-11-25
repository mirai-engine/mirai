package abilities

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:testing"
import "mirai:core"
import audio "mirai:engine/audio"
import inp "mirai:engine/input"
import scene "mirai:engine/scene"
import "mirai:std/base"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"
import locomotion "plugins:locomotion/runtime"
import phys "plugins:physics/runtime"

// A hitscan rifle as data: a gun is an ability user of its own that its wielder's seat fires, with
// a magazine, a reload that refills it and a headshot row, against targets with colliders and hit
// zones in a physics world of the test.

@(private="file") RATE :: 60
@(private="file") FIRE_ACTION :: inp.Action(0)
@(private="file") SPRINT_ACTION :: inp.Action(1)
@(private="file") RELOAD_ACTION :: inp.Action(2)
@(private="file") HEALTH :: Ability_Attribute(1)
@(private="file") AMMO :: Ability_Attribute(2)
@(private="file") STUNNED :: Ability_Status(1)
@(private="file") SPRINTING :: Ability_Status(2)
@(private="file") HEAD :: scene.Tag(3)

@(private="file") FIRE :: 0
@(private="file") RELOAD :: 1
@(private="file") SPRINT :: 2
@(private="file") SHEETS :: 3
@(private="file") RAY :: 0
@(private="file") REFILL :: 1

@(private="file") ABILITY_TABLE :: base.Asset_Id{7,1}
@(private="file") KIT_TABLE :: base.Asset_Id{7,2}
@(private="file") HITBOX_TABLE :: base.Asset_Id{7,3}
@(private="file") ZONE_TABLE :: base.Asset_Id{7,4}

@(private="file")
ref :: proc(i:int) -> core.Record(Ability) {return {ABILITY_TABLE,core.Record_Id(i+1)}}

@(private)
@(test_world)
Rays_World :: struct {
    using world:Test_World,
    users:core.Table(Ability_User),
    states:core.Table(Ability_State),
    tracking:core.Table(Ability_Tracking),
    locals:core.Table(Ability_Local),
    wielded:core.Table(Ability_Wielded),
    seats:core.Table(inp.Seat),
    seat_state:inp.Seats,
    seat_runtime:inp.Seat_States,
    worlds:core.Table(core.World_Transform),
    verticals:core.Table(core.Vertical),
    ids:core.Table(core.Id),
    remotes:core.Table(core.Remote),
    tags:core.Table(scene.Tags),
    zone_sets:core.Table(anim.Hit_Zone_Set),
    zone_poses:core.Table(anim.Hit_Zone_Pose),
    characters:core.Table(phys.Character),
    locomotions:core.Table(locomotion.Locomotion_State),
    paces:core.Table(core.Own_Pace),
    helds:core.Table(Ability_Held),
    requests:Ability_Requests,
    events:Ability_Events,
    shots:Ability_Shots,
    kicks:inp.Look_Kicks,
    sounds:audio.Sound_Requests,
    births:core.Births,
    moves:locomotion.Locomotion_Requests,
    animations:anim.Animation_Requests,
    time:core.Time,
}

@(private="file")
Rifle :: struct {
    using w:Rays_World,
    physics:phys.Physics_State,
    collision:phys.Collision_Settings,
    problems:core.Problems,
    cache:Ability_Sheets,
    checks:Ability_Attributes,
    sheets:[SHEETS]Ability,
    sheet_rows:[SHEETS]core.Record_Row,
    hitboxes:[2]Ability_Hitbox,
    hitbox_rows:[2]core.Record_Row,
    kits:[2]Ability_Kit,
    kit_rows:[2]core.Record_Row,
    zones:[1]anim.Hit_Zones,
    zone_rows:[1]core.Record_Row,
    index:[4]u32,
    sheet_set,hitbox_set,kit_set,zone_set:core.Record_Set,
    player,seat:core.Entity,
    down,was:[3]bool,
    log:[dynamic]Ability_Event,
}

@(private="file")
rifle_make :: proc(t:^testing.T,f:^Rifle) -> bool {
    if !test_world_init(t,&f.w) {return false}
    if !testing.expect(t,phys.test_state_make(&f.physics)) {return false}
    f.collision=phys.COLLISION_SETTINGS_DEFAULT
    s:=&f.sheets
    // Fire: a semi-automatic shot that costs a round, kicks the look up and has a short cooldown.
    s[FIRE]={input={action=FIRE_ACTION,on=.Pressed},blocked_by=status_bit(STUNNED),duration=0.1,cooldown=0.1}
    s[FIRE].costs[0]={attribute=AMMO,amount=1}
    s[FIRE].windows[0]={from=0,to=0.05,hitbox={HITBOX_TABLE,RAY+1}}
    f.hitboxes[RAY]={shape=.Ray,ray={range=50},kick={0,0.06},effect={attribute=HEALTH,amount=-25}}
    f.hitboxes[RAY].target_effects[0]={attribute=HEALTH,amount=-100,target_tags={bits=1<<HEAD}}
    // Reload: the arms of the wielder play it; near its end a self hit refills the magazine.
    s[RELOAD]={input={action=RELOAD_ACTION,on=.Pressed},duration=1}
    base.text_set(s[RELOAD].action[:],"reload")
    s[RELOAD].windows[0]={from=0.8,to=0.9,hitbox={HITBOX_TABLE,REFILL+1}}
    f.hitboxes[REFILL]={shape=.Self,effect={attribute=AMMO,amount=30}}
    // The wielder's own sprint.
    s[SPRINT]={input={action=SPRINT_ACTION,on=.Pressed},duration=2}
    s[SPRINT].windows[0]={from=0,to=2,statuses=status_bit(SPRINTING)}
    f.kits[0].abilities[0],f.kits[0].abilities[1]=ref(FIRE),ref(RELOAD)
    f.kits[1].abilities[0]=ref(SPRINT)
    for i in 0..<4 {f.index[i]=u32(i)}
    for i in 0..<SHEETS {f.sheet_rows[i]={table=ABILITY_TABLE,row=core.Record_Id(i+1)}}
    for i in 0..<2 {f.hitbox_rows[i]={table=HITBOX_TABLE,row=core.Record_Id(i+1)};f.kit_rows[i]={table=KIT_TABLE,row=core.Record_Id(i+1)}}
    f.zone_rows[0]={table=ZONE_TABLE,row=1}
    f.sheet_set={size=size_of(Ability),rows=f.sheet_rows[:],index=f.index[:SHEETS],values=mem.slice_to_bytes(f.sheets[:])}
    f.hitbox_set={size=size_of(Ability_Hitbox),rows=f.hitbox_rows[:],index=f.index[:2],values=mem.slice_to_bytes(f.hitboxes[:])}
    f.kit_set={size=size_of(Ability_Kit),rows=f.kit_rows[:],index=f.index[:2],values=mem.slice_to_bytes(f.kits[:])}
    // A head and a chest; the legs have a collider and no zone.
    f.zones[0].zones[0]={shape=.Sphere,size={0.2,0,0},tags={bits=1<<HEAD}}
    f.zones[0].zones[1]={shape=.Box,size={0.3,0.4,0.2}}
    f.zone_set={size=size_of(anim.Hit_Zones),rows=f.zone_rows[:],index=f.index[:1],values=mem.slice_to_bytes(f.zones[:])}
    f.player,f.seat=core.create(&f.entities),core.create(&f.entities)
    player:=Ability_User{kit={KIT_TABLE,2}}
    player.attributes[0]={attribute=HEALTH,base=100,max=100}
    core.add(&f.users,f.player,player)
    core.add(&f.seats,f.seat,inp.Seat{body=f.player})
    core.add(&f.worlds,f.player,core.World_Transform{transform={rotation=1,scale=1}})
    test_world_settle(&f.w)
    inp.input_seat_index(core.ref(&f.entities),core.read(&f.seats),&f.seat_state,&f.problems)
    // Its player looks along -Z from 1.5 m up.
    inp.seat_runtime_edit(&f.seat_runtime,f.seat).view={eye={0,1.5,0},kind=.Body}
    f.time={tick=1,dt=1.0/RATE,playing=true}
    ability_room(&f.events,16*EVENT_CAPACITY,&f.problems)
    _=reserve(&f.sounds.items,audio.SOUND_REQUESTS)
    _=reserve(&f.kicks.queue.items,inp.LOOK_KICKS)
    return true
}

@(private="file")
rifle_destroy :: proc(f:^Rifle) {
    test_world_destroy(&f.w)
    phys.state_destroy(&f.physics)
    core.value_free(&f.cache,type_info_of(Ability_Sheets))
    core.entity_map_destroy(&f.checks.entries)
    delete(f.log)
}

// A gun with a magazine of rounds of 30, wielded by the player, with an Id that seeds its spread.
@(private="file")
gun_make :: proc(f:^Rifle,rounds:f32,id:base.Entity_Id) -> core.Entity {
    gun:=core.create(&f.entities)
    user:=Ability_User{kit={KIT_TABLE,1}}
    user.attributes[0]={attribute=AMMO,base=rounds,max=30}
    core.add(&f.users,gun,user)
    core.add(&f.ids,gun,core.Id{id})
    core.add(&f.worlds,gun,core.World_Transform{transform={position={0,1.2,-0.5},rotation=1,scale=1}})
    test_world_settle(&f.w)
    return gun
}

// A static box of the test's physics for entity e, with the health of an ability user.
@(private="file")
target_make :: proc(f:^Rifle,center,half:[3]f32,health:=true) -> core.Entity {
    e:=core.create(&f.entities)
    body,_:=phys.owned_body_create(&f.physics,{1,e,0},center,1)
    phys.owned_shape_create(&f.physics,&f.collision,body,{collider=phys.collider_box(half),rotation=1})
    if health {
        user:Ability_User
        user.attributes[0]={attribute=HEALTH,base=100,max=100}
        core.add(&f.users,e,user)
    }
    core.add(&f.worlds,e,core.World_Transform{transform={position=center,rotation=1,scale=1}})
    test_world_settle(&f.w)
    return e
}

@(private="file")
data :: proc(f:^Rifle) -> Ability_Data {return {{&f.sheet_set},{&f.kit_set},{&f.hitbox_set}}}

@(private="file")
rifle_step :: proc(f:^Rifle,ticks:=1) {
    for _ in 0..<ticks {
        seat:=inp.seat_runtime_edit(&f.seat_runtime,f.seat)
        seat.actions.count=3
        for a in 0..<3 {
            seat.actions.states[a]={down=f.down[a],pressed=f.down[a] && !f.was[a],released=!f.down[a] && f.was[a]}
            f.was[a]=f.down[a]
        }
        w:=Ability_World{
            time=f.time,seats=core.ref(&f.seat_state),seat_states=core.ref(&f.seat_runtime),worlds=core.read(&f.worlds),
            remotes=core.read(&f.remotes),tags=core.read(&f.tags),clock=core.CLOCK_DEFAULT,moves=&f.moves,
            animations=&f.animations,problems=&f.problems,sounds=&f.sounds,births=&f.births,ids=core.read(&f.ids),
            verticals=core.read(&f.verticals),kicks=&f.kicks,shots=&f.shots,physics=core.ref(&f.physics),
            characters=core.read(&f.characters),locomotions=core.read(&f.locomotions),paces=core.read(&f.paces),helds=core.read(&f.helds),
        }
        from:=len(f.events.queue.items)
        ability_rows({&f.users,&f.states,&f.tracking,&f.locals,&f.wielded},&f.checks,&f.problems)
        test_world_settle(&f.w)
        abilities_tick({&f.users,&f.states,&f.tracking,&f.locals,&f.wielded},data(f),&f.cache,&f.checks,&f.requests,&f.events,&w,nil)
        sw:=Shot_World{
            physics=core.ref(&f.physics),zone_sets=core.read(&f.zone_sets),zone_poses=core.read(&f.zone_poses),
            zones={&f.zone_set},tags=core.read(&f.tags),remotes=core.read(&f.remotes),sounds=&f.sounds,births=&f.births,problems=&f.problems,
        }
        abilities_shots(&f.shots,data(f),core.ref(&f.cache),&f.requests,&f.events,sw)
        for e in f.events.queue.items[from:] {append(&f.log,e)}
        core.events_age(&f.events.queue)
        test_world_settle(&f.w)
        core.time_advance(&f.time)
    }
}

// Presses an action for a tick and lets it go for another.
@(private="file")
press :: proc(f:^Rifle,action:inp.Action) {
    f.down[action]=true
    rifle_step(f)
    f.down[action]=false
    rifle_step(f)
}

@(private="file")
health :: proc(f:^Rifle,e:core.Entity) -> f32 {
    u,_:=core.get(&f.users,e)
    s,_:=core.get(&f.states,e)
    return ability_base(&u,&s,0,f.time.tick-1,f.time.dt)
}

@(private="file")
seen :: proc(f:^Rifle,kind:Ability_Event_Kind,e:core.Entity,target:=core.NONE) -> (n:int) {
    for ev in f.log {if ev.kind==kind && (e==core.NONE || ev.entity==e) && (target==core.NONE || ev.target==target) {n+=1}}
    return
}

// Each pellet of a ray reaches the nearest collider along it, once, with where and how far, and
// applies its effect; a thick ray grazes what a thin one passes by, and one that reaches nothing
// goes its whole range.
@(test)
a_ray_hits_the_nearest_collider_once_per_pellet :: proc(t:^testing.T) {
    Case :: struct {pellets:u8,radius,beside,range:f32,near,far:int}
    cases:=[]Case{
        {pellets=3,near=3},
        {pellets=1,beside=0.7,far=1},
        {pellets=1,beside=0.7,radius=0.3,near=1},
        {pellets=2,range=3},
    }
    for c in cases {
        f:=new(Rifle);defer free(f)
        if !rifle_make(t,f) {return}
        defer rifle_destroy(f)
        shooter:=gun_make(f,30,1)
        near:=target_make(f,{0,1.2,-5},{0.5,0.5,0.5})
        far:=target_make(f,{0,1.2,-10},{2,2,0.5})
        f.hitboxes[RAY].ray={range=c.range,radius=c.radius,pellets=c.pellets,from=.Body}
        f.hitboxes[RAY].center={c.beside,0,0}
        f.hitboxes[RAY].kick={}
        ability_use(&f.requests,shooter,ref(FIRE))
        rifle_step(f,3)
        pellets:=max(int(c.pellets),1)
        testing.expectf(t,seen(f,.Shot,shooter)==pellets,"%v: %d shots",c,seen(f,.Shot,shooter))
        testing.expectf(t,seen(f,.Hit,shooter,near)==c.near && seen(f,.Hit,shooter,far)==c.far,"%v: near %d, far %d",c,seen(f,.Hit,shooter,near),seen(f,.Hit,shooter,far))
        testing.expectf(t,health(f,near)==100-25*f32(c.near) && health(f,far)==100-25*f32(c.far),"%v: near %v, far %v",c,health(f,near),health(f,far))
        for ev in f.log {
            if ev.kind!=.Shot {continue}
            if c.radius>0 {continue}
            testing.expectf(t,abs(linalg.length(ev.point-ev.origin)-ev.distance)<1e-3,"%v: the point is distance along the ray",c)
            if ev.target==near {testing.expectf(t,abs(ev.point.z+4.5+c.radius)<0.05 && ev.normal.z>0.9,"%v: it stops at the face of the near box: %v %v",c,ev.point,ev.normal)}
            if ev.target==core.NONE {testing.expectf(t,abs(ev.distance-c.range)<1e-4,"%v: a miss goes its range",c)}
        }
        testing.expect_value(t,f.problems.count,0)
    }
}

// The zone a ray meets picks the effect by its tags: the head takes the headshot row, the chest the
// hitbox's effect, and a ray through the collider beside every zone goes on to what is behind it.
@(test)
a_zone_tag_picks_the_effect_of_a_hit :: proc(t:^testing.T) {
    Case :: struct {height:f32,zone:i8,damage:f32,wall:bool}
    cases:=[]Case{{1.7,0,100,false},{1.1,1,25,false},{0.3,-1,0,true}}
    for c in cases {
        f:=new(Rifle);defer free(f)
        if !rifle_make(t,f) {return}
        defer rifle_destroy(f)
        shooter:=gun_make(f,30,1)
        target:=target_make(f,{0,1,-5},{0.5,1,0.5})
        wall:=target_make(f,{0,1,-8},{3,3,0.2},health=false)
        core.add(&f.zone_sets,target,anim.Hit_Zone_Set{zones={ZONE_TABLE,1}})
        pose:anim.Hit_Zone_Pose
        pose.placed[0]={{0,1.7,-5},1}
        pose.placed[1]={{0,1.1,-5},1}
        pose.placed_bits=0b11
        core.add(&f.zone_poses,target,pose)
        test_world_settle(&f.w)
        f.hitboxes[RAY].ray={range=50,from=.Body}
        f.hitboxes[RAY].center={0,c.height-1.2,0.5}
        ability_use(&f.requests,shooter,ref(FIRE))
        rifle_step(f,3)
        hit:=false
        for ev in f.log {
            if ev.kind!=.Hit {continue}
            if c.wall {
                testing.expectf(t,ev.target==wall && ev.zone==-1,"%v: %v",c,ev)
            } else {
                testing.expectf(t,ev.target==target && ev.zone==c.zone,"%v: %v",c,ev)
            }
            hit=true
        }
        testing.expectf(t,hit,"%v: it hits",c)
        testing.expectf(t,health(f,target)==100-c.damage,"%v: health %v",c,health(f,target))
        testing.expect_value(t,f.problems.count,0)
    }
}

// The pellets of a spread take the same directions in a copy of the world and when the tick runs
// again, apart from each other, and other ones for another gun or another tick.
@(test)
the_spread_is_the_same_in_a_copy_and_a_resimulation :: proc(t:^testing.T) {
    a,b,snap:=new(Rifle),new(Rifle),new(Rifle);defer free(a);defer free(b);defer free(snap)
    if !rifle_make(t,a) || !rifle_make(t,b) || !rifle_make(t,snap) {return}
    defer rifle_destroy(a)
    defer rifle_destroy(b)
    defer rifle_destroy(snap)
    guns:[2]core.Entity
    for f in ([]^Rifle{a,b,snap}) {
        guns[0]=gun_make(f,30,0x5eed)
        guns[1]=gun_make(f,30,0x5eee)
        f.hitboxes[RAY].ray={range=20,spread=0.1,pellets=8,from=.Body}
    }
    a.time.tick,b.time.tick=40,40
    testing.expect(t,test_world_copy(&b.w,&a.w))
    testing.expect(t,test_world_copy(&snap.w,&a.w))
    directions :: proc(f:^Rifle,gun:core.Entity) -> (out:[8][3]f32) {
        n:=0
        for ev in f.log {if ev.kind==.Shot && ev.entity==gun && n<8 {out[n]=linalg.normalize(ev.point-ev.origin);n+=1}}
        return
    }
    for f in ([]^Rifle{a,b}) {
        ability_use(&f.requests,guns[0],ref(FIRE))
        ability_use(&f.requests,guns[1],ref(FIRE))
        rifle_step(f,2)
    }
    first,copied,other:=directions(a,guns[0]),directions(b,guns[0]),directions(a,guns[1])
    testing.expect_value(t,copied,first)
    testing.expect(t,first!=other,"another gun spreads otherwise")
    for d,i in first {
        testing.expectf(t,linalg.dot(d,[3]f32{0,0,-1})>math.cos(f32(0.1))-1e-4,"pellet %d stays in the cone",i)
        for e in first[:i] {testing.expect(t,e!=d,"two pellets take two directions")}
    }
    // The same tick again, after a rollback to the copy: the same rays.
    testing.expect(t,test_world_copy(&a.w,&snap.w))
    a.was={}
    a.time.tick=40
    clear(&a.log)
    ability_use(&a.requests,guns[0],ref(FIRE))
    rifle_step(a,2)
    testing.expect_value(t,directions(a,guns[0]),first)
    // Another tick: other rays.
    clear(&a.log)
    rifle_step(a,10)
    ability_use(&a.requests,guns[0],ref(FIRE))
    rifle_step(a,2)
    testing.expect(t,directions(a,guns[0])!=first)
}

// A wielded gun is fired by its wielder's seat while the wielder runs its own sprint, from the aim
// of that seat, kicking its look; an empty magazine blocks the shot until the reload, which plays on
// the wielder; the wielder's statuses gate the gun.
@(test)
a_weapon_fires_while_its_wielder_sprints_until_its_magazine_is_empty :: proc(t:^testing.T) {
    f:=new(Rifle);defer free(f)
    if !rifle_make(t,f) {return}
    defer rifle_destroy(f)
    gun:=gun_make(f,2,1)
    target:=target_make(f,{0,1.5,-6},{0.5,0.5,0.5})
    ability_wield(&f.requests,gun,f.player)
    rifle_step(f)
    held,wielded:=core.get(&f.wielded,gun)
    testing.expect(t,wielded && held.wielder==f.player)
    press(f,SPRINT_ACTION)
    state,_:=core.get(&f.states,f.player)
    testing.expect_value(t,state.ability,ref(SPRINT))
    press(f,FIRE_ACTION)
    rifle_step(f,8)
    press(f,FIRE_ACTION)
    rifle_step(f,8)
    press(f,FIRE_ACTION)
    rifle_step(f,8)
    testing.expect_value(t,seen(f,.Started,gun),2)
    testing.expect_value(t,seen(f,.Hit,gun,target),2)
    testing.expect_value(t,health(f,target),50)
    state,_=core.get(&f.states,f.player)
    testing.expect_value(t,state.ability,ref(SPRINT))
    // The shots came from the eye of the player, along its view.
    for ev in f.log {if ev.kind==.Shot {testing.expectf(t,ev.origin==[3]f32{0,1.5,0},"from the eye: %v",ev.origin)}}
    // Each kicked the look of the wielder up by its kick, spread over its window.
    pitch:f32
    for kick in f.kicks.queue.items {
        testing.expect(t,kick.body==f.player)
        pitch+=kick.pitch
    }
    testing.expectf(t,abs(pitch-2*0.06)<1e-4,"kicked by %v",pitch)
    // The reload plays on the wielder's body and refills the gun's own magazine.
    clear(&f.animations.plays.items)
    press(f,RELOAD_ACTION)
    rifle_step(f,seconds(1))
    played:=false
    for &p in f.animations.plays.items {if p.entity==f.player && base.text_get(p.action[:])=="reload" {played=true}}
    testing.expect(t,played,"the reload plays on the wielder")
    testing.expect_value(t,health(f,gun),30) // the first attribute of the gun is its magazine
    // A stunned wielder cannot fire it.
    ability_effect(&f.requests,f.player,{statuses=status_bit(STUNNED),seconds=1})
    rifle_step(f)
    press(f,FIRE_ACTION)
    testing.expect_value(t,seen(f,.Started,gun),3) // the reload; no shot
    testing.expect_value(t,f.problems.count,0)
}

@(private="file")
seconds :: proc(s:f32) -> int {return int(math.round(s*RATE))}

// The magazine is the gun's: it goes with the gun when the player swaps to another and back, and a
// rollback to a copy before a shot comes to the same rows.
@(test)
a_magazine_survives_a_swap_and_a_rollback :: proc(t:^testing.T) {
    f,snap:=new(Rifle),new(Rifle);defer free(f);defer free(snap)
    if !rifle_make(t,f) || !rifle_make(t,snap) {return}
    defer rifle_destroy(f)
    defer rifle_destroy(snap)
    first:=gun_make(f,30,1)
    second:=gun_make(f,30,2)
    ability_wield(&f.requests,first,f.player)
    rifle_step(f)
    press(f,FIRE_ACTION)
    rifle_step(f,8)
    testing.expect_value(t,health(f,first),29)
    // Swap: the first is let go, the second fires, the first keeps its rounds.
    ability_wield(&f.requests,first,core.NONE)
    ability_wield(&f.requests,second,f.player)
    rifle_step(f)
    press(f,FIRE_ACTION)
    rifle_step(f,8)
    testing.expect(t,health(f,first)==29 && health(f,second)==29,"each keeps its own magazine")
    // Back: the first goes on from 29.
    ability_wield(&f.requests,second,core.NONE)
    ability_wield(&f.requests,first,f.player)
    rifle_step(f)
    testing.expect(t,test_world_copy(&snap.w,&f.w))
    tick,was:=f.time.tick,f.was
    press(f,FIRE_ACTION)
    rifle_step(f,8)
    after:=health(f,first)
    testing.expect_value(t,after,28)
    states:=[2]Ability_State{}
    states[0],_=core.get(&f.states,first)
    // The rollback: back to the copy, the same ticks again.
    testing.expect(t,test_world_copy(&f.w,&snap.w))
    f.time.tick,f.was=tick,was
    press(f,FIRE_ACTION)
    rifle_step(f,8)
    states[1],_=core.get(&f.states,first)
    testing.expect_value(t,health(f,first),after)
    testing.expect_value(t,states[1],states[0])
    testing.expect_value(t,f.problems.count,0)
}

// Without rays in a tick the shots step does nothing and takes no memory.
@(test)
no_shot_does_no_work :: proc(t:^testing.T) {
    f:=new(Rifle);defer free(f)
    if !rifle_make(t,f) {return}
    defer rifle_destroy(f)
    saved:=context
    context.allocator,context.temp_allocator=runtime.nil_allocator(),runtime.nil_allocator()
    abilities_shots(&f.shots,data(f),core.ref(&f.cache),&f.requests,&f.events,{problems=&f.problems})
    context=saved
    testing.expect_value(t,len(f.events.queue.items),0)
    testing.expect_value(t,f.problems.count,0)
}
