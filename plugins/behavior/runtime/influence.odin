package behavior

import "core:math/linalg"
import "mirai:core"
import "mirai:std/ai"
import mm "mirai:std/math"
import phys "plugins:physics/runtime"

// Influence maps over the ground: a layer for each team of the first
// INFLUENCE_TEAMS, where its Perceivables are and how far that reaches, and
// the cover of each cell. A think procedure or a place query reads the threat
// at a point (the influence of the teams an agent fears), the allies near it
// (that of its own team) and how covered it is from someone. Each tick spreads
// Behavior_Settings.influence_cells cells and casts influence_rays rays of
// cover, so its cost is bounded: the cover is measured first around the
// Perceivables, in turns, and then over the rest of the map. A world with
// nobody to stamp them or to read them (no Perceivable, Perceiver, Mind_Agent
// or querier of places) has no maps and spends nothing on them.

INFLUENCE_TEAMS :: 4
INFLUENCE_HEIGHT :: f32(40)   // m above influence_center a ray looks down for the ground of a cell from
INFLUENCE_BODY :: f32(1.1)    // m above the ground where cover is measured
INFLUENCE_AROUND :: 2         // cells on each side of a Perceivable whose cover is measured first

@(storage,host,by_world,free="influence_free")
Influence :: struct {
    grid:ai.Influence_Grid,
    made:[4]f32,  // the cell, size and center of the settings it was made with
    sweep:int,    // the next cell of the cover over the whole map
    turn:int,     // the Perceivable whose cells are measured next
}

influence_free :: proc(i:^Influence) {
    ai.influence_destroy(&i.grid)
    i^={}
}

@(step="fixed",stage="input",server,after="perception_update")
influence_update :: proc(
    influence:^Influence,settings:core.Ref(Behavior_Settings),perceivables:^core.Table(Perceivable,.Read),perceivers:^core.Table(Perceiver,.Read),minds:^core.Table(Mind_Agent,.Read),
    queriers:^core.Table(Place_Result,.Read),worlds:^core.Table(core.World_Transform,.Read),physics:core.Ref(phys.Physics_State),time:core.Time,
) {
    if settings.ptr==nil || !time.playing || time.dt<=0 {return}
    used:=core.count(perceivables)>0 || core.count(perceivers)>0 || core.count(minds)>0 || core.count(queriers)>0
    s:=settings.ptr^
    if !used || !(s.influence_cell>0) || s.influence_size<=0 {
        if influence.grid.width>0 {influence_free(influence)}
        return
    }
    made:=[4]f32{s.influence_cell,f32(s.influence_size),s.influence_center.x,s.influence_center.z}
    if influence.made!=made || !ai.influence_ready(&influence.grid) {
        size:=int(s.influence_size)
        half:=s.influence_cell*f32(size)/2
        influence^={made=made}
        if !ai.influence_init(&influence.grid,{s.influence_center.x-half,s.influence_center.z-half},s.influence_cell,size,size,INFLUENCE_TEAMS) {return}
    }
    g:=&influence.grid
    if !ai.influence_running(g) {
        for row in 0..<core.count(perceivables) {
            p:=perceivables.values[row]
            if int(p.team)>=INFLUENCE_TEAMS {continue}
            if pose,ok:=core.get(worlds,core.entity_at(perceivables,row));ok {ai.influence_stamp(g,int(p.team),pose.position,1)}
        }
    }
    ai.influence_spread(g,int(max(s.influence_cells,1)),s.influence_falloff,s.influence_blend)
    rays:=int(s.influence_rays)
    // Around the Perceivables in turns, while some cell there is not measured.
    count:=core.count(perceivables)
    for _ in 0..<count {
        if rays<10 {break}
        influence.turn=(influence.turn+1)%count
        pose,ok:=core.get(worlds,core.entity_at(perceivables,influence.turn))
        center,inside:=ai.influence_cell(g,pose.position)
        if !ok || !inside {continue}
        for z in center.y-INFLUENCE_AROUND..=center.y+INFLUENCE_AROUND {
            for x in center.x-INFLUENCE_AROUND..=center.x+INFLUENCE_AROUND {
                if x<0 || z<0 || int(x)>=g.width || int(z)>=g.height || g.known[int(z)*g.width+int(x)]!=0 || rays<10 {continue}
                rays-=influence_measure(g,{x,z},s.influence_center.y,physics)
            }
        }
    }
    cells:=g.width*g.height
    for rays>=10 && cells>0 {
        at:=influence.sweep%cells
        influence.sweep=(at+1)%cells
        rays-=influence_measure(g,{i32(at%g.width),i32(at/g.width)},s.influence_center.y,physics)
    }
}

// Measures the cover of a cell: its ground below, then a ray in each
// direction at a body's height, a cell long. Returns the rays it cast.
@(private)
influence_measure :: proc(g:^ai.Influence_Grid,cell:ai.Cell,top:f32,physics:core.Ref(phys.Physics_State)) -> int {
    above:=ai.influence_center(g,cell,top+INFLUENCE_HEIGHT)
    ground,hit:=phys.raycast(physics,above,{0,-1,0},2*INFLUENCE_HEIGHT)
    if !hit {
        ai.influence_cover_set(g,cell,0)
        return 1
    }
    eye:=mm.Vec3(ground.point)+{0,INFLUENCE_BODY,0}
    blocked:u8
    for d in 0..<ai.INFLUENCE_DIRECTIONS {
        s,c:=mm.sincos_det(f32(d)*f32(linalg.PI)/4)
        if _,ok:=phys.raycast(physics,eye,{c,0,s},max(g.cell,1));ok {blocked|=1<<uint(d)}
    }
    ai.influence_cover_set(g,cell,blocked)
    return 1+ai.INFLUENCE_DIRECTIONS
}

// The influence of some teams at a point: the threat of those an agent
// fears, or the allies of its own. 0 without a map.
influence_at :: proc "contextless" (influence:^Influence,position:[3]f32,teams:Teams) -> f32 {
    if influence==nil {return 0}
    total:f32
    for layer in 0..<INFLUENCE_TEAMS {
        if u32(teams)&(1<<u32(layer))!=0 {total+=ai.influence_sample(&influence.grid,layer,position)}
    }
    return total
}

// How covered a point is from another: 1 when something blocks the way at a
// body's height beside it, 0.5 when only to one side, 0 in the open or where
// the cover is not measured yet.
cover_at :: proc "contextless" (influence:^Influence,position,from:[3]f32) -> f32 {
    if influence==nil {return 0}
    return ai.influence_cover(&influence.grid,position,from)
}
