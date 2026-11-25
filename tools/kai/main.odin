package main

import "core:fmt"
import "core:os"
import "mirai:kai/hub"

// mirai-kai: the headless Kai node, with only what a node needs (no SDL,
// GPU, audio or editor code), so it links statically for a small Linux
// server: `mirai build kai --target linux_arm64`. It runs the procedures
// `mirai kai serve` and `mirai kai pair join` run.

PROGRAM :: "mirai-kai"

main :: proc() {
    args:=os.args[1:]
    if len(args)>0 && args[0]=="kai" {args=args[1:]}
    code:=2
    switch {
    case len(args)>=1 && args[0]=="serve": code=hub.serve_command(PROGRAM,args[1:])
    case len(args)>=2 && args[0]=="pair" && args[1]=="join": code=hub.join_command(PROGRAM,args[2:])
    case: fmt.eprintfln("Usage: %s %s\n       %s kai pair join <ticket> --store <folder> [--name N]",PROGRAM,hub.SERVE_USAGE,PROGRAM)
    }
    os.exit(code)
}
