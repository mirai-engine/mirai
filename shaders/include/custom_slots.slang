// The bindings of the slots of a custom pass of a render pipeline
// (render.CUSTOM_PASS_BINDINGS): the first ten are SLOT_PASS0 to SLOT_PASS9,
// the rest those of the tables of the scene, which a pass that binds them
// does not read. Only defines, so that HLSL of other sources can name them in
// its registers.
#ifndef MIRAI_CUSTOM_SLOTS_SLANG
#define MIRAI_CUSTOM_SLOTS_SLANG

#define CUSTOM_SLOT_0 19
#define CUSTOM_SLOT_1 20
#define CUSTOM_SLOT_2 21
#define CUSTOM_SLOT_3 22
#define CUSTOM_SLOT_4 23
#define CUSTOM_SLOT_5 24
#define CUSTOM_SLOT_6 25
#define CUSTOM_SLOT_7 26
#define CUSTOM_SLOT_8 27
#define CUSTOM_SLOT_9 28
#define CUSTOM_SLOT_10 4
#define CUSTOM_SLOT_11 5
#define CUSTOM_SLOT_12 6
#define CUSTOM_SLOT_13 7
#define CUSTOM_SLOT_14 8
#define CUSTOM_SLOT_15 9
#define CUSTOM_SLOT_16 10
#define CUSTOM_SLOT_17 11
#define CUSTOM_SLOT_18 12
#define CUSTOM_SLOT_19 13
#define CUSTOM_SLOT_20 14
#define CUSTOM_SLOT_21 16
#define CUSTOM_SLOT_22 17
#define CUSTOM_SLOT_23 18

#endif
