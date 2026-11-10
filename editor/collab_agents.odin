package editor

import "mirai:core"
import "mirai:host"
import wire "mirai:net"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// The agents of each editor stand in the scenes of the others: where its
// figure is and what it faces, its color, glyph and name, and what the turn
// changed while it waits for review, which the others outline in its color.
// Each end sends its own when they change, and every COLLAB_AGENTS_INTERVAL
// while it has some, so whoever joins later sees them; the host passes them
// on. The chat of an agent stays with the editor that started it.

COLLAB_AGENTS :: AI_TASK_CAPACITY
COLLAB_AGENT_IDS :: 512 // of the changes of all the agents of an editor
COLLAB_AGENTS_INTERVAL :: 2.0

@(private)
Collab_Agent :: struct {
    task:u16,
    color,icon:u8,
    anchor:[3]f32,
    facing:f32,
    name:[32]u8,
    name_length:int,
    first,count:int, // of the ids of its editor
}

// What one editor said of its agents.
@(private)
Collab_Agents :: struct {
    list:[COLLAB_AGENTS]Collab_Agent,
    count:int,
    ids:[COLLAB_AGENT_IDS]base.Entity_Id,
    id_count:int,
}

@(private)
collab_agents_send :: proc(s:^Session,st:^Collab_State,now:f64) {
    w:serial.Writer
    collab_begin(&w,.Agents,1024)
    serial.write_scalar(&w,st.self)
    m:=s.ai
    world:=edited_world(s)
    count:=0
    if m!=nil {
        for &task in m.tasks[:m.task_count] {if ai_scene_task_visible(s,world,&task) {count+=1}}
    }
    count=min(count,COLLAB_AGENTS)
    serial.write_scalar(&w,u8(count))
    room:=COLLAB_AGENT_IDS
    written:=0
    if m!=nil {
        for &task in m.tasks[:m.task_count] {
            if written==count {break}
            if !ai_scene_task_visible(s,world,&task) {continue}
            written+=1
            anchor:=ai_scene_anchor(s,&task)
            serial.write_scalar(&w,u16(task.id))
            serial.write_scalar(&w,task.color_index)
            serial.write_scalar(&w,task.icon)
            serial.write_scalar(&w,anchor.x);serial.write_scalar(&w,anchor.y);serial.write_scalar(&w,anchor.z)
            serial.write_scalar(&w,task.facing)
            name:=ai_agent_name(m,&task)
            serial.write_string(&w,name)
            ids:[]base.Entity_Id
            if task.review.pending {ids=task.review.changed_ids[:min(len(task.review.changed_ids),room)]}
            room-=len(ids)
            serial.write_scalar(&w,u16(len(ids)))
            for id in ids {serial.write_scalar(&w,u64(id))}
        }
    }
    bytes:=serial.writer_bytes(&w)
    key:=base.hash64(bytes)
    if key==st.agents_key && (count==0 || now-st.agents_at<COLLAB_AGENTS_INTERVAL) {return}
    st.agents_key,st.agents_at=key,now
    collab_broadcast(st,bytes)
}

// What another editor said of its agents; the host passes it on.
@(private)
collab_agents_receive :: proc(st:^Collab_State,from:int,data:[]u8) {
    r:=serial.reader_init(data[1:])
    id:=int(serial.read_u8(&r))
    count:=int(serial.read_u8(&r))
    if r.failed || id>=COLLAB_PEERS || id==int(st.self) || count>COLLAB_AGENTS {return}
    if st.role==.Host && id!=from {return}
    agents:=&st.peers[id].agents
    agents.count,agents.id_count=0,0
    for _ in 0..<count {
        agent:Collab_Agent
        agent.task=serial.read_u16(&r)
        agent.color=serial.read_u8(&r)
        agent.icon=serial.read_u8(&r)
        agent.anchor={serial.read_f32(&r),serial.read_f32(&r),serial.read_f32(&r)}
        agent.facing=serial.read_f32(&r)
        agent.name_length=copy(agent.name[:],serial.read_string(&r))
        ids:=int(serial.read_u16(&r))
        if r.failed || ids>COLLAB_AGENT_IDS-agents.id_count {break}
        agent.first=agents.id_count
        for _ in 0..<ids {
            agents.ids[agents.id_count]=base.Entity_Id(serial.read_u64(&r))
            agents.id_count+=1
        }
        if r.failed {break}
        agent.count=ids
        agents.list[agents.count]=agent
        agents.count+=1
    }
    if st.role==.Host {collab_broadcast(st,data,from)}
}

// The agents of another editor that is in the session now.
@(private)
collab_remote_agents :: proc(s:^Session,st:^Collab_State,i:int,now:f64) -> []Collab_Agent {
    if !collab_peer_live(st,i,now) || s.ai!=nil && !s.ai.show_agents_in_scene {return nil}
    agents:=&st.peers[i].agents
    return agents.list[:agents.count]
}

// Their figures, glyphs and names, as those of the agents of this end.
@(private)
collab_agents_draw :: proc(s:^Session,st:^Collab_State,now:f64) {
    _,low,high,loaded:=presence_mesh(s.app.assets)
    if !loaded {return}
    for i in 0..<COLLAB_PEERS {
        for &agent,k in collab_remote_agents(s,st,i,now) {
            color:=agent_color(int(agent.color))
            eyes:=agent.anchor+{0,-low.y,0}
            figure:=&st.agent_figures[i][k]
            if presence_prepare(s,figure,eyes,agent.facing,color,agent_level(int(agent.color)),u64(1)<<32|u64(i)<<16|u64(agent.task)) {host.extras_instance_add(&s.app.extras,figure.instance)}
            if rect,shown:=presence_glyph_rect(s,presence_shown(figure,eyes)+{0,high.y,0},s.viewport.view_projection);shown {
                presence_icon_draw(s,rect,collab_agent_icon(agent),color)
                presence_name_draw(s,rect,string(agent.name[:agent.name_length]),color)
            }
        }
    }
}

@(private)
collab_agent_icon :: proc "contextless" (agent:Collab_Agent) -> ui.Icon {
    return ui.icon_user(u8(User_Icon.Agent_Star)+agent.icon%AI_AGENT_GLYPHS)
}

// What the agents of the others changed, outlined in their colors.
@(private)
collab_agents_highlights :: proc(s:^Session,st:^Collab_State,w:core.World_Ref,levels:[]u8,now:f64) {
    es:=core.world_entities(w)
    for i in 0..<COLLAB_PEERS {
        agents:=&st.peers[i].agents
        for agent in collab_remote_agents(s,st,i,now) {
            for id in agents.ids[agent.first:][:agent.count] {
                e:=api_entity(w,id)
                if e==core.NONE || !core.alive(es,e) {continue}
                if at:=core.entity_index(e);at<len(levels) && levels[at]==0 {levels[at]=agent_level(int(agent.color))}
            }
        }
    }
}

// What the outlines of the agents of the others depend on.
@(private)
collab_agents_key :: proc(s:^Session,st:^Collab_State,now:f64) -> u64 {
    key:=u64(0)
    for i in 0..<COLLAB_PEERS {
        agents:=&st.peers[i].agents
        for agent in collab_remote_agents(s,st,i,now) {
            key=base.hash_combine(key,u64(agent.color)+1)
            for id in agents.ids[agent.first:][:agent.count] {key=base.hash_combine(key,u64(id))}
        }
    }
    return key
}

// The remote agent whose glyph is at a point of the viewport.
@(private)
collab_agent_at :: proc(s:^Session,point:[2]f32) -> (peer,agent:int,rect:ui.Rect,found:bool) {
    st:=collab_state(s)
    if st==nil || st.phase!=.Joined || s.mode!=.Edit {return}
    _,low,high,loaded:=presence_mesh(s.app.assets)
    if !loaded {return}
    now:=wire.host_time(&st.host)
    for i in 0..<COLLAB_PEERS {
        for &a,k in collab_remote_agents(s,st,i,now) {
            r,shown:=presence_glyph_rect(s,presence_shown(&st.agent_figures[i][k],a.anchor+{0,-low.y,0})+{0,high.y,0},s.viewport.view_projection)
            if shown && ui.rect_contains(r,point) {return i,k,r,true}
        }
    }
    return
}
