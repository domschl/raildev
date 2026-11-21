#include <cmath>
#include <cstdlib>
#include <iostream>

#include "core/Camera2D.hpp"
#include "core/SimClock.hpp"
#include "map/CityFootprint.hpp"
#include "map/EuropeData.hpp"
#include "map/EuropeMap.hpp"
#include "track/TrackGraph.hpp"

#define CHECK(cond)                                                              \
    do {                                                                         \
        if (!(cond)) {                                                           \
            std::cerr << "Test failed at " << __FILE__ << ":" << __LINE__        \
                      << ": " #cond "\n";                                        \
            std::exit(1);                                                        \
        }                                                                        \
    } while (0)

using namespace raildev;

void testCamera() {
    Camera2D cam(2048.0, 1536.0);
    cam.setViewportSize(1280, 720);
    cam.focusOn(1024.0, 768.0, 1.5);

    const Vec2 screenPt = cam.worldToScreen(1100.0, 800.0);
    const Vec2 backWorld = cam.screenToWorld(screenPt.x, screenPt.y);
    CHECK(std::abs(backWorld.x - 1100.0) < 1e-6);
    CHECK(std::abs(backWorld.y - 800.0) < 1e-6);

    // Zoom-to-cursor keeps world point under cursor invariant
    const double cursorX = 400.0;
    const double cursorY = 250.0;
    const Vec2 before = cam.screenToWorld(cursorX, cursorY);
    cam.zoomAtScreenPoint(cursorX, cursorY, 1.8);
    const Vec2 after = cam.screenToWorld(cursorX, cursorY);
    CHECK(std::abs(before.x - after.x) < 1e-4);
    CHECK(std::abs(before.y - after.y) < 1e-4);

    // Zoom-out limit guarantees the viewport is always filled with the map (no empty borders)
    cam.zoomAtScreenPoint(640.0, 360.0, 0.01);
    CHECK(cam.zoom() >= cam.minZoom() - 1e-9);
    CHECK(cam.zoom() >= 1280.0 / 2048.0 - 1e-9);
    CHECK(cam.zoom() >= 720.0 / 1536.0 - 1e-9);

    // Aggressive panning past edges never exposes empty area outside [0, worldWidth] x [0, worldHeight]
    cam.panByScreenDelta(50000.0, 50000.0);
    const Vec2 tl = cam.screenToWorld(0.0, 0.0);
    const Vec2 br = cam.screenToWorld(1280.0, 720.0);
    CHECK(tl.x >= -1e-6 && tl.y >= -1e-6);
    CHECK(br.x <= 2048.0 + 1e-6 && br.y <= 1536.0 + 1e-6);

    // Smooth zoom converges cleanly and preserves anchor point
    cam.focusOn(1024.0, 768.0, 1.5);
    const Vec2 smoothBefore = cam.screenToWorld(500.0, 300.0);
    cam.smoothZoomAtScreenPoint(500.0, 300.0, 1.5);
    CHECK(cam.zoom() < 2.25);  // Does not snap instantaneously
    for (int i = 0; i < 120; ++i) {
        cam.update(1.0 / 60.0);
    }
    CHECK(std::abs(cam.zoom() - 2.25) < 1e-3);
    const Vec2 smoothAfter = cam.screenToWorld(500.0, 300.0);
    CHECK(std::abs(smoothBefore.x - smoothAfter.x) < 1e-2);
    CHECK(std::abs(smoothBefore.y - smoothAfter.y) < 1e-2);
}

void testSimClock() {
    SimClock clock(1835, 5, 1);
    CHECK(clock.formattedDate() == "01 May 1835");

    // 1.0s at 1x speed (in 4 x 0.25s steps) = 20 ticks = 1 day
    int ticks = 0;
    for (int i = 0; i < 4; ++i) {
        ticks += clock.advance(0.25);
    }
    CHECK(ticks == 20);
    CHECK(clock.day() == 2);

    // Pause produces 0 ticks
    clock.togglePause();
    CHECK(clock.isPaused());
    CHECK(clock.advance(1.0) == 0);
    clock.togglePause();
    CHECK(!clock.isPaused());

    // 4x speed advances 4 days per 1.0s
    clock.setSpeed(SimSpeed::Ultra);
    clock.advance(0.25);
    clock.advance(0.25);
    clock.advance(0.25);
    clock.advance(0.25);
    CHECK(clock.day() == 6);
}

void testEuropeMap() {
    EuropeMap map;

    auto elevAtGeo = [&](double lat, double lon) {
        double wx = 0.0, wy = 0.0;
        EuropeProjection::latLonToWorld(lat, lon, wx, wy);
        return map.elevationAtWorld(wx, wy);
    };

    // Major cities should be on land
    CHECK(elevAtGeo(48.857, 2.352) >= 0.0f);   // Paris
    CHECK(elevAtGeo(52.520, 13.405) >= 0.0f);  // Berlin
    CHECK(elevAtGeo(51.507, -0.128) >= 0.0f);  // London

    // Alps should be significantly higher than Berlin lowlands
    const float alpsElev = elevAtGeo(46.5, 8.5);
    const float berlinElev = elevAtGeo(52.520, 13.405);
    CHECK(alpsElev > 1500.0f);
    CHECK(alpsElev > berlinElev + 1000.0f);

    // Open Mediterranean Sea should be below sea level
    CHECK(elevAtGeo(38.0, 5.0) < 0.0f);
}

void testCityFootprint() {
    EuropeMap map;
    const auto& cities = map.cities();
    const CityData* london = nullptr;
    const CityData* zurich = nullptr;
    for (const auto& c : cities) {
        if (c.name == "London") london = &c;
        if (c.name == "Zurich") zurich = &c;
    }
    CHECK(london != nullptr);
    CHECK(zurich != nullptr);

    const CityFootprint fpLondon = generateCityFootprint(*london, map);
    const CityFootprint fpZurich = generateCityFootprint(*zurich, map);

    CHECK(fpLondon.boundary.size() >= 12);
    CHECK(fpLondon.contains(fpLondon.center.x, fpLondon.center.y));
    CHECK(!fpLondon.blocks.empty());
    CHECK(!fpLondon.streets.empty());
    CHECK(fpLondon.radius > fpZurich.radius);
}

void testTrackGraph() {
    EuropeMap map;
    TrackGraph graph;

    Vec2 paris{}, lyon{};
    EuropeProjection::latLonToWorld(48.857, 2.352, paris.x, paris.y);
    EuropeProjection::latLonToWorld(45.764, 4.836, lyon.x, lyon.y);

    const std::uint32_t stParis = graph.addStation(map, paris, 4, "Paris Central");
    const std::uint32_t stLyon = graph.addStation(map, lyon, 5, "Lyon Central");
    CHECK(stParis != 0);
    CHECK(stLyon != 0);
    CHECK(graph.stations().size() == 2);

    // Single track preview & build
    const TrackPreview pv = graph.previewTrack(map, paris, lyon);
    CHECK(pv.valid);
    CHECK(pv.lengthKm > 200.0f);
    CHECK(pv.cost > 0);

    const std::uint32_t eid = graph.addTrackFromPreview(map, pv);
    CHECK(eid != 0);
    CHECK(graph.edges().size() == 3);  // 2 internal station tracks + 1 mainline

    // Station throat tangent check
    Vec2 depDir{};
    const auto* parisStNode = graph.getNode(graph.stations()[0].nodeId);
    CHECK(parisStNode != nullptr);
    CHECK(graph.getNodeTangent(parisStNode->id, lyon, depDir));

    // Auto-signal placement along Paris-Lyon
    const int sigCount = graph.autoSignalEdge(eid, 50.0f, 1, SignalType::OneWay);
    CHECK(sigCount >= 3);
    CHECK(graph.getEdge(eid)->signals.size() == static_cast<std::size_t>(sigCount));

    // Double track build between Cologne and Frankfurt (crosses Rhine -> bridge)
    Vec2 cologne{}, frankfurt{};
    EuropeProjection::latLonToWorld(50.938, 6.960, cologne.x, cologne.y);
    EuropeProjection::latLonToWorld(50.111, 8.682, frankfurt.x, frankfurt.y);
    std::vector<std::uint32_t> dblIds;
    const int dblCost = graph.addDoubleTrack(map, cologne, frankfurt, &dblIds);
    CHECK(dblCost > 0);
    CHECK(dblIds.size() == 2);

    // Alpine crossing (Zurich -> Milan) should trigger tunnel
    Vec2 zurich{}, milan{};
    EuropeProjection::latLonToWorld(47.377, 8.542, zurich.x, zurich.y);
    EuropeProjection::latLonToWorld(45.464, 9.190, milan.x, milan.y);
    const TrackPreview alpsPv = graph.previewTrack(map, zurich, milan);
    CHECK(alpsPv.valid);
    CHECK(alpsPv.hasTunnel);
}

int main() {
    testCamera();
    testSimClock();
    testEuropeMap();
    testCityFootprint();
    testTrackGraph();
    std::cout << "All raildev unit tests passed!\n";
    return 0;
}
