package mirai_render

import "core:testing"

// A local view runs the effects of its slot; any other view, those of the frame.
@(test)
each_local_view_runs_the_effects_of_its_slot :: proc(t:^testing.T) {
    r:=new(Renderer);defer free(r)
    frame:=Postprocess_Desc{program=1,enabled=true}
    second:=Postprocess_Desc{program=2,enabled=true,after_tonemap=true}
    testing.expect(t,renderer_set_postprocesses(r,{count=1,entries={0=frame}}))
    testing.expect(t,renderer_set_view_postprocesses(r,1,{count=1,entries={0=second}}))
    testing.expect(t,!renderer_set_view_postprocesses(r,VIEW_CAPACITY,{}) && !renderer_set_view_postprocesses(r,0,{count=POSTPROCESS_CAPACITY+1}))
    p:=Pass{r=r}
    testing.expect(t,postprocess_active(&p,false) && !postprocess_active(&p,true),"the view of the frame")
    p.camera.slot=2
    testing.expect(t,!postprocess_active(&p,false) && postprocess_active(&p,true),"the second player")
    p.camera.slot=1
    testing.expect(t,!postprocess_active(&p,false) && !postprocess_active(&p,true),"the first player has none of its own")
}
