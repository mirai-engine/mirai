package shared_device

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "mirai:rhi"

// The devices the GPU tests of a process share. A device for each test costs
// it again what the driver keeps of the pipelines of a renderer, and several
// tests at once take gigabytes. A test takes a device and gives it back when
// it ends, so the GPU tests of a process run one at a time whatever
// ODIN_TEST_THREADS says; the tests without a GPU run beside them.
//
// The one package with state of its own (AGENTS.md): only tests import it.

@(private)
Shared :: struct {
	lock:    sync.Atomic_Mutex, // held from the first take of a test to its end, which may give it back from another thread
	holder:  ^testing.T,        // the test that holds it
	devices: [2]^rhi.Device,    // by hardware_rt
	refused: [2]string,         // why one could not be made: the takes after it say the same
	taken:   [2]bool,           // by the holder
	before:  [2][ALIVE]int,     // what was alive on each when the holder took it
	errors:  int,               // Error messages since the first take; atomic: drivers send them from their threads
}

@(private)
ALIVE :: 5

@(private)
shared: Shared

// The device of a GPU test, as rhi.device_create answers: nil and why when
// there is none. hardware_rt allows hardware ray tracing, as
// Device_Desc.allow_hardware_ray_tracing. The test destroys what it makes on
// the device before it ends, and fails if it leaves something alive or the
// device or its validation report errors. A test of a device itself (its
// capacities, its ring, its messages, a loss) makes its own.
take :: proc(t: ^testing.T, hardware_rt := true) -> (device: ^rhi.Device, message: string) {
	hold(t)
	i := int(hardware_rt)
	make_shared(i)
	d := shared.devices[i]
	if d == nil {return nil, shared.refused[i]}
	if !shared.taken[i] {
		rhi.device_validation_forget(d)
		shared.taken[i], shared.before[i] = true, alive(d)
	}
	return d, ""
}

// The device of a GPU test, or nil with the test told why: without a device
// a test is skipped where MIRAI_ALLOW_GPU_SKIP allows it and fails elsewhere.
take_or_skip :: proc(t: ^testing.T, hardware_rt := true, loc := #caller_location) -> ^rhi.Device {
	device, message := take(t, hardware_rt)
	if device == nil {skip(t, message, loc)}
	return device
}

// A device of its own for a test of a device itself, which destroys it, with
// the GPU of the process held as hold does; or nil as take_or_skip.
create_or_skip :: proc(t: ^testing.T, desc: rhi.Device_Desc, loc := #caller_location) -> ^rhi.Device {
	hold(t)
	device, message := rhi.device_create(desc)
	if device == nil {skip(t, message, loc)}
	return device
}

@(private)
skip :: proc(t: ^testing.T, message: string, loc: runtime.Source_Code_Location) {
	if rhi.gpu_skip_allowed() {
		fmt.eprintfln("%s skipped: %s", loc.procedure, message)
	} else {
		testing.expectf(t, false, "no GPU device: %s (set MIRAI_ALLOW_GPU_SKIP=1 to skip)", message, loc = loc)
	}
}

// Holds the GPU of the process until the test ends, for a test that makes its
// own device: no other GPU test runs beside it.
hold :: proc(t: ^testing.T) {
	if sync.atomic_load(&shared.holder) == t {return}
	sync.atomic_mutex_lock(&shared.lock)
	sync.atomic_store(&shared.holder, t)
	sync.atomic_store(&shared.errors, 0)
	shared.taken = {}
	testing.cleanup(t, give, t)
	keep_one()
}

// The NVIDIA Windows driver (616.92) frees the context of the worker threads
// of a process's last device while they still run: a device destroyed with
// none other alive and another made after it end the process at random
// (ODIN_WORKAROUNDS.md, Drivers). One device lives from the first hold to the
// end of the process, so the devices of the tests are never the last.
@(private)
keep_one :: proc() {
	if shared.devices[0] == nil && shared.devices[1] == nil {make_shared(1)}
}

@(private)
make_shared :: proc(i: int) {
	if shared.devices[i] != nil || shared.refused[i] != "" {return}
	context.allocator = runtime.heap_allocator()
	d, refusal := rhi.device_create({app_name = "mirai GPU tests", validation = true, allow_hardware_ray_tracing = i == 1, on_message = count_message, message_user = &shared.errors, allocator = context.allocator})
	shared.devices[i] = d
	if d == nil {shared.refused[i] = strings.clone(refusal != "" ? refusal : "no device")}
}

@(private)
count_message :: proc(kind: rhi.Message_Kind, text: string, user: rawptr) {
	rhi.message_print(kind, text, user)
	if kind == .Error {sync.atomic_add((^int)(user), 1)}
}

@(private)
alive :: proc(d: ^rhi.Device) -> [ALIVE]int {
	s := rhi.device_stats(d)
	return {s.buffers, s.textures, s.samplers, s.pipelines, s.accels}
}

// A device that failed, or on which the test left something, is not lent
// again: the next take makes another.
@(private)
give :: proc(data: rawptr) {
	t := (^testing.T)(data)
	defer sync.atomic_mutex_unlock(&shared.lock)
	defer sync.atomic_store(&shared.holder, nil)
	if errors := sync.atomic_load(&shared.errors); errors > 0 {
		testing.expectf(t, false, "the shared device reported %d errors", errors)
	}
	dropped: [2]^rhi.Device
	defer for d in dropped {if d != nil {rhi.device_destroy(d)}}
	defer keep_one()
	for taken, i in shared.taken {
		d := shared.devices[i]
		if !taken || d == nil {continue}
		idle := rhi.device_wait_idle(d)
		if errors := rhi.device_validation_errors(d); errors > 0 {
			testing.expectf(t, false, "validation reported %d errors on the shared device; last: %s", errors, rhi.device_validation_message(d))
		}
		left := alive(d) - shared.before[i]
		if left != {} {
			testing.expectf(t, false, "the test left alive on the shared device %d buffers, %d textures, %d samplers, %d pipelines and %d acceleration structures", left[0], left[1], left[2], left[3], left[4])
		}
		failure, text := rhi.device_failure(d)
		if failure != .None {testing.expectf(t, false, "the shared device failed: %s", text)}
		if !idle || failure != .None || left != {} {
			if idle {dropped[i] = d}
			shared.devices[i] = nil
		}
	}
}

@(private, fini)
shared_destroy :: proc "contextless" () {
	context = runtime.default_context()
	for d in shared.devices {
		if d == nil {continue}
		rhi.device_wait_idle(d)
		rhi.device_destroy(d)
	}
}
