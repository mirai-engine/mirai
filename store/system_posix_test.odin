#+build darwin, linux
package store

import "core:sys/posix"
import "core:testing"
import "mirai:std/base"

// A process a shell handed few open files opens a store with the limit the
// system allows: a value holds a descriptor per pack it loaded.
@(test)
opening_a_store_raises_the_limit_of_open_files :: proc(t:^testing.T) {
    FEW :: 4096
    limit:posix.rlimit
    if !testing.expect(t,posix.getrlimit(.NOFILE,&limit)==.OK) {return}
    if limit.rlim_max<=FEW {return}
    few:=posix.rlimit{rlim_cur=FEW,rlim_max=limit.rlim_max}
    if !testing.expect(t,posix.setrlimit(.NOFILE,&few)==.OK) {return}
    folder:=base.test_folder(t,"store-files-limit");if folder=="" {return}
    s,error:=open(folder)
    if !testing.expect_value(t,error,Error.None) {return}
    defer close(&s)
    raised:posix.rlimit
    testing.expect(t,posix.getrlimit(.NOFILE,&raised)==.OK && raised.rlim_cur>FEW && raised.rlim_max==limit.rlim_max,"the soft limit is raised and the hard one kept")
}
