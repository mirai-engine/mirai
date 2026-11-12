package zstd

SPLIT_BLOCK_WORKSPACE_SIZE :: 8208

@(private="file") THRESHOLD_PENALTY_RATE :: 16
@(private="file") THRESHOLD_BASE :: THRESHOLD_PENALTY_RATE-2
@(private="file") THRESHOLD_PENALTY :: 3
@(private="file") HASH_LENGTH :: 2
@(private="file") HASH_LOG_MAX :: 10
@(private="file") HASH_TABLE_SIZE :: 1<<HASH_LOG_MAX
@(private="file") KNUTH :: u32(0x9e3779b9)
@(private="file") CHUNK_SIZE :: 8<<10
@(private="file") SEGMENT_SIZE :: 512

@(private="file")
Fingerprint :: struct {
    events:[HASH_TABLE_SIZE]u32,
    nb_events:int,
}

@(private="file")
Fp_Stats :: struct {
    past_events,new_events:Fingerprint,
}

#assert(size_of(Fp_Stats)<=SPLIT_BLOCK_WORKSPACE_SIZE)

// With a hash_log of 8 the event is the byte itself.
@(private="file")
hash2 :: #force_inline proc "contextless" (p:[^]u8,hash_log:u32) -> u32 {
    if hash_log==8 {return u32(p[0])}
    return u32(read16(p))*KNUTH>>(32-hash_log)
}

@(private="file")
add_events :: #force_inline proc "contextless" (fp:^Fingerprint,src:[^]u8,src_size,sampling_rate:int,hash_log:u32) {
    limit:=src_size-HASH_LENGTH+1
    for n:=0;n<limit;n+=sampling_rate {
        fp.events[hash2(padd(src,n),hash_log)]+=1
    }
    fp.nb_events+=limit/sampling_rate
}

@(private="file")
record_fingerprint :: proc "contextless" (fp:^Fingerprint,src:[^]u8,src_size,sampling_rate:int,hash_log:u32) {
    for i in 0..<(1<<hash_log) {fp.events[i]=0}
    fp.nb_events=0
    add_events(fp,src,src_size,sampling_rate,hash_log)
}

@(private="file")
abs64 :: #force_inline proc "contextless" (v:i64) -> u64 {return u64(v<0 ? -v : v)}

@(private="file")
fp_distance :: proc "contextless" (fp1,fp2:^Fingerprint,hash_log:u32) -> u64 {
    distance:=u64(0)
    for n in 0..<(1<<hash_log) {
        distance+=abs64(i64(fp1.events[n])*i64(fp2.nb_events)-i64(fp2.events[n])*i64(fp1.nb_events))
    }
    return distance
}

@(private="file")
compare_fingerprints :: proc "contextless" (reference,new_fp:^Fingerprint,penalty:int,hash_log:u32) -> bool {
    p50:=u64(reference.nb_events)*u64(new_fp.nb_events)
    deviation:=fp_distance(reference,new_fp,hash_log)
    threshold:=p50*u64(THRESHOLD_BASE+penalty)/THRESHOLD_PENALTY_RATE
    return deviation>=threshold
}

@(private="file")
merge_events :: proc "contextless" (acc,new_fp:^Fingerprint) {
    for n in 0..<HASH_TABLE_SIZE {acc.events[n]+=new_fp.events[n]}
    acc.nb_events+=new_fp.nb_events
}

@(rodata,private="file") SAMPLING_RATES:=[4]int{43,11,5,1}
@(rodata,private="file") HASH_PARAMS:=[4]u32{8,9,10,10}

@(private="file")
split_block_by_chunks :: proc "contextless" (block_start:[^]u8,block_size,level:int,workspace:[^]u8) -> int {
    fpstats:=(^Fp_Stats)(workspace)
    rate:=SAMPLING_RATES[level]
    hash_log:=HASH_PARAMS[level]
    penalty:=THRESHOLD_PENALTY
    fpstats^={}
    record_fingerprint(&fpstats.past_events,block_start,CHUNK_SIZE,rate,hash_log)
    for pos:=CHUNK_SIZE;pos<=block_size-CHUNK_SIZE;pos+=CHUNK_SIZE {
        record_fingerprint(&fpstats.new_events,padd(block_start,pos),CHUNK_SIZE,rate,hash_log)
        if compare_fingerprints(&fpstats.past_events,&fpstats.new_events,penalty,hash_log) {return pos}
        merge_events(&fpstats.past_events,&fpstats.new_events)
        if penalty>0 {penalty-=1}
    }
    return block_size
}

@(private="file")
split_block_from_borders :: proc "contextless" (block_start:[^]u8,block_size:int,workspace:[^]u8) -> int {
    fpstats:=(^Fp_Stats)(workspace)
    middle_events:=(^Fingerprint)(padd(workspace,512*size_of(u32)))
    fpstats^={}
    hist_add(raw_data(fpstats.past_events.events[:]),block_start,SEGMENT_SIZE)
    hist_add(raw_data(fpstats.new_events.events[:]),padd(block_start,block_size-SEGMENT_SIZE),SEGMENT_SIZE)
    fpstats.past_events.nb_events=SEGMENT_SIZE
    fpstats.new_events.nb_events=SEGMENT_SIZE
    if !compare_fingerprints(&fpstats.past_events,&fpstats.new_events,0,8) {return block_size}
    hist_add(raw_data(middle_events.events[:]),padd(block_start,block_size/2-SEGMENT_SIZE/2),SEGMENT_SIZE)
    middle_events.nb_events=SEGMENT_SIZE
    dist_from_begin:=fp_distance(&fpstats.past_events,middle_events,8)
    dist_from_end:=fp_distance(&fpstats.new_events,middle_events,8)
    min_distance:=u64(SEGMENT_SIZE*SEGMENT_SIZE/3)
    if abs64(i64(dist_from_begin)-i64(dist_from_end))<min_distance {return 64*KB}
    return dist_from_begin>dist_from_end ? 32*KB : 96*KB
}

split_block :: proc "contextless" (block_start:[^]u8,block_size,level:int,workspace:[^]u8,wksp_size:int) -> int {
    if level==0 {return split_block_from_borders(block_start,block_size,workspace)}
    return split_block_by_chunks(block_start,block_size,level-1,workspace)
}
