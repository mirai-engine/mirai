package main

import "core:fmt"
import "core:os"
import "mirai:kai/hub"

// mirai-kai: the headless Kai server, with only what a server needs (no SDL,
// GPU, audio or editor code), so it links statically for a small Linux
// server: `mirai build kai --target linux_arm64`. It runs what `mirai kai
// serve` runs.

PROGRAM :: "mirai-kai"

main :: proc() {
    args:=os.args[1:]
    if len(args)>0 && args[0]=="kai" {args=args[1:]}
    code:=2
    if len(args)>=1 && args[0]=="serve" {
        code=hub.serve_command(PROGRAM,args[1:])
    } else {
        fmt.eprintfln("Usage: %s %s",PROGRAM,hub.SERVE_USAGE)
    }
    os.exit(code)
}
