// Fuzzes agenui::EdgeInsetsParser — CSS padding/margin shorthand parsing,
// physical and logical (LTR and RTL) forms.
#include <cstddef>
#include <cstdint>
#include <string>
#include "style_parser/agenui_edge_insets_parser.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    std::string s(reinterpret_cast<const char*>(data), size);
    agenui::EdgeInsets r;
    agenui::EdgeInsetsParser::parse(s, r);
    agenui::EdgeInsets a;
    agenui::EdgeInsetsParser::parseInline(s, false, a);
    agenui::EdgeInsets b;
    agenui::EdgeInsetsParser::parseInline(s, true, b);
    return 0;
}
