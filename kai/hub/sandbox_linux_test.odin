#+build linux
package hub

import "core:encoding/endian"
import "core:sys/linux"
import "core:testing"

// The seccomp program lets through the calls the node makes, and refuses
// kill, an executable mapping, a signal to another process's threads, a call
// it does not make and another architecture's calls: run here as the kernel
// runs it, on the seccomp_data of each call.
@(test)
hub_seccomp_program_refuses_what_the_node_does_not_do :: proc(t:^testing.T) {
    PID :: 4242
    program:=seccomp_program(PID)
    run :: proc(program:[]Sock_Filter,nr:uintptr,args:[6]u64={},arch:=u32(0)) -> u32 {
        data:[64]u8
        endian.put_u32(data[0:],.Little,u32(nr))
        endian.put_u32(data[4:],.Little,arch!=0?arch:(0xC00000B7 when ODIN_ARCH==.arm64 else 0xC000003E))
        for a,i in args {endian.put_u64(data[16+8*i:],.Little,a)}
        accumulator:u32
        for pc:=0;pc<len(program); {
            f:=program[pc]
            switch f.code {
            case 0x20: accumulator,_=endian.get_u32(data[f.k:],.Little)
            case 0x15: pc+=int(accumulator==f.k?f.jt:f.jf)
            case 0x45: pc+=int(accumulator&f.k!=0?f.jt:f.jf)
            case 0x06: return f.k
            case: return 0xffffffff
            }
            pc+=1
        }
        return 0xffffffff
    }
    ALLOW :: 0x7fff0000
    EPERM :: 0x00050001
    Case :: struct {name:string,nr:uintptr,args:[6]u64,arch:u32,want:u32}
    cases:=[]Case{
        {"read",linux.SYS_read,{},0,ALLOW},
        {"sendto",linux.SYS_sendto,{},0,ALLOW},
        {"kill",linux.SYS_kill,{PID,9,0,0,0,0},0,EPERM},
        {"tgkill to its own thread",linux.SYS_tgkill,{PID,PID+1,6,0,0,0},0,ALLOW},
        {"tgkill to another process",linux.SYS_tgkill,{PID+7,PID+8,9,0,0,0},0,EPERM},
        {"mmap read and write",linux.SYS_mmap,{0,4096,3,0x22,0,0},0,ALLOW},
        {"mmap executable",linux.SYS_mmap,{0,4096,5,0x22,0,0},0,EPERM},
        {"mprotect executable",linux.SYS_mprotect,{0x1000,4096,4,0,0,0},0,EPERM},
        {"mprotect read",linux.SYS_mprotect,{0x1000,4096,1,0,0,0},0,ALLOW},
        {"execve",linux.SYS_execve,{},0,EPERM},
        {"ptrace",linux.SYS_ptrace,{},0,EPERM},
        {"read of another architecture",linux.SYS_read,{},0x40000003,EPERM},
    }
    for c in cases {
        got:=run(program[:],c.nr,c.args,c.arch)
        testing.expectf(t,got==c.want,"%s: %x, want %x",c.name,got,c.want)
    }
}
