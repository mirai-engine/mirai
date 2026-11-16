package sources

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:std/geom"
import importer "mirai:cook/import"

@(test)
every_imported_mesh_passes_the_checks_of_the_asset :: proc(t:^testing.T) {
    paths:=[]string{FIXTURES+"hierarchy.gltf",FIXTURES+"concave.obj",FIXTURES+"skeletal-analytic.glb",FIXTURES+"hierarchy.fbx",FIXTURES+"skinned.fbx",DEMO+"gallery/plant.gltf"}
    for path in paths {
        model,ok:=import_ok(t,path)
        if !ok {continue}
        defer importer.model_destroy(&model)
        types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
        for &mesh in model.meshes {
            source:=asset.Mesh_Source{vertices=mesh.vertices,skin=mesh.skin,morphs=mesh.morphs,morph_deltas=mesh.morph_deltas,flags=mesh.flags}
            geometry:asset.Mesh_Geometry
            if !testing.expectf(t,asset.mesh_build(source,mesh.indices,nil,&geometry,context.temp_allocator),"%s: mesh %s makes clusters",path,mesh.name) {continue}
            slots:=make([]asset.Material_Slot,len(mesh.slots),context.temp_allocator)
            for slot,i in mesh.slots {slots[i].id=slot.id;asset.text_set(slots[i].label[:],slot.label)}
            desc:=asset.Mesh_Desc{id={1,1},geometry=geometry,slots=slots,joints=mesh.joints}
            if len(mesh.skin)>0 {desc.skeleton={1,1}}
            doc:asset.Document
            made:=asset.mesh_document(&doc,&types,desc)
            if made==.None {asset.document_destroy(&doc)}
            testing.expectf(t,made==.None,"%s: mesh %s passes the checks",path,mesh.name)
        }
    }
}
