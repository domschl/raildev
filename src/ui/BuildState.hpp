#pragma once

#include <cstdint>
#include <optional>
#include <vector>

#include "core/Camera2D.hpp"
#include "track/TrackGraph.hpp"

namespace raildev {

enum class ToolMode {
    Inspect,
    BuildStation,
    BuildTrack,
    PlaceSignal
};

struct BuildState {
    ToolMode tool = ToolMode::Inspect;
    bool doubleTrack = false;
    bool autoSignal = true;
    SignalType signalType = SignalType::OneWay;

    int treasury = 500000;  // Starting capital (£)
    static constexpr int kStationCost = 25000;
    static constexpr int kSignalCost = 1200;

    bool hasTrackStart = false;
    Vec2 trackStartWorld{};
    std::uint32_t trackStartNodeId = 0;
    float stationAngle = 0.0f;
    float trackCurveAngle = 0.0f;  // Manual tangent offset (Q/E) when starting on open ground

    std::optional<TrackPreview> livePreview;
    std::optional<TrackPreview> livePreview2;  // Second parallel track when doubleTrack=true
    std::uint32_t hoverNodeId = 0;
    std::uint32_t hoverEdgeId = 0;
    float hoverEdgeT = 0.0f;
};

}  // namespace raildev
