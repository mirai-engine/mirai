package scene

import "core:testing"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"

// The scene the player was launched with is asked once per world; one that
// does not load ends the player, and every request that fails leaves its
// result and a problem that says how to fix it.
@(test)
a_scene_that_does_not_load_leaves_its_result_and_a_problem :: proc(t:^testing.T) {
    app:host.App
    app.launch.scene="scenes/missing.scene"
    requests:Scene_Requests
    results:Scene_Results
    launch:Scene_Launch
    problems:core.Problems
    defer delete(requests.queue.items)
    defer delete(results.queue.items)

    scene_requests({},&app,&requests,&results,&launch,nil,nil,{},&problems)
    testing.expect(t,launch.taken)
    testing.expect_value(t,app.exit_code,host.PLAYER_SCENE)
    result,found:=result_of(&results,{},"scenes/missing.scene")
    testing.expect(t,found)
    testing.expect_value(t,result.error,Error.No_Assets)
    testing.expect_value(t,problems.count,1)

    app.quit,app.exit_code=false,0
    request(&requests,base.Asset_Id{1,2})
    scene_requests({},&app,&requests,&results,&launch,nil,nil,{},&problems)
    testing.expect_value(t,len(results.queue.items),1)
    testing.expect(t,!app.quit)
    by_id,_:=result_of(&results,base.Asset_Id{1,2})
    testing.expect_value(t,by_id.error,Error.No_Assets)

    scene_requests({},&app,&requests,&results,&launch,nil,nil,{},&problems)
    testing.expect_value(t,len(results.queue.items),0)
}

// A path that names nothing is served like any other: nothing is lost in
// silence, its result and a problem say what happened.
@(test)
a_path_that_does_not_fit_or_is_empty_is_a_problem :: proc(t:^testing.T) {
    app:host.App
    requests:Scene_Requests
    results:Scene_Results
    launch:Scene_Launch
    problems:core.Problems
    defer delete(requests.queue.items)
    defer delete(results.queue.items)
    long:[SCENE_PATH_CAPACITY]u8
    for &c in long {c='a'}
    request_path(&requests,string(long[:]))
    request_path(&requests,"")
    for _ in 1..=2 {
        scene_requests({},&app,&requests,&results,&launch,nil,nil,{},&problems)
        testing.expect_value(t,len(results.queue.items),1)
        testing.expect(t,results.queue.items[0].error!=.None)
    }
    testing.expect(t,core.problem_find(&problems,core.NONE,"scene.load")!=nil)
}

// A restart loads the scene the world is at that moment; a world that came
// from no scene has none to load, and a problem says how to give it one.
@(test)
a_restart_asks_for_the_scene_the_world_is :: proc(t:^testing.T) {
    app:host.App
    requests:Scene_Requests
    results:Scene_Results
    launch:Scene_Launch
    problems:core.Problems
    root:Scene_Root
    defer delete(requests.queue.items)
    defer delete(results.queue.items)
    request_restart(&requests)
    scene_requests({},&app,&requests,&results,&launch,nil,nil,core.ref(&root),&problems)
    testing.expect_value(t,results.queue.items[0].error,Error.Not_Found)
    testing.expect(t,core.problem_find(&problems,core.NONE,"scene.restart")!=nil)

    root.scene=base.Asset_Id{3,4}
    request_restart(&requests)
    scene_requests({},&app,&requests,&results,&launch,nil,nil,core.ref(&root),&problems)
    result,found:=result_of(&results,base.Asset_Id{3,4})
    testing.expect(t,found)
    testing.expect_value(t,result.error,Error.No_Assets)
}
