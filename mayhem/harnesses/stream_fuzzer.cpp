// Fuzzes the A2UI text-stream pipeline: ISurfaceManager::beginTextStream /
// receiveTextChunk / endTextStream (stream extractor, markdown/text plugins,
// message parser, surface coordinator, components, data model, layout).
// The first input byte chooses the chunk size (1..64) so chunk boundaries vary
// the way an LLM's streamed output does; the rest is the raw stream text.
#include "engine_common.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    if (size < 1) return 0;
    size_t chunk = (data[0] % 64) + 1;
    const char* text = reinterpret_cast<const char*>(data + 1);
    size_t len = size - 1;

    agenui::IAGenUIEngine* e = mayhem_harness::engine();
    if (!e) return 0;
    agenui::ISurfaceManager* sm = e->createSurfaceManager();
    if (sm) {
        sm->addSurfaceEventListener(&mayhem_harness::noopListener());
        sm->beginTextStream();
        for (size_t off = 0; off < len; off += chunk) {
            size_t n = len - off < chunk ? len - off : chunk;
            sm->receiveTextChunk(std::string(text + off, n));
        }
        sm->endTextStream();
    }
    mayhem_harness::finishInput(e, sm);
    return 0;
}
