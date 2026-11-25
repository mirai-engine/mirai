package abilities

import "mirai:core"
import audio "mirai:engine/audio"
import inp "mirai:engine/input"
import scene "mirai:engine/scene"
import "mirai:std/base"
import locomotion "plugins:locomotion/runtime"

// Abilities: what a character does on top of its locomotion (an attack, a dash, a block, a hit
// reaction) as rows of game data. An Ability is a sheet: the input that starts it, what it
// requires and costs, how long it lasts and a timeline of windows relative to its start (a
// hitbox, a dash, cancel windows that say which abilities may follow, statuses it grants, cues
// for presentation). There is no graph of transitions: an ability starts over the running one
// only while an open cancel window accepts one of its tags (or its kit lets those tags interrupt
// anything), and among the valid candidates the one of highest priority wins.
//
ABILITY_WINDOWS :: 16
ABILITY_CONDITIONS :: 4
ABILITY_COSTS :: 4
ABILITY_NAME :: 64
ABILITY_SPAN_NAME :: 32
KIT_ABILITIES :: 32
ATTRIBUTE_ENTRIES :: 8
USER_HITS :: 16
USER_BUFFER :: 4
USER_COOLDOWNS :: 8
USER_TIMERS :: 8
EVENT_CAPACITY :: 1024
HITBOX_RESULTS :: 32
// A hitbox open on the tick before is tested at up to this many poses between that tick and this
// one, spaced at most its smallest half extent (not less than HITBOX_STEP_MIN m) apart.
HITBOX_STEPS :: 6
HITBOX_STEP_MIN :: 0.05
// The layered moves of the windows of an ability use these ids, plus the window index.
MOVE_ID :: u32(0x4142_0000)
// The knockback of an effect, as a layered move of its target.
KNOCKBACK_ID :: u32(0x4142_ffff)
// The pellets the rays of a tick can cast, the range of a ray that gives none and the colliders
// without placed zones a ray passes through before it gives up.
SHOTS :: 256
RAY_RANGE :: f32(1000)
RAY_PELLETS :: 16
RAY_PASSES :: 4

// A state an entity is in (stunned, invulnerable, armed): the game declares its values
// (STATUS_STUNNED :: abilities.Ability_Status(1)) and the data names them.
@(names="STATUS_")
Ability_Status :: distinct u8

@(name_bits="Ability_Status")
Ability_Statuses :: distinct u64

// What kind of ability it is for the cancel windows (light, heavy, dash, reaction): the game
// declares its values.
@(names="TAG_")
Ability_Tag :: distinct u8

@(name_bits="Ability_Tag")
Ability_Tags :: distinct u64

// A quantity of an entity (health, charges, durability): the game declares its values; 0 is
// none.
@(names="ATTRIBUTE_")
Ability_Attribute :: distinct u8
@(name="none") ATTRIBUTE_NONE :: Ability_Attribute(0)

// What a window tells presentation (a slash trail, a sound, a camera shake): the game declares
// its values and plays them from Ability_Events; 0 is none.
@(names="CUE_")
Ability_Cue :: distinct u16
@(name="none") CUE_NONE :: Ability_Cue(0)

// Locomotion modes of the Character of a user: those an ability may start in, pauses its costs in
// or ends in.
@(name_bits="locomotion.Locomotion_Mode")
Ability_Modes :: distinct u32

Ability_Trigger :: enum u8 {
    None,     // only Ability_Requests, a kit's next or an effect start it
    Pressed,  // the tick the action goes down
    Released, // the tick it is let go, after being held at least hold seconds
    Held,     // the tick it has been held hold seconds
    Down,     // every tick it is held
}

// How long an input that fired waits for a moment its ability can start.
Ability_Wait :: enum u8 {
    Buffer,  // the buffer seconds of the kit
    Running, // also while the ability that ran when it fired goes on: it starts at the cancel window of that one, however far (a combo's next technique queued before the branch)
}

Ability_Input :: struct {
    action:inp.Action, // of the seat that drives the entity
    on:Ability_Trigger,
    hold:f32 `mirai:"min=0,unit=s"`,
    after:f32 `mirai:"min=0,unit=s"`, // while another ability runs, the input counts only from this many seconds into it; earlier it is ignored, so the release of the press that started that one does not fire this one
    wait:Ability_Wait,
}

// What a condition measures. What the game decides about the world (a ledge ahead, a target in
// sight) is not a condition: a step of the game asks its query and uses the ability, or gives the
// user a status the ability requires.
Ability_Condition_Kind :: enum u8 {
    Attribute, // the current value of attribute
    Speed,     // m/s of the user's Character across its up, relative to the ground it stands on
}

// It holds while what kind measures is within at_least..at_most.
Ability_Condition :: struct {
    attribute:Ability_Attribute,
    at_least:f32,
    at_most:f32, // 0: no limit
    kind:Ability_Condition_Kind,
}

Ability_Cost :: struct {
    attribute:Ability_Attribute,
    amount:f32 `mirai:"min=0"`, // taken from its base when the ability starts; it cannot start with less
    per_second:f32 `mirai:"min=0,unit=1/s"`, // taken from its base every second it runs after its start, but in the pause_modes of the ability; it completes when the attribute cannot pay the tick
}

// value = (base + add) * (1 + more), summed over the modifiers in force.
// With ramp_in / ramp_out, the modifier fades from 0 to full over ramp_in seconds after its window
// or timer starts, and back to 0 over ramp_out seconds before it ends.
Ability_Modifier :: struct {
    attribute:Ability_Attribute,
    add:f32,
    more:f32, // 0.5: half as much more; -0.5: half
    ramp_in:f32 `mirai:"min=0,unit=s"`,  // seconds from start to reach full effect; 0: at once
    ramp_out:f32 `mirai:"min=0,unit=s"`, // seconds before end to fade to zero; 0: instant
}

// What an ability does to what it hits, or what a game asks for through Ability_Requests. With
// seconds it lasts as a timer of the target: its statuses and modifier, and its amount every
// period. Applied again while its timer with the same tags lasts, it stacks up to max_stacks and
// lasts seconds from then.
Ability_Effect :: struct {
    attribute:Ability_Attribute,
    amount:f32, // added to the base of the attribute of the target: -35 health; with period, every period
    scale_by:Ability_Attribute, // amount times the current value of this attribute of the source: its strength
    period:f32 `mirai:"min=0,unit=s"`, // 0: amount once, at once
    statuses:Ability_Statuses,  // the target is in them for seconds
    modify:Ability_Modifier,    // of the target for seconds
    seconds:f32 `mirai:"min=0,unit=s"`,
    tags:Ability_Tags,          // what its timer is (poison, burn): what stacks it and what removes it
    max_stacks:u8,              // 0 and 1: applying again only lasts seconds from then
    remove:Ability_Tags,        // the timers of the target with one of these tags end: a cleanse
    blocked_by:Ability_Statuses, // a target in any of them takes nothing: immune, unstoppable
    target_tags:scene.Tags,     // when non-zero, applies only to targets whose scene.Tags share at least one bit
    cue:Ability_Cue,            // carried by the events of the start and end of its timer
    on_hit:audio.Cue,           // played at the target when a hitbox hits with this effect
    knockback:[3]f32 `mirai:"unit=m/s"`, // in the axes of the source: a velocity its Character takes
    knockback_seconds:f32 `mirai:"min=0,unit=s"`,
    use:core.Record(Ability), // the target starts it: a hit reaction
}

Hitbox_Shape :: enum u8 {
    None,
    Box,
    Sphere,
    Capsule,
    Ray,  // cast once when its window opens, as its ray says: a shot
    Self, // touches its own user once when its window opens: a reload that refills a magazine
}

// What a hitbox does to the look of the body that aims, the turn of its kick (yaw left, pitch up)
// over the window that holds it: evenly by tick for a window on the world clock, at once for one
// on a span or the own clock. A recoil; a later window with the opposite kick brings it back.

Ability_Ray_From :: enum u8 {
    Aim,  // the view of the seat that drives the user or its wielder (input.aim); without a seat (an AI), as Body
    Body, // the user at the center of the hitbox, along its -Z
}

// What a Ray hitbox casts: through the physics query, then the hit zones of what it reaches.
Ability_Ray :: struct {
    range:f32 `mirai:"min=0,unit=m"`, // 0: RAY_RANGE
    radius:f32 `mirai:"min=0,max=1,unit=m"`, // 0: a thin ray; else a sphere of this radius swept along it
    spread:f32 `mirai:"min=0,max=1.5,unit=rad"`, // half angle of the cone around the aim each pellet takes its direction in, the same on every end and in every tick run again
    pellets:u8 `mirai:"max=16"`, // rays it casts at once; 0 and 1: one
    from:Ability_Ray_From,
}

Ability_Move :: struct {
    velocity:[3]f32 `mirai:"unit=m/s"`, // in the axes of the user when the window opens; zero: no move
    mix:locomotion.Move_Mix,
}

// What the seconds of a window count.
Ability_Clock :: enum u8 {
    World, // the fixed step of the world
    Own,   // the user's own time (core.Own_Pace), as its animation counts it: a window that follows a clip played in slow motion
}

// A span of the timeline of an ability, either in seconds from its start (open while
// from <= time < to) or bound to an animation clip span name (Animation_Events .Span_Begin /
// .Span_End). A window with empty span and to at 0 is not used.
Ability_Window :: struct {
    from,to:f32 `mirai:"min=0,unit=s"`,
    cancel_into:Ability_Tags,
    statuses:Ability_Statuses,
    hitbox:core.Record(Ability_Hitbox),
    on_begin:audio.Cue, // played at the user when it opens: a window from 0 plays at the start
    modify:Ability_Modifier,
    move:Ability_Move,
    cue:Ability_Cue,
    clock:Ability_Clock,
    attach:bool, // while it is open the Ability_Held of the user is at its socket
    span:[ABILITY_SPAN_NAME]u8 `mirai:"text"`, // animation clip span name; when non-empty, opens/closes on .Span_Begin/.Span_End instead of from/to
}

Ability_Attribute_Entry :: struct {
    attribute:Ability_Attribute,
    base:f32 `mirai:"min=0"`, // what it starts at: costs, effects and regeneration then change the base its Ability_State keeps, in 0..max
    max:f32 `mirai:"min=0"`,  // 0: no limit
    regen:f32 `mirai:"unit=1/s"`, // added to base every second
    regen_delay:f32 `mirai:"min=0,unit=s"`, // seconds after the last cost or negative effect before positive regen resumes
}

// An input waits while the ability that started at run-1 is still running (run == 0: buffer only).
Ability_Buffered :: struct {ability:core.Record(Ability),tick,run:u64}
Ability_Cooldown :: struct {ability:core.Record(Ability),until:u64}

Ability_Timer :: struct {
    tags:Ability_Tags,
    statuses:Ability_Statuses,
    start,until:u64,
    modify:Ability_Modifier,
    amount:f32,
    period:u32,
    cue:Ability_Cue,
    attribute:Ability_Attribute,
    stacks:u8,
}

@(component,replicated,description="Uses the abilities of its kit, with the attributes it starts with that costs and effects then change. The current values of its speed, jump and acceleration attributes scale the locomotion of its Character: a sprint is a window or an effect that modifies them.")
Ability_User :: struct {
    kit:core.Record(Ability_Kit),
    attributes:[ATTRIBUTE_ENTRIES]Ability_Attribute_Entry,
    speed:Ability_Attribute,        // its current value is the speed scale of its locomotion (locomotion.set_speed_scale); none: abilities leave that scale
    jump:Ability_Attribute,         // its current value is the jump scale of its locomotion (locomotion.set_jump_scale); none: abilities leave that scale
    acceleration:Ability_Attribute, // its current value is the acceleration scale of its locomotion (locomotion.set_acceleration_scale); none: abilities leave that scale
}

// The body that holds an Ability_User of its own (a weapon in a hand): the seat of that body drives
// and aims it, its statuses gate it, the actions of its abilities play on it and their moves move
// it, and it fires beside whatever the wielder's own abilities do. The attributes (a magazine),
// cooldowns and durability stay the weapon's own rows, so they go with it from hand to hand.
// ability_wield asks for it; a scene or a prefab may author it.
@(component,replicated,description="The body that wields this ability user (a weapon): its seat drives and aims it, its statuses gate it, and its actions and moves are that body's. The weapon keeps its own attributes, cooldowns and durability.")
Ability_Wielded :: struct {
    wielder:core.Entity,
}

// What an Ability_User holds that the windows with attach of its abilities move: at socket while
// one is open, and otherwise where its Bone_Attachment says (a sword drawn into the hand for a
// combo, then back to the hip).
@(component,description="An entity with a Bone_Attachment on this Ability_User (a weapon) that ability windows with attach hold at socket, and that rests at the socket of its Bone_Attachment otherwise.")
Ability_Held :: struct {
    entity:core.Entity,
    socket:[32]u8 `mirai:"text"`, // of the skeleton of the user, where the windows with attach hold it (a hand)
    blend:f32 `mirai:"min=0,max=0.2,unit=s"`, // seconds it takes from one socket to the other; 0: at once
}

// What a client cannot work out itself, written only when it changes, never every tick: the ability
// its user runs and the bases of its attributes as a line from the tick since, base i being
// bases[i] + rates[i] per second after it, kept in 0..max (ability_base). A cost or an effect, a
// drain that starts, pauses or stops and regeneration that resumes write a new line. Saved with
// the tracking row so a save can resume an ability in progress.
@(component,replicated,description="The running ability and the bases of the attributes of an ability user.")
Ability_State :: struct {
    ability:core.Record(Ability) `mirai:"readonly"`,
    start:u64 `mirai:"readonly,hidden"`,
    since:u64 `mirai:"readonly,hidden"`, // tick of bases
    bases:[ATTRIBUTE_ENTRIES]f32 `mirai:"readonly"`,
    rates:[ATTRIBUTE_ENTRIES]f32 `mirai:"readonly,hidden,unit=1/s"`, // regeneration less what the running ability drains
    drains:u8 `mirai:"readonly,hidden"`, // bit i: a per_second cost of the running ability takes from entry i
}

// The deadlines a client cannot work out, written when they start or end.
@(component,replicated,description="The cooldowns, lasting effects and regeneration deadlines of an ability user.")
Ability_Tracking :: struct {
    cooldowns:[USER_COOLDOWNS]Ability_Cooldown `mirai:"readonly,hidden"`,
    timers:[USER_TIMERS]Ability_Timer `mirai:"readonly,hidden"`,
    regen_at:[ATTRIBUTE_ENTRIES]u64 `mirai:"readonly,hidden"`, // tick from which entry i may regenerate after being spent
}

// What each end works out itself from the replicated rows, its input and its animation, and never
// sends: a client predicts it for its own character and a rollback runs it again. The fields of
// the run go back to their start when the ability and start tick of Ability_State change (run).
@(component,derived,description="The statuses, current values, input buffer and hits an ability user works out each tick.")
Ability_Local :: struct {
    statuses:Ability_Statuses `mirai:"transient,readonly"`,
    values:[ATTRIBUTE_ENTRIES]f32 `mirai:"transient,readonly"`,
    buffer:[USER_BUFFER]Ability_Buffered `mirai:"transient,readonly,hidden"`,
    run:u64 `mirai:"transient,readonly,hidden"`, // start+1 of the run the fields below follow; 0: none
    own:f32 `mirai:"transient,readonly,hidden"`, // ticks on the user's own clock
    span_open:u16 `mirai:"transient,readonly,hidden"`, // bit i: clip-span-bound window i is open
    span_start:[ABILITY_WINDOWS]u32 `mirai:"transient,readonly,hidden"`, // local tick offset when span-bound window i opened
    end_since:u64 `mirai:"transient,readonly,hidden"`, // tick from which its Character has been in an end_modes of the running ability; 0: not in one
    targets:[USER_HITS]core.Entity `mirai:"transient,readonly,hidden"`,
    windows:[USER_HITS]u8 `mirai:"transient,readonly,hidden"`,
    hit_count:u8 `mirai:"transient,readonly,hidden"`,
    held:core.Entity `mirai:"transient,readonly,hidden"`, // the Ability_Held entity last asked where to be
    held_at:bool `mirai:"transient,readonly,hidden"`,     // it was asked to the socket of a window
}

Ability_Request_Kind :: enum u8 {Use,Cancel,Effect,Kit,Wield}

Ability_Request :: struct {
    kind:Ability_Request_Kind,
    entity:core.Entity, // who uses, cancels or receives
    source:core.Entity, // of an effect: whose axes its knockback is in; of a wield: the wielder
    ability:core.Record(Ability),
    effect:Ability_Effect,
    kit:core.Record(Ability_Kit),
}

// Many push; abilities_step takes them at the start of the next tick.
@(storage,queue)
Ability_Requests :: struct {queue:core.Queue(Ability_Request)}

Ability_Event_Kind :: enum u8 {
    Started,
    Completed,   // it ran its duration, or its input was let go
    Interrupted, // another ability started over it
    Canceled,    // by a request, a missing sheet or the loss of its user
    Window_Begin,
    Window_End,
    Hit,      // its window's hitbox touched target; of a ray, at point with normal, distance along it and the zone of target (-1: none)
    Shot,     // a pellet of a ray went from origin to point (where it hit target, or its range): a tracer
    Depleted, // the base of attribute fell to 0
    Effect_Begin, // a timer started on entity, with the cue of its effect
    Effect_End,   // it ran out or was removed
}

Ability_Event :: struct {
    kind:Ability_Event_Kind,
    entity:core.Entity,
    ability:core.Record(Ability),
    window:i8, // -1: none
    zone:i8,   // of a ray's Hit and Shot: the hit zone of target, -1 for none
    cue:Ability_Cue,
    target:core.Entity,
    attribute:Ability_Attribute,
    origin,point,normal:[3]f32, // of a ray's Hit and Shot
    distance:f32,
}

// What the abilities did, appended by abilities_step and aged by the world.
@(storage)
Ability_Events :: struct {queue:core.Events(Ability_Event)}

// What a pellet hit: the entity whose collider it reached, where, and its zone with the tags of the
// zone; none: it went its whole range.
Shot_Hit :: struct {
    entity:core.Entity,
    point,normal:[3]f32,
    distance:f32,
    zone:i8, // -1: none
    tags:scene.Tags,
}

// A pellet a Ray hitbox cast in this tick, from where and toward where, which abilities_shots
// resolves and applies after abilities_step. A library that sees the world as the player who aimed
// it saw it (lag compensation) resolves it before: resolved.
Ability_Shot :: struct {
    user:core.Entity,
    aim:core.Entity, // the body whose seat aimed it; none: it was not aimed by a seat
    ability:core.Record(Ability),
    hitbox:i32,      // its row among the Ability_Hitbox rows
    window:i8,
    origin,direction:[3]f32,
    range,radius:f32,
    resolved:bool,
    hit:Shot_Hit,
}

// The pellets of a tick: written by abilities_step, resolved by lag compensation where it runs, and
// applied and emptied by abilities_shots. Nothing lives past the tick, so a copy of the world
// takes nothing of it.
@(storage,shared,copy=false)
Ability_Shots :: struct {
    items:[SHOTS]Ability_Shot,
    count:int,
    dropped:int, // past SHOTS in this tick
}

// Asks entity to start ability as if its input fired: it waits for a moment it is valid as its
// input.wait says (the kit's buffer, or also while the running ability goes on).
ability_use :: proc(requests:^Ability_Requests,entity:core.Entity,ability:core.Record(Ability)) {
    if requests==nil {return}
    if ability=={} {core.refuse(&requests.queue);return}
    request_offer(requests,{kind=.Use,entity=entity,ability=ability})
}

// Ends the ability entity runs (Canceled).
ability_cancel :: proc(requests:^Ability_Requests,entity:core.Entity) {
    request_offer(requests,{kind=.Cancel,entity=entity})
}

// Applies effect to target on the next tick, where this end decides target (core.owned).
ability_effect :: proc(requests:^Ability_Requests,target:core.Entity,effect:Ability_Effect,source:=core.NONE) {
    request_offer(requests,{kind=.Effect,entity=target,source=source,effect=effect})
}

// Makes wielder hold entity, a user of its own (a weapon): its seat drives and aims it, from the
// next tick. none lets it go. The ability entity runs ends when its wielder changes; its
// attributes, cooldowns and timers stay its own.
ability_wield :: proc(requests:^Ability_Requests,entity,wielder:core.Entity) {
    request_offer(requests,{kind=.Wield,entity=entity,source=wielder})
}

// Gives entity another kit (a weapon it takes); the running ability goes on.
ability_kit_set :: proc(requests:^Ability_Requests,entity:core.Entity,kit:core.Record(Ability_Kit)) {
    request_offer(requests,{kind=.Kit,entity=entity,kit=kit})
}

@(private)
request_offer :: proc(requests:^Ability_Requests,request:Ability_Request) {
    if requests==nil {return}
    if request.entity==core.NONE {core.refuse(&requests.queue);return}
    core.offer(&requests.queue,request)
}

@(storage,setting)
Ability_Settings :: struct {
    requests:u32 `mirai:"advanced"`, // uses, cancels, effects and kits a tick can ask for; past it they are dropped and reported
}
ABILITY_SETTINGS_DEFAULT :: Ability_Settings{requests=1024}

// The room of the requests of a tick, and what did not fit in it.
@(step="input fixed",loops="game",stage="begin")
ability_requests_serve :: proc(requests:^Ability_Requests,settings:Ability_Settings,problems:^core.Problems) {
    core.queue_serve(&requests.queue,int(settings.requests),problems,"abilities.requests","ability requests","Ability_Settings.requests","name an entity, and an ability to use")
}

// The current value of an attribute of a user and whether it has it.
ability_value :: proc "contextless" (user:^Ability_User,local:^Ability_Local,attribute:Ability_Attribute) -> (value:f32,found:bool) {
    if user==nil || local==nil || attribute==ATTRIBUTE_NONE {return}
    for entry,i in user.attributes {
        if entry.attribute==attribute {return local.values[i],true}
    }
    return
}

// The base of attributes[i] of a user at tick: the line of its Ability_State, in 0..max.
ability_base :: proc "contextless" (user:^Ability_User,state:^Ability_State,i:int,tick:u64,dt:f32) -> f32 {
    return clamp_base(user.attributes[i],base_line(state,i,tick,dt))
}

// The line of base i at tick, not kept in 0..max.
@(private)
base_line :: #force_inline proc "contextless" (state:^Ability_State,i:int,tick:u64,dt:f32) -> f32 {
    v:=state.bases[i]
    if tick>state.since && state.rates[i]!=0 {v+=state.rates[i]*dt*f32(tick-state.since)}
    return v if finite(v) else max(f32) if v>0 else 0
}

@(private)
clamp_base :: #force_inline proc "contextless" (entry:Ability_Attribute_Entry,value:f32) -> f32 {
    v:=max(value,0)
    return min(v,entry.max) if entry.max>0 else v
}

// Where a running ability is in its timeline: ticks of the world, of the user's own time since
// it started, and the bitmask of open clip-span-bound windows.
Ability_Time :: struct {local:i64,own:f32,spans:u16}

ability_has :: #force_inline proc "contextless" (local:Ability_Local,status:Ability_Status) -> bool {
    return u64(status)<64 && local.statuses&Ability_Statuses(u64(1)<<u64(status))!=0
}

status_bit :: #force_inline proc "contextless" (status:Ability_Status) -> Ability_Statuses {
    return u64(status)<64?Ability_Statuses(u64(1)<<u64(status)):0
}

tag_bit :: #force_inline proc "contextless" (tag:Ability_Tag) -> Ability_Tags {
    return u64(tag)<64?Ability_Tags(u64(1)<<u64(tag)):0
}

record_row :: proc "contextless" (rows:core.Records($T),ref:core.Record(T)) -> int {
    return -1 if ref=={} else core.record_index(rows.set,ref.table,ref.row,size_of(T))
}

record_at :: proc "contextless" (rows:core.Records($T),row:int) -> ^T {
    if row<0 || row>=core.records_count(rows) || row>=len(rows.set.values)/size_of(T) {return nil}
    return cast(^T)&rows.set.values[row*size_of(T)]
}

record_sheet :: proc "contextless" (rows:core.Records($T),ref:core.Record(T)) -> ^T {
    return record_at(rows,record_row(rows,ref))
}

ability_name_text :: proc "contextless" (name:^[ABILITY_NAME]u8) -> string {return base.text_get(name[:])}
