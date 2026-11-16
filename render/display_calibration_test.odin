package mirai_render

import "core:math"
import "core:testing"

@(test)
every_display_transform_shows_the_meters_gray_alike :: proc(t: ^testing.T) {
	testing.expect_value(t, display_exposure_bias(.ACES_2), EXPOSURE_BIAS)
	card := MIDDLE_GRAY * math.pow(f32(2), display_exposure_bias(.Neutral))
	// Where PBR Neutral takes its constant offset and has not started to roll off.
	testing.expectf(t, card >= 0.08 && card - DISPLAY_NEUTRAL_OFFSET < 0.76, "the card is a midtone of Neutral: %v", card)
	testing.expectf(t, abs(card - DISPLAY_NEUTRAL_OFFSET - DISPLAY_ACES_GRAY) < 1e-5, "Neutral shows the card as %v, ACES 2.0 as %v", card - DISPLAY_NEUTRAL_OFFSET, DISPLAY_ACES_GRAY)
}

@(test)
exposure_follows_the_bias_of_the_transform :: proc(t: ^testing.T) {
	ev100 := f32(10)
	testing.expect_value(t, exposure_of_ev100(ev100), exposure_of_ev100(ev100, EXPOSURE_BIAS))
	ratio := exposure_of_ev100(ev100, display_exposure_bias(.Neutral)) / exposure_of_ev100(ev100, display_exposure_bias(.ACES_2))
	testing.expectf(t, abs(ratio - math.pow(f32(2), display_exposure_bias(.Neutral) - EXPOSURE_BIAS)) < 1e-5, "the exposure ratio is that of the bias: %v", ratio)
}
