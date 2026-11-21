#include "ui/HudOverlay.hpp"

#include <imgui.h>

#include <algorithm>
#include <cmath>
#include <cstdio>

#include "map/EuropeData.hpp"
#include "ui/MapRenderer.hpp"

namespace raildev {
namespace {

const char* tierName(int tier) {
    switch (tier) {
        case 3: return "Metropolis";
        case 2: return "City";
        default: return "Town";
    }
}

std::string formatMoney(int pounds) {
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%d", pounds);
    std::string s(buf);
    int n = static_cast<int>(s.length()) - 3;
    while (n > 0) {
        s.insert(static_cast<std::size_t>(n), ",");
        n -= 3;
    }
    return "£" + s;
}

}  // namespace

void HudOverlay::render(SimClock& clock, Camera2D& camera, const EuropeMap& map,
                        const TrackGraph& tracks, BuildState& buildState,
                        MapRenderer& mapRenderer, int selectedCityIndex,
                        float cursorX, float cursorY, bool& showHelp) {
    // 1. Top Control Bar
    ImGui::SetNextWindowPos(ImVec2(10, 10), ImGuiCond_Always);
    ImGui::SetNextWindowBgAlpha(0.90f);
    constexpr ImGuiWindowFlags kBarFlags =
        ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
        ImGuiWindowFlags_AlwaysAutoResize | ImGuiWindowFlags_NoMove;

    if (ImGui::Begin("TopBar", nullptr, kBarFlags)) {
        ImGui::Text("RAILDEV  |  %s  |  %s",
                    clock.formattedDate().c_str(),
                    formatMoney(buildState.treasury).c_str());
        ImGui::SameLine(0.0f, 14.0f);

        auto speedBtn = [&](const char* label, SimSpeed target) {
            const bool active = (clock.speed() == target);
            if (active) {
                ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.80f, 0.58f, 0.16f, 1.0f));
            }
            if (ImGui::Button(label)) {
                clock.setSpeed(target);
            }
            if (active) {
                ImGui::PopStyleColor();
            }
            ImGui::SameLine();
        };

        speedBtn("||", SimSpeed::Paused);
        speedBtn("1x", SimSpeed::Normal);
        speedBtn("2x", SimSpeed::Fast);
        speedBtn("4x", SimSpeed::Ultra);

        ImGui::SameLine(0.0f, 10.0f);
        if (ImGui::Button(" - ")) {
            camera.smoothZoomAtScreenPoint(
                camera.viewportWidth() * 0.5, camera.viewportHeight() * 0.5, 1.0 / 1.18);
        }
        ImGui::SameLine(0.0f, 3.0f);
        if (ImGui::Button(" + ")) {
            camera.smoothZoomAtScreenPoint(
                camera.viewportWidth() * 0.5, camera.viewportHeight() * 0.5, 1.18);
        }

        ImGui::SameLine(0.0f, 10.0f);
        const bool isRelief = (mapRenderer.overlay() == TerrainOverlay::Relief);
        if (ImGui::Button(isRelief ? "Overlay: Relief [G]" : "Overlay: Grade [G]")) {
            mapRenderer.setOverlay(isRelief ? TerrainOverlay::Grade : TerrainOverlay::Relief);
        }

        ImGui::SameLine(0.0f, 6.0f);
        const char* detailLabel = "Detail: Auto [V]";
        if (mapRenderer.detailMode() == DetailMode::GenerativeOnly) detailLabel = "Detail: Map [V]";
        else if (mapRenderer.detailMode() == DetailMode::Textured) detailLabel = "Detail: Textured [V]";
        if (ImGui::Button(detailLabel)) {
            if (mapRenderer.detailMode() == DetailMode::AutoZoomLOD) {
                mapRenderer.setDetailMode(DetailMode::GenerativeOnly);
            } else if (mapRenderer.detailMode() == DetailMode::GenerativeOnly) {
                mapRenderer.setDetailMode(DetailMode::Textured);
            } else {
                mapRenderer.setDetailMode(DetailMode::AutoZoomLOD);
            }
        }

        ImGui::SameLine(0.0f, 10.0f);
        if (ImGui::BeginCombo("##Region", "Region...", ImGuiComboFlags_WidthFitPreview)) {
            for (const auto& preset : getEuropeRegionPresets()) {
                if (ImGui::Selectable(preset.name.c_str())) {
                    double wx = 0.0, wy = 0.0;
                    EuropeProjection::latLonToWorld(preset.lat, preset.lon, wx, wy);
                    camera.focusOn(wx, wy, preset.zoom);
                }
            }
            ImGui::EndCombo();
        }

        ImGui::SameLine(0.0f, 8.0f);
        if (showHelp) {
            ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.32f, 0.52f, 0.78f, 1.0f));
        }
        if (ImGui::Button("? [H]")) {
            showHelp = !showHelp;
        }
        if (showHelp) {
            ImGui::PopStyleColor();
        }

        ImGui::Separator();

        // Construction Toolbar
        auto toolBtn = [&](const char* label, ToolMode mode) {
            const bool active = (buildState.tool == mode);
            if (active) {
                ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.24f, 0.62f, 0.36f, 1.0f));
            }
            if (ImGui::Button(label)) {
                buildState.tool = mode;
                buildState.hasTrackStart = false;
                buildState.livePreview.reset();
                buildState.livePreview2.reset();
            }
            if (active) {
                ImGui::PopStyleColor();
            }
            ImGui::SameLine();
        };

        toolBtn("Inspect [I]", ToolMode::Inspect);
        toolBtn("Station (£25k) [B]", ToolMode::BuildStation);
        toolBtn("Track [T]", ToolMode::BuildTrack);
        toolBtn("Signals [N]", ToolMode::PlaceSignal);

        if (buildState.tool == ToolMode::BuildStation) {
            ImGui::SameLine(0.0f, 14.0f);
            if (ImGui::Button("Rot -15°")) {
                buildState.stationAngle -= 3.14159265f / 12.0f;
            }
            ImGui::SameLine(0.0f, 4.0f);
            if (ImGui::Button("Rot +15° [R]")) {
                buildState.stationAngle += 3.14159265f / 12.0f;
            }
        } else if (buildState.tool == ToolMode::BuildTrack) {
            ImGui::SameLine(0.0f, 14.0f);
            ImGui::Checkbox("Double [L]", &buildState.doubleTrack);
            ImGui::SameLine(0.0f, 10.0f);
            if (ImGui::Button("Curve L [Q]")) {
                buildState.trackCurveAngle -= 0.15f;
            }
            ImGui::SameLine(0.0f, 4.0f);
            if (ImGui::Button("Straight")) {
                buildState.trackCurveAngle = 0.0f;
            }
            ImGui::SameLine(0.0f, 4.0f);
            if (ImGui::Button("Curve R [E]")) {
                buildState.trackCurveAngle += 0.15f;
            }
        } else if (buildState.tool == ToolMode::PlaceSignal) {
            ImGui::SameLine(0.0f, 14.0f);
            ImGui::Checkbox("Auto-Signal [U]", &buildState.autoSignal);
            ImGui::SameLine();
            int sigIdx = static_cast<int>(buildState.signalType);
            const char* sigNames[] = {"Block", "One-Way", "Chain"};
            ImGui::SetNextItemWidth(95.0f);
            if (ImGui::Combo("##SigType", &sigIdx, sigNames, 3)) {
                buildState.signalType = static_cast<SignalType>(sigIdx);
            }
        } else {
            ImGui::NewLine();
        }
    }
    ImGui::End();

    // 2. Floating Build Tooltip near cursor
    if (buildState.tool == ToolMode::BuildTrack && buildState.hasTrackStart && buildState.livePreview) {
        const auto& pv = *buildState.livePreview;
        ImGui::SetNextWindowPos(ImVec2(cursorX + 18.0f, cursorY + 18.0f), ImGuiCond_Always);
        ImGui::SetNextWindowBgAlpha(0.88f);
        if (ImGui::Begin("TrackTooltip", nullptr,
                         kBarFlags | ImGuiWindowFlags_NoInputs)) {
            if (!pv.valid) {
                ImGui::TextColored(ImVec4(1.0f, 0.35f, 0.35f, 1.0f), "%s", pv.invalidReason.c_str());
            } else {
                int totalCost = pv.cost;
                if (buildState.doubleTrack && buildState.livePreview2 && buildState.livePreview2->valid) {
                    totalCost += buildState.livePreview2->cost;
                }
                ImGui::Text("%.1f km  |  Max Grade: %.1f%%", pv.lengthKm, pv.maxGradePct);
                if (pv.hasBridge || pv.hasTunnel) {
                    ImGui::TextColored(ImVec4(1.0f, 0.80f, 0.30f, 1.0f),
                                       "%s%s%s",
                                       pv.hasBridge ? "[BRIDGE] " : "",
                                       pv.hasTunnel ? "[TUNNEL]" : "",
                                       "");
                }
                const bool canAfford = (buildState.treasury >= totalCost);
                ImGui::TextColored(
                    canAfford ? ImVec4(0.45f, 0.95f, 0.55f, 1.0f) : ImVec4(1.0f, 0.35f, 0.35f, 1.0f),
                    "Cost: %s%s", formatMoney(totalCost).c_str(),
                    buildState.doubleTrack ? " (Double)" : "");
            }
        }
        ImGui::End();
    }

    // 3. Bottom-Left Terrain Cursor Telemetry
    const ImGuiIO& io = ImGui::GetIO();
    const Vec2 worldPos = camera.screenToWorld(cursorX, cursorY);
    const int ix = std::clamp(static_cast<int>(std::round(worldPos.x)), 0, EuropeMap::kWidth - 1);
    const int iy = std::clamp(static_cast<int>(std::round(worldPos.y)), 0, EuropeMap::kHeight - 1);
    double lat = 0.0, lon = 0.0;
    EuropeProjection::worldToLatLon(worldPos.x, worldPos.y, lat, lon);
    const float elev = map.elevationAt(ix, iy);
    const float gradePct = map.slopeAt(ix, iy) * 100.0f;

    ImGui::SetNextWindowPos(ImVec2(10, io.DisplaySize.y - 10), ImGuiCond_Always, ImVec2(0.0f, 1.0f));
    ImGui::SetNextWindowBgAlpha(0.84f);
    if (ImGui::Begin("Telemetry", nullptr, kBarFlags)) {
        if (elev < 0.0f) {
            ImGui::Text("%.2f N, %.2f E  |  Sea  |  Zoom: %.0f%%  |  Stations: %zu  Tracks: %zu",
                        lat, lon, camera.zoom() * 100.0,
                        tracks.stations().size(), tracks.edges().size());
        } else {
            ImGui::Text("%.2f N, %.2f E  |  Elev: %.0f m  |  Grade: %.1f%%  |  Zoom: %.0f%%  |  Stations: %zu  Tracks: %zu",
                        lat, lon, elev, gradePct, camera.zoom() * 100.0,
                        tracks.stations().size(), tracks.edges().size());
        }
        ImGui::TextDisabled("Pan: Drag/WASD/Arrows  Zoom: Wheel/Pinch/+/-/PgUp/PgDn  Action: Click/Enter  Tools: I/B/T/N  Help: H");
    }
    ImGui::End();

    // 3b. Controls Help Overlay
    if (showHelp) {
        ImGui::SetNextWindowPos(ImVec2(io.DisplaySize.x * 0.5f, io.DisplaySize.y * 0.5f),
                                ImGuiCond_Appearing, ImVec2(0.5f, 0.5f));
        ImGui::SetNextWindowBgAlpha(0.94f);
        if (ImGui::Begin("Controls — Mouse / Touchpad & Keyboard", &showHelp,
                         ImGuiWindowFlags_AlwaysAutoResize | ImGuiWindowFlags_NoCollapse)) {
            ImGui::Text("Camera Navigation");
            ImGui::BulletText("Pan: Click-drag (L/M/R) or WASD / Arrow Keys (Shift = faster)");
            ImGui::BulletText("Zoom: Scroll Wheel, Touchpad Pinch, +/- buttons, or + / - / PgUp / PgDn");
            ImGui::BulletText("Regions & Cities: Region menu, [ / ] (regions), Tab / Shift+Tab (cities), Home (reset)");
            ImGui::Separator();
            ImGui::Text("Building & Map Interaction");
            ImGui::BulletText("Select / Place / Confirm: Left-Click or Enter (at crosshair)");
            ImGui::BulletText("Cancel / Back to Inspect: Right-Click, Esc, or Backspace");
            ImGui::BulletText("Tools: I (Inspect), B (Station), T (Track), N (Signals)");
            ImGui::BulletText("Station Rotation: R / Shift+R, Shift+Wheel, or HUD Rotate buttons");
            ImGui::BulletText("Track Curvature: Q / E, Shift+Wheel, or HUD Curve buttons");
            ImGui::BulletText("Options: L (Double Track), U (Auto-Signal), C (Signal Type)");
            ImGui::Separator();
            ImGui::Text("Simulation & Display");
            ImGui::BulletText("Speed: Space / P (Pause), 1 / 2 / 3 (1x / 2x / 4x)");
            ImGui::BulletText("Overlays: G (Relief / Grade), V (Detail LOD), H (Toggle Help)");
        }
        ImGui::End();
    }

    // 4. City Inspector Panel
    if (selectedCityIndex >= 0 &&
        selectedCityIndex < static_cast<int>(map.cities().size())) {
        const auto& city = map.cities()[static_cast<std::size_t>(selectedCityIndex)];
        double wx = 0.0, wy = 0.0;
        EuropeProjection::latLonToWorld(city.lat, city.lon, wx, wy);
        const float cityElev = map.elevationAtWorld(wx, wy);

        ImGui::SetNextWindowPos(ImVec2(io.DisplaySize.x - 10, 10), ImGuiCond_Always, ImVec2(1.0f, 0.0f));
        ImGui::SetNextWindowSize(ImVec2(280, 0), ImGuiCond_Always);
        ImGui::SetNextWindowBgAlpha(0.90f);
        if (ImGui::Begin("City Inspector", nullptr,
                         ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoCollapse)) {
            ImGui::Text("%s (%s)", city.name.c_str(), city.country.c_str());
            ImGui::Separator();
            ImGui::Text("Tier: %s", tierName(city.tier));
            ImGui::Text("Population: %d", city.population);
            ImGui::Text("Elevation: %.0f m", std::max(0.0f, cityElev));
            ImGui::Text("Coords: %.2f N, %.2f E", city.lat, city.lon);
            ImGui::Separator();

            int stationCount = 0;
            for (const auto& st : tracks.stations()) {
                if (st.cityIndex == selectedCityIndex) {
                    ImGui::BulletText("%s (%d platforms)", st.name.c_str(), st.platforms);
                    ++stationCount;
                }
            }
            if (stationCount == 0) {
                ImGui::TextDisabled("No station connected yet.");
            }
        }
        ImGui::End();
    }
}

}  // namespace raildev
