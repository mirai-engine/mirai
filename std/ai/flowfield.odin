package ai

import "base:runtime"
import "core:math/linalg"
import cmath "core:math"
import "mirai:std/math"

// A flow field serves every agent that heads for the same goals: one
// Dijkstra pass from the goals fills the cost of getting to them from each
// cell (the integration field), and each cell keeps the unit direction of its
// cheapest step. Reading it is a lookup, whatever the number of agents.
Flow_Field :: struct {
    width,height:int,
    cost:[]f32,         // to the nearest goal; INFINITY when it cannot be reached
    direction:[]math.Vec2, // unit vector to the cheapest next cell; zero at a goal or an unreachable cell
    open:Open_Set,
    allocator:runtime.Allocator,
}

flow_field_init :: proc(f:^Flow_Field,width,height:int,allocator:=context.allocator) -> bool {
    f^={allocator=allocator}
    if width<=0 || height<=0 || width>int(max(i32))/height {return false}
    e1,e2:runtime.Allocator_Error
    f.cost,e1=make([]f32,width*height,allocator)
    f.direction,e2=make([]math.Vec2,width*height,allocator)
    if e1!=nil || e2!=nil || !open_init(&f.open,width*height,width*height,allocator) {flow_field_destroy(f);return false}
    f.width=width;f.height=height
    for &c in f.cost {c=INFINITY}
    return true
}
flow_field_destroy :: proc(f:^Flow_Field) {
    if f.allocator.procedure!=nil {delete(f.cost,f.allocator);delete(f.direction,f.allocator)}
    open_destroy(&f.open)
    f^={}
}

INFINITY :: f32(1e30)

// Recomputes the field for a grid of the same size. Goals that are walls or
// outside the grid are ignored; Invalid, leaving the field unreachable, when
// the sizes differ or no goal is valid.
flow_field_build :: proc(f:^Flow_Field,g:^Grid,goals:[]Cell,hood:Neighborhood) -> Search_Status {
    for &c in f.cost {c=INFINITY}
    for &d in f.direction {d={}}
    open_clear(&f.open)
    if f.width==0 || g.width!=f.width || g.height!=f.height {return .Invalid}
    valid:=false
    for goal in goals {
        if !grid_passable(g,goal) {continue}
        index:=grid_index(g,goal)
        f.cost[index]=0
        open_push(&f.open,u32(index),0)
        valid=true
    }
    if !valid {return .Invalid}
    steps:[8]Cell
    lengths:[8]f32
    for {
        node,cost,ok:=open_pop(&f.open)
        if !ok {break}
        cell:=grid_cell(g,int(node))
        // The cells that can step onto this one, by the same rules as the steps it can take.
        n:=grid_steps(g,cell,hood,&steps,&lengths)
        entering:=f32(grid_cost(g,cell))
        for i in 0..<n {
            index:=grid_index(g,steps[i])
            next:=cost+entering*lengths[i]
            if next<f.cost[index] {
                f.cost[index]=next
                open_push(&f.open,u32(index),next)
            }
        }
    }
    for index in 0..<len(f.cost) {
        if f.cost[index]>=INFINITY || f.cost[index]==0 {continue}
        cell:=grid_cell(g,index)
        n:=grid_steps(g,cell,hood,&steps,&lengths)
        best:=INFINITY
        for i in 0..<n {
            next:=f.cost[grid_index(g,steps[i])]
            total:=next+f32(grid_cost(g,steps[i]))*lengths[i]
            if total<best {best=total;f.direction[index]=math.Vec2{f32(steps[i].x-cell.x),f32(steps[i].y-cell.y)}}
        }
        f.direction[index]=linalg.normalize0(f.direction[index])
    }
    return .Found
}

flow_field_cost :: #force_inline proc "contextless" (f:^Flow_Field,c:Cell) -> f32 {
    if c.x<0 || c.y<0 || int(c.x)>=f.width || int(c.y)>=f.height {return INFINITY}
    return f.cost[int(c.y)*f.width+int(c.x)]
}
// The direction of a cell; zero outside the field.
flow_field_direction :: #force_inline proc "contextless" (f:^Flow_Field,c:Cell) -> math.Vec2 {
    if c.x<0 || c.y<0 || int(c.x)>=f.width || int(c.y)>=f.height {return {}}
    return f.direction[int(c.y)*f.width+int(c.x)]
}
// The direction at a position in cell units (cell centers at whole numbers):
// the four nearest cells' directions blended bilinearly and normalized, so an
// agent turns smoothly across cell borders. Zero at a position that is not finite.
flow_field_sample :: proc "contextless" (f:^Flow_Field,position:math.Vec2) -> math.Vec2 {
    if position-position!={} {return {}}
    x0,y0:=i32(cmath.floor(position.x)),i32(cmath.floor(position.y))
    fx,fy:=position.x-f32(x0),position.y-f32(y0)
    top:=flow_field_direction(f,{x0,y0})*(1-fx)+flow_field_direction(f,{x0+1,y0})*fx
    bottom:=flow_field_direction(f,{x0,y0+1})*(1-fx)+flow_field_direction(f,{x0+1,y0+1})*fx
    return linalg.normalize0(top*(1-fy)+bottom*fy)
}
