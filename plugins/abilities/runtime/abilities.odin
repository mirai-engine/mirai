package abilities

import "mirai:core"
import inp "mirai:engine/input"
import "mirai:std/base"
import phys "plugins:physics/runtime"

// Abilities: what a character does on top of its locomotion (an attack, a dash, a block, a hit
// reaction) as rows of game data. An Ability is a sheet: the input that starts it, what it
// requires and costs, how long it lasts and a timeline of windows relative to its start (a
// hitbox, a dash, cancel windows that say which abilities may follow, statuses it grants, cues
// for presentation). There is no graph of transitions: an ability starts over the running one
// only while an open cancel window accepts one of its tags (or its kit lets those tags interrupt
// anything), and among the valid candidates the one of highest priority wins.
//
// The state of an Ability_User is which ability runs and the tick it started; the phase, the
// open windows and the statuses they grant are derived each tick from the tick against the
// immutable sheet, so an interruption or a rollback leaves nothing behind. Attributes are bases
// that effects change through Ability_Requests, plus modifiers recomputed every tick.

ABILITY_WINDOWS :: 16
ABILITY_CONDITIONS :: 4
ABILITY_COSTS :: 4
ABILITY_NAME :: 64
KIT_ABILITIES :: 32
ATTRIBUTE_ENTRIES :: 8
USER_HITS :: 16
USER_BUFFER :: 4
USER_COOLDOWNS :: 8
USER_TIMERS :: 8
EVENT_CAPACITY :: 1024
HITBOX_RESULTS :: 32
// The layered moves of the windows of an ability use these ids, plus the window index.
MOVE_ID :: u32(0x4142_0000)
// The knockback of an effect, as a layered move of its target.
KNOCKBACK_ID :: u32(0x4142_ffff)

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

// Locomotion modes of the physics Character an ability may start in.
@(name_bits="phys.Locomotion_Mode")
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

Ability_Condition :: struct {
    attribute:Ability_Attribute,
    at_least:f32,
    at_most:f32, // 0: no limit
}

Ability_Cost :: struct {
    attribute:Ability_Attribute,
    amount:f32 `mirai:"min=0"`, // taken from its base when the ability starts; it cannot start with less
}

// value = (base + add) * (1 + more), summed over the modifiers in force.
Ability_Modifier :: struct {
    attribute:Ability_Attribute,
    add:f32,
    more:f32, // 0.5: half as much more; -0.5: half
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
    cue:Ability_Cue,            // carried by the events of the start and end of its timer
    knockback:[3]f32 `mirai:"unit=m/s"`, // in the axes of the source: a velocity its Character takes
    knockback_seconds:f32 `mirai:"min=0,unit=s"`,
    use:core.Record(Ability), // the target starts it: a hit reaction
}

Hitbox_Shape :: enum u8 {None,Box,Sphere,Capsule}

Ability_Hitbox :: struct {
    shape:Hitbox_Shape,
    center:[3]f32 `mirai:"unit=m"`, // in the axes of the user
    size:[3]f32 `mirai:"min=0,unit=m"`, // box: half extents; sphere: x is the radius; capsule: x radius, y half height along its y
    effect:Ability_Effect, // on each entity it touches, once per window
}

Ability_Move :: struct {
    velocity:[3]f32 `mirai:"unit=m/s"`, // in the axes of the user when the window opens; zero: no move
    mix:phys.Move_Mix,
}

// What the seconds of a window count.
Ability_Clock :: enum u8 {
    World, // the fixed step of the world
    Own,   // the user's own time (core.Own_Pace), as its animation counts it: a window that follows a clip played in slow motion
}

// A span of the timeline of an ability, in seconds from its start; it is open while
// from <= time < to. A window with to at 0 is not used.
Ability_Window :: struct {
    from,to:f32 `mirai:"min=0,unit=s"`,
    clock:Ability_Clock, // Own: from and to are seconds of the user's own time, and the window may close after the duration (the ability's end closes it)
    cancel_into:Ability_Tags,   // abilities with one of these tags may start over this one
    statuses:Ability_Statuses,  // the user is in them
    modify:Ability_Modifier,    // of the user
    hitbox:Ability_Hitbox,
    move:Ability_Move, // a layered move of the user's Character for the whole window
    cue:Ability_Cue,   // carried by the events of its opening and closing
}

@(record,description="An ability: the input that starts it, what it requires and costs, how long it lasts, what it plays and a timeline of windows from its start (hitboxes, dashes, cancel windows, statuses, cues). It starts over the running one only inside a window of that one that accepts one of its tags.")
Ability :: struct {
    input:Ability_Input,
    priority:i16, // among the candidates of a tick, the highest starts
    tags:Ability_Tags,
    requires:Ability_Statuses, // all of them
    blocked_by:Ability_Statuses, // any of them
    modes:Ability_Modes, // of the user's Character; none: any
    conditions:[ABILITY_CONDITIONS]Ability_Condition,
    costs:[ABILITY_COSTS]Ability_Cost,
    cooldown:f32 `mirai:"min=0,unit=s"`,
    duration:f32 `mirai:"min=0,unit=s"`,
    hold:bool, // it ends when its input is let go
    action:[ABILITY_NAME]u8 `mirai:"text"`, // an action of the user's Animation (a layer over locomotion)
    clip:[ABILITY_NAME]u8 `mirai:"text"`,   // a clip of its .match played over the whole body (match_play)
    windows:[ABILITY_WINDOWS]Ability_Window,
    next:core.Record(Ability), // asked for when it completes, in the statuses its windows gave on its last tick
}
ABILITY_DEFAULT :: Ability{input={on=.Pressed},duration=0.5}

@(record,description="The abilities an Ability_User may start by input, in order of preference on equal priority: those of a weapon or a character.")
Ability_Kit :: struct {
    abilities:[KIT_ABILITIES]core.Record(Ability),
    buffer:f32 `mirai:"min=0,unit=s"`, // an input that cannot start its ability yet waits this long
    interrupts:Ability_Tags,           // abilities with these tags start over any other: reactions, death
}
ABILITY_KIT_DEFAULT :: Ability_Kit{buffer=0.2}

Ability_Attribute_Entry :: struct {
    attribute:Ability_Attribute,
    base:f32 `mirai:"min=0"`, // costs and effects change it; it stays in 0..max
    max:f32 `mirai:"min=0"`,  // 0: no limit
    regen:f32 `mirai:"unit=1/s"`, // added to base every second
}

Ability_Hit :: struct {target:core.Entity,window:u8}
// An input that waits; running: also while the ability that started at tick run goes on.
Ability_Buffered :: struct {ability:core.Record(Ability),tick:u64,run:u64,running:bool}
Ability_Cooldown :: struct {ability:core.Record(Ability),until:u64}
// An effect that lasts; its modifier and its amount count once per stack.
Ability_Timer :: struct {
    tags:Ability_Tags,
    statuses:Ability_Statuses,
    modify:Ability_Modifier,
    attribute:Ability_Attribute,
    amount:f32,  // added every period ticks from start
    period:u32,
    stacks:u8,
    cue:Ability_Cue,
    start,until:u64, // ticks; it ends at until
}

@(component,replicated,description="Uses abilities: those of its kit by the input of the seat that drives it, and those asked through Ability_Requests. Holds its attributes, which costs and effects change.")
Ability_User :: struct {
    kit:core.Record(Ability_Kit),
    attributes:[ATTRIBUTE_ENTRIES]Ability_Attribute_Entry,
    ability:core.Record(Ability) `mirai:"readonly"`, // the one running; none: idle
    start:u64 `mirai:"readonly,hidden"`,             // tick it started at
    own:f32 `mirai:"readonly,hidden"`,               // ticks of the user's own time (core.Own_Pace) since it started
    hits:[USER_HITS]Ability_Hit `mirai:"readonly,hidden"`, // of the one running
    hit_count:u8 `mirai:"readonly,hidden"`,
    buffer:[USER_BUFFER]Ability_Buffered `mirai:"readonly,hidden"`,
    cooldowns:[USER_COOLDOWNS]Ability_Cooldown `mirai:"readonly,hidden"`,
    timers:[USER_TIMERS]Ability_Timer `mirai:"readonly,hidden"`,
    statuses:Ability_Statuses `mirai:"transient,readonly"`, // of its timers and of the open windows
    values:[ATTRIBUTE_ENTRIES]f32 `mirai:"transient,readonly"`, // of its attributes, with the modifiers
}

Ability_Request_Kind :: enum u8 {Use,Cancel,Effect,Kit}

Ability_Request :: struct {
    kind:Ability_Request_Kind,
    entity:core.Entity, // who uses, cancels or receives
    source:core.Entity, // of an effect: whose axes its knockback is in
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
    Hit,      // its window's hitbox touched target
    Depleted, // the base of attribute fell to 0
    Effect_Begin, // a timer started on entity, with the cue of its effect
    Effect_End,   // it ran out or was removed
}

Ability_Event :: struct {
    kind:Ability_Event_Kind,
    entity:core.Entity,
    ability:core.Record(Ability),
    window:i8, // -1: none
    cue:Ability_Cue,
    target:core.Entity,
    attribute:Ability_Attribute,
}

// What the abilities did this tick; abilities_step clears and fills it.
@(storage,events)
Ability_Events :: struct {queue:core.Queue(Ability_Event)}

// Asks entity to start ability as if its input fired: it waits for a moment it is valid as its
// input.wait says (the kit's buffer, or also while the running ability goes on).
ability_use :: proc(requests:^Ability_Requests,entity:core.Entity,ability:core.Record(Ability)) {
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
ability_value :: proc "contextless" (user:Ability_User,attribute:Ability_Attribute) -> (value:f32,found:bool) {
    if attribute==ATTRIBUTE_NONE {return}
    for entry,i in user.attributes {
        if entry.attribute==attribute {return user.values[i],true}
    }
    return
}

// Where a running ability is in its timeline: ticks of the world and of the user's own time since
// it started.
Ability_Time :: struct {local:i64,own:f32}

ability_has :: #force_inline proc "contextless" (user:Ability_User,status:Ability_Status) -> bool {
    return u64(status)<64 && user.statuses&Ability_Statuses(u64(1)<<u64(status))!=0
}

status_bit :: #force_inline proc "contextless" (status:Ability_Status) -> Ability_Statuses {
    return u64(status)<64?Ability_Statuses(u64(1)<<u64(status)):0
}

tag_bit :: #force_inline proc "contextless" (tag:Ability_Tag) -> Ability_Tags {
    return u64(tag)<64?Ability_Tags(u64(1)<<u64(tag)):0
}

// The sheet a reference names, read in place; nil without it.
ability_sheet :: proc "contextless" (rows:core.Records(Ability),ref:core.Record(Ability)) -> ^Ability {
    if ref=={} {return nil}
    at:=core.record_index(rows.set,ref.table,ref.row,size_of(Ability))
    if at<0 {return nil}
    return cast(^Ability)&rows.set.values[at*size_of(Ability)]
}

kit_sheet :: proc "contextless" (rows:core.Records(Ability_Kit),ref:core.Record(Ability_Kit)) -> ^Ability_Kit {
    if ref=={} {return nil}
    at:=core.record_index(rows.set,ref.table,ref.row,size_of(Ability_Kit))
    if at<0 {return nil}
    return cast(^Ability_Kit)&rows.set.values[at*size_of(Ability_Kit)]
}

ability_name_text :: proc "contextless" (name:^[ABILITY_NAME]u8) -> string {return base.text_get(name[:])}
