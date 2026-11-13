package importer

import "core:fmt"
import "core:io"
import "core:time"

// What an import says of how far it is while it runs, for a sync to print
// under the line of its source: the assets it wrote, of those its sidecar
// listed (what the previous import gave), and how long it has run; a line at
// most every PROGRESS_EVERY. The caller owns it; the thread that writes the
// import updates it.
Progress :: struct {
    out:io.Writer,
    source:string, // as the lines name it
    started,said:time.Tick,
    written:int,
}

PROGRESS_EVERY :: 5*time.Second

progress_begin :: proc(p:^Progress,out:io.Writer,source:string) {
    now:=time.tick_now()
    p^={out=out,source=source,started=now,said=now}
}

// One more asset written, of expected (0 when not known).
@(private)
progress_written :: proc(p:^Progress,expected:int) {
    if p==nil || p.out.procedure==nil {return}
    p.written+=1
    if time.tick_since(p.said)<PROGRESS_EVERY {return}
    p.said=time.tick_now()
    seconds:=time.duration_seconds(time.tick_since(p.started))
    if expected>=p.written {
        fmt.wprintfln(p.out,"  %s: %d of %d assets written, %.0f s",p.source,p.written,expected,seconds)
    } else {
        fmt.wprintfln(p.out,"  %s: %d assets written, %.0f s",p.source,p.written,seconds)
    }
}
