package mirai_render

import "core:math"
import "core:mem"
import "core:testing"
import "mirai:rhi"
import mm "mirai:std/math"

@(private = "file")
edit_fixture :: proc(t: ^testing.T, f: ^Fixture, loc := #caller_location) -> bool {
	settings := DEFAULT_SETTINGS
	settings.gi_enabled, settings.reflections, settings.taa = false, false, false
	// Images are compared pixel by pixel: every pixel traces its own rays.
	settings.reference_lights = true
	return fixture_init(t, f, 160, 120, settings, hardware_rt = false, loc = loc)
}

@(private = "file")
edit_texture :: proc(r: ^Renderer, color: [4]u8) -> Texture_Handle {
	pixels: [64]u8
	for &value, i in pixels {value = color[i % 4]}
	handle, _ := texture_add(r, {pixels = pixels[:], width = 4, height = 4, srgb = true, name = "edit"})
	return handle
}

@(test)
shared_grid_instances_keep_all_quadrants_after_scene_rebuild_and_preview_retirement :: proc(t:^testing.T) {
	f: Fixture
	if !edit_fixture(t, &f) {return}
	defer fixture_destroy(&f)
	r, device := f.renderer, f.device
	camera:=Camera{position={8,8,12},forward={-8,-8,-12},up={0,1,0},fov_y=50,near=0.05,far=200,exposure=UNIT_EXPOSURE}
	material:=DEFAULT_MATERIAL
	material.emission={3,3,3}
	materials_set(r,{material})
	centers:=[4]Vec3{{-16,0,-16},{16,0,-16},{-16,0,16},{16,0,16}}
	meshes:[4]Mesh_Handle
	descs:[8]Instance_Desc
	for center,i in centers {
		vertices,indices:=edit_grid(32,32)
		for &v in vertices {v.position+=center;v.color=0xffffffff;v.material=0}
		added:bool
		meshes[i],added=edit_add(r,vertices[:],indices[:],{1})
		delete(vertices);delete(indices)
		if !testing.expect(t,added,r.error) {return}
		descs[i]=Instance_Desc{object_id=u64(i+1),mesh=meshes[i],transform=Mat4(1),material=1,tint={1,1,1},uniform_color=true}
		descs[i+4]=descs[i]
		descs[i+4].object_id=u64(i+5)
		descs[i+4].transform[0,3]=72
		descs[i+4].tint={0,1,0}
	}
	scene_given(r,descs[:4],nil,{},Environment{})
	for _ in 0..<3 {if !testing.expect(t,renderer_frame(r,{camera=camera}),r.error) {return}}
	reference,_,_,captured:=golden_capture(r)
	defer delete(reference)
	if !testing.expect(t,captured,r.error) {return}
	// Each staging buffer, once made, is the one the later uploads use.
	staging:=r.scene.geometry_staging
	testing.expect(t,staging!={})
	staging_sizes:[len(staging)]u64
	for b,i in staging {if b!=0 {staging_sizes[i]=rhi.buffer_size(device,b)}}
	view_projection:=mm.perspective(camera.fov_y*0.01745329252,160.0/120.0,camera.near,camera.far)*mm.look_at(camera.position,camera.position+camera.forward,camera.up)
	for point in ([4]Vec3{{-2,0,-2},{2,0,-2},{-2,0,2},{2,0,2}}) {
		pixel,_,visible:=mm.world_to_screen(point,{160,120},view_projection)
		at:=(int(pixel.y)*160+int(pixel.x))*4
		if testing.expect(t,visible && at>=0 && at+3<len(reference)) {testing.expectf(t,reference[at]>150,"the quadrant at %v is present (%v)",point,reference[at:][:3])}
	}
	for pass in 0..<4 {
		if pass==2 {
			for handle in meshes {testing.expect(t,mesh_remove(r,handle))}
			for center,i in centers {
				vertices,indices:=edit_grid(32,32)
				for &v in vertices {v.position+=center;v.color=0xffffffff;v.material=0}
				meshes[i],_=edit_add(r,vertices[:],indices[:],{1})
				delete(vertices);delete(indices)
				descs[i].mesh,descs[i+4].mesh=meshes[i],meshes[i]
			}
		}
		scene_given(r,descs[:],nil,{},Environment{})
		if pass==1 || pass==3 {
			preview:Mesh_Handle
			for revision in 0..<2 {
				vertices,indices:=edit_grid(32,32,0.05*f32(revision+1))
				for &v in vertices {v.position+=centers[0]}
				previous:=preview
				preview,_=edit_add(r,vertices[:],indices[:],{1,1})
				delete(vertices);delete(indices)
				if revision>0 {testing.expect(t,mesh_remove(r,previous))}
				for index in ([2]u32{0,4}) {
					hidden:=descs[index];hidden.hidden=true
					testing.expect(t,scene_update(r,index,{hidden}))
					copy:=descs[index];copy.mesh=preview;copy.copy_owner=99;copy.copy_variant=1
					testing.expect(t,scene_update(r,8+index/4,{copy}))
				}
				for _ in 0..<3 {if !testing.expect(t,renderer_frame(r,{camera=camera}),r.error) {return}}
			}
			testing.expect(t,mesh_remove(r,preview))
			for index in ([2]u32{0,4}) {testing.expect(t,scene_update(r,index,{descs[index]}))}
			testing.expect(t,scene_update(r,8,nil,true))
		}
		for _ in 0..<3 {if !testing.expect(t,renderer_frame(r,{camera=camera}),r.error) {return}}
		actual,_,_,ok:=golden_capture(r)
		testing.expect(t,ok,r.error)
		testing.expectf(t,len(actual)==len(reference) && mem.compare(actual,reference)==0,"all quadrants remain after scene rebuild, shared geometry and retirement (pass %d)",pass)
		delete(actual)
		for b,i in staging {
			if b==0 {continue}
			testing.expect_value(t,r.scene.geometry_staging[i],b)
			testing.expect_value(t,rhi.buffer_size(device,b),staging_sizes[i])
		}
	}
	testing.expectf(t,rhi.device_validation_errors(device)==0,"validation: %s",rhi.device_validation_message(device))
}

// Geometry and textures removed after they were uploaded leave the image a
// renderer that never had them draws.
@(test)
removed_meshes_and_textures_leave_the_image_of_a_scene_without_them :: proc(t: ^testing.T) {
	camera := Camera{position = {3, 5, 6}, forward = {-3, -4.5, -6}, up = {0, 1, 0}, fov_y = 50, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	sun := Sun_Desc{direction = {0.4, 0.8, 0.3}, color = {1, 1, 1}, illuminance = 2 * math.PI, enabled = true}
	environment := Environment{sky = {0.2, 0.25, 0.3}}
	images: [2][]u8
	defer for image in images {delete(image)}
	for pass in 0 ..< 2 {
		f: Fixture
		if !edit_fixture(t, &f) {return}
		defer fixture_destroy(&f)
		r, device := f.renderer, f.device
		meshes: [3]Mesh_Handle
		textures: [3]Texture_Handle
		for cells, i in ([3]int{20, 16, 4}) {
			if pass == 1 && i == 1 {continue}
			vertices, indices := edit_grid(cells, f32(8 - 3 * i), f32(i) * 0.75)
			added: bool
			meshes[i], added = edit_add(r,vertices[:],indices[:],[]u32{0, 1})
			testing.expect(t, added, r.error)
			delete(vertices)
			delete(indices)
		}
		for color, i in ([3][4]u8{{255, 0, 0, 255}, {0, 255, 0, 255}, {0, 0, 255, 255}}) {
			if pass == 1 && i == 0 {continue}
			textures[i] = edit_texture(r, color)
		}
		if pass == 0 {
			material := DEFAULT_MATERIAL
			material.textures[.Base_Color] = textures[0]
			materials_set(r, {material})
			scene_given(r, []Instance_Desc{{object_id = 1, mesh = meshes[0], transform = Mat4(1), tint = {1, 1, 1}}, {object_id = 2, mesh = meshes[1], transform = Mat4(1), tint = {1, 1, 1}}, {object_id = 3, mesh = meshes[2], transform = Mat4(1), tint = {1, 1, 1}}}, nil, sun, environment)
			testing.expect(t, renderer_frame(r,{camera=camera}), r.error)
			kept:=r.scene.meshes[meshes[2]]
			testing.expect(t, mesh_remove(r, meshes[1]))
			vertices,indices:=edit_grid(64,10)
			large,added:=edit_add(r,vertices[:],indices[:],{0,1})
			delete(vertices);delete(indices)
			testing.expect(t,added && large==meshes[1])
			testing.expect(t,renderer_commit_geometry(r),r.error)
			testing.expect_value(t,r.scene.meshes[meshes[2]],kept)
			testing.expect(t,mesh_remove(r,large))
			testing.expect(t, texture_remove(r, textures[0]))
			testing.expect(t, !texture_remove(r, textures[0]) && !texture_remove(r, 0))
			testing.expect_value(t, texture_count(r), 3)
			testing.expect_value(t, texture_index(r, textures[0]), GPU_NONE)
			again := edit_texture(r, {9, 9, 9, 255})
			testing.expect_value(t, again, textures[0])
			testing.expect(t, texture_remove(r, again) && texture_remove(r, textures[2]))
			testing.expect_value(t, texture_count(r), 2)
			textures[2] = edit_texture(r, {0, 0, 255, 255})
		}
		material := DEFAULT_MATERIAL
		material.textures[.Base_Color] = textures[2]
		materials_set(r, {material})
		if pass==1 {
			scene_given(r, []Instance_Desc{{object_id = 1, mesh = meshes[0], transform = Mat4(1), tint = {1, 1, 1}}, {object_id = 3, mesh = meshes[2], transform = Mat4(1), tint = {1, 1, 1}}}, nil, sun, environment)
			testing.expect(t,renderer_frame(r,{camera=camera}),r.error)
		}
		for _ in 0 ..< 3 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
		captured: bool
		images[pass], _, _, captured = golden_capture(r)
		testing.expect(t, captured, r.error)
		testing.expectf(t, rhi.device_validation_errors(device) == 0, "validation: %s", rhi.device_validation_message(device))
	}
	if images[0] == nil || images[1] == nil {return}
	testing.expect(t, len(images[0]) == len(images[1]) && mem.compare(images[0], images[1]) == 0, "the image is the one of a renderer that never had what was removed")
	blue := 0
	for at := 0; at < len(images[0]); at += 4 {
		if images[0][at + 2] > images[0][at] + 20 {blue += 1}
	}
	testing.expectf(t, blue > 200, "the textured slot shows its texture (%d pixels)", blue)
}
