package editor

import "core:fmt"
import "core:log"
import "mirai:editor/api"

// What the editor offers besides its window: the agent API, the shared
// session and the prefab records of the document. The editor opens them with
// the arguments it was given, serves them once per frame between frames and
// closes them with itself.

// False when the API was asked for and did not open.
@(private)
services_open :: proc(s:^Session,options:Options) -> (api_ok:bool) {
    api_ok=true
    manual:=options.headless && options.frames==0
    if !options.no_api {
        port:=options.api_port>0?options.api_port:api.DEFAULT_PORT
        if options.api_port_any {port=0}
        opened:=api_open(s,port,manual)
        if opened==.Server && options.api_port==0 && !options.api_port_any {
            log.warnf("the API port %d is taken: the system picks another",port)
            opened=api_open(s,0,manual)
        }
        switch opened {
        case .None:      fmt.eprintfln("mirai: API at 127.0.0.1:%d",api_port(s))
        case .Methods:   // api_open already said which
        case .No_Storage, .Server: fmt.eprintln("mirai: the agent API could not open")
        }
        api_ok=opened==.None
    }
    if options.share!=0 {
        if error:=collab_host(s,max(options.share,0),options.name);error!=.None {
            log.errorf("the scene could not be shared: %s",collab_error_text(error))
        }
    } else if options.join!="" {
        if error:=collab_join(s,options.join,options.name,true);error!=.None {
            log.errorf("the session could not be entered: %s",collab_error_text(error))
        }
    }
    return
}

@(private)
services_poll :: proc(s:^Session) {
    collab_update(s)
    api_poll(s)
}

@(private)
services_close :: proc(s:^Session) {
    collab_close(s)
    api_close(s)
    prefabs_free(s)
}
