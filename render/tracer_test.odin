package mirai_render

import "core:fmt"
import "core:reflect"
import "core:strings"
import "core:testing"

// A device makes the pipelines of one tracer: each pass traced by hardware
// has a twin the other runs (Contact's also blurs for either), and no
// pipeline belongs to both.
@(test)
each_traced_pass_has_one_pipeline_per_tracer :: proc(t: ^testing.T) {
	for id in Pipeline_Id {
		testing.expectf(t, !(pipeline_uses_hardware(id) && pipeline_uses_software(id)), "%v belongs to one tracer", id)
		testing.expectf(t, !pipeline_uses_software(id) || id in LAZY_PIPELINES || pipeline_required(id), "%v is required where rays are traced by software", id)
		name := fmt.tprint(id)
		if !strings.has_suffix(name, "_Hw") {continue}
		testing.expectf(t, pipeline_uses_hardware(id), "%v traces by hardware", id)
		twin, found := reflect.enum_from_name(Pipeline_Id, name[:len(name) - len("_Hw")])
		testing.expectf(t, found && !pipeline_uses_hardware(twin), "%v has a twin rays traced by software run", id)
	}
}
