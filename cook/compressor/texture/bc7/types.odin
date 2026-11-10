package bc7

import "core:simd"
import "mirai:asset"
import "mirai:cook/compressor/texture/bc67"
import "mirai:cook/compressor/texture/common"

// Search passes and constraints of the encoder (BC7Flags).
Flags :: u64

IGNORE_ALPHA            :: Flags(0x00000001)
LSQ_FIT                 :: Flags(0x00000002)
PCA_STRETCH             :: Flags(0x00000004)
JITTER_SELECTORS        :: Flags(0x00000008)
ANNEAL_ENDPOINTS        :: Flags(0x00000010)
PCA                     :: Flags(0x00000020)
NO_INITIAL_BBOX         :: Flags(0x00000040) // only the PCA fit, not the bbox one
EXTRAPOLATE_SELECTORS   :: Flags(0x00000080)
SCALE_SELECTORS         :: Flags(0x00000100)
MODE4_ISB1_ONLY         :: Flags(0x00000200)
BRUTE_PBITS             :: Flags(0x00000800)
IDXS_EXACT              :: Flags(0x00002000)
PCA_TRY_HARD            :: Flags(0x00010000)
SLIDE_SELECTORS         :: Flags(0x00020000)
BRUTE_PBITS_IDXS_EXACT  :: Flags(0x00080000)
SEPARATE_ALPHA          :: Flags(0x00100000)
PRESERVE_A0             :: Flags(0x00400000)
PRESERVE_A255           :: Flags(0x00800000)
PRESERVE_EXTREMES       :: PRESERVE_A0|PRESERVE_A255
AEP0_LO                 :: Flags(0x01000000) // alpha endpoint 0 must be the low one
AEP0_HI                 :: Flags(0x02000000)
AEP0_CONSTRAINED        :: AEP0_LO|AEP0_HI
DISABLE_MODE0123        :: Flags(0x04000000)
DISABLE_MODE67          :: Flags(0x08000000)
INDEX_MASK              :: IDXS_EXACT
RETAIN_MASK             :: IGNORE_ALPHA|INDEX_MASK|SEPARATE_ALPHA|PRESERVE_EXTREMES
RANDOMIZED_MASK         :: JITTER_SELECTORS|ANNEAL_ENDPOINTS
ALL_PCA                 :: PCA|PCA_STRETCH

// Sum of squared differences.
Error :: u32
ERROR_MAX :: max(u32)

// Fields of each mode, indexed by mode.
MODE_NS  :: [8]int{3,2,3,2,1,1,1,2}
MODE_PB  :: [8]int{4,6,6,6,0,0,0,6}
MODE_RB  :: [8]int{0,0,0,0,2,2,0,0}
MODE_ISB :: [8]int{0,0,0,0,1,0,0,0}
MODE_CB  :: [8]int{4,6,5,7,5,7,7,5}
MODE_AB  :: [8]int{0,0,0,0,6,8,7,5}
MODE_EPB :: [8]int{1,0,0,1,0,0,1,1}
MODE_SPB :: [8]int{0,1,0,0,0,0,0,0}
MODE_IB  :: [8]int{3,3,2,2,2,2,4,2}
MODE_IB2 :: [8]int{0,0,0,0,3,2,0,0}

// Squared-error bias per mode added when choosing between candidate blocks;
// ERROR_MAX disables the mode.
Mode_Err_Bias :: struct {
    ssd_err_bias:[8]u32,
}

// The search of one effort (BC7EncOptions).
Enc_Options :: struct {
    enable_mode:[8]bool,
    partition_lsq_iters:int, // LSQ passes of the initial trials
    nbest_part2:int,         // 2-subset partitions kept for the trials (at most NBEST)
    nbest_part3:int,
    narrow0:int,             // candidates kept after the trials
    narrow2:int,             // candidates kept after the LSQ refinement
    max_lsq_iter:int,
    max_pca_stretch_passes:int,
    optiters_early:[2]int,   // jitter and anneal iterations of the narrow2 candidates
    optiters_late:[2]int,    // of the final candidate
    alpha_weight:int,
    forced_mode:int,         // -1: free; a mode with partitions also needs forced_partition
    forced_partition:int,
    subsets:^bc67.Subset_Collection,
    err_threshold_for_subset3:f32, // below this worst 2-subset error, 3 subsets are not tried
    flags:Flags,
}

enc_options_default :: proc "contextless" () -> Enc_Options {
    return {
        enable_mode={true,true,true,true,true,true,true,true},
        partition_lsq_iters=2,
        nbest_part2=8, nbest_part3=8,
        narrow0=32, narrow2=4,
        max_lsq_iter=4, max_pca_stretch_passes=4,
        alpha_weight=1,
        forced_mode=-1, forced_partition=-1,
    }
}

Color :: [4]u8

Partition_Info :: struct {
    bbox:[3][2]Color, // [subset][lo,hi]
}

Partition_Choice :: struct {
    mode,partition:u8,
    subsets:[3]u8,
}

NBEST :: 8

Partition_Ranking :: struct {
    best_part2:[NBEST]Partition_Choice,
    best_part3:[NBEST]Partition_Choice,
    num_part2,num_part3:int,
    pca_subset1:[3]u8, // subset ids of the 1-subset cases
}

// What the encoder knows of a block before choosing modes.
Prep :: struct {
    info_1sub:Partition_Info,
    local_block:[16]Color,
    single_color:bool,
    has_alpha:bool,
    rand_seed:u64,
    max_ns:int,
    analysis_initialized:bool,
    ranking:Partition_Ranking,
    analysis:Subset_Analysis,
}

// The texels of a block gathered subset by subset, with the channel rotation
// applied; 8 zero texels pad it for reads past the last subset.
Block_Input :: struct {
    pixels:[24]Color,
}

// One subset of a Block_Input (which must outlive it).
Subset_Input :: struct {
    pixels:[^]Color,
    num_pixels:int,
    rcp_num_pixels:f32,
    channel_weights:[4]u16, // in the channel order of pixels
}

Input :: struct {
    block:Block_Input,
    subsets:[3]Subset_Input,
}

Subset_State :: struct #align(16) {
    idxs:[2][16]u8,       // [vector,scalar] in subset order
    endpoints:[2]Color,   // the endpoints a solve wants, maybe not representable
    endpoints_q:[2]Color, // quantized with pbits; A forced to 255 when alpha is ignored
    err:Error,
    scalar_err:Error,     // of the scalar channel in modes 4 and 5
    pbits:u8,
    isbit:u8,
    rbit:u8,
    pca_subset:u8,        // 1-based analysis subset; 0 none
    _pad:u32,
}

Block_State :: struct #align(16) {
    subsets:[3]Subset_State,
    err:Error,
    mode,p:u8,
    _pad:[10]u8,
}

// For every texel, the error of each index value.
Index_Errors :: struct #align(16) {
    err:[16][16]Error,
}

Endpoint_Coeff_Cache :: struct {
    entry:[3][4]f32, // {iata11,-iata10,iata00,_} per subset, or per index set of a 1-subset mode
}

Block_And_Input :: struct {
    state:Block_State,
    input:Input,
}

// RGBA lerp of the index weights of ib bits.
@(private)
lerp_factor :: #force_inline proc "contextless" (ib,i:int) -> int {
    return int(asset.BC7_WEIGHTS[ib&7][i&15])
}

// cvtss2si: nearest, ties to even; NaN and out of range give min(i32).
@(private)
round_to_int :: #force_inline proc "contextless" (x:f32) -> i32 {
    return common.round_to_int(x)
}

@(private)
clamp_u8 :: #force_inline proc "contextless" (x:i32) -> u8 {
    return u8(x<0 ? 0 : (x>255 ? 255 : x))
}

@(private)
round_and_clamp_u8 :: #force_inline proc "contextless" (f:f32) -> u8 {
    return clamp_u8(round_to_int(f))
}

// packssdw then packuswb of one value.
@(private)
sat_u8 :: #force_inline proc "contextless" (x:i32) -> u8 {
    v:=x<-32768 ? -32768 : (x>32767 ? 32767 : x)
    return u8(v<0 ? 0 : (v>255 ? 255 : v))
}

@(private)
rand64 :: #force_inline proc "contextless" (state:^u64) -> u64 {
    z:=state^+0x9E3779B97F4A7C15
    state^=z
    z=(z~(z>>30))*0xBF58476D1CE4E5B9
    z=(z~(z>>27))*0x94D049BB133111EB
    return z~(z>>31)
}

@(private)
rand64_mod :: #force_inline proc "contextless" (r:u64,count:u32) -> u32 {
    return u32(((r>>32)*u64(count))>>32)
}

@(private)
rand64_in_range :: #force_inline proc "contextless" (r:u64,lo,hi:i32) -> i32 {
    return lo+i32(rand64_mod(r,u32(hi-lo+1)))
}

@(private)
rand64_seed_from_u64s :: proc "contextless" (vals:[]u64) -> u64 {
    rand_state:u64=0x9E3779B97F4A7C15
    for val in vals {
        v:=val*0xBF58476D1CE4E5B9
        v~=(rand_state>>43)|(rand_state<<21)
        rand_state*=0x94D049BB133111EB
        rand_state~=v
    }
    z:=rand_state+0x9E3779B97F4A7C15
    z=(z~(z>>30))*0xBF58476D1CE4E5B9
    z=(z~(z>>27))*0x94D049BB133111EB
    return z~(z>>31)
}

// Settings of an effort (bc7_enc_options_set).
enc_options_set :: proc "contextless" (opt:^Enc_Options,level:common.Level,options:common.Options) {
    opt^=enc_options_default()
    level:=level
    if level>.Reference {level=.Slow}
    switch level {
    case .Very_Fast:
        opt.flags=PCA_STRETCH|NO_INITIAL_BBOX|MODE4_ISB1_ONLY
        opt.partition_lsq_iters=0
        opt.subsets=&bc67.BC7_SUBSETS_LOW
        opt.nbest_part2=1; opt.nbest_part3=1
        opt.narrow0=1; opt.narrow2=1
        opt.enable_mode[2]=false; opt.enable_mode[3]=false; opt.enable_mode[5]=false
        opt.max_pca_stretch_passes=2
    case .Fast:
        opt.flags=PCA_STRETCH|NO_INITIAL_BBOX|BRUTE_PBITS_IDXS_EXACT
        opt.partition_lsq_iters=0
        opt.subsets=&bc67.BC7_SUBSETS_HIGH95
        opt.nbest_part2=4; opt.nbest_part3=4
        opt.narrow0=3; opt.narrow2=1
        opt.max_lsq_iter=2
        opt.max_pca_stretch_passes=4
        opt.err_threshold_for_subset3=48.0
    case .Slow:
        opt.flags=PCA_STRETCH|SLIDE_SELECTORS|EXTRAPOLATE_SELECTORS|JITTER_SELECTORS|
            BRUTE_PBITS_IDXS_EXACT
        opt.subsets=&bc67.BC7_SUBSETS_FULL
        opt.nbest_part2=6; opt.nbest_part3=6
        opt.narrow0=4; opt.narrow2=0
        opt.max_lsq_iter=2
        opt.max_pca_stretch_passes=4
        opt.err_threshold_for_subset3=32.0
        opt.optiters_early[0]=0
        opt.optiters_late[0]=16
    case .Very_Slow:
        opt.flags=PCA_STRETCH|SLIDE_SELECTORS|EXTRAPOLATE_SELECTORS|SCALE_SELECTORS|
            JITTER_SELECTORS|BRUTE_PBITS_IDXS_EXACT|ANNEAL_ENDPOINTS
        opt.subsets=&bc67.BC7_SUBSETS_FULL
        opt.partition_lsq_iters=2
        opt.nbest_part2=8; opt.nbest_part3=8
        opt.narrow0=6; opt.narrow2=0
        opt.max_pca_stretch_passes=4
        opt.err_threshold_for_subset3=16.0
        opt.optiters_early[0]=5
        opt.optiters_late[0]=20
        opt.optiters_late[1]=16
    case .Reference:
        opt.flags=PCA_STRETCH|SLIDE_SELECTORS|EXTRAPOLATE_SELECTORS|SCALE_SELECTORS|
            JITTER_SELECTORS|ANNEAL_ENDPOINTS|BRUTE_PBITS|BRUTE_PBITS_IDXS_EXACT
        opt.subsets=&bc67.BC7_SUBSETS_FULL
        opt.partition_lsq_iters=2
        opt.nbest_part2=8; opt.nbest_part3=8
        opt.optiters_early[0]=24
        opt.optiters_early[1]=40
        opt.optiters_late[0]=64
        opt.optiters_late[1]=128
        opt.narrow0=12; opt.narrow2=12
        opt.max_lsq_iter=4
        opt.max_pca_stretch_passes=12
    }
    if .BC7_Ignore_Alpha in options {opt.flags|=IGNORE_ALPHA}
    if .BC3457_Preserve_Extremes in options {opt.flags|=PRESERVE_EXTREMES}
}
