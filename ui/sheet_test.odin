package ui

import "mirai:asset"
import "mirai:std/serial"

// The theme of the editor, the sheet the tests of the controls draw with.
TEST_THEME :: #load("../assets/editor/theme.ui")

// context_init with the theme of the editor as the sheet.
test_context_init :: proc(ctx:^Context,desc:Context_Desc) -> bool {
    if !context_init(ctx,desc) {return false}
    types:asset.Types
    asset.types_init(&types,context.temp_allocator)
    defer asset.types_destroy(&types)
    file:asset.Asset
    if asset.asset_open(&file,TEST_THEME,context.temp_allocator)!=.None {context_destroy(ctx);return false}
    defer asset.asset_close(&file)
    data:Tree_Data
    styles,styles_error:=asset.asset_rows(&file,&types,asset.UI_TABLE_STYLES,"",Node_Style)
    variants,variants_error:=asset.asset_rows(&file,&types,asset.UI_TABLE_VARIANTS,"",Tree_Style_Variant)
    infos,infos_error:=asset.asset_rows(&file,&types,asset.UI_TABLE_STYLE_INFOS,"",Tree_Style_Info)
    tokens,tokens_error:=asset.asset_rows(&file,&types,asset.UI_TABLE_TOKENS,"",Tree_Token)
    if styles_error!=.None || variants_error!=.None || infos_error!=.None || tokens_error!=.None || !context_sheet_set(ctx,{styles=styles,variants=variants,style_infos=infos,tokens=tokens}) {
        context_destroy(ctx)
        return false
    }
    return true
}

// Gives a color token of the sheet another value.
test_tone_set :: proc(ctx:^Context,name:string,color:Color) {
    for &token in ctx.sheet_tokens {if serial.text_field(token.name[:])==name {token.color=color}}
}
