package editor

import "core:os"
import wire "mirai:net"
import "mirai:std/serial"

// What the session carries of the game a plugin serves from the Play of the
// host (Play_Provider), so a guest joins it: in the presence of the host,
// what its plugin offers of the game; and the scene that game runs. When the
// host starts the game it sends a mark in the ordered stream of edits. A
// guest that processes it and has nothing of its own unconfirmed has, at that
// moment, the scene the server of the host runs, and copies it; a guest that
// cannot, or that entered after the mark, asks the host for the copy when it
// joins the game.

@(private)
collab_host_seen :: proc(st:^Collab_State) -> bool {
    if st==nil || st.role!=.Guest || st.phase!=.Joined {return false}
    host:=&st.peers[0]
    return host.used && host.has_pose && wire.host_time(&st.host)-host.seen<=COLLAB_PRESENCE_SEEN
}

// A guest: whether it is in a session, and whether it hears the host now.
collab_host_heard :: proc(s:^Session) -> (joined,heard:bool) {
    st:=collab_state(s)
    return st!=nil && st.role==.Guest && st.phase==.Joined,collab_host_seen(st)
}

// What this editor tells its guests of the game of a plugin it serves (Play_Provider.offer); 0: none.
@(private)
collab_offer :: proc(s:^Session,out:[]u8) -> int {
    p:=providers(s)
    if !p.plays || p.play.offer==nil {return 0}
    return clamp(p.play.offer(s,out),0,len(out))
}

// A guest: the offer of the game the host serves, and the invitation of the
// session it joined with. The offer is a copy.
collab_host_offer :: proc(s:^Session) -> (offer:[]u8,invitation:wire.Invitation,ok:bool) {
    st:=collab_state(s)
    if !collab_host_seen(st) || !st.peers[0].serving {return}
    host:=&st.peers[0]
    offer=make([]u8,host.offer_size,context.temp_allocator)
    copy(offer,host.offer[:host.offer_size])
    return offer,st.invitation,true
}

// The host started the game of a plugin on the scene as it is: what it edited
// travels first, then the mark, so a guest that processes the mark has that scene.
collab_play_mark :: proc(s:^Session,game:u32) {
    st:=collab_state(s)
    if st==nil || st.role!=.Host || st.phase!=.Joined {return}
    collab_edits_send(s,st)
    w:serial.Writer
    collab_begin(&w,.Play_Mark,8)
    serial.write_scalar(&w,game)
    collab_broadcast(st,serial.writer_bytes(&w))
}

// A guest at the mark: its document is the scene of the server of the host
// when nothing of its own is waiting to be confirmed.
@(private)
collab_play_copy :: proc(s:^Session,st:^Collab_State,game:u32) {
    st.play_serial,st.play_copied=game,false
    if st.phase!=.Joined || collab_snapshot_loading(st) || st.sent_edits!=st.echoed_edits || s.edits.open || s.edits.preview || s.edits.commit {return}
    if collab_unsent(s,st) {return}
    st.play_copied=document_write(s,play_copy_file(s,PLAY_HOST_SCENE),false)==.None
}

// The copy of the scene of a game of the host: true when it is in its file;
// otherwise it is asked for, and Play_Provider.scene_arrived says when it is.
collab_play_scene :: proc(s:^Session,game:u32) -> bool {
    st:=collab_state(s)
    if st==nil || st.role!=.Guest || st.phase!=.Joined {return false}
    if st.play_serial==game && st.play_copied {return true}
    w:serial.Writer
    collab_begin(&w,.Play_Scene_Request,8)
    serial.write_scalar(&w,game)
    collab_queue(&st.peers[0],serial.writer_bytes(&w))
    return false
}

// The host sends the file its server runs, when the game is still that one.
@(private)
collab_play_scene_send :: proc(s:^Session,st:^Collab_State,peer:^Collab_Peer,game:u32) {
    p:=providers(s)
    if !p.plays || p.play.game==nil || game==0 || p.play.game(s)!=game {return}
    data,error:=os.read_entire_file(play_copy_file(s,PLAY_SCENE),context.temp_allocator)
    if error!=nil {return}
    collab_chunks_queue(peer,.Play_Scene,data,game)
}

@(private)
collab_play_scene_take :: proc(s:^Session,st:^Collab_State,r:^serial.Reader) {
    game,complete:=collab_chunk_take(r,&st.play_bytes,&st.play_total)
    if !complete {return}
    defer clear(&st.play_bytes)
    file:=play_copy_file(s,PLAY_HOST_SCENE)
    if os.write_entire_file(file,st.play_bytes[:])!=nil {return}
    st.play_serial,st.play_copied=game,true
    if p:=providers(s);p.plays && p.play.scene_arrived!=nil {p.play.scene_arrived(s,game)}
}
