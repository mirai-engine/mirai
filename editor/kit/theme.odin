package kit

import "mirai:asset"
import "mirai:host"
import "mirai:ui"

// The widgets and the look of the editor, which a game does not contain. The
// look is a style file of the kind the interfaces of a game use, its tokens
// and its named styles (the button and its variants), and it is read as a
// game reads one: what changes it is that file, edited as any other .ui.
THEME :: #load("../../assets/editor/theme.ui")

// Gives ctx the theme as its sheet: a transaction.
theme_set :: proc(ctx:^ui.Context) -> bool {
    types:asset.Types
    asset.types_init(&types,context.temp_allocator)
    defer asset.types_destroy(&types)
    file:asset.Asset
    if asset.asset_open(&file,THEME,context.temp_allocator)!=.None {return false}
    defer asset.asset_close(&file)
    data,error:=host.ui_tree_view(&file,&types)
    return error==.None && ui.context_sheet_set(ctx,data)
}
