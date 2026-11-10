package core

import mm "mirai:std/math"

// How an entity a simulation moves is moving: only the library that
// simulates it writes it (physics, for its bodies and characters). What a
// saved game holds is applied when the body is made again.
@(component,description="The velocities the simulation gives this entity.")
Motion :: struct {
    linear:[3]f32 `mirai:"readonly,unit=m/s"`,
    angular:[3]f32 `mirai:"readonly,unit=rad/s"`,
    center:[3]f32 `mirai:"transient,readonly,hidden,unit=m"`, // of mass, in the frame of the entity
    island:u32 `mirai:"transient,readonly,hidden"`, // shared this tick with what touches it or is joined to it, awake, while some entity has a Pose_Target; 0: none
    awake:bool `mirai:"transient,readonly"`,
}

// The vertical of an entity its simulation turns, as a character that walks
// around a planet: the +Y of frame is its up, and the yaw of its look
// (input.Move_Input) turns about that up. The frame turns with the up without
// twisting about it, so a look that keeps its yaw keeps heading the same way
// along the ground. Only the library that simulates the entity writes it
// (physics, for its characters), from the state it keeps; without it the up
// is +Y of the world.
@(component,description="The up of this entity and the frame its look turns in, as its simulation turns them.")
Vertical :: struct {
    frame:mm.Quat `mirai:"transient,readonly"`,
}

// The frame of the vertical of e: the identity without one.
vertical_of :: proc(verticals:Read(Vertical),e:Entity) -> mm.Quat {
    if verticals.table!=nil {
        if vertical,ok:=get(verticals,e);ok && vertical.frame!=0 {return vertical.frame}
    }
    return mm.QUAT_IDENTITY
}

// Where another owner of an entity asks its owner to put it (the network,
// for the state of another end). A change of placed asks to put it at the
// pose, with those velocities, at once; a following one heads for the pose
// in each tick besides, pushing what it touches. Whoever owns the Transform
// of the entity takes it at the start of the tick: the library that
// simulates it (physics, for a body), or pose_targets_place for a Transform
// nobody owns.
@(component,description="A pose another owner asks for this entity.")
Pose_Target :: struct {
    follow:bool `mirai:"transient,readonly"`,
    placed:u32 `mirai:"transient,readonly,hidden"`, // grows with every place asked
    rest:bool `mirai:"transient,readonly,hidden"`,  // the place asked leaves it at rest
    position:[3]f32 `mirai:"transient,readonly,unit=m"`,
    rotation:mm.Quat `mirai:"transient,readonly"`,
    scale:[3]f32 `mirai:"transient,readonly"`,
    linear:[3]f32 `mirai:"transient,readonly,hidden,unit=m/s"`,
    angular:[3]f32 `mirai:"transient,readonly,hidden,unit=rad/s"`,
}

@(storage)
Pose_Target_Places :: struct {seen:Seen}

// The pose a target asks of a Transform no component owns, at the start of
// the tick.
@(step="fixed",loops="game",stage="begin")
pose_targets_place :: proc(targets:Read(Pose_Target),transforms:^Table(Transform),places:^Pose_Target_Places) {
    c:=changes(targets,&places.seen)
    for row in each_changed(targets,&c) {
        local:=free(transforms,entity_at(targets,row))
        if local==nil {continue}
        target:=at(targets,row)
        local^={target.position,target.rotation,target.scale}
    }
}
