package terrain

import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:testing"
import "mirai:asset"
import "mirai:std/base"

@(test)
coded_pages_keep_heights_within_half_a_step_and_other_values_exactly :: proc(t:^testing.T) {
    seed:=u32(7)
    random :: proc(seed:^u32) -> f32 {
        seed^=seed^*1664525+1013904223
        return f32(seed^>>8)/f32(1<<24)
    }
    Case :: struct {name:string,width:int,count:int,height:proc(x,z:int,noise:f32) -> f32}
    cases:=[]Case{
        {"rolling ground",PAGE,PAGE_VALUES,proc(x,z:int,noise:f32) -> f32 {return 40*math.sin(f32(x)*0.1)*math.cos(f32(z)*0.07)+noise}},
        {"a cliff higher than 64 m",PAGE,PAGE_VALUES,proc(x,z:int,noise:f32) -> f32 {return (x<20?-300:900)+noise}},
        {"the far edge of a source",17,17*5,proc(x,z:int,noise:f32) -> f32 {return f32(z)*1000+noise}},
        {"the height limit",PAGE,PAGE_VALUES,proc(x,z:int,noise:f32) -> f32 {return (x+z)%2==0?HEIGHT_LIMIT:-HEIGHT_LIMIT+noise}},
    }
    values,decoded,again:[PAGE_VALUES]f32
    coded,recoded:[PAGE_BYTES_MAX]u8
    for c in cases {
        n:=c.count
        for k in 0..<n {values[k]=c.height(k%c.width,k/c.width,random(&seed))}
        extent:=[3]int{c.width,1,n/c.width}
        page:=page_code(values[:n],extent,true,coded[:])
        testing.expect(t,page_uncode(page,mem.slice_to_bytes(decoded[:n])),c.name)
        worst:f32
        for k in 0..<n {
            worst=max(worst,abs(decoded[k]-values[k]))
            if decoded[k]!=height_quantize(values[k]) {testing.expectf(t,false,"%s: sample %d is not the multiple of the step nearest it",c.name,k);break}
        }
        // Past 2^14 m an f32 is coarser than the step and keeps its own value.
        testing.expectf(t,worst<=HEIGHT_STEP/2,"%s: %v m away",c.name,worst)
        // What a file holds is saved again as it is.
        testing.expect(t,string(page_code(decoded[:n],extent,true,recoded[:]))==string(page),c.name)
        _,on:=page_lattice(decoded[:n])
        testing.expect(t,on,c.name)
        // Without quantizing, a page comes back bit for bit, on the lattice or not.
        for source in ([2][]f32{values[:n],decoded[:n]}) {
            testing.expect(t,page_uncode(page_code(source,extent,false,recoded[:]),mem.slice_to_bytes(again[:n])),c.name)
            testing.expect(t,mem.compare(mem.slice_to_bytes(again[:n]),mem.slice_to_bytes(source))==0,c.name)
        }
    }
    // Distances of a Volume, on no lattice, come back bit for bit, in whole blocks and at its far edges.
    for extent in ([][3]int{{BLOCK,BLOCK,BLOCK},{1,BLOCK,3},{BLOCK,2,1}}) {
        n:=extent.x*extent.y*extent.z
        for k in 0..<n {
            p:=[3]f32{f32(k%extent.x),f32(k/extent.x%extent.y),f32(k/(extent.x*extent.y))}
            values[k]=clamp(math.sqrt(p.x*p.x+p.y*p.y*0.7+p.z*p.z)-9.3,-SDF_BAND_CELLS,SDF_BAND_CELLS)
        }
        page:=page_code(values[:n],extent,false,coded[:])
        testing.expectf(t,page_uncode(page,mem.slice_to_bytes(again[:n])) && mem.compare(mem.slice_to_bytes(again[:n]),mem.slice_to_bytes(values[:n]))==0,"distances %v",extent)
        if n==PAGE_VALUES {testing.expectf(t,len(page)<n*size_of(f32)/2,"a block of distances codes in %d bytes",len(page))}
    }
    // Values of other grids come back as they were, those that code and those that do not.
    weights,out:[PAGE_VALUES]Weights
    for pattern in 0..<2 {
        for &w,k in weights {
            seed=seed*1664525+1013904223
            w=pattern==0?Weights(seed~seed>>15):WEIGHTS_FIRST+Weights(k/700)
        }
        page:=page_code(weights[:],{PAGE,1,PAGE},true,coded[:])
        testing.expect(t,page_uncode(page,mem.slice_to_bytes(out[:])) && out==weights)
        testing.expect_value(t,Page_Code(page[0]),pattern==0?Page_Code.Values:Page_Code.Bytes)
    }
    holes,holes_out:[PAGE_VALUES]u8
    paint,paint_out:[PAGE_VALUES]Paint
    for k in 0..<PAGE_VALUES {holes[k],paint[k]=u8(k%PAGE>40),{u8(k),200,u8(k/PAGE),128}}
    testing.expect(t,page_uncode(page_code(holes[:],{PAGE,1,PAGE},false,coded[:]),holes_out[:]) && holes_out==holes)
    testing.expect(t,page_uncode(page_code(paint[:],{PAGE,1,PAGE},false,coded[:]),mem.slice_to_bytes(paint_out[:])) && paint_out==paint)
    // A page of another size, code or layout is refused.
    page:=page_code(values[:PAGE],{PAGE,1,1},true,coded[:])
    testing.expect(t,!page_uncode(page,mem.slice_to_bytes(decoded[:PAGE-1])))
    bad:[PAGE_HEADER+4*PAGE]u8
    copy(bad[:],page)
    testing.expect(t,!page_uncode(bad[:],mem.slice_to_bytes(decoded[:PAGE])),"a coded page as long as its values")
    for edit in ([3][2]int{{0,9},{1,3},{2,0}}) {
        copy(bad[:],page)
        bad[edit[0]]=u8(edit[1])
        testing.expect(t,!page_uncode(bad[:len(page)],mem.slice_to_bytes(decoded[:PAGE])))
    }
}

// Pages of any bytes, as a file or a peer may send them, decode into their room or are refused.
@(test)
hostile_pages_decode_within_their_room_or_are_refused :: proc(t:^testing.T) {
    seed:=u64(0x9e3779b97f4a7c15)
    next :: proc(seed:^u64) -> u64 {
        seed^~=seed^<<13;seed^~=seed^>>7;seed^~=seed^<<17
        return seed^
    }
    bytes:[PAGE_BYTES_MAX]u8
    out:[PAGE_VALUES*4+16]u8
    refused:=0
    sizes:=[3]int{1,2,4}
    counts:=[3]int{PAGE_VALUES,BLOCK*BLOCK*3,PAGE}
    for round in 0..<600 {
        size,n:=sizes[round%3],counts[round/3%3]
        length:=PAGE_HEADER+int(next(&seed)%u64(n*size))
        for &b in bytes[:length] {b=u8(next(&seed))}
        bytes[0]=u8(round%4)
        bytes[1]=u8(size)
        bytes[2],bytes[3]=u8(round%2==0?PAGE:BLOCK),u8(round%2==0?PAGE:BLOCK)
        if n%(int(bytes[2])*int(bytes[3]))!=0 {bytes[3]=1}
        out[n*size]=0xa5
        if !page_uncode(bytes[:length],out[:n*size]) {refused+=1}
        testing.expect(t,out[n*size]==0xa5,"nothing is written past its room")
    }
    testing.expect(t,refused>0)
    // A real page cut short or with bytes after it.
    values:[PAGE_VALUES]f32
    for &v,k in values {v=f32(k%PAGE)*0.37+f32(k/PAGE)*0.11}
    coded:[PAGE_BYTES_MAX]u8
    page:=page_code(values[:],{PAGE,1,PAGE},false,coded[:])
    for length in ([]int{0,PAGE_HEADER,len(page)/2,len(page)+64}) {
        _=page_uncode(coded[:length],out[:PAGE_VALUES*4])
    }
    testing.expect(t,!page_uncode(coded[:PAGE_HEADER-1],out[:PAGE_VALUES*4]))
}

@(test)
saved_heights_stay_where_the_file_put_them_through_edits_and_saves :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    s,loaded:Source
    defer source_destroy(&s);defer source_destroy(&loaded)
    samples:=[3]int{PAGE+9,1,PAGE+5}
    testing.expect(t,source_make(&s,.Heightfield,samples,0.25,8))
    for z in 0..<samples.z {for x in 0..<samples.x {testing.expect(t,source_set(&s,{x,0,z},12.3456789*math.sin(f32(x*z)*0.013)+f32(x)*0.1))}}
    path:=fmt.tprintf("%s/quantized.terrain",base.test_folder(t,"terrain"))
    id:=base.Asset_Id{91,92}
    testing.expect_value(t,source_save(&s,path,id,&types),asset.Error.None)
    _,ok:=source_load(&loaded,path,&types)
    testing.expect(t,ok)
    for z in 0..<samples.z {for x in 0..<samples.x {
        h:=source_value(&loaded,{x,0,z}) or_else 0
        testing.expect(t,abs(h-(source_value(&s,{x,0,z}) or_else 0))<=HEIGHT_STEP/2 && h==height_quantize(h))
    }}
    // Edit and save several times: what is not edited keeps its height, bit for bit.
    edited:=[3]int{3,0,PAGE+2}
    for round in 0..<3 {
        testing.expect(t,source_set(&loaded,edited,(source_value(&loaded,edited) or_else 0)+0.0001234))
        testing.expect_value(t,source_save(&loaded,path,id,&types),asset.Error.None)
        again:Source;defer source_destroy(&again)
        _,ok=source_load(&again,path,&types)
        testing.expect(t,ok)
        for z in 0..<samples.z {for x in 0..<samples.x {
            p:=[3]int{x,0,z}
            if p==edited {
                testing.expect(t,abs((source_value(&again,p) or_else 0)-(source_value(&loaded,p) or_else 0))<=HEIGHT_STEP/2)
            } else if (source_value(&again,p) or_else 0)!=(source_value(&loaded,p) or_else 0) {
                testing.expectf(t,false,"round %d: sample %v moved",round,p);return
            }
        }}
        source_destroy(&loaded)
        loaded=again
        again={}
    }
    // Saving what a file holds writes that file again.
    first_load:Source;defer source_destroy(&first_load)
    _,ok=source_load(&first_load,path,&types)
    second:=fmt.tprintf("%s/quantized_again.terrain",base.test_folder(t,"terrain"))
    testing.expect_value(t,source_save(&first_load,second,id,&types),asset.Error.None)
    a,_:=os.read_entire_file(path,context.temp_allocator)
    b,_:=os.read_entire_file(second,context.temp_allocator)
    testing.expect(t,ok && string(a)==string(b))
}
