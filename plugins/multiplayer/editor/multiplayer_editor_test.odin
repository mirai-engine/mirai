package multiplayer_editor

import "core:testing"
import "mirai:core"
import wire "mirai:net"
import "mirai:std/base"
import multiplayer "plugins:multiplayer/runtime"

// The code play.network.status returns is the whole code: it decodes to the invitation of the server.
@(test)
the_code_play_network_status_returns_reads_as_the_invitation :: proc(t:^testing.T) {
    key,made:=wire.invite_key()
    if !testing.expect(t,made) {return}
    invitation:=wire.Invitation{lan=wire.address_ip4(192,168,1,2,27500),public=wire.address_ip4(203,0,113,9,27500),key={public=key.public,secret=key.secret}}
    r:Api_Network_Result
    testing.expect(t,base.text_set(r.invite[:],wire.invite_encode(invitation,context.temp_allocator)))
    got,refused:=wire.invite_decode(base.text_get(r.invite[:]))
    testing.expect(t,refused==.None && got==invitation)
}

// play.network.status reads the session of the run of the call: none plays locally, a server
// shows no prediction, and a client its counters and its newest corrections first, a component
// by its name.
@(test)
play_network_status_says_how_the_run_predicts_and_corrects :: proc(t:^testing.T) {
    info:=core.World_Info{tables=[]core.Table_Info{{name="Transform"},{name="Health"}}}
    w:=core.World_Ref{info=&info}
    Case :: struct {session:bool,status:multiplayer.Status,mode:wire.Mode,notes:int,role:Api_Network_Role,fields:[]string}
    cases:=[]Case{
        {role=.Local},
        {session=true,role=.Local},
        {session=true,status=.Connected,mode=.Server,role=.Server},
        {session=true,status=.Connected,mode=.Client,notes=2,role=.Client,fields={"Health","Position"}},
        {session=true,status=.Disconnected,mode=.Client,notes=multiplayer.CORRECTIONS_KEPT+3,role=.Client},
    }
    for c,index in cases {
        session:=new(multiplayer.Net_Session)
        defer free(session)
        session.status,session.mode=c.status,c.mode
        session.stats.corrected,session.stats.resimulated,session.stats.largest_resimulation=u64(min(c.notes,1)),u64(3*min(c.notes,1)),3*min(c.notes,1)
        d:=&session.diagnostics
        for k in 0..<c.notes {
            component:=k%2==1
            d.corrections[k%multiplayer.CORRECTIONS_KEPT]={tick=u32(40+k),entity=core.Entity(7),field=component?.Component:.Position,table=component?1:-1,magnitude=0.25}
            d.correction_count+=1
        }
        if c.notes>0 {
            d.resimulations[0]={from=41,to=43,ticks=3}
            d.resimulation_count=1
        }
        r:Api_Network_Run
        api_network_run(&r,w,c.session?session:nil,context.temp_allocator)
        testing.expectf(t,r.role==c.role && r.status==(c.session?c.status:.Offline),"case %d: %v %v",index,r.role,r.status)
        testing.expectf(t,len(r.links)==0,"case %d: %d links without a host",index,len(r.links))
        testing.expectf(t,r.corrections==u64(c.notes) && len(r.recent_corrections)==min(c.notes,multiplayer.CORRECTIONS_KEPT),"case %d: %d corrections, %d recent",index,r.corrections,len(r.recent_corrections))
        testing.expectf(t,r.rollbacks==u64(min(c.notes,1)) && len(r.recent_resimulations)==min(c.notes,1),"case %d: %d rollbacks",index,r.rollbacks)
        if len(r.recent_corrections)>0 {
            newest:=r.recent_corrections[0]
            testing.expectf(t,newest.tick==u32(40+c.notes-1) && newest.entity==core.Entity(7) && newest.magnitude==0.25,"case %d: %v",index,newest)
        }
        for field,k in c.fields {testing.expectf(t,r.recent_corrections[k].field==field,"case %d: field %d is %s",index,k,r.recent_corrections[k].field)}
        if len(r.recent_resimulations)>0 {testing.expect(t,r.recent_resimulations[0]==Api_Network_Resimulation{from=41,to=43,ticks=3})}
    }
}
