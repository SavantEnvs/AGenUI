// Fuzzes IAGenUIEngine::loadThemeConfig (the per-engine component property /
// style-default spec) and then renders a small fixed surface that uses styles,
// so the loaded configuration is consumed. First byte: bit 0 selects day/night
// mode, which is set explicitly on every input (it lives in a process-global
// TokenParser). loadDesignTokenConfig is not fuzzed: it accumulates into that
// process-global TokenParser with no reset, so results would depend on earlier
// inputs.
// The engine (and its ComponentPropertySpecManager) is a process singleton and
// loadThemeConfig merges per theme name, so after each input every theme the
// input named is reloaded as {} (= the built-in base spec) — the per-input
// reset.
#include "engine_common.h"
#include "nlohmann/json.hpp"

static const char* const kMessages[] = {
    "{\"version\":\"v0.9\",\"createSurface\":{\"surfaceId\":\"main\",\"catalogId\":\"test\","
    "\"theme\":{},\"sendDataModel\":false,\"animated\":true}}",
    "{\"version\":\"v0.9\",\"updateComponents\":{\"surfaceId\":\"main\",\"components\":["
    "{\"id\":\"root\",\"component\":\"Column\",\"children\":[\"t\",\"b\",\"c\"],"
    "\"styles\":{\"background-color\":\"$color_bg\",\"padding\":\"8px 12px\"}},"
    "{\"id\":\"t\",\"component\":\"Text\",\"text\":\"hello\",\"variant\":\"h1\","
    "\"styles\":{\"color\":\"$color_text\",\"font-size\":\"$font_size_m\"}},"
    "{\"id\":\"b\",\"component\":\"Button\",\"child\":\"t\",\"variant\":\"primary\"},"
    "{\"id\":\"c\",\"component\":\"Card\",\"child\":\"t\"}]}}",
};

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    if (size < 1) return 0;
    uint8_t mode = data[0];
    std::string cfg(reinterpret_cast<const char*>(data + 1), size - 1);
    agenui::IAGenUIEngine* e = mayhem_harness::engine();
    if (!e) return 0;
    std::string result;
    e->loadThemeConfig(cfg, result);
    e->setDayNightMode((mode & 1) ? "dark" : "light");
    agenui::ISurfaceManager* sm = e->createSurfaceManager();
    if (sm) {
        sm->addSurfaceEventListener(&mayhem_harness::noopListener());
        sm->beginTextStream();
        for (const char* m : kMessages) sm->receiveTextChunk(m);
        sm->endTextStream();
        agenui::SurfaceLayoutInfo layout;
        layout.surfaceId = "main";
        layout.width = 750.0f;
        layout.height = 1600.0f;
        sm->onSurfaceSizeChanged(layout);
    }
    mayhem_harness::finishInput(e, sm);
    nlohmann::json j = nlohmann::json::parse(cfg, nullptr, false);
    if (!j.is_discarded() && j.is_object()) {
        for (auto it = j.begin(); it != j.end(); ++it) {
            nlohmann::json reset = nlohmann::json::object();
            reset[it.key()] = nlohmann::json::object();
            e->loadThemeConfig(reset.dump(), result);
        }
    }
    return 0;
}
