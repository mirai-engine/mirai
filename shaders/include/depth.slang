// The depth of a pixel, as the linear depth target holds it: the distance
// along the view, 0 where nothing was drawn and, with nested views,
// negative in the pixels one of them drew. No arithmetic is done on the
// raw value: these decode it. A source that decodes depth includes this, so
// only its stages change with nested views.
#ifndef MIRAI_DEPTH_SLANG
#define MIRAI_DEPTH_SLANG
bool depth_empty(float depth) { return depth == 0.0; }
#ifdef MIRAI_NESTED_VIEWS
float depth_distance(float depth) { return abs(depth); }
bool depth_nested(float depth) { return depth < 0.0; }
bool depth_same_side(float a, float b) { return (a < 0.0) == (b < 0.0); }
#else
float depth_distance(float depth) { return depth; }
bool depth_nested(float depth) { return false; }
bool depth_same_side(float a, float b) { return true; }
#endif
#endif
