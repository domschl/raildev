#pragma once

#include "core/Camera2D.hpp"
#include "core/SimClock.hpp"
#include "map/EuropeMap.hpp"
#include "track/TrackGraph.hpp"
#include "ui/BuildState.hpp"

namespace raildev {

class MapRenderer;

class HudOverlay {
public:
    void render(SimClock& clock, Camera2D& camera, const EuropeMap& map,
                const TrackGraph& tracks, BuildState& buildState,
                MapRenderer& mapRenderer, int selectedCityIndex,
                float cursorX, float cursorY, bool& showHelp);
};

}  // namespace raildev
