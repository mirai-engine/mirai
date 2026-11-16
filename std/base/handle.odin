package base

// Generational handle: slot index in the low 32 bits, generation in the high 32. Zero is null.
Handle :: distinct u64

handle_make :: #force_inline proc "contextless" (index,generation:u32) -> Handle {return Handle(u64(generation)<<32|u64(index))}
handle_index :: #force_inline proc "contextless" (h:Handle) -> u32 {return u32(h)}
handle_generation :: #force_inline proc "contextless" (h:Handle) -> u32 {return u32(u64(h)>>32)}
