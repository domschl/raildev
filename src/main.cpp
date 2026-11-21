#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <SDL3_ttf/SDL_ttf.h>
#include <imgui.h>
#include <imgui_impl_sdl3.h>
#include <imgui_impl_sdlrenderer3.h>

#include <algorithm>
#include <cmath>
#include <cstdio>

#include "core/Camera2D.hpp"
#include "core/SimClock.hpp"
#include "map/EuropeData.hpp"
#include "map/EuropeMap.hpp"
#include "track/TrackGraph.hpp"
#include "ui/BuildState.hpp"
#include "ui/HudOverlay.hpp"
#include "ui/MapRenderer.hpp"

namespace {

int findNearestCityCatchment(const raildev::EuropeMap& map,
                             const std::vector<raildev::CityFootprint>& footprints,
                             const raildev::Vec2& worldPos) {
    int bestIdx = -1;
    double bestDist = 1e9;
    for (std::size_t i = 0; i < footprints.size(); ++i) {
        const auto& fp = footprints[i];
        const double d = std::hypot(worldPos.x - fp.center.x, worldPos.y - fp.center.y);
        if (d <= fp.radius * 1.45 && d < bestDist) {
            bestDist = d;
            bestIdx = static_cast<int>(i);
        }
    }
    (void)map;
    return bestIdx;
}

}  // namespace

int main(int /*argc*/, char* /*argv*/[]) {
    if (!SDL_Init(SDL_INIT_VIDEO)) {
        std::fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
        return 1;
    }
    if (!TTF_Init()) {
        std::fprintf(stderr, "TTF_Init failed: %s\n", SDL_GetError());
        SDL_Quit();
        return 1;
    }

    SDL_Window* window = SDL_CreateWindow(
        "Raildev — European Railway Management Sim",
        1440, 900,
        SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY);
    if (!window) {
        std::fprintf(stderr, "SDL_CreateWindow failed: %s\n", SDL_GetError());
        TTF_Quit();
        SDL_Quit();
        return 1;
    }

    SDL_Renderer* renderer = SDL_CreateRenderer(window, nullptr);
    if (!renderer) {
        std::fprintf(stderr, "SDL_CreateRenderer failed: %s\n", SDL_GetError());
        SDL_DestroyWindow(window);
        TTF_Quit();
        SDL_Quit();
        return 1;
    }
    SDL_SetRenderVSync(renderer, 1);

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
    ImGui::StyleColorsDark();

    ImGui_ImplSDL3_InitForSDLRenderer(window, renderer);
    ImGui_ImplSDLRenderer3_Init(renderer);

    {
        raildev::EuropeMap europeMap;
        raildev::Camera2D camera(raildev::EuropeMap::kWidth, raildev::EuropeMap::kHeight);
        {
            int w = 1440, h = 900;
            SDL_GetWindowSize(window, &w, &h);
            camera.setViewportSize(w, h);
            double wx = 0.0, wy = 0.0;
            raildev::EuropeProjection::latLonToWorld(48.0, 8.0, wx, wy);
            camera.focusOn(wx, wy, 0.72);
        }

        raildev::SimClock simClock(1835, 5, 1);
        raildev::TrackGraph trackGraph;
        raildev::BuildState buildState;
        raildev::MapRenderer mapRenderer(renderer, europeMap);
        raildev::HudOverlay hud;

        bool running = true;
        bool isDragging = false;
        bool dragMoved = false;
        Uint8 dragButton = 0;
        float dragStartX = 0.0f;
        float dragStartY = 0.0f;
        float mouseX = static_cast<float>(camera.viewportWidth()) * 0.5f;
        float mouseY = static_cast<float>(camera.viewportHeight()) * 0.5f;
        bool keyboardCursorActive = false;
        bool showHelp = false;
        int selectedCityIndex = -1;
        int hoveredCityIndex = -1;
        int regionPresetIdx = 0;

        auto activeCursorX = [&]() -> float {
            return keyboardCursorActive ? static_cast<float>(camera.viewportWidth()) * 0.5f : mouseX;
        };
        auto activeCursorY = [&]() -> float {
            return keyboardCursorActive ? static_cast<float>(camera.viewportHeight()) * 0.5f : mouseY;
        };

        std::uint64_t prevCounter = SDL_GetPerformanceCounter();
        const double perfFreq = static_cast<double>(SDL_GetPerformanceFrequency());

        auto updateHoverAndPreview = [&]() {
            if (!keyboardCursorActive && io.WantCaptureMouse) {
                hoveredCityIndex = -1;
                buildState.hoverNodeId = 0;
                buildState.hoverEdgeId = 0;
                return;
            }

            const float cx = activeCursorX();
            const float cy = activeCursorY();
            const raildev::Vec2 worldPos = camera.screenToWorld(cx, cy);
            const float snapRadius = static_cast<float>(10.0 / camera.zoom());
            hoveredCityIndex = mapRenderer.pickCityAtScreen(camera, cx, cy);

            if (buildState.tool == raildev::ToolMode::BuildTrack) {
                buildState.hoverNodeId = trackGraph.findNodeNear(worldPos, snapRadius);
                raildev::Vec2 endPos = worldPos;
                if (buildState.hoverNodeId != 0) {
                    if (const auto* n = trackGraph.getNode(buildState.hoverNodeId)) {
                        endPos = n->pos;
                    }
                }
                if (buildState.hasTrackStart) {
                    raildev::Vec2 startDir{};
                    bool hasStartDir = false;
                    if (buildState.trackStartNodeId != 0) {
                        hasStartDir = trackGraph.getNodeTangent(
                            buildState.trackStartNodeId, endPos, startDir);
                    }
                    if (!hasStartDir && std::abs(buildState.trackCurveAngle) > 1e-4f) {
                        const double dx = endPos.x - buildState.trackStartWorld.x;
                        const double dy = endPos.y - buildState.trackStartWorld.y;
                        const double baseAng = std::atan2(dy, dx) + buildState.trackCurveAngle;
                        startDir = {std::cos(baseAng), std::sin(baseAng)};
                        hasStartDir = true;
                    }

                    raildev::Vec2 endDir{};
                    bool hasEndDir = false;
                    if (buildState.hoverNodeId != 0) {
                        hasEndDir = trackGraph.getNodeTangent(
                            buildState.hoverNodeId, buildState.trackStartWorld, endDir);
                    }

                    const raildev::Vec2* pStartDir = hasStartDir ? &startDir : nullptr;
                    const raildev::Vec2* pEndDir = hasEndDir ? &endDir : nullptr;

                    if (buildState.doubleTrack) {
                        const double dx = endPos.x - buildState.trackStartWorld.x;
                        const double dy = endPos.y - buildState.trackStartWorld.y;
                        const double len = std::hypot(dx, dy);
                        if (len >= 2.0) {
                            const double nx = -dy / len;
                            const double ny = dx / len;
                            const double h = raildev::TrackGraph::kDoubleTrackOffsetWorld * 0.5;
                            const raildev::Vec2 s1 = (buildState.trackStartNodeId != 0)
                                ? buildState.trackStartWorld
                                : raildev::Vec2{buildState.trackStartWorld.x + nx * h,
                                                buildState.trackStartWorld.y + ny * h};
                            const raildev::Vec2 e1 = (buildState.hoverNodeId != 0)
                                ? endPos
                                : raildev::Vec2{endPos.x + nx * h, endPos.y + ny * h};
                            const raildev::Vec2 s2 = (buildState.trackStartNodeId != 0)
                                ? buildState.trackStartWorld
                                : raildev::Vec2{buildState.trackStartWorld.x - nx * h,
                                                buildState.trackStartWorld.y - ny * h};
                            const raildev::Vec2 e2 = (buildState.hoverNodeId != 0)
                                ? endPos
                                : raildev::Vec2{endPos.x - nx * h, endPos.y - ny * h};

                            buildState.livePreview = trackGraph.previewTrack(
                                europeMap, s1, e1, pStartDir, pEndDir);
                            buildState.livePreview2 = trackGraph.previewTrack(
                                europeMap, s2, e2, pStartDir, pEndDir);
                        } else {
                            buildState.livePreview.reset();
                            buildState.livePreview2.reset();
                        }
                    } else {
                        buildState.livePreview = trackGraph.previewTrack(
                            europeMap, buildState.trackStartWorld, endPos, pStartDir, pEndDir);
                        buildState.livePreview2.reset();
                    }
                }
            } else if (buildState.tool == raildev::ToolMode::PlaceSignal) {
                std::uint32_t eid = 0;
                float et = 0.0f;
                if (trackGraph.findEdgeNear(worldPos, snapRadius, eid, et)) {
                    buildState.hoverEdgeId = eid;
                    buildState.hoverEdgeT = et;
                } else {
                    buildState.hoverEdgeId = 0;
                }
            } else {
                buildState.hoverNodeId = 0;
                buildState.hoverEdgeId = 0;
            }
        };

        auto setToolMode = [&](raildev::ToolMode mode) {
            buildState.tool = mode;
            buildState.hasTrackStart = false;
            buildState.livePreview.reset();
            buildState.livePreview2.reset();
            updateHoverAndPreview();
        };

        auto performCancelAction = [&]() {
            if (buildState.hasTrackStart) {
                buildState.hasTrackStart = false;
                buildState.livePreview.reset();
                buildState.livePreview2.reset();
            } else if (buildState.tool != raildev::ToolMode::Inspect) {
                buildState.tool = raildev::ToolMode::Inspect;
            } else {
                selectedCityIndex = -1;
            }
            updateHoverAndPreview();
        };

        auto performPrimaryAction = [&](float screenX, float screenY) {
            const raildev::Vec2 worldPos = camera.screenToWorld(screenX, screenY);

            if (buildState.tool == raildev::ToolMode::Inspect) {
                selectedCityIndex = mapRenderer.pickCityAtScreen(camera, screenX, screenY);
            } else if (buildState.tool == raildev::ToolMode::BuildStation) {
                if (europeMap.elevationAtWorld(worldPos.x, worldPos.y) >= 0.0f &&
                    buildState.treasury >= raildev::BuildState::kStationCost) {
                    const int cIdx = findNearestCityCatchment(
                        europeMap, mapRenderer.cityFootprints(), worldPos);
                    std::string stName;
                    if (cIdx >= 0) {
                        stName = europeMap.cities()[static_cast<std::size_t>(cIdx)].name + " Central";
                        selectedCityIndex = cIdx;
                    } else {
                        stName = "Junction #" + std::to_string(trackGraph.stations().size() + 1);
                    }
                    trackGraph.addStation(europeMap, worldPos, cIdx, stName,
                                          buildState.stationAngle);
                    buildState.treasury -= raildev::BuildState::kStationCost;
                }
            } else if (buildState.tool == raildev::ToolMode::BuildTrack) {
                raildev::Vec2 clickPos = worldPos;
                std::uint32_t snapId = buildState.hoverNodeId;
                if (snapId != 0) {
                    if (const auto* n = trackGraph.getNode(snapId)) {
                        clickPos = n->pos;
                    }
                }

                if (!buildState.hasTrackStart) {
                    if (europeMap.elevationAtWorld(clickPos.x, clickPos.y) >= 0.0f) {
                        buildState.hasTrackStart = true;
                        buildState.trackStartWorld = clickPos;
                        buildState.trackStartNodeId = snapId;
                        buildState.trackCurveAngle = 0.0f;
                    }
                } else {
                    if (buildState.doubleTrack) {
                        if (buildState.livePreview && buildState.livePreview2 &&
                            buildState.livePreview->valid && buildState.livePreview2->valid) {
                            const int cost = buildState.livePreview->cost +
                                             buildState.livePreview2->cost;
                            if (buildState.treasury >= cost) {
                                raildev::Vec2 startDir{};
                                const bool hasStartDir = (buildState.trackStartNodeId != 0) &&
                                    trackGraph.getNodeTangent(buildState.trackStartNodeId, clickPos, startDir);
                                raildev::Vec2 endDir{};
                                const bool hasEndDir = (snapId != 0) &&
                                    trackGraph.getNodeTangent(snapId, buildState.trackStartWorld, endDir);
                                std::vector<std::uint32_t> createdIds;
                                trackGraph.addDoubleTrack(
                                    europeMap, buildState.trackStartWorld, clickPos,
                                    &createdIds, buildState.trackStartNodeId, snapId,
                                    hasStartDir ? &startDir : nullptr,
                                    hasEndDir ? &endDir : nullptr);
                                buildState.treasury -= cost;
                                buildState.trackStartWorld = clickPos;
                                buildState.trackStartNodeId = snapId;
                                buildState.trackCurveAngle = 0.0f;
                                buildState.livePreview.reset();
                                buildState.livePreview2.reset();
                            }
                        }
                    } else if (buildState.livePreview && buildState.livePreview->valid) {
                        const int cost = buildState.livePreview->cost;
                        if (buildState.treasury >= cost) {
                            const std::uint32_t eid = trackGraph.addTrackFromPreview(
                                europeMap, *buildState.livePreview,
                                buildState.trackStartNodeId, snapId);
                            if (eid != 0) {
                                buildState.treasury -= cost;
                                const auto* edge = trackGraph.getEdge(eid);
                                buildState.trackStartWorld = clickPos;
                                buildState.trackStartNodeId = edge ? edge->nodeB : 0;
                                buildState.trackCurveAngle = 0.0f;
                                buildState.livePreview.reset();
                            }
                        }
                    }
                }
            } else if (buildState.tool == raildev::ToolMode::PlaceSignal) {
                if (buildState.hoverEdgeId != 0) {
                    if (buildState.autoSignal) {
                        const int count = trackGraph.autoSignalEdge(
                            buildState.hoverEdgeId, 25.0f, 1, buildState.signalType);
                        buildState.treasury -= count * raildev::BuildState::kSignalCost;
                    } else if (buildState.treasury >= raildev::BuildState::kSignalCost) {
                        trackGraph.addSignal(
                            buildState.hoverEdgeId, buildState.hoverEdgeT,
                            1, buildState.signalType);
                        buildState.treasury -= raildev::BuildState::kSignalCost;
                    }
                }
            }
            updateHoverAndPreview();
        };

        while (running) {
            const std::uint64_t nowCounter = SDL_GetPerformanceCounter();
            const double dt = static_cast<double>(nowCounter - prevCounter) / perfFreq;
            prevCounter = nowCounter;

            SDL_Event event;
            while (SDL_PollEvent(&event)) {
                ImGui_ImplSDL3_ProcessEvent(&event);

                if (event.type == SDL_EVENT_QUIT) {
                    running = false;
                } else if (event.type == SDL_EVENT_WINDOW_RESIZED) {
                    camera.setViewportSize(event.window.data1, event.window.data2);
                } else if (event.type == SDL_EVENT_MOUSE_MOTION) {
                    mouseX = event.motion.x;
                    mouseY = event.motion.y;
                    keyboardCursorActive = false;
                    if (isDragging) {
                        camera.panByScreenDelta(event.motion.xrel, event.motion.yrel);
                        if (std::hypot(mouseX - dragStartX, mouseY - dragStartY) > 4.0f) {
                            dragMoved = true;
                        }
                    }
                    updateHoverAndPreview();
                } else if (event.type == SDL_EVENT_MOUSE_BUTTON_DOWN) {
                    keyboardCursorActive = false;
                    if (!io.WantCaptureMouse &&
                        (event.button.button == SDL_BUTTON_LEFT ||
                         event.button.button == SDL_BUTTON_MIDDLE ||
                         event.button.button == SDL_BUTTON_RIGHT)) {
                        isDragging = true;
                        dragMoved = false;
                        dragButton = event.button.button;
                        dragStartX = event.button.x;
                        dragStartY = event.button.y;
                    }
                } else if (event.type == SDL_EVENT_MOUSE_BUTTON_UP) {
                    if (isDragging) {
                        if (!dragMoved && !io.WantCaptureMouse) {
                            if (dragButton == SDL_BUTTON_RIGHT) {
                                performCancelAction();
                            } else if (dragButton == SDL_BUTTON_LEFT) {
                                performPrimaryAction(event.button.x, event.button.y);
                            }
                        }
                        isDragging = false;
                        updateHoverAndPreview();
                    }
                } else if (event.type == SDL_EVENT_MOUSE_WHEEL) {
                    if (!io.WantCaptureMouse) {
                        const SDL_Keymod mods = SDL_GetModState();
                        const bool shiftHeld = (mods & SDL_KMOD_SHIFT) != 0;
                        const float wy = std::clamp(event.wheel.y, -2.5f, 2.5f);

                        if (shiftHeld && buildState.tool == raildev::ToolMode::BuildStation) {
                            buildState.stationAngle += wy * (3.14159265f / 18.0f);
                        } else if (shiftHeld && buildState.tool == raildev::ToolMode::BuildTrack &&
                                   buildState.hasTrackStart) {
                            buildState.trackCurveAngle += wy * 0.10f;
                            updateHoverAndPreview();
                        } else if (std::abs(wy) > 1e-4f) {
                            // Gentle proportional zoom (smooth on both mouse wheel & high-res touchpads)
                            const double factor = std::pow(1.065, static_cast<double>(wy));
                            camera.smoothZoomAtScreenPoint(mouseX, mouseY, factor);
                            updateHoverAndPreview();
                        }
                    }
                } else if (event.type == SDL_EVENT_PINCH_UPDATE) {
                    if (!io.WantCaptureMouse && event.pinch.scale > 0.0f) {
                        const double clampedScale = std::clamp(
                            static_cast<double>(event.pinch.scale), 0.75, 1.35);
                        const double dampedScale = std::pow(clampedScale, 0.70);
                        camera.zoomAtScreenPoint(mouseX, mouseY, dampedScale);
                        updateHoverAndPreview();
                    }
                } else if (event.type == SDL_EVENT_KEY_DOWN && !io.WantCaptureKeyboard) {
                    const bool shiftHeld = (event.key.mod & SDL_KMOD_SHIFT) != 0;
                    switch (event.key.key) {
                        case SDLK_SPACE:
                        case SDLK_P:
                            simClock.togglePause();
                            break;
                        case SDLK_1:
                            simClock.setSpeed(raildev::SimSpeed::Normal);
                            break;
                        case SDLK_2:
                            simClock.setSpeed(raildev::SimSpeed::Fast);
                            break;
                        case SDLK_3:
                            simClock.setSpeed(raildev::SimSpeed::Ultra);
                            break;
                        case SDLK_PLUS:
                        case SDLK_EQUALS:
                        case SDLK_KP_PLUS:
                        case SDLK_PAGEUP:
                            camera.smoothZoomAtScreenPoint(activeCursorX(), activeCursorY(), 1.15);
                            break;
                        case SDLK_MINUS:
                        case SDLK_KP_MINUS:
                        case SDLK_PAGEDOWN:
                            camera.smoothZoomAtScreenPoint(activeCursorX(), activeCursorY(), 1.0 / 1.15);
                            break;
                        case SDLK_I:
                        case SDLK_F1:
                            setToolMode(raildev::ToolMode::Inspect);
                            break;
                        case SDLK_B:
                        case SDLK_F2:
                            setToolMode(raildev::ToolMode::BuildStation);
                            break;
                        case SDLK_T:
                        case SDLK_F3:
                            setToolMode(raildev::ToolMode::BuildTrack);
                            break;
                        case SDLK_N:
                        case SDLK_F4:
                            setToolMode(raildev::ToolMode::PlaceSignal);
                            break;
                        case SDLK_R:
                            if (buildState.tool == raildev::ToolMode::BuildStation) {
                                buildState.stationAngle += (shiftHeld ? -1.0f : 1.0f) * (3.14159265f / 12.0f);
                            }
                            break;
                        case SDLK_Q:
                            if (buildState.tool == raildev::ToolMode::BuildTrack && buildState.hasTrackStart) {
                                buildState.trackCurveAngle -= 0.15f;
                                updateHoverAndPreview();
                            }
                            break;
                        case SDLK_E:
                            if (buildState.tool == raildev::ToolMode::BuildTrack && buildState.hasTrackStart) {
                                buildState.trackCurveAngle += 0.15f;
                                updateHoverAndPreview();
                            }
                            break;
                        case SDLK_L:
                            buildState.doubleTrack = !buildState.doubleTrack;
                            updateHoverAndPreview();
                            break;
                        case SDLK_U:
                            buildState.autoSignal = !buildState.autoSignal;
                            break;
                        case SDLK_C: {
                            int nextSig = (static_cast<int>(buildState.signalType) + 1) % 3;
                            buildState.signalType = static_cast<raildev::SignalType>(nextSig);
                            break;
                        }
                        case SDLK_G:
                            mapRenderer.setOverlay(
                                mapRenderer.overlay() == raildev::TerrainOverlay::Relief
                                    ? raildev::TerrainOverlay::Grade
                                    : raildev::TerrainOverlay::Relief);
                            break;
                        case SDLK_V:
                            if (mapRenderer.detailMode() == raildev::DetailMode::AutoZoomLOD) {
                                mapRenderer.setDetailMode(raildev::DetailMode::GenerativeOnly);
                            } else if (mapRenderer.detailMode() == raildev::DetailMode::GenerativeOnly) {
                                mapRenderer.setDetailMode(raildev::DetailMode::Textured);
                            } else {
                                mapRenderer.setDetailMode(raildev::DetailMode::AutoZoomLOD);
                            }
                            break;
                        case SDLK_H:
                        case SDLK_SLASH:
                            showHelp = !showHelp;
                            break;
                        case SDLK_LEFTBRACKET:
                        case SDLK_RIGHTBRACKET: {
                            const auto& presets = raildev::getEuropeRegionPresets();
                            if (!presets.empty()) {
                                const int n = static_cast<int>(presets.size());
                                regionPresetIdx = (event.key.key == SDLK_RIGHTBRACKET)
                                    ? (regionPresetIdx + 1) % n
                                    : (regionPresetIdx - 1 + n) % n;
                                const auto& p = presets[static_cast<std::size_t>(regionPresetIdx)];
                                double wx = 0.0, wy = 0.0;
                                raildev::EuropeProjection::latLonToWorld(p.lat, p.lon, wx, wy);
                                camera.focusOn(wx, wy, p.zoom);
                                updateHoverAndPreview();
                            }
                            break;
                        }
                        case SDLK_TAB: {
                            const auto& cities = europeMap.cities();
                            if (!cities.empty()) {
                                const int n = static_cast<int>(cities.size());
                                if (selectedCityIndex < 0) {
                                    selectedCityIndex = 0;
                                } else {
                                    selectedCityIndex = shiftHeld
                                        ? (selectedCityIndex - 1 + n) % n
                                        : (selectedCityIndex + 1) % n;
                                }
                                const auto& c = cities[static_cast<std::size_t>(selectedCityIndex)];
                                double wx = 0.0, wy = 0.0;
                                raildev::EuropeProjection::latLonToWorld(c.lat, c.lon, wx, wy);
                                camera.focusOn(wx, wy, std::max(camera.zoom(), 1.6));
                                keyboardCursorActive = true;
                                updateHoverAndPreview();
                            }
                            break;
                        }
                        case SDLK_HOME: {
                            double wx = 0.0, wy = 0.0;
                            raildev::EuropeProjection::latLonToWorld(48.0, 8.0, wx, wy);
                            camera.focusOn(wx, wy, 0.72);
                            updateHoverAndPreview();
                            break;
                        }
                        case SDLK_RETURN:
                        case SDLK_KP_ENTER:
                            keyboardCursorActive = true;
                            updateHoverAndPreview();
                            performPrimaryAction(activeCursorX(), activeCursorY());
                            break;
                        case SDLK_ESCAPE:
                        case SDLK_BACKSPACE:
                            performCancelAction();
                            break;
                        default:
                            break;
                    }
                }
            }

            // Smooth keyboard panning
            if (!io.WantCaptureKeyboard) {
                const bool* keys = SDL_GetKeyboardState(nullptr);
                const bool shiftHeld = keys[SDL_SCANCODE_LSHIFT] || keys[SDL_SCANCODE_RSHIFT];
                const double panSpeed = (shiftHeld ? 1100.0 : 580.0) * dt;
                double dx = 0.0, dy = 0.0;
                if (keys[SDL_SCANCODE_A] || keys[SDL_SCANCODE_LEFT]) dx += panSpeed;
                if (keys[SDL_SCANCODE_D] || keys[SDL_SCANCODE_RIGHT]) dx -= panSpeed;
                if (keys[SDL_SCANCODE_W] || keys[SDL_SCANCODE_UP]) dy += panSpeed;
                if (keys[SDL_SCANCODE_S] || keys[SDL_SCANCODE_DOWN]) dy -= panSpeed;
                if (dx != 0.0 || dy != 0.0) {
                    keyboardCursorActive = true;
                    camera.panByScreenDelta(dx, dy);
                    updateHoverAndPreview();
                }
            }

            const double prevZoom = camera.zoom();
            camera.update(dt);
            if (std::abs(camera.zoom() - prevZoom) > 1e-6) {
                updateHoverAndPreview();
            }

            simClock.advance(dt);

            const float cx = activeCursorX();
            const float cy = activeCursorY();

            ImGui_ImplSDLRenderer3_NewFrame();
            ImGui_ImplSDL3_NewFrame();
            ImGui::NewFrame();

            hud.render(simClock, camera, europeMap, trackGraph, buildState,
                       mapRenderer, selectedCityIndex, cx, cy, showHelp);
            ImGui::Render();

            int winW = 1, winH = 1;
            int outW = 1, outH = 1;
            SDL_GetWindowSize(window, &winW, &winH);
            SDL_GetRenderOutputSize(renderer, &outW, &outH);
            const float scaleX = (winW > 0) ? static_cast<float>(outW) / static_cast<float>(winW) : 1.0f;
            const float scaleY = (winH > 0) ? static_cast<float>(outH) / static_cast<float>(winH) : 1.0f;

            SDL_SetRenderScale(renderer, 1.0f, 1.0f);
            SDL_SetRenderDrawColor(renderer, 30, 56, 82, 255);
            SDL_RenderClear(renderer);

            SDL_SetRenderScale(renderer, scaleX, scaleY);
            mapRenderer.render(camera, trackGraph, buildState,
                               selectedCityIndex, hoveredCityIndex,
                               cx, cy, keyboardCursorActive);
            ImGui_ImplSDLRenderer3_RenderDrawData(ImGui::GetDrawData(), renderer);

            SDL_RenderPresent(renderer);
        }
    }

    ImGui_ImplSDLRenderer3_Shutdown();
    ImGui_ImplSDL3_Shutdown();
    ImGui::DestroyContext();

    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    TTF_Quit();
    SDL_Quit();
    return 0;
}
