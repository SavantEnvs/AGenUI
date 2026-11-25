// Shared helpers for the AGenUI engine harnesses (mayhem integration layer).
#pragma once
#include <cstddef>
#include <cstdint>
#include <condition_variable>
#include <mutex>
#include <string>
#include "agenui_engine.h"
#include "agenui_engine_entry.h"
#include "agenui_logger_interface.h"
#include "agenui_message_listener.h"
#include "agenui_dispatcher_types.h"
#include "agenui_render_info_types.h"
#include "agenui_surface_manager_interface.h"

namespace mayhem_harness {

// The engine logs hundreds of lines per input through its runtime logger; a
// no-op logger keeps fuzzing fast. It holds no state.
class QuietLogger : public agenui::IRuntimeLogger {
public:
    void log(agenui::LogLevel, const char*, const char*, int, const char*, ...) override {}
    agenui::LogLevel getMinLevel() const override { return agenui::LOG_LEVEL_FATAL; }
};

inline QuietLogger& quietLogger() { static QuietLogger l; return l; }

// The engine is a process-wide singleton that can be initialised only once
// (initAGenUIEngine uses std::call_once; after destroyAGenUIEngine it returns
// nullptr), so it is created once and kept. Per-input state lives in the
// surface manager, which each input creates and destroys.
inline agenui::IAGenUIEngine* engine() {
    static agenui::IAGenUIEngine* e = [] {
        agenui::IAGenUIEngine* eng = agenui::initAGenUIEngine();
        if (eng) {
            eng->setRuntimeLogger(&quietLogger());
            eng->setDebug(false);
        }
        return eng;
    }();
    return e;
}

// Stateless listener shared by every surface manager (static, so it outlives
// any task still queued for a destroyed manager).
inline agenui::IAGenUIMessageListener& noopListener() {
    static agenui::IAGenUIMessageListener l;
    return l;
}

// All surface managers share one FIFO worker thread. Draining = streaming a
// createSurface on a fresh sentinel manager and waiting (no deadline: a hang
// is a finding) for its onCreateSurface, which runs after every task posted
// before it — so all work for this input is done before the next input.
class DrainListener : public agenui::IAGenUIMessageListener {
public:
    void onCreateSurface(const agenui::CreateSurfaceMessage&) override {
        std::lock_guard<std::mutex> lk(mu_);
        done_ = true;
        cv_.notify_all();
    }
    void reset() { std::lock_guard<std::mutex> lk(mu_); done_ = false; }
    void wait() {
        std::unique_lock<std::mutex> lk(mu_);
        cv_.wait(lk, [&] { return done_; });
    }
private:
    std::mutex mu_;
    std::condition_variable cv_;
    bool done_ = false;
};

inline void drain(agenui::IAGenUIEngine* e) {
    static DrainListener l;
    agenui::ISurfaceManager* sm = e->createSurfaceManager();
    if (!sm) return;
    l.reset();
    sm->addSurfaceEventListener(&l);
    sm->beginTextStream();
    sm->receiveTextChunk(
        "{\"version\":\"v0.9\",\"createSurface\":{\"surfaceId\":\"_mayhem_drain_\","
        "\"catalogId\":\"drain\",\"theme\":{},\"sendDataModel\":false,\"animated\":false}}");
    sm->endTextStream();
    l.wait();
    sm->removeSurfaceEventListener(&l);
    e->destroySurfaceManager(sm);
}

// Destroy this input's surface manager and wait until the worker has run
// everything the input queued (including the manager's teardown).
inline void finishInput(agenui::IAGenUIEngine* e, agenui::ISurfaceManager* sm) {
    if (sm) e->destroySurfaceManager(sm);
    drain(e);
}

}  // namespace mayhem_harness
