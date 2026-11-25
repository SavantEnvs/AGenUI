// Fuzzes agenui::ColorParser::parse — the CSS color/gradient parser (hex, rgb,
// hsl, hwb, named colors, linear/radial/conic gradients) that renderers call on
// style strings from the A2UI protocol.
#include <cstddef>
#include <cstdint>
#include <string>
#include "style_parser/agenui_color_parser.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    std::string s(reinterpret_cast<const char*>(data), size);
    agenui::ColorValue v;
    agenui::ColorParser::parse(s, v);
    return 0;
}
