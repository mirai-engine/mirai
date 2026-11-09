package platform

// The memory this process holds, in bytes, as its system counts it: resident,
// the pages in physical memory (the working set, with what is shared with
// other processes); private, what only this process uses and the system has
// to back (Windows: the private commit; Linux: the anonymous resident pages
// and the swapped ones; macOS: the physical footprint). Zeros when the system
// does not say. Reading it allocates nothing.
Process_Memory :: struct {resident,private:u64}
