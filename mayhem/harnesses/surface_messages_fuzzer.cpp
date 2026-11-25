// Fuzzes whole A2UI messages on an existing surface: a fixed createSurface for
// surfaceId "main" is streamed first, then each newline-separated input line is
// sent as one receiveTextChunk message (updateComponents, updateDataModel,
// appendDataModel, deleteSurface, function calls, templates...), followed by a
// layout pass. Lines that start with "@action " / "@sync <componentId> " are
// delivered as UI events (submitUIAction / submitUIDataModel) instead, which
// reach the action-context parsing and data-model write-back paths.
#include "engine_common.h"

static const char kCreateSurface[] =
    "{\"version\":\"v0.9\",\"createSurface\":{\"surfaceId\":\"main\",\"catalogId\":\"test\","
    "\"theme\":{},\"sendDataModel\":true,\"animated\":true}}";

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    std::string in(reinterpret_cast<const char*>(data), size);
    agenui::IAGenUIEngine* e = mayhem_harness::engine();
    if (!e) return 0;
    agenui::ISurfaceManager* sm = e->createSurfaceManager();
    if (!sm) return 0;
    sm->addSurfaceEventListener(&mayhem_harness::noopListener());
    sm->beginTextStream();
    sm->receiveTextChunk(kCreateSurface);
    agenui::SurfaceLayoutInfo layout;
    layout.surfaceId = "main";
    layout.width = 750.0f;
    layout.height = 1600.0f;
    sm->onSurfaceSizeChanged(layout);

    size_t pos = 0;
    while (pos <= in.size()) {
        size_t nl = in.find('\n', pos);
        if (nl == std::string::npos) nl = in.size();
        std::string line = in.substr(pos, nl - pos);
        pos = nl + 1;
        if (line.empty()) continue;
        if (line.compare(0, 8, "@action ") == 0) {
            std::string rest = line.substr(8);
            size_t sp = rest.find(' ');
            agenui::ActionMessage m;
            m.surfaceId = "main";
            m.sourceComponentId = rest.substr(0, sp);
            m.contextJson = sp == std::string::npos ? "" : rest.substr(sp + 1);
            sm->submitUIAction(m);
        } else if (line.compare(0, 6, "@sync ") == 0) {
            std::string rest = line.substr(6);
            size_t sp = rest.find(' ');
            agenui::SyncUIToDataMessage m;
            m.surfaceId = "main";
            m.componentId = rest.substr(0, sp);
            m.change = sp == std::string::npos ? "" : rest.substr(sp + 1);
            sm->submitUIDataModel(m);
        } else {
            sm->receiveTextChunk(line);
        }
    }
    sm->endTextStream();
    layout.width = 375.0f;
    sm->onSurfaceSizeChanged(layout);
    mayhem_harness::finishInput(e, sm);
    return 0;
}
