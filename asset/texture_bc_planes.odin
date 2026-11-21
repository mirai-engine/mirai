package asset

import "base:intrinsics"
import "core:math/bits"
import "core:mem"

TEXTURE_FIELD_MODES :: 15
TEXTURE_FIELD_PLANES :: 5
TEXTURE_FIELD_SPANS :: 32

Texture_Field_Counts :: [TEXTURE_FIELD_MODES]u32

Texture_Field_Mode :: struct {
    prefix:u32,
    bit_planes:u32, // endpoint planes stored one bit at a time across blocks
    widths:[TEXTURE_FIELD_PLANES]u32, // bytes per entry
    spans:[TEXTURE_FIELD_SPANS]u32,   // wire bit, plane, plane bit, bit count (one byte each)
}

Texture_Field_Layout :: struct {
    modes:int, // including the raw bucket; zero for BC1 and BC5
    mode:[TEXTURE_FIELD_MODES]Texture_Field_Mode,
}

@(private)
field_span :: proc "contextless" (m:^Texture_Field_Mode, at:^int, plane,source,target,width:int) {
    for offset:=0;offset<width;offset+=32 {
        m.spans[at^]=u32(source+offset)|u32(plane)<<8|u32(target+offset)<<16|
            u32(min(width-offset,32))<<24
        at^+=1
    }
    m.widths[plane]=max(m.widths[plane],u32((target+width+7)/8))
}

texture_field_layout :: proc "contextless" (format:Texture_Format) -> (l:Texture_Field_Layout) {
    #partial switch format {
    case .BC1,.BC5:
        offsets,widths:=BC1_FIELD_AT,BC1_FIELD_SIZE
        if format==.BC5 {offsets,widths=BC5_FIELD_AT,BC5_FIELD_SIZE}
        at:=0
        for width,i in widths {
            if width>0 {field_span(&l.mode[0],&at,i,offsets[i]*8,0,width*8)}
        }
    case .BC7:
        l.modes=len(BC7_MODES)+1
        for s,i in BC7_MODES {
            m:=&l.mode[i]
            m.prefix=1<<uint(i)
            endpoints:=int(s.ns)*2
            widths:=[TEXTURE_FIELD_PLANES]int{int(s.pb),int(s.rb+s.isb),
                endpoints*int(3*s.cb+s.ab),endpoints*int(s.epb)+int(s.ns*s.spb),0}
            wire,at:=i+1,0
            for &width,plane in widths {
                if plane==len(widths)-1 {width=128-wire}
                if width>0 {field_span(m,&at,plane,wire,0,width)}
                wire+=width
            }
        }
    case .BC6H:
        l.modes=len(BC6H_MODES)+1
        layouts:=BC6H_ENDPOINT_SPANS
        for s,i in BC6H_MODES {
            m:=&l.mode[i]
            m.prefix=texture_bc6h_mode_prefix(i)
            m.bit_planes=1<<1|1<<2
            at:=0
            deltas,delta_at:=[3]int{},[3]int{}
            for &width,c in deltas {
                width=int(s.epb)
                if s.db>0 {width=int(s.db)+int(c==int(s.bc))}
                if c>0 {delta_at[c]=delta_at[c-1]+deltas[c-1]*(int(s.ns)*2-1)}
            }
            for span in layouts[i] {
                c,e,b,w,n:=int(span[0]),int(span[1]),int(span[2]),int(span[3]),int(span[4])
                if e==0 {field_span(m,&at,1,w,c*int(s.epb)+b,n)}
                else {field_span(m,&at,2,w,delta_at[c]+(e-1)*deltas[c]+b,n)}
            }
            index:=bc6h_index_start(s)
            if s.pb>0 {field_span(m,&at,0,index-int(s.pb),0,int(s.pb))}
            field_span(m,&at,3,index,0,128-index)
        }
    }
    if l.modes>0 {
        at:=0
        field_span(&l.mode[l.modes-1],&at,0,0,0,128)
    }
    return
}

@(private)
fields_mode :: proc "contextless" (format:Texture_Format,first:u8) -> int {
    if format==.BC7 {return int(bits.trailing_zeros(first))}
    return min(texture_bc6h_mode(first),len(BC6H_MODES))
}

@(private)
fields_count :: proc "contextless" (format:Texture_Format,
    blocks:[]u8) -> (counts:Texture_Field_Counts) {
    for i in 0..<len(blocks)/16 {counts[fields_mode(format,blocks[i*16])]+=1}
    return
}

@(private)
fields_payload_size :: proc "contextless" (l:^Texture_Field_Layout,counts:Texture_Field_Counts,
    n:int) -> int {
    size:=(1+l.modes)*4+n
    for m in 0..<l.modes {
        for p in 0..<TEXTURE_FIELD_PLANES {
            size+=texture_field_plane_bytes(&l.mode[m],p,int(counts[m]))
        }
    }
    return size
}

texture_field_bit_plane :: proc "contextless" (mode:^Texture_Field_Mode,plane:int) -> bool {
    return (mode.bit_planes>>uint(plane))&1!=0
}

texture_field_group_count :: proc "contextless" (blocks:int) -> int {return (blocks+7)/8}

@(private)
texture_field_plane_bytes :: proc "contextless" (mode:^Texture_Field_Mode,
    plane,count:int) -> int {
    width:=int(mode.widths[plane])
    if texture_field_bit_plane(mode,plane) {return width*8*texture_field_group_count(count)}
    return width*count
}

// Bounds on a level's stored size, before reading its header and mode histogram.
@(private)
texture_fields_bounds :: proc "contextless" (format:Texture_Format) -> (header,low,high,pad:int) {
    if format!=.BC6H && format!=.BC7 {
        return 0,texture_block_bytes(format),texture_block_bytes(format),0
    }
    l:=texture_field_layout(format)
    low=max(int)
    for &m in l.mode[:l.modes] {
        stride:=1 // mode byte
        for w,p in m.widths {
            stride+=int(w)
            if texture_field_bit_plane(&m,p) {pad+=int(w)*7}
        }
        low,high=min(low,stride),max(high,stride)
    }
    return (1+l.modes)*4,low,high,pad
}

texture_fields_size :: proc "contextless" (format:Texture_Format,blocks:[]u8) -> int {
    if format!=.BC6H && format!=.BC7 {return len(blocks)}
    l:=texture_field_layout(format)
    return fields_payload_size(&l,fields_count(format,blocks),len(blocks)/16)
}

// Offsets and counts of each plane in a mode mip. Rows optionally receive mode counts
// before each row, plus a sentinel for the end, for bounded uploads of a mip's rows.
Texture_Field_Index :: struct {
    counts:Texture_Field_Counts,
    offsets:[TEXTURE_FIELD_MODES][TEXTURE_FIELD_PLANES]int,
    modes:[]u8,
}

texture_fields_index :: proc "contextless" (l:^Texture_Field_Layout,planes:[]u8,n:int,
    rows:[]Texture_Field_Counts=nil) -> (index:Texture_Field_Index,ok:bool) {
    if l==nil || l.modes<=0 || l.modes>TEXTURE_FIELD_MODES || n<0 || n>len(planes) {return}
    header:=(1+l.modes)*4
    if header>len(planes)-n || int(fields_u32(planes))!=n {return}
    count:=0
    for m in 0..<l.modes {
        k:=fields_u32(planes[4*(m+1):])
        if int(k)>n-count {return}
        index.counts[m]=k
        count+=int(k)
    }
    if count!=n || fields_payload_size(l,index.counts,n)!=len(planes) {return}
    index.modes=planes[header:][:n]
    found:Texture_Field_Counts
    row_size:=n
    if len(rows)>0 {
        if len(rows)<2 || n==0 || n%(len(rows)-1)!=0 || len(rows)-1>n {return}
        row_size=n/(len(rows)-1)
    }
    for start:=0;start<n;start+=row_size {
        if len(rows)>0 {rows[start/row_size]=found}
        for m in index.modes[start:][:row_size] {
            if int(m)>=l.modes {return}
            found[m]+=1
        }
    }
    if found!=index.counts {return}
    if len(rows)>0 {rows[len(rows)-1]=found}
    index.offsets=field_offsets(l,index.counts,header+n)
    return index,true
}

@(private)
fields_u32 :: proc "contextless" (b:[]u8) -> u32 {
    return u32(intrinsics.unaligned_load((^u32le)(raw_data(b))))
}

@(private)
field_offsets :: proc "contextless" (l:^Texture_Field_Layout,counts:Texture_Field_Counts,
    start:int) -> (offsets:[TEXTURE_FIELD_MODES][TEXTURE_FIELD_PLANES]int) {
    at:=start
    for m in 0..<max(l.modes,1) {
        for p in 0..<TEXTURE_FIELD_PLANES {
            offsets[m][p]=at
            at+=texture_field_plane_bytes(&l.mode[m],p,int(counts[m]))
        }
    }
    return
}

@(private)
field_value_move :: proc "contextless" (value:^u128,planes:[]u8,mode:^Texture_Field_Mode,
    plane,offset,rank,total:int,join:bool) {
    width:=int(mode.widths[plane])
    if !texture_field_bit_plane(mode,plane) {
        position:=offset+rank*width
        if join {mem.copy(value,raw_data(planes[position:]),width)}
        else {mem.copy(raw_data(planes[position:]),value,width)}
        return
    }
    groups:=texture_field_group_count(total)
    at:=offset+rank/8
    lane:=uint(rank%8)
    for bit in 0..<width*8 {
        if join {
            value^|=u128(planes[at]>>lane&1)<<uint(bit)
        } else {
            planes[at]|=u8(value^>>uint(bit)&1)<<lane
        }
        at+=groups
    }
}

@(private)
fields_modes_move :: proc "contextless" (format:Texture_Format,blocks,planes:[]u8,join:bool) -> bool {
    if len(blocks)%16!=0 {return false}
    n:=len(blocks)/16
    l:=texture_field_layout(format)
    index:Texture_Field_Index
    if join {
        ok:bool
        if index,ok=texture_fields_index(&l,planes,n);!ok {return false}
    } else {
        index.counts=fields_count(format,blocks)
        if len(planes)!=fields_payload_size(&l,index.counts,n) {return false}
        header:=(1+l.modes)*4
        intrinsics.unaligned_store((^u32le)(raw_data(planes)),u32le(n))
        for m in 0..<l.modes {
            at:=4*(m+1)
            intrinsics.unaligned_store((^u32le)(raw_data(planes[at:])),u32le(index.counts[m]))
        }
        index.modes=planes[header:][:n]
        index.offsets=field_offsets(&l,index.counts,header+n)
        for m in 0..<l.modes {
            mode:=&l.mode[m]
            for p in 0..<TEXTURE_FIELD_PLANES {
                if !texture_field_bit_plane(mode,p) {continue}
                at:=index.offsets[m][p]
                size:=texture_field_plane_bytes(mode,p,int(index.counts[m]))
                mem.zero_slice(planes[at:][:size])
            }
        }
    }
    rank:Texture_Field_Counts
    for i in 0..<n {
        m:=int(index.modes[i])
        block:=blocks[i*16:][:16]
        if !join {
            m=fields_mode(format,block[0])
            index.modes[i]=u8(m)
        }
        mode:=&l.mode[m]
        values:[TEXTURE_FIELD_PLANES]u128
        wire:=u128(mode.prefix)
        if !join {
            wire=u128(intrinsics.unaligned_load((^u128le)(raw_data(block))))
        }
        if join {
            for width,p in mode.widths {
                if width==0 {continue}
                field_value_move(&values[p],planes,mode,p,index.offsets[m][p],
                    int(rank[m]),int(index.counts[m]),true)
            }
        }
        for span in mode.spans {
            if span==0 {break}
            source,plane,target,width:=u8(span),u8(span>>8),u8(span>>16),span>>24
            mask:=(u128(1)<<width)-1
            if join {wire|=((values[plane]>>target)&mask)<<source}
            else {values[plane]|=((wire>>source)&mask)<<target}
        }
        if join {intrinsics.unaligned_store((^u128le)(raw_data(block)),u128le(wire))}
        else {
            for width,p in mode.widths {
                if width==0 {continue}
                field_value_move(&values[p],planes,mode,p,index.offsets[m][p],
                    int(rank[m]),int(index.counts[m]),false)
            }
        }
        rank[m]+=1
    }
    return true
}
