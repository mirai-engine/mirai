#+build linux
package hub

import "base:intrinsics"
import "core:strings"
import "core:sys/linux"

// The confinement of a node on Linux, once its sockets are open: Landlock
// lets it touch only the folder of its store (the device's keys and the web
// certificates live there), read the files the resolver of ACME reads and,
// where the kernel's Landlock has network rules, bind and connect TCP only on
// the ports the node uses; seccomp lets through only the system calls the
// node makes, signals only to its own threads and maps nothing executable,
// any other call failing with EPERM. A kernel without them refuses the
// sandbox, and serve says why.

@(private="file") LANDLOCK_CREATE_RULESET_VERSION :: 1
@(private="file") LANDLOCK_RULE_PATH_BENEATH :: 1
@(private="file") LANDLOCK_RULE_NET_PORT :: 2
@(private="file") ACCESS_NET_BIND_TCP :: u64(1)
@(private="file") ACCESS_NET_CONNECT_TCP :: u64(2)
@(private="file") PROT_EXEC :: 4
@(private="file") PR_SET_NO_NEW_PRIVS :: 38
@(private="file") PR_SET_SECCOMP :: 22
@(private="file") SECCOMP_MODE_FILTER :: 2
@(private="file") SECCOMP_RET_ALLOW :: 0x7fff0000
@(private="file") SECCOMP_RET_EPERM :: 0x00050000|1
@(private="file") READ_FILE :: u64(1)<<2
@(private="file") AUDIT_ARCH :: u32(0xC00000B7) when ODIN_ARCH==.arm64 else u32(0xC000003E)

@(private="file")
Ruleset_Attr :: struct {handled_access_fs,handled_access_net:u64}

@(private="file")
Path_Beneath :: struct #packed {allowed_access:u64,parent_fd:i32}

@(private="file")
Net_Port :: struct {allowed_access,port:u64}

Sock_Filter :: struct {code:u16,jt,jf:u8,k:u32}

@(private="file")
Sock_Fprog :: struct {len:u16,filter:[^]Sock_Filter}

@(private="file")
ALLOWED :: [?]uintptr{
    linux.SYS_read,linux.SYS_write,linux.SYS_readv,linux.SYS_writev,linux.SYS_pread64,linux.SYS_pwrite64,
    linux.SYS_openat,linux.SYS_close,linux.SYS_lseek,linux.SYS_fstat,linux.SYS_statx,linux.SYS_getdents64,
    linux.SYS_mkdirat,linux.SYS_unlinkat,linux.SYS_renameat,linux.SYS_renameat2,linux.SYS_ftruncate,linux.SYS_fallocate,
    linux.SYS_fsync,linux.SYS_fdatasync,linux.SYS_flock,linux.SYS_fcntl,linux.SYS_ioctl,linux.SYS_fstatfs,linux.SYS_statfs,
    linux.SYS_munmap,linux.SYS_mremap,linux.SYS_madvise,linux.SYS_brk,linux.SYS_membarrier,
    linux.SYS_futex,linux.SYS_set_robust_list,linux.SYS_rseq,linux.SYS_set_tid_address,linux.SYS_clone,linux.SYS_clone3,
    linux.SYS_exit,linux.SYS_exit_group,linux.SYS_gettid,linux.SYS_getpid,
    linux.SYS_rt_sigaction,linux.SYS_rt_sigprocmask,linux.SYS_rt_sigreturn,linux.SYS_sigaltstack,linux.SYS_restart_syscall,
    linux.SYS_sched_yield,linux.SYS_sched_getaffinity,linux.SYS_nanosleep,linux.SYS_clock_nanosleep,
    linux.SYS_clock_gettime,linux.SYS_clock_getres,linux.SYS_gettimeofday,linux.SYS_getrandom,
    linux.SYS_socket,linux.SYS_bind,linux.SYS_listen,linux.SYS_accept4,linux.SYS_connect,linux.SYS_getsockname,
    linux.SYS_getpeername,linux.SYS_setsockopt,linux.SYS_getsockopt,linux.SYS_sendto,linux.SYS_recvfrom,
    linux.SYS_sendmsg,linux.SYS_recvmsg,linux.SYS_sendmmsg,linux.SYS_recvmmsg,linux.SYS_shutdown,
    linux.SYS_ppoll,linux.SYS_pselect6,linux.SYS_epoll_create1,linux.SYS_epoll_ctl,linux.SYS_epoll_pwait,
    linux.SYS_uname,linux.SYS_getuid,linux.SYS_geteuid,linux.SYS_getgid,linux.SYS_getegid,linux.SYS_prlimit64,
    linux.SYS_umask,linux.SYS_fchmod,linux.SYS_fchmodat,linux.SYS_utimensat,linux.SYS_faccessat,linux.SYS_faccessat2,
    linux.SYS_readlinkat,linux.SYS_getcwd,linux.SYS_dup,linux.SYS_dup3,linux.SYS_pipe2,linux.SYS_sysinfo,
}

when ODIN_ARCH==.amd64 {
    @(private="file")
    ALLOWED_ARCH :: [?]uintptr{
        linux.SYS_newfstatat,linux.SYS_open,linux.SYS_stat,linux.SYS_lstat,linux.SYS_poll,linux.SYS_access,linux.SYS_pipe,
        linux.SYS_dup2,linux.SYS_rename,linux.SYS_unlink,linux.SYS_mkdir,linux.SYS_rmdir,linux.SYS_readlink,
        linux.SYS_arch_prctl,linux.SYS_getdents,linux.SYS_select,linux.SYS_time,linux.SYS_accept,linux.SYS_epoll_wait,
        linux.SYS_getrlimit,
    }
} else {
    @(private="file")
    ALLOWED_ARCH :: [?]uintptr{linux.SYS_fstatat}
}

// Confines the process to the store's folder, the TCP ports it binds and
// connects to, and the system calls it uses.
sandbox_apply :: proc(store_root:string,ports:Sandbox_Ports) -> (applied:bool,why:string) {
    abi:=int(intrinsics.syscall(linux.SYS_landlock_create_ruleset,0,0,LANDLOCK_CREATE_RULESET_VERSION))
    if abi<1 || abi>4096 {return false,"the kernel has no Landlock"}
    handled:=u64(1)<<13-1 // ABI 1: execute to make_sym
    if abi>=2 {handled|=1<<13} // refer
    if abi>=3 {handled|=1<<14} // truncate
    if abi>=5 {handled|=1<<15} // ioctl_dev
    attr:=Ruleset_Attr{handled_access_fs=handled}
    attr_size:=size_of(u64)
    if abi>=4 {
        attr.handled_access_net=ACCESS_NET_BIND_TCP|ACCESS_NET_CONNECT_TCP
        attr_size=size_of(Ruleset_Attr)
    }
    ruleset:=int(intrinsics.syscall(linux.SYS_landlock_create_ruleset,uintptr(&attr),uintptr(attr_size),0))
    if ruleset<0 {return false,"Landlock refused the ruleset"}
    defer linux.close(linux.Fd(ruleset))
    executable:=u64(1)
    if !path_rule(ruleset,store_root,handled &~ executable) {return false,"the store's folder does not open for Landlock"}
    for file in ([?]string{"/etc/resolv.conf","/etc/hosts","/etc/nsswitch.conf","/etc/gai.conf"}) {
        path_rule(ruleset,file,READ_FILE)
    }
    if abi>=4 {
        for list,k in ([2][]int{ports.bind,ports.connect}) {
            for port in list {
                if port<=0 || port>65535 {continue}
                rule:=Net_Port{allowed_access=k==0?ACCESS_NET_BIND_TCP:ACCESS_NET_CONNECT_TCP,port=u64(port)}
                if int(intrinsics.syscall(linux.SYS_landlock_add_rule,uintptr(ruleset),LANDLOCK_RULE_NET_PORT,uintptr(&rule),0))!=0 {return false,"Landlock refused a port's rule"}
            }
        }
    }
    if linux.prctl(PR_SET_NO_NEW_PRIVS,1,0,0,0)!=.NONE {return false,"no_new_privs is refused"}
    if int(intrinsics.syscall(linux.SYS_landlock_restrict_self,uintptr(ruleset),0))<0 {return false,"Landlock does not restrict this process"}
    program:=seccomp_program(u32(linux.getpid()))
    prog:=Sock_Fprog{len=u16(len(program)),filter=raw_data(program[:])}
    if linux.prctl(PR_SET_SECCOMP,SECCOMP_MODE_FILTER,uint(uintptr(&prog)),0,0)!=.NONE {return false,"Landlock applies, but the kernel refused the seccomp filter"}
    return true,""
}

@(private="file")
path_rule :: proc(ruleset:int,path:string,access:u64) -> bool {
    fd,e:=linux.open(strings.clone_to_cstring(path,context.temp_allocator),{.PATH,.CLOEXEC})
    if e!=.NONE {return false}
    defer linux.close(fd)
    rule:=Path_Beneath{allowed_access=access,parent_fd=i32(fd)}
    return int(intrinsics.syscall(linux.SYS_landlock_add_rule,uintptr(ruleset),LANDLOCK_RULE_PATH_BENEATH,uintptr(&rule),0))==0
}

SECCOMP_LENGTH :: 6+len(ALLOWED)+len(ALLOWED_ARCH)+7

// The seccomp filter of the node, whose process is pid: the calls it makes,
// mmap and mprotect without PROT_EXEC, tgkill to its own threads; any other
// call, or another architecture's, fails with EPERM.
seccomp_program :: proc(pid:u32) -> (filter:[SECCOMP_LENGTH]Sock_Filter) {
    LD :: 0x20 // BPF_LD|BPF_W|BPF_ABS
    JEQ :: 0x15 // BPF_JMP|BPF_JEQ|BPF_K
    JSET :: 0x45 // BPF_JMP|BPF_JSET|BPF_K
    RET :: 0x06 // BPF_RET|BPF_K
    allowed:=ALLOWED
    arch:=ALLOWED_ARCH
    n:=len(allowed)+len(arch)
    // Past the list, a refusal; then the checks of arguments and the two
    // answers they jump to: BPF jumps only forward.
    prot,signal:=7+n,9+n
    deny,allow:=11+n,12+n
    to :: proc(from,target:int) -> u8 {return u8(target-from-1)}
    filter[0]={LD,0,0,4} // seccomp_data.arch
    filter[1]={JEQ,0,to(1,deny),AUDIT_ARCH}
    filter[2]={LD,0,0,0} // seccomp_data.nr
    filter[3]={JEQ,to(3,prot),0,u32(linux.SYS_mmap)}
    filter[4]={JEQ,to(4,prot),0,u32(linux.SYS_mprotect)}
    filter[5]={JEQ,to(5,signal),0,u32(linux.SYS_tgkill)}
    for i in 0..<n {
        nr:=i<len(allowed)?allowed[i]:arch[i-len(allowed)]
        filter[6+i]={JEQ,to(6+i,allow),0,u32(nr)}
    }
    filter[6+n]={RET,0,0,SECCOMP_RET_EPERM}
    filter[prot]={LD,0,0,16+8*2} // the low word of args[2]: prot
    filter[prot+1]={JSET,to(prot+1,deny),to(prot+1,allow),PROT_EXEC}
    filter[signal]={LD,0,0,16} // the low word of args[0]: the thread group
    filter[signal+1]={JEQ,to(signal+1,allow),to(signal+1,deny),pid}
    filter[deny]={RET,0,0,SECCOMP_RET_EPERM}
    filter[allow]={RET,0,0,SECCOMP_RET_ALLOW}
    return
}
