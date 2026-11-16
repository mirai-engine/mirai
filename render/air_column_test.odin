package mirai_render

import "core:math"
import "core:testing"

@(test)
the_air_overhead_is_the_column_of_its_densities :: proc(t: ^testing.T) {
	over := air_overhead(AIR_EARTH)
	// The optical depth straight up: Rayleigh 8 km of 33.1e-6 in blue, Mie 1.2 km of 4.44e-6, ozone 15 km of 0.085e-6.
	blue := math.exp(f32(33.1e-6 * 8000 * (1 - math.exp(f64(-100000.0 / 8000))) + 4.44e-6 * 1200 + 0.085e-6 * 15000))
	testing.expectf(t, abs(over.z - blue) < 1e-4, "blue: %v against %v", over.z, blue)
	testing.expect(t, over.z > over.y && over.y > over.x, "the air stops more blue than red")
}
