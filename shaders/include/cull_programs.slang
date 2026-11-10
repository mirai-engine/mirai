#ifndef MIRAI_CULL_PROGRAMS_SLANG
#define MIRAI_CULL_PROGRAMS_SLANG
// The visible clusters of materials with a Surface program
// (render.Program_Clusters), in words: of each phase how many the cull listed
// (past the capacity too) and the groups of a pass over them, then, by
// program, the count, cursor and offset of each phase, the draws of each phase
// and program, and the clusters as the cull listed them: the instance, the
// cluster as a word of the index pool and the program. The G-buffer draws
// those of each program from their range of a list of their own.
#include <shared_constants.slang>
#define PROGRAMS_GROUP 64u
uint programs_count(uint phase, uint programs) { return PROGRAMS_HEADER + 3u * phase * programs; }
uint programs_cursor(uint phase, uint programs) { return programs_count(phase, programs) + programs; }
uint programs_offset(uint phase, uint programs) { return programs_count(phase, programs) + 2u * programs; }
uint programs_draw(uint phase, uint program, uint programs) { return PROGRAMS_HEADER + 6u * programs + (phase * programs + program) * 4u; }
uint programs_entry(uint i, uint programs) { return PROGRAMS_HEADER + 14u * programs + i * 3u; }
#endif
