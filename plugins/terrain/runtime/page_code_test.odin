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
        page:=page_code(values[:n],c.width,true,coded[:])
        testing.expect_value(t,len(page),PAGE_HEADER+4*n)
        testing.expect(t,page_uncode(page,mem.slice_to_bytes(decoded[:n])),c.name)
        worst:f32
        for k in 0..<n {
            worst=max(worst,abs(decoded[k]-values[k]))
            if decoded[k]!=height_quantize(values[k]) {testing.expectf(t,false,"%s: sample %d is not the multiple of the step nearest it",c.name,k);break}
        }
        // Past 2^14 m an f32 is coarser than the step and keeps its own value.
        testing.expectf(t,worst<=HEIGHT_STEP/2,"%s: %v m away",c.name,worst)
        // What a file holds is saved again as it is.
        testing.expect(t,string(page_code(decoded[:n],c.width,true,recoded[:]))==string(page),c.name)
        testing.expect(t,page_on_lattice(decoded[:n]),c.name)
        // Without quantizing, a page comes back bit for bit, on the lattice or not.
        for source in ([2][]f32{values[:n],decoded[:n]}) {
            testing.expect(t,page_uncode(page_code(source,c.width,false,recoded[:]),mem.slice_to_bytes(again[:n])),c.name)
            testing.expect(t,mem.compare(mem.slice_to_bytes(again[:n]),mem.slice_to_bytes(source))==0,c.name)
        }
    }
    // Values of other grids come back as they were.
    weights:[PAGE_VALUES]Weights
    for &w,k in weights {w={u8(k),u8(k>>8),u8(255-k),0}}
    out:[PAGE_VALUES]Weights
    testing.expect(t,page_uncode(page_code(weights[:],PAGE,true,coded[:]),mem.slice_to_bytes(out[:])))
    testing.expect(t,out==weights)
    // A page of another size, code or layout is refused.
    page:=page_code(values[:PAGE],PAGE,true,coded[:])
    testing.expect(t,!page_uncode(page,mem.slice_to_bytes(decoded[:PAGE-1])))
    bad:[PAGE_HEADER+4*PAGE]u8
    for edit in ([3][2]int{{0,9},{1,3},{2,0}}) {
        copy(bad[:],page)
        bad[edit[0]]=u8(edit[1])
        testing.expect(t,!page_uncode(bad[:],mem.slice_to_bytes(decoded[:PAGE])))
    }
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
