package host

import "core:strings"
import "core:testing"

// --frames, --input and --capture run without a window unless --show-window
// asks for one, and the options that do not go together say so; a server is
// not given a --headless it does not go with.
@(test)
automation_options_imply_no_window_and_what_cannot_combine_says_so :: proc(t:^testing.T) {
    for c in ([]struct{args:[]string,headless:bool,says:string}{
        {{"--frames","3"},true,""},
        {{"--input","run.txt"},true,""},
        {{"--capture","a.png"},true,""},
        {{},false,""},
        {{"--scene","a.scene"},false,""},
        {{"--frames","3","--show-window"},false,""},
        {{"--frames","3","--show-window","--window","10,20,640,360"},false,""},
        {{"--window","10,20,640,360"},false,""},
        {{"--dedicated","--frames","3"},false,""},
        {{"--no-gpu","--frames","3"},true,""},
        {{"--surface","640,360,1","--frames","3"},true,""},
        {{"--frames","3","--window","10,20,640,360"},false,"--show-window"},
        {{"--show-window","--headless"},false,"--show-window"},
        {{"--show-window","--no-gpu"},false,"--show-window"},
        {{"--show-window","--surface","640,360,1"},false,"--show-window"},
        {{"--dedicated","--show-window"},false,"--dedicated"},
        {{"--dedicated","--headless"},false,"--dedicated"},
        {{"--dedicated","--capture","a.png"},false,"--dedicated"},
    }) {
        options,ok:=player_options(c.args)
        defer delete(options.arguments)
        testing.expectf(t,ok,"%v is read",c.args)
        problem:=player_options_settle(&options)
        if c.says=="" {
            testing.expectf(t,problem=="" && options.headless==c.headless,"%v: %q, headless %v",c.args,problem,options.headless)
        } else {
            testing.expectf(t,problem!="" && strings.contains(problem,c.says),"%v: %q",c.args,problem)
        }
    }
    _,ok:=player_options({"--frames","0"})
    testing.expect(t,!ok,"a number of frames below 1 is not understood")
}
