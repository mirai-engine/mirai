#+build !windows
package build

import "core:os"

@(private)
publish :: proc(staged,published:string,retired:="") -> bool {
    return os.rename(staged,published)==nil
}
