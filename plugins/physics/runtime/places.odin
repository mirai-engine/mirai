package physics

import "mirai:core"

// What core.place asks of an entity whose Transform this library owns becomes
// a teleport of its body, applied by the step with the other requests. The
// rest stays for core.places_drop. A place asked after this function waits for
// the next tick.
@(step="fixed",loops="game editor",stage="simulate",after="physics_prepare")
physics_places :: proc(places:^core.Places,requests:^Body_Requests,state:core.Ref(Physics_State),rigids:^core.Table(Rigid_Body,.Read),characters:^core.Table(Character,.Read)) {
    asked:=core.take(&places.queue)
    left:=0
    for request in asked {
        e:=request.entity
        l:=state.ready?link_find(state.ptr,e):nil
        if core.has(rigids,e) || core.has(characters,e) || l!=nil && l.kind==.Proxy {
            core.push(&requests.queue,Body_Request{entity=e,kind=.Teleport,position=request.position,rotation=request.rotation})
            if request.at_rest {core.push(&requests.queue,Body_Request{entity=e,kind=.Velocity})}
        } else {
            asked[left]=request
            left+=1
        }
    }
    for request in asked[:left] {core.push(&places.queue,request)}
}
