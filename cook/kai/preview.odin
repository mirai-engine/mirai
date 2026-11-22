package kai_assets

import "base:runtime"
import "core:fmt"
import "core:strings"
import "mirai:asset"
import "mirai:std/base"
import "mirai:store"
import vcs "mirai:kai"

// The previews of assets the web view of a node shows (vcs.Preview_Kind): the
// summary of an asset, read through the schema its file carries as
// `mirai asset get` reads it; the detail of what a change did to it, as
// file_detail tells it; and the thumbnail its editor already keeps. The
// machine that publishes a bookmark of an org's project publishes those of
// the assets its changes touched (bookmarks_publish), never of a file a
// scope of the org takes, and nothing renders a thumbnail for them.

SUMMARY_FILE_MAX :: 32<<20  // bytes of an asset past which its summary is its kind and size
SUMMARY_NAMES :: 8          // entities, clips or tables a summary names
SUMMARY_SCAN_MAX :: 1<<16   // rows a summary reads of one table
PREVIEW_CHANGES_MAX :: 64   // changes a publish walks back from its bookmarks
PREVIEW_FILES_MAX :: 256    // files one publish makes previews of
PREVIEW_BYTES_MAX :: 64<<20 // bytes of assets one publish reads

// What gives the thumbnail of an asset, as a PNG of at most
// vcs.PREVIEW_SIDE_MAX pixels a side, into out: false when there is none
// here. The editor gives one from the views it keeps; nothing draws one.
Thumbnail_Source :: struct {
    data:rawptr,
    png:proc(data:rawptr,file:[]u8,out:^[dynamic]u8) -> bool,
}

// The summary of the asset in bytes as a preview record (vcs.preview_summary_encode),
// in allocator: false when the bytes are not an asset this build reads.
asset_summary :: proc(bytes:[]u8,allocator:=context.allocator) -> (record:[]u8,ok:bool) {
    header,he:=asset.header_read(bytes)
    if he!=.None {return}
    facts:=make([dynamic]vcs.Preview_Fact,context.temp_allocator)
    kind:=kind_name(header.kind)
    if len(bytes)>SUMMARY_FILE_MAX {
        append(&facts,vcs.Preview_Fact{"File",vcs.bytes_text(i64(len(bytes)))})
        r,e:=vcs.preview_summary_encode(kind,facts[:],allocator)
        return r,e==.None
    }
    doc:asset.Document
    if asset.document_read(&doc,bytes)!=.None {return}
    defer asset.document_destroy(&doc)
    fact :: proc(facts:^[dynamic]vcs.Preview_Fact,label,value:string) {
        if value!="" && len(facts)<vcs.PREVIEW_FACTS_MAX {append(facts,vcs.Preview_Fact{label,value})}
    }
    switch header.kind {
    case asset.KIND_SCENE:
        if .Prefab in header.flags {kind="prefab"}
        rows:=table_rows(&doc,"entities")
        fact(&facts,"Entities",fmt.tprint(rows))
        top:=strings.builder_make(context.temp_allocator)
        tops:=0
        for row in 0..<min(rows,SUMMARY_SCAN_MAX) {
            parent,_,_:=asset.document_get(&doc,fmt.tprintf("entities[%d].parent",row))
            if p,is:=parent.(base.Entity_Id);!is || p!=0 {continue}
            tops+=1
            if tops>SUMMARY_NAMES {continue}
            name,_,_:=asset.document_get(&doc,fmt.tprintf("entities[%d].name",row))
            if tops>1 {strings.write_string(&top,", ")}
            text,_:=name.(string)
            strings.write_string(&top,text==""?"(unnamed)":text)
        }
        if tops>SUMMARY_NAMES {fmt.sbprintf(&top," and %d more",tops-SUMMARY_NAMES)}
        fact(&facts,"Top entities",strings.to_string(top))
        components:=strings.builder_make(context.temp_allocator)
        for &t in doc.tables {
            if t.name=="entities" || t.name=="scene" || t.rows==0 {continue}
            if len(components.buf)>0 {strings.write_string(&components,", ")}
            strings.write_string(&components,t.name)
        }
        fact(&facts,"Components",strings.to_string(components))
    case asset.KIND_MESH:
        fact(&facts,"Vertices",fact_text(&doc,"mesh.vertex_count"))
        fact(&facts,"Triangles",fact_text(&doc,"mesh.triangle_count"))
        fact(&facts,"Materials",fmt.tprint(table_rows(&doc,"slots")))
        lo,hi:[3]f64
        sized:=true
        for k in 0..<3 {
            a,_,ea:=asset.document_get(&doc,fmt.tprintf("mesh.bounds_min[%d]",k))
            b,_,eb:=asset.document_get(&doc,fmt.tprintf("mesh.bounds_max[%d]",k))
            x,xa:=a.(f64)
            y,yb:=b.(f64)
            if ea!=.None || eb!=.None || !xa || !yb {sized=false;break}
            lo[k],hi[k]=x,y
        }
        if sized {fact(&facts,"Extent",fmt.tprintf("%.3g × %.3g × %.3g m",hi.x-lo.x,hi.y-lo.y,hi.z-lo.z))}
        if skeleton,_,e:=asset.document_get(&doc,"mesh.skeleton");e==.None {
            if id,is:=skeleton.(base.Asset_Id);is && id!={} {fact(&facts,"Skinned","yes")}
        }
    case asset.KIND_TEXTURE:
        fact(&facts,"Pixels",fmt.tprintf("%s × %s",fact_text(&doc,"texture.width"),fact_text(&doc,"texture.height")))
        fact(&facts,"Format",fact_text(&doc,"texture.format"))
        fact(&facts,"Mips",fact_text(&doc,"texture.mip_count"))
        if layers:=fact_text(&doc,"texture.layers");layers!="1" {fact(&facts,"Layers",layers)}
    case asset.KIND_ANIMATION:
        clips:=table_rows(&doc,"clips")
        fact(&facts,"Clips",fmt.tprint(clips))
        b:=strings.builder_make(context.temp_allocator)
        for row in 0..<min(clips,SUMMARY_NAMES) {
            if row>0 {strings.write_string(&b,", ")}
            strings.write_string(&b,fact_text(&doc,fmt.tprintf("clips[%d].name",row)))
            if length,known:=clip_length(&doc,row);known {fmt.sbprintf(&b," (%.3g s)",length)}
        }
        if clips>SUMMARY_NAMES {fmt.sbprintf(&b," and %d more",clips-SUMMARY_NAMES)}
        fact(&facts,"Names",strings.to_string(b))
        fact(&facts,"Tracks",fmt.tprint(table_rows(&doc,"tracks")))
    case asset.KIND_SOUND:
        fact(&facts,"Channels",fact_text(&doc,"sound.channels"))
        fact(&facts,"Sample rate",fmt.tprintf("%s Hz",fact_text(&doc,"sound.sample_rate")))
        frames,_,fe:=asset.document_get(&doc,"sound.frames")
        rate,_,re:=asset.document_get(&doc,"sound.sample_rate")
        f,fok:=frames.(u64)
        r,rok:=rate.(u64)
        if fe==.None && re==.None && fok && rok && f>0 && r>0 {fact(&facts,"Length",fmt.tprintf("%.3g s",f64(f)/f64(r)))}
    case asset.KIND_SKELETON:
        fact(&facts,"Bones",fmt.tprint(table_rows(&doc,"bones")))
        fact(&facts,"Sockets",fmt.tprint(table_rows(&doc,"sockets")))
    case asset.KIND_MATERIAL:
        fact(&facts,"Alpha",fact_text(&doc,"material.alpha_mode"))
        fact(&facts,"Two sided",fact_text(&doc,"material.two_sided"))
        fact(&facts,"Metallic",fact_text(&doc,"material.metallic"))
        fact(&facts,"Roughness",fact_text(&doc,"material.roughness"))
        fact(&facts,"Parameters",fmt.tprint(table_rows(&doc,"parameters")))
    case:
        for &t,i in doc.tables {
            if i>=SUMMARY_NAMES {break}
            fact(&facts,t.name,fmt.tprintf("%d row%s",t.rows,t.rows==1?"":"s"))
        }
    }
    fact(&facts,"File",vcs.bytes_text(i64(len(bytes))))
    r,e:=vcs.preview_summary_encode(kind,facts[:],allocator)
    return r,e==.None
}

// The name of a kind the engine defines, or its four characters.
@(private)
kind_name :: proc(kind:asset.Fourcc) -> string {
    if info,found:=asset.kind_info(kind);found {return info.name}
    buffer:=new([4]u8,context.temp_allocator)
    return asset.fourcc_text(kind,buffer)
}

@(private)
table_rows :: proc(doc:^asset.Document,name:string) -> int {
    for &t in doc.tables {
        if t.name==name {return t.rows}
    }
    return 0
}

// The value at path as `mirai asset get` writes it on one line, a text or an
// enum member without its quotes; "" when there is none.
@(private)
fact_text :: proc(doc:^asset.Document,path:string) -> string {
    text:=value_text(doc,path,context.temp_allocator)
    if len(text)>=2 && text[0]=='"' && text[len(text)-1]=='"' && strings.index_byte(text[1:len(text)-1],'"')<0 {return text[1:len(text)-1]}
    return text
}

// The time of the last key of the tracks of a clip, in seconds.
@(private)
clip_length :: proc(doc:^asset.Document,clip:int) -> (length:f64,known:bool) {
    first,_,e1:=asset.document_get(doc,fmt.tprintf("clips[%d].first_track",clip))
    count,_,e2:=asset.document_get(doc,fmt.tprintf("clips[%d].track_count",clip))
    t0,ok1:=first.(u64)
    tn,ok2:=count.(u64)
    if e1!=.None || e2!=.None || !ok1 || !ok2 {return}
    scanned:=0
    for track in t0..<t0+min(tn,SUMMARY_SCAN_MAX) {
        k0,_,e3:=asset.document_get(doc,fmt.tprintf("tracks[%d].first_key",track))
        kn,_,e4:=asset.document_get(doc,fmt.tprintf("tracks[%d].key_count",track))
        a,ok3:=k0.(u64)
        n,ok4:=kn.(u64)
        if e3!=.None || e4!=.None || !ok3 || !ok4 || n==0 {continue}
        last,_,e5:=asset.document_get(doc,fmt.tprintf("keys[%d].time",a+n-1))
        if time,is:=last.(f64);e5==.None && is {
            length=max(length,time)
            known=true
        }
        scanned+=1
        if scanned>=SUMMARY_SCAN_MAX {break}
    }
    return
}

// The detail of what changed from before to after, the bytes of the two sides
// of an asset (nil: not there), as a preview record (vcs.preview_detail_encode),
// in allocator: false when they are not an asset of one kind.
asset_detail :: proc(before,after:[]u8,allocator:=context.allocator) -> (record:[]u8,ok:bool) {
    if len(before)>DETAIL_BYTES || len(after)>DETAIL_BYTES {return}
    out:File_Detail
    if !detail_asset({before,after},&out,context.temp_allocator) {return}
    rows:=make([]vcs.Preview_Row,len(out.rows),context.temp_allocator)
    for r,i in out.rows {rows[i]={mark=r.mark,name=r.name,text=r.text}}
    d:=vcs.Preview_Detail{added=out.added,removed=out.removed,changed=out.changed,cut=out.cut,rows=rows}
    r,e:=vcs.preview_detail_encode(&d,allocator)
    return r,e==.None
}

// Publishes the previews of the assets the changes from targets back to
// known (what this device published before) touched, of the project of org:
// the summary of each asset a change leaves, the detail of what it did to it
// and, from thumbnails, its thumbnail. A path a scope of the org takes gets
// none, nor does anything when the org's scopes do not read. Walks at most
// PREVIEW_CHANGES_MAX changes, PREVIEW_FILES_MAX files and PREVIEW_BYTES_MAX
// bytes, one file at a time in memory; what was published before is not made
// again. Returns how many records it published.
previews_publish :: proc(m:^vcs.Machine,s:^store.Store,org,project:vcs.Log_Id,targets,known:[]vcs.Revision,thumbnails:=Thumbnail_Source{}) -> (published:int) {
    state:vcs.Org_State
    if vcs.org_state_load(&m.store,org,&state,context.temp_allocator)!=.None || !state.folded {return}
    defer vcs.org_state_destroy(&state)
    seen:=make(map[vcs.Revision]bool,context.temp_allocator)
    for k in known {seen[k]=true}
    stack:=make([dynamic]vcs.Revision,context.temp_allocator)
    append(&stack,..targets)
    diffs:=make([dynamic]vcs.Diff,context.temp_allocator)
    // Grown while a file's temporary memory is taken back: not in it.
    done:=make(map[store.Hash]bool)
    defer delete(done)
    png:=make([dynamic]u8)
    defer delete(png)
    changes,files,read:=0,0,u64(0)
    for len(stack)>0 && changes<PREVIEW_CHANGES_MAX && files<PREVIEW_FILES_MAX && read<PREVIEW_BYTES_MAX {
        r:=pop(&stack)
        if r=={} || seen[r] {continue}
        seen[r]=true
        c,ce:=vcs.change_get(s,r,context.temp_allocator)
        if ce!=.None {continue}
        changes+=1
        base_tree:store.Hash
        if len(c.parents)>0 {
            if p,pe:=vcs.change_get(s,c.parents[0],context.temp_allocator);pe==.None {base_tree=p.tree} else {continue}
        }
        append(&stack,..c.parents)
        clear(&diffs)
        if vcs.tree_diff(s,base_tree,c.tree,&diffs,context.temp_allocator)!=.None {continue}
        for d in diffs {
            if files>=PREVIEW_FILES_MAX || read>=PREVIEW_BYTES_MAX {break}
            if d.after.kind==.Conflict || d.before.kind==.Conflict {continue}
            if _,taken:=vcs.scope_of(&state.fold,project,d.path);taken {continue}
            runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
            sides:[2][]u8
            for f,k in ([2]vcs.File{d.before,d.after}) {
                if f.address=={} || f.size>SUMMARY_FILE_MAX {continue}
                read+=f.size
                bytes,be:=vcs.file_bytes(s,f.address,context.temp_allocator)
                if be!=.None {continue}
                if _,he:=asset.header_read(bytes);he==.None {sides[k]=bytes}
            }
            if sides[0]==nil && sides[1]==nil {continue}
            files+=1
            if sides[1]!=nil && !done[d.after.address] {
                done[d.after.address]=true
                key:=vcs.preview_key(.Summary,{},d.after.address)
                if !vcs.preview_published(m,org,key) {
                    if record,ok:=asset_summary(sides[1],context.temp_allocator);ok && vcs.machine_publish_preview(m,org,.Summary,key,record)==.None {published+=1}
                }
                key=vcs.preview_key(.Thumbnail,{},d.after.address)
                clear(&png)
                if thumbnails.png!=nil && !vcs.preview_published(m,org,key) && thumbnails.png(thumbnails.data,sides[1],&png) {
                    if vcs.machine_publish_preview(m,org,.Thumbnail,key,png[:])==.None {published+=1}
                }
            }
            if (d.before.address=={} || sides[0]!=nil) && (d.after.address=={} || sides[1]!=nil) {
                key:=vcs.preview_key(.Detail,d.before.address,d.after.address)
                if !vcs.preview_published(m,org,key) {
                    if record,ok:=asset_detail(sides[0],sides[1],context.temp_allocator);ok && vcs.machine_publish_preview(m,org,.Detail,key,record)==.None {published+=1}
                }
            }
        }
    }
    return
}
