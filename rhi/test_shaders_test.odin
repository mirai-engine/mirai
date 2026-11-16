package rhi

// Whether this build has the shaders of the tests, which the generation
// compiles from shaders/tests into shaders_gen_test.odin: every test build,
// and mirai check, which generates them first. Other builds of rhi, as the
// one of the mirai tool, come before any generation.
TEST_SHADERS :: #config(MIRAI_TEST_SHADERS, ODIN_TEST)

// A shader of the tests by its name (fill.comp); nil when there is none.
test_shader :: proc(name: string) -> ^Shader_Code {
	when TEST_SHADERS {
		for &shader in SHADERS {if shader.name == name {return &shader}}
	}
	return nil
}
