package gridfile

import "mirai:asset"
import "mirai:std/base"

// .grid, a state of a grid of the vfx plugin in a file: what the
// cells of its region held, which a Particle_Grid that names it starts from.
//
//   grid   Grid_Info, one row
//   cells  f32: of each cell from the first of the region, x fastest, then
//          y, then z, its layers of four floats in order

VERSION :: 1

Grid_Info :: struct {
    cells:[3]u32,
    layers:u32,
    cell_size:f32 `mirai:"unit=m"`,
}

Grid_Desc :: struct {
    id:base.Asset_Id,
    info:Grid_Info,
    cells:[]f32,
    source:^asset.Import_Info, // of a state an import wrote; nil for one written by code
}

// The floats a grid of info holds: four for each layer of each cell.
grid_floats :: proc "contextless" (info:Grid_Info) -> int {
    return int(info.cells.x)*int(info.cells.y)*int(info.cells.z)*int(info.layers)*4
}

grid_valid :: proc "contextless" (info:Grid_Info,cells:int) -> bool {
    return info.cells.x>0 && info.cells.y>0 && info.cells.z>0 && info.layers>=1 && info.layers<=4 && info.cell_size>0 && cells==grid_floats(info)
}

// The file of a state, as bytes from allocator.
grid_bytes :: proc(types:^asset.Types,desc:Grid_Desc,allocator:=context.allocator) -> (data:[]u8,error:asset.Error) {
    if !grid_valid(desc.info,len(desc.cells)) {return nil,.Invalid}
    doc:asset.Document
    asset.document_init(&doc,GRID_KIND,desc.id,allocator)
    defer asset.document_destroy(&doc)
    doc.kind_version=VERSION
    info:=desc.info
    asset.document_put_row(&doc,types,"grid",&info) or_return
    asset.document_put(&doc,types,"cells",desc.cells,{.Bulk},.Stream) or_return
    if desc.source!=nil {asset.import_put(&doc,types,desc.source) or_return}
    return asset.document_bytes(&doc,allocator)
}

// The state a file holds; Corrupt when its cells are not those of its grid.
grid_view :: proc(a:^asset.Asset,types:^asset.Types) -> (info:Grid_Info,cells:[]f32,error:asset.Error) {
    asset.kind_check(a,GRID_KIND,VERSION) or_return
    row:=asset.asset_row(a,types,"grid",Grid_Info) or_return
    cells=asset.asset_rows(a,types,"cells","",f32) or_return
    if !grid_valid(row^,len(cells)) {return {},nil,.Corrupt}
    return row^,cells,.None
}
