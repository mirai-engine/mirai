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
// Perceivables, in turns, and then over the rest of the map.

INFLUENCE_TEAMS :: 4
INFLUENCE_HEIGHT :: f32(40)   // m above influence_center a ray looks down for the ground of a cell from
INFLUENCE_BODY :: f32(1.1)    // m above the ground where cover is measured
INFLUENCE_AROUND :: 2         // cells on each side of a Perceivable whose cover is measured first

@(storage,host,by_world,free="influence_free")
Influence :: struct {
    grid:ai.Influence_Grid,
    center:[3]f32,
    sight_layers:phys.Collision_Layers,
    sweep:int,    // the next cell of the cover over the whole map
    turn:int,     // the Perceivable whose cells are measured next
}

influence_free :: proc(i:^Influence) {
    ai.influence_destroy(&i.grid)
    i^={}
}

@(step="fixed",stage="input",server)
influence_update :: proc(
    influence:^Influence,settings:core.Ref(Behavior_Settings),perceivables:^core.Table(Perceivable,.Read),
    worlds:^core.Table(core.World_Transform,.Read),physics:core.Ref(phys.Physics_State),time:core.Time,
) {
    if settings.ptr==nil || !settings.influence_enabled {
        if influence.grid.width>0 {influence_free(influence)}
        return
    }
    if !time.playing || time.dt<=0 {return}
    s:=settings.ptr^
    size:=int(s.influence_size)
    if !(s.influence_cell>0 && s.influence_cell<=max(f32)) ||
        size<=0 || size>1024 || s.influence_center-s.influence_center!={} {
        if influence.grid.width>0 {influence_free(influence)}
        return
    }
    g:=&influence.grid
    if g.cell!=s.influence_cell || g.width!=size || influence.center.xz!=s.influence_center.xz {
        half:=s.influence_cell*f32(size)/2
        if !ai.influence_init(g,s.influence_center.xz-half,s.influence_cell,size,size,INFLUENCE_TEAMS) {return}
        influence.sweep,influence.turn=0,0
    }
    if influence.sight_layers!=s.sight_layers || influence.center.y!=s.influence_center.y {
        for &known in g.known {known=0}
        for &cover in g.cover {cover=0}
        influence.sweep=0
    }
    influence.center,influence.sight_layers=s.influence_center,s.sight_layers
    if !ai.influence_running(g) {
        for row in 0..<core.count(perceivables) {
            p:=perceivables.values[row]
            if int(p.team)>=INFLUENCE_TEAMS {continue}
            if pose,ok:=core.get(worlds,core.entity_at(perceivables,row));ok {ai.influence_stamp(g,int(p.team),pose.position,1)}
        }
    }
    ai.influence_spread(g,int(max(s.influence_cells,1)),s.influence_falloff,s.influence_blend)
    if !physics.ready || physics.ptr==nil {return}
    filter:=sight_filter(s.sight_layers)
    rays:=int(s.influence_rays)
    cell_rays:=1+ai.INFLUENCE_DIRECTIONS
    // Around the Perceivables in turns, while some cell there is not measured.
    count:=core.count(perceivables)
    for _ in 0..<count {
        if rays<cell_rays {break}
        influence.turn=(influence.turn+1)%count
        pose,ok:=core.get(worlds,core.entity_at(perceivables,influence.turn))
        center,inside:=ai.influence_cell(g,pose.position)
        if !ok || !inside {continue}
        for z in center.y-INFLUENCE_AROUND..=center.y+INFLUENCE_AROUND {
            for x in center.x-INFLUENCE_AROUND..=center.x+INFLUENCE_AROUND {
                if x<0 || z<0 || int(x)>=g.width || int(z)>=g.height || rays<cell_rays {continue}
                if g.known[int(z)*g.width+int(x)]!=0 {continue}
                rays-=influence_measure(g,{x,z},s.influence_center.y,physics,filter)
            }
        }
    }
    cells:=g.width*g.height
    for rays>=cell_rays && cells>0 {
        at:=influence.sweep%cells
        influence.sweep=(at+1)%cells
        rays-=influence_measure(g,{i32(at%g.width),i32(at/g.width)},s.influence_center.y,physics,filter)
    }
}

// Measures the cover of a cell: its ground below, then a ray in each
// direction at a body's height, a cell long. Returns the rays it cast.
@(private)
influence_measure :: proc(
    g:^ai.Influence_Grid,cell:ai.Cell,top:f32,physics:core.Ref(phys.Physics_State),filter:phys.Query_Filter,
) -> int {
    above:=ai.influence_center(g,cell,top+INFLUENCE_HEIGHT)
    ground,hit:=phys.raycast(physics,above,{0,-1,0},2*INFLUENCE_HEIGHT,filter=filter)
    if !hit {
        ai.influence_cover_set(g,cell,0)
        return 1
    }
    eye:=mm.Vec3(ground.point)+{0,INFLUENCE_BODY,0}
    blocked:u8
    for d in 0..<ai.INFLUENCE_DIRECTIONS {
        s,c:=mm.sincos_det(f32(d)*f32(linalg.PI)/4)
        if _,ok:=phys.raycast(physics,eye,{c,0,s},max(g.cell,1),filter=filter);ok {blocked|=1<<uint(d)}
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
