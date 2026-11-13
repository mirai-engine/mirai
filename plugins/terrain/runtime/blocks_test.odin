package terrain

import "core:fmt"
import "core:os"
import "core:testing"
import "mirai:asset"
import "mirai:std/base"

// A Volume of 97 samples a side: its solid box leaves blocks deep inside
// that are all solid, and above its top blocks all air.
@(private="file")
blocks_volume :: proc(t:^testing.T,s:^Source) -> bool {
    return testing.expect(t,source_make(s,.Volume,{97,97,97},1,16))
}

@(private="file")
blocks_same :: proc(t:^testing.T,a,b:^Source,low,high:[3]int) -> bool {
    for z in low.z..=high.z {for y in low.y..=high.y {for x in low.x..=high.x {
        if (source_value(a,{x,y,z}) or_else 0)!=(source_value(b,{x,y,z}) or_else 0) {
            testing.expectf(t,false,"sample %v: %v and %v",[3]int{x,y,z},source_value(a,{x,y,z}) or_else 0,source_value(b,{x,y,z}) or_else 0)
            return false
        }
    }}}
    return true
}

// The block (2,1,2) lies deep in the solid; centered on it, a sphere of
// radius 20 leaves it all air.
@(private="file")
BLOCKS_DEEP :: 2+7*(1+7*2)
@(private="file")
BLOCKS_CENTER :: [3]f32{39.5-48,23.5-48,39.5-48}

@(test)
volume_blocks_all_air_or_all_solid_hold_no_values_through_brushes_and_the_file :: proc(t:^testing.T) {
    source,loaded:Source;defer source_destroy(&source);defer source_destroy(&loaded)
    if !blocks_volume(t,&source) {return}
    g:=&source.field
    band:=source.cell*SDF_BAND_CELLS
    testing.expect_value(t,g.counts,[3]int{7,7,7})
    // A block of one value holds none: all air or all solid past the band,
    // or a thin block at a far edge that the margin of air fills alike.
    band_wide,held:=0,0
    blocks:=g.counts.x*g.counts.y*g.counts.z
    for i in 0..<blocks {
        page:=grid_page(g,i)
        if page.values!=nil {
            _,count:=grid_page_extent(g,i)
            testing.expect_value(t,len(page.values),count)
            held+=count
            continue
        }
        if page.fill==band || page.fill==-band {band_wide+=1}
    }
    testing.expect(t,band_wide>blocks/3,"blocks all air or all solid")
    testing.expect_value(t,grid_dense(g),held)
    testing.expect(t,held<97*97*97,"fewer values than samples: a block at a far edge holds only those of the field there")
    testing.expect(t,grid_page(g,BLOCKS_DEEP).values==nil && grid_page(g,BLOCKS_DEEP).fill==-band)
    // A brush gives the blocks it changes values of their own; one it leaves all air holds none again.
    change:=source_edit(&source,{kind=.Carve,center=BLOCKS_CENTER,radius=20,amount=1})
    testing.expect(t,change.changed)
    testing.expect(t,grid_page(g,BLOCKS_DEEP).values==nil && grid_page(g,BLOCKS_DEEP).fill==band,"the carved block is all air and holds no values")
    testing.expect(t,(source_value(&source,{40,24,40}) or_else 0)==band)
    neighbor:=BLOCKS_DEEP+1
    testing.expect(t,grid_page(g,neighbor).values!=nil,"a block the surface of the cavity crosses holds its values")
    // The file keeps a uniform block as its value and every other one as its own block.
    root:=base.test_folder(t,"terrain")
    path:=fmt.tprintf("%s/volume.terrain",root)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    id:=base.Asset_Id{441,442}
    testing.expect_value(t,source_save(&source,path,id,&types),asset.Error.None)
    file:asset.Asset
    if !testing.expect_value(t,asset.asset_load(&file,path),asset.Error.None) {return}
    testing.expect_value(t,file.blob.header.kind_version,u16(TERRAIN_VERSION))
    runs,error:=asset.asset_rows(&file,&types,"field_pages","",Page_Run)
    testing.expect_value(t,error,asset.Error.None)
    // A run for each block with values, and one for the blocks of one value that follow one another.
    stored,counted:=0,0
    for run in runs {
        counted+=int(run.count)
        if run.size!=0 {stored+=1}
    }
    with_values:=0
    for page in g.pages {if page.values!=nil {with_values+=1}}
    testing.expect_value(t,counted,blocks)
    testing.expect_value(t,stored,with_values)
    testing.expect(t,len(runs)<blocks,"blocks of one value share a run")
    _,found:=asset.asset_table(&file,"values")
    testing.expect(t,!found,"no dense array of values")
    asset.asset_close(&file)
    got,ok:=source_load(&loaded,path,&types)
    testing.expect(t,ok && got==id)
    blocks_same(t,&loaded,&source,{},{96,96,96})
    testing.expect_value(t,grid_dense(&loaded.field),grid_dense(g))
    // A game shipped without compression stores its blocks as a cook writes them, and reads the same values.
    saved,read_error:=os.read_entire_file(path,context.temp_allocator)
    testing.expect(t,read_error==nil)
    cooked,repack_error:=asset.document_repack(saved,.Ultra,.None,context.temp_allocator)
    testing.expect_value(t,repack_error,asset.Error.None)
    cooked_path:=fmt.tprintf("%s/cooked.terrain",root)
    testing.expect(t,os.write_entire_file(cooked_path,cooked)==nil)
    from_cook:Source;defer source_destroy(&from_cook)
    _,cook_ok:=source_load(&from_cook,cooked_path,&types)
    testing.expect(t,cook_ok)
    blocks_same(t,&from_cook,&source,{},{96,96,96})
}

@(test)
volume_files_of_another_version_or_with_distances_past_the_band_are_refused :: proc(t:^testing.T) {
    source,loaded:Source;defer source_destroy(&source);defer source_destroy(&loaded)
    if !testing.expect(t,source_make(&source,.Volume,{33,17,33},1,8)) {return}
    root:=base.test_folder(t,"terrain")
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    id:=base.Asset_Id{443,444}
    path:=fmt.tprintf("%s/volume.terrain",root)
    data,error:=source_bytes(&source,id,&types)
    if !testing.expect_value(t,error,asset.Error.None) {return}
    defer delete(data)
    // The version is in the header: the file of the version before is not read.
    document:asset.Document
    asset.document_init(&document,TERRAIN_KIND,id)
    document.kind_version=TERRAIN_VERSION-1
    info:=source.info
    _,put:=asset.document_put_row(&document,&types,"terrain",&info)
    testing.expect_value(t,put,asset.Error.None)
    old,old_error:=asset.document_bytes(&document)
    asset.document_destroy(&document)
    testing.expect_value(t,old_error,asset.Error.None)
    testing.expect(t,os.write_entire_file(path,old)==nil)
    delete(old)
    _,ok:=source_load(&loaded,path,&types)
    testing.expect(t,!ok,"a file of the version before is refused")
    testing.expect(t,os.write_entire_file(path,data)==nil)
    _,ok=source_load(&loaded,path,&types)
    testing.expect(t,ok)
    // A distance past the band is not saved.
    band:=source.cell*SDF_BAND_CELLS
    if held:=grid_page_ref(&source.field,0,source.allocator);testing.expect(t,held!=nil) {held.fill=band*2}
    _,error=source_bytes(&source,id,&types)
    testing.expect_value(t,error,asset.Error.Invalid)
}

@(test)
a_volume_read_by_pages_holds_only_the_blocks_it_reads_and_a_block_that_leaves_keeps_its_edits :: proc(t:^testing.T) {
    source,paged,copied:Source;defer source_destroy(&source);defer source_destroy(&paged);defer source_destroy(&copied)
    if !blocks_volume(t,&source) {return}
    // Its weights, in blocks as its distances, page with them.
    testing.expect(t,source_layer_set(&source,0,LAYER_DEFAULT) && source_layer_set(&source,1,LAYER_DEFAULT))
    testing.expect(t,source_edit(&source,{kind=.Paint,center=[3]f32{40,48,40}-48,radius=3,amount=1,layer=1}).changed)
    root:=base.test_folder(t,"terrain")
    path:=fmt.tprintf("%s/volume.terrain",root)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    id:=base.Asset_Id{445,446}
    testing.expect_value(t,source_save(&source,path,id,&types),asset.Error.None)
    front:asset.Asset
    if !testing.expect_value(t,asset.asset_load_front(&front,path),asset.Error.None) {return}
    got,ok:=source_read(&paged,&front,&types,pages=path)
    asset.asset_close(&front)
    if !testing.expect(t,ok && got==id) {return}
    g:=&paged.field
    testing.expect(t,source_paged(&paged) && grid_dense(g)==0 && grid_dense(&paged.weights)==0,"the blocks stay in the file")
    // Around the top of the box: two blocks the surface crosses.
    low,high:=[3]int{36,44,36},[3]int{44,52,44}
    testing.expect(t,!source_region_held(&paged,low,high))
    testing.expect(t,source_region_read(&paged,low,high))
    testing.expect(t,source_region_held(&paged,low,high))
    blocks_same(t,&paged,&source,low,high)
    testing.expect(t,grid_dense(&paged.weights)>0 && grid_value(&paged.weights,{40,48,40})==grid_value(&source.weights,{40,48,40}))
    held:=grid_dense(g)
    testing.expect_value(t,held,2*PAGE_VALUES)
    // A copy, as Play and the snapshots of a World make, copies what is in memory and leaves the rest in the file.
    testing.expect(t,source_clone(&copied,&paged))
    testing.expect_value(t,grid_dense(&copied.field),held)
    testing.expect(t,source_paged(&copied) && copied.file==paged.file)
    // An edit stays in a block of its own when its block leaves, and comes back with it.
    at:=[3]int{40,46,40}
    testing.expect(t,source_edit(&paged,{kind=.Carve,center=[3]f32{40,46,40}-48,radius=1.5,amount=1}).changed)
    edited:=source_value(&paged,at) or_else 0
    testing.expect(t,edited>(source_value(&source,at) or_else 0))
    testing.expect(t,source_pages_leave(&paged)>0)
    testing.expect_value(t,grid_dense(g),0)
    testing.expect_value(t,grid_dense(&paged.weights),0)
    block,_:=grid_page_at(g,at)
    testing.expect(t,grid_absent(g,block) && grid_block(g,block).own!=nil,"the edited block keeps its edits in a block of its own")
    _,read:=source_value(&paged,at)
    testing.expect(t,!read && !source_set(&paged,at,0),"a sample whose block is not in memory is not read or written")
    testing.expect(t,source_region_read(&paged,low,high))
    testing.expect_value(t,source_value(&paged,at) or_else 0,edited)
    testing.expect_value(t,grid_value(&paged.weights,{40,48,40}),grid_value(&source.weights,{40,48,40}))
    // The copy did not see the edit.
    testing.expect_value(t,source_value(&copied,at) or_else 0,source_value(&source,at) or_else 0)
}

@(test)
volume_snapshots_hold_only_their_blocks_and_give_back_each_stroke :: proc(t:^testing.T) {
    source,before,after:Source
    defer source_destroy(&source);defer source_destroy(&before);defer source_destroy(&after)
    if !blocks_volume(t,&source) {return}
    testing.expect(t,source_clone(&before,&source))
    dense:=97*97*97
    testing.expect(t,grid_dense(&before.field)<dense,"a snapshot holds no values for the blocks all air or all solid")
    testing.expect(t,source_edit(&source,{kind=.Carve,center=BLOCKS_CENTER,radius=20,amount=1}).changed)
    testing.expect(t,source_edit(&source,{kind=.Add,center=BLOCKS_CENTER,radius=6,amount=1}).changed)
    testing.expect(t,source_clone(&after,&source))
    testing.expect_value(t,grid_dense(&after.field),grid_dense(&source.field))
    // Undo and redo copy a snapshot back over the source.
    testing.expect(t,data_source_copy(&source,&before))
    blocks_same(t,&source,&before,{},{96,96,96})
    testing.expect(t,data_source_copy(&source,&after))
    blocks_same(t,&source,&after,{},{96,96,96})
    testing.expect(t,(source_value(&source,{40,24,40}) or_else 0)<0 && (source_value(&source,{40,10,40}) or_else 0)>0)
}
