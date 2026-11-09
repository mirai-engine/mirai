package common

// What the block encoders share: their options, the 4x4 blocks they
// read and the surfaces the perceptual activity is measured on.

// Effort of an encode. The public Low, Normal and High are Fast,
// Slow and Very_Slow; Very_Fast and Reference are its hidden levels.
Level :: enum u8 {Very_Fast, Fast, Slow, Very_Slow, Reference}

// The bits of rrDXTCOptions, at the same positions.
Option :: enum u8 {
    BC1_One_Bit_Alpha        = 0, // BC1 keeps texels with alpha < 128 transparent
    BC3457_Preserve_Extremes = 1, // alpha (BC3, BC7) or every channel (BC4, BC5) keeps 0 and 255
    BC7_Ignore_Alpha         = 2,
    BC6_Favor_Luminance      = 4,
    Avoid_Wide_Vectors       = 5,
    Prefer_Wide_Vectors      = 6,
    Linear_To_SRGB           = 7,
}
Options :: bit_set[Option;u32]

// rrDXTCRD_Options.
RD_Options :: struct {
    effort:Level,
    use_bc3_alpha_lambda:bool,
    bc3_alpha_lambda:int,
}

Error :: enum u8 {
    None,
    Out_Of_Memory,
    Invalid, // an input the encoder cannot take; the public package says which
}

// 4x4 texels row by row, four 8-bit channels in the order the encoder that
// reads them expects (RGBA, BGRA for the non-RDO BC1 and BC3 color encoder).
Color_Block :: [16][4]u8
// One float per texel of a block: the activity (perceptual weight) of the RDO.
Float_Block :: [16]f32
// RGBA half floats (the bits of f16) of a BC6H block.
Half_Block :: [16][4]u16
// RGBA floats of a BC6H block, what its RDO reads.
Float4_Block :: [16][4]f32
// One or two 16-bit unsigned channels per texel: what BC4 and BC5 read.
R16_Block :: [16]u16
RG16_Block :: [16][2]u16

Pixel_Format :: enum u8 {RGBA8, RGBA16F, RGBA32F, R32F}

pixel_bytes :: #force_inline proc "contextless" (format:Pixel_Format) -> int {
    switch format {
    case .RGBA8,.R32F: return 4
    case .RGBA16F: return 8
    case .RGBA32F: return 16
    }
    return 4
}

// Rows from the top; stride in bytes between rows. A view of part of another
// surface shares its pixels and stride.
Surface :: struct {
    pixels:[]u8,
    width,height,stride:int,
    format:Pixel_Format,
}

surface_row :: #force_inline proc "contextless" (s:Surface,y:int) -> []u8 {
    start:=y*s.stride
    return s.pixels[start:start+s.width*pixel_bytes(s.format)]
}

// The rectangle (x,y,w,h) of s, which must lie inside it, with w and h above 0.
surface_view :: proc "contextless" (s:Surface,x,y,w,h:int) -> Surface {
    start:=y*s.stride+x*pixel_bytes(s.format)
    end:=start+(h-1)*s.stride+w*pixel_bytes(s.format)
    return {pixels=s.pixels[start:end],width=w,height=h,stride=s.stride,format=s.format}
}
