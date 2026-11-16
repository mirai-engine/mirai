/*
 * The FreeType modules of Mirai: TrueType and CFF outlines, the auto-hinter
 * and the anti-aliasing rasterizer. CFF needs psaux, pshinter and psnames. It
 * shadows include/freetype/config/ftmodule.h because config/ precedes
 * include/ on the include path.
 */

FT_USE_MODULE( FT_Module_Class, autofit_module_class )
FT_USE_MODULE( FT_Driver_ClassRec, tt_driver_class )
FT_USE_MODULE( FT_Driver_ClassRec, cff_driver_class )
FT_USE_MODULE( FT_Module_Class, psaux_module_class )
FT_USE_MODULE( FT_Module_Class, psnames_module_class )
FT_USE_MODULE( FT_Module_Class, pshinter_module_class )
FT_USE_MODULE( FT_Module_Class, sfnt_module_class )
FT_USE_MODULE( FT_Renderer_Class, ft_smooth_renderer_class )

/* EOF */
