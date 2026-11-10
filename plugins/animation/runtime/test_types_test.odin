package anim

import "mirai:core"
import erender "mirai:engine/render"

// What the declarations of this library and of those it uses name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    erender.test_types(types)
    append(types,
        core.test_type(Animation,default=proc(dst:^Animation) {dst^=ANIMATION_DEFAULT}),
        core.test_type(Animation_Settings,default=proc(dst:^Animation_Settings) {dst^=ANIMATION_SETTINGS_DEFAULT}),
        core.test_type(Animation_Budget,default=proc(dst:^Animation_Budget) {dst^=ANIMATION_BUDGET_DEFAULT}),
        core.test_type(Animation_Budget_Config,default=proc(dst:^Animation_Budget_Config) {dst^=ANIMATION_BUDGET_CONFIG_DEFAULT}),
        core.test_type(Pose_Modifiers,default=proc(dst:^Pose_Modifiers) {dst^=POSE_MODIFIERS_DEFAULT}),
        core.test_type(Bone_Attachment,default=proc(dst:^Bone_Attachment) {dst^=BONE_ATTACHMENT_DEFAULT}),
        core.test_type(Keyframe_Path,default=proc(dst:^Keyframe_Path) {dst^=keyframe_path_default()}),
        core.test_type(Playback,free=playback_free),
        core.test_type(Morph_Playback,free=morph_playback_free),
        core.test_type(Keyframe_Path_Playback,free=keyframe_path_playback_free),
        core.test_type(Animation_Constraints,free=constraints_free),
        core.test_type(Grounding_Runtime,free=grounding_free),
        core.test_type(Motion_Runtime,free=motion_runtime_free),
        core.test_type(Budget_Runtime,free=budget_runtime_free),
        core.test_type(Action_Runtime,free=actions_runtime_free),
        core.test_type(Modifier_Runtime,free=modifier_runtime_free),
        core.test_type(Skin_Runtime,free=skin_runtime_free),
        core.test_type(Skin_Instances,free=skin_instances_free),
        core.test_type(Actions_Assets,free=actions_assets_free),
        core.test_type(Blend_Assets,free=blend_assets_free),
        core.test_type(Match_Assets,free=match_assets_free),
        core.test_type(Motion_Assets,free=motion_assets_free),
        core.test_type(Pose_Assets,free=pose_assets_free),
        core.test_type(Skeleton_Assets,free=skeleton_assets_free),
        core.test_type(Source_Assets,free=source_assets_free),
    )
}
