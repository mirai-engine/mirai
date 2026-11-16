package editor

import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:host"

@(test)
player_processes_run_the_game_of_the_library_of_the_editor :: proc(t:^testing.T) {
    app:host.App
    app.density=1
    gui:Editor_Ui
    processes:Player_Processes
    s:=Session{app=&app,gui=&gui,processes=&processes,project_root="/game"}
    player_processes_reserve(&s,1,2)
    for embedded in ([2]bool{false,true}) {
        processes.embedded=embedded
        command:=player_process_command(&s,"mirai-player",{"--connect","code"},1,{0,0,1920,1080},true)
        // Attached to this editor, before the arguments of the plugin.
        testing.expect(t,slice.equal(command[:4],[]string{"mirai-player","--attached","--connect","code"}),strings.join(command," ",context.temp_allocator))
        testing.expect(t,slice.contains(command,embedded?"--surface":"--window"),strings.join(command," ",context.temp_allocator))
    }
    testing.expect(t,processes.processes[1].asked.x>0,"a surfaced process is told the pixels of its tile")
}
