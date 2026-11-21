#include "ui/MapRenderer.hpp"

#include <SDL3_image/SDL_image.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <filesystem>

namespace raildev {
namespace {

void drawFilledCircle(SDL_Renderer* renderer, float cx, float cy, float radius) {
    const int r = static_cast<int>(std::ceil(radius));
    for (int dy = -r; dy <= r; ++dy) {
        const float fy = static_cast<float>(dy);
        const float dxMax = std::sqrt(std::max(0.0f, radius * radius - fy * fy));
        SDL_RenderLine(renderer, cx - dxMax, cy + fy, cx + dxMax, cy + fy);
    }
}

void drawCircleOutline(SDL_Renderer* renderer, float cx, float cy, float radius, int segments = 24) {
    for (int i = 0; i < segments; ++i) {
        const float a0 = (2.0f * 3.14159265f * i) / static_cast<float>(segments);
        const float a1 = (2.0f * 3.14159265f * (i + 1)) / static_cast<float>(segments);
        SDL_RenderLine(renderer,
                       cx + std::cos(a0) * radius, cy + std::sin(a0) * radius,
                       cx + std::cos(a1) * radius, cy + std::sin(a1) * radius);
    }
}

void drawDashedCircle(SDL_Renderer* renderer, float cx, float cy, float radius, int segments = 36) {
    for (int i = 0; i < segments; i += 2) {
        const float a0 = (2.0f * 3.14159265f * i) / static_cast<float>(segments);
        const float a1 = (2.0f * 3.14159265f * (i + 1)) / static_cast<float>(segments);
        SDL_RenderLine(renderer,
                       cx + std::cos(a0) * radius, cy + std::sin(a0) * radius,
                       cx + std::cos(a1) * radius, cy + std::sin(a1) * radius);
    }
}

void drawRotatedFilledRect(SDL_Renderer* renderer, float cx, float cy,
                           float w, float h, float angle, SDL_FColor col) {
    const float hw = w * 0.5f;
    const float hh = h * 0.5f;
    const float c = std::cos(angle);
    const float s = std::sin(angle);

    auto pt = [&](float lx, float ly) -> SDL_FPoint {
        return {cx + lx * c - ly * s, cy + lx * s + ly * c};
    };

    const SDL_Vertex verts[4] = {
        {pt(-hw, -hh), col, {0.0f, 0.0f}},
        {pt( hw, -hh), col, {0.0f, 0.0f}},
        {pt( hw,  hh), col, {0.0f, 0.0f}},
        {pt(-hw,  hh), col, {0.0f, 0.0f}},
    };
    static constexpr int kIndices[6] = {0, 1, 2, 0, 2, 3};
    SDL_RenderGeometry(renderer, nullptr, verts, 4, kIndices, 6);
}

void drawThickLine(SDL_Renderer* renderer, float x0, float y0, float x1, float y1,
                   float thickness, SDL_FColor col) {
    const float dx = x1 - x0;
    const float dy = y1 - y0;
    const float len = std::hypot(dx, dy);
    if (len < 1e-4f) return;
    const float nx = (-dy / len) * (thickness * 0.5f);
    const float ny = (dx / len) * (thickness * 0.5f);

    const SDL_Vertex verts[4] = {
        {{x0 + nx, y0 + ny}, col, {0.0f, 0.0f}},
        {{x0 - nx, y0 - ny}, col, {0.0f, 0.0f}},
        {{x1 - nx, y1 - ny}, col, {0.0f, 0.0f}},
        {{x1 + nx, y1 + ny}, col, {0.0f, 0.0f}},
    };
    static constexpr int kIndices[6] = {0, 1, 2, 0, 2, 3};
    SDL_RenderGeometry(renderer, nullptr, verts, 4, kIndices, 6);
}

void drawTexturedSegment(SDL_Renderer* renderer, SDL_Texture* tex,
                         float x0, float y0, float x1, float y1,
                         float thickness, float u0, float u1, SDL_FColor col) {
    const float dx = x1 - x0;
    const float dy = y1 - y0;
    const float len = std::hypot(dx, dy);
    if (len < 1e-4f || !tex) return;
    const float nx = (-dy / len) * (thickness * 0.5f);
    const float ny = (dx / len) * (thickness * 0.5f);

    const SDL_Vertex verts[4] = {
        {{x0 + nx, y0 + ny}, col, {u0, 0.0f}},
        {{x0 - nx, y0 - ny}, col, {u0, 1.0f}},
        {{x1 - nx, y1 - ny}, col, {u1, 1.0f}},
        {{x1 + nx, y1 + ny}, col, {u1, 0.0f}},
    };
    static constexpr int kIndices[6] = {0, 1, 2, 0, 2, 3};
    SDL_RenderGeometry(renderer, tex, verts, 4, kIndices, 6);
}

SDL_Texture* loadAssetTexture(SDL_Renderer* renderer, const char* filename) {
    const std::string p1 = std::string("assets/textures/") + filename;
    const std::string p2 = std::string("../assets/textures/") + filename;
    const char* path = std::filesystem::exists(p1) ? p1.c_str()
                     : (std::filesystem::exists(p2) ? p2.c_str() : nullptr);
    if (!path) return nullptr;
    SDL_Texture* tex = IMG_LoadTexture(renderer, path);
    if (tex) {
        SDL_SetTextureScaleMode(tex, SDL_SCALEMODE_LINEAR);
        SDL_SetTextureBlendMode(tex, SDL_BLENDMODE_BLEND);
    }
    return tex;
}

const char* findSystemFontPath() {
    static constexpr std::array<const char*, 4> kCandidates = {
        "/usr/share/fonts/noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
        "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
    };
    for (const char* path : kCandidates) {
        if (std::filesystem::exists(path)) {
            return path;
        }
    }
    return nullptr;
}

inline float hash2DFloat(int x, int y) {
    std::uint32_t h = static_cast<std::uint32_t>(x) * 374761393u +
                      static_cast<std::uint32_t>(y) * 668265263u;
    h = (h ^ (h >> 13)) * 1274126177u;
    return static_cast<float>((h ^ (h >> 16)) & 0xFFFFu) / 65535.0f;
}

float smoothValueNoise(float x, float y) {
    const int xi = static_cast<int>(std::floor(x));
    const int yi = static_cast<int>(std::floor(y));
    const float tx = x - static_cast<float>(xi);
    const float ty = y - static_cast<float>(yi);
    const float ux = tx * tx * (3.0f - 2.0f * tx);
    const float uy = ty * ty * (3.0f - 2.0f * ty);
    const float a = hash2DFloat(xi, yi);
    const float b = hash2DFloat(xi + 1, yi);
    const float c = hash2DFloat(xi, yi + 1);
    const float d = hash2DFloat(xi + 1, yi + 1);
    return (a + (b - a) * ux) + ((c + (d - c) * ux) - (a + (b - a) * ux)) * uy;
}

float biomeEdgeNoise(float wx, float wy) {
    const float n1 = smoothValueNoise(wx * 0.045f + 11.3f, wy * 0.045f + 27.1f);
    const float n2 = smoothValueNoise(wx * 0.11f + 53.7f, wy * 0.11f + 9.4f);
    return (n1 * 0.65f + n2 * 0.35f) * 2.0f - 1.0f;  // [-1, 1]
}

void drawDiamondFilled(SDL_Renderer* renderer, float cx, float cy, float radius, SDL_FColor col) {
    const SDL_Vertex verts[4] = {
        {{cx, cy - radius}, col, {0.0f, 0.0f}},
        {{cx + radius, cy}, col, {0.0f, 0.0f}},
        {{cx, cy + radius}, col, {0.0f, 0.0f}},
        {{cx - radius, cy}, col, {0.0f, 0.0f}},
    };
    static constexpr int kIndices[6] = {0, 1, 2, 0, 2, 3};
    SDL_RenderGeometry(renderer, nullptr, verts, 4, kIndices, 6);
}

}  // namespace

MapRenderer::MapRenderer(SDL_Renderer* renderer, const EuropeMap& map)
    : renderer_(renderer), map_(map) {
    chunkTextures_.resize(static_cast<std::size_t>(EuropeMap::kChunksX) * EuropeMap::kChunksY, nullptr);
    rebuildChunkTextures();
    loadFontAndLabels();
    loadTextures();

    const auto& cities = map_.cities();
    cityFootprints_.reserve(cities.size());
    for (const auto& city : cities) {
        cityFootprints_.push_back(generateCityFootprint(city, map_));
    }
}

MapRenderer::~MapRenderer() {
    for (SDL_Texture* tex : chunkTextures_) {
        if (tex) SDL_DestroyTexture(tex);
    }
    for (auto& lbl : cityLabels_) {
        if (lbl.texture) SDL_DestroyTexture(lbl.texture);
    }
    if (font_) {
        TTF_CloseFont(font_);
    }
    auto destroyTex = [](SDL_Texture*& t) {
        if (t) {
            SDL_DestroyTexture(t);
            t = nullptr;
        }
    };
    destroyTex(texGrass_);
    destroyTex(texGrassMed_);
    destroyTex(texForest_);
    destroyTex(texRock_);
    destroyTex(texWater_);
    destroyTex(texStation_);
    destroyTex(texCityHistoric_);
    destroyTex(texCityHistoricMed_);
    destroyTex(texCityOuter_);
    destroyTex(texTrackRail_);
}

void MapRenderer::loadTextures() {
    texGrass_ = loadAssetTexture(renderer_, "terrain_grass.png");
    texGrassMed_ = loadAssetTexture(renderer_, "terrain_grass_mediterranean.png");
    texForest_ = loadAssetTexture(renderer_, "terrain_forest.png");
    texRock_ = loadAssetTexture(renderer_, "terrain_rock.png");
    texWater_ = loadAssetTexture(renderer_, "terrain_water.png");
    texStation_ = loadAssetTexture(renderer_, "station_sprite.png");
    texCityHistoric_ = loadAssetTexture(renderer_, "city_historic.png");
    texCityHistoricMed_ = loadAssetTexture(renderer_, "city_historic_mediterranean.png");
    texCityOuter_ = loadAssetTexture(renderer_, "city_outer.png");
    texTrackRail_ = loadAssetTexture(renderer_, "track_rail.png");
}

void MapRenderer::setOverlay(TerrainOverlay overlay) {
    if (overlay_ == overlay) return;
    overlay_ = overlay;
    rebuildChunkTextures();
}

void MapRenderer::rebuildChunkTextures() {
    std::vector<std::uint8_t> rgba;
    for (int cy = 0; cy < EuropeMap::kChunksY; ++cy) {
        for (int cx = 0; cx < EuropeMap::kChunksX; ++cx) {
            const std::size_t idx = static_cast<std::size_t>(cy) * EuropeMap::kChunksX + cx;
            if (!chunkTextures_[idx]) {
                chunkTextures_[idx] = SDL_CreateTexture(
                    renderer_,
                    SDL_PIXELFORMAT_RGBA32,
                    SDL_TEXTUREACCESS_STATIC,
                    EuropeMap::kChunkSize,
                    EuropeMap::kChunkSize);
                SDL_SetTextureScaleMode(chunkTextures_[idx], SDL_SCALEMODE_LINEAR);
            }
            map_.renderChunkRGBA(cx, cy, overlay_, rgba);
            SDL_UpdateTexture(chunkTextures_[idx], nullptr, rgba.data(),
                              EuropeMap::kChunkSize * 4);
        }
    }
}

void MapRenderer::loadFontAndLabels() {
    const char* fontPath = findSystemFontPath();
    if (!fontPath) return;

    font_ = TTF_OpenFont(fontPath, 14.0f);
    if (!font_) return;

    const auto& cities = map_.cities();
    cityLabels_.resize(cities.size());
    for (std::size_t i = 0; i < cities.size(); ++i) {
        SDL_Surface* surf = TTF_RenderText_Blended(
            font_, cities[i].name.c_str(), cities[i].name.size(),
            SDL_Color{245, 245, 242, 255});
        if (!surf) continue;
        cityLabels_[i].texture = SDL_CreateTextureFromSurface(renderer_, surf);
        cityLabels_[i].width = static_cast<float>(surf->w);
        cityLabels_[i].height = static_cast<float>(surf->h);
        SDL_DestroySurface(surf);
    }
}

void MapRenderer::renderTerrainTextures(const Camera2D& camera, float texAlpha) {
    if (texAlpha <= 0.01f || overlay_ != TerrainOverlay::Relief) return;

    auto smoothstep = [](float edge0, float edge1, float x) -> float {
        const float t = std::clamp((x - edge0) / (edge1 - edge0), 0.0f, 1.0f);
        return t * t * (3.0f - 2.0f * t);
    };

    // Larger 128-world-unit tiles for 1024x1024 textures -> 4x less repetition, crisp close-up detail
    constexpr int kTileWorld = 128;
    constexpr int kSubDiv = 8;  // 16 world-unit coarse vertex spacing; coasts adaptively subdivide to 4 units
    const int stepWorld = kTileWorld / kSubDiv;

    const Vec2 topLeft = camera.screenToWorld(0.0, 0.0);
    const Vec2 botRight = camera.screenToWorld(camera.viewportWidth(), camera.viewportHeight());

    const int tx0 = std::max(0, static_cast<int>(std::floor(topLeft.x / kTileWorld)));
    const int ty0 = std::max(0, static_cast<int>(std::floor(topLeft.y / kTileWorld)));
    const int tx1 = std::min((EuropeMap::kWidth / kTileWorld) - 1,
                             static_cast<int>(std::floor(botRight.x / kTileWorld)));
    const int ty1 = std::min((EuropeMap::kHeight / kTileWorld) - 1,
                             static_cast<int>(std::floor(botRight.y / kTileWorld)));

    struct BiomeMesh {
        SDL_Texture* tex = nullptr;
        float layerAlpha = 1.0f;
        std::vector<SDL_Vertex> verts;
        std::vector<int> indices;
    };

    // 5 geographic biome layers: Water, Northern Temperate Grass, Mediterranean Grass, Forest Canopy, Alpine Rock
    std::array<BiomeMesh, 5> meshes = {{
        {texWater_,    texAlpha * 0.62f, {}, {}},
        {texGrass_,    texAlpha * 0.78f, {}, {}},
        {texGrassMed_ ? texGrassMed_ : texGrass_, texAlpha * 0.80f, {}, {}},
        {texForest_,   texAlpha * 0.88f, {}, {}},
        {texRock_,     texAlpha * 0.86f, {}, {}},
    }};

    struct SampleVertex {
        SDL_FPoint screenPt{};
        float weights[5]{};
        SDL_FColor landTint{};
        SDL_FColor rockCol{};
        bool isLand = false;
    };

    auto evalSample = [&](int wx, int wy) -> SampleVertex {
        SampleVertex sv;
        const Vec2 sp = camera.worldToScreen(wx, wy);
        sv.screenPt = {static_cast<float>(sp.x), static_cast<float>(sp.y)};

        const float elev = map_.elevationAt(wx, wy);
        const float slope = map_.slopeAt(wx, wy);
        const float forest = map_.forestDensityAt(wx, wy);
        const float riverDist = map_.riverDistAt(wx, wy);
        const float edgeN = biomeEdgeNoise(static_cast<float>(wx), static_cast<float>(wy));

        sv.isLand = (elev >= 0.0f);

        // Strict land/sea separation at elev == 0 so fields NEVER wash into oceans
        const float seaWater = sv.isLand ? 0.0f : 1.0f;
        const float riverWater = sv.isLand ? smoothstep(2.2f, 0.7f, riverDist) : 0.0f;
        const float wWater = std::max(seaWater, riverWater);
        const float wLand = 1.0f - wWater;

        // Suppress rock & dense forest directly inside city valleys so buildings never morph into crags
        float cityClearance = 0.0f;
        for (const auto& fp : cityFootprints_) {
            const float dx = static_cast<float>(wx) - static_cast<float>(fp.center.x);
            const float dy = static_cast<float>(wy) - static_cast<float>(fp.center.y);
            const float rClear = fp.radius * 1.45f;
            const float d2 = dx * dx + dy * dy;
            if (d2 < rClear * rClear) {
                const float d = std::sqrt(d2);
                cityClearance = std::max(cityClearance, smoothstep(rClear, fp.radius * 0.85f, d));
            }
        }

        // Crisp noise-modulated rocky ridge & alpine transition (suppressed in city valleys)
        const float rawRock = std::max(
            smoothstep(960.0f, 1260.0f, elev + edgeN * 150.0f),
            smoothstep(0.036f, 0.056f, slope + edgeN * 0.010f));
        const float wRock = wLand * rawRock * (1.0f - cityClearance);

        // Crisp canopy-edge forest mask (suppressed inside city footprints)
        const float rawForest = smoothstep(0.545f, 0.585f, forest + edgeN * 0.045f);
        const float wForest = wLand * (1.0f - wRock) * rawForest * (1.0f - cityClearance);

        // Geographic climate split: Northern/Central Temperate vs Southern Mediterranean
        double lat = 48.0, lon = 8.0;
        EuropeProjection::worldToLatLon(wx, wy, lat, lon);
        const float medClimate = smoothstep(46.2f, 42.8f,
            static_cast<float>(lat) + edgeN * 0.9f) *
            smoothstep(1050.0f, 550.0f, elev);
        const float wGrassTotal = wLand * (1.0f - wRock) * (1.0f - wForest);
        const float wGrassMed = wGrassTotal * medClimate;
        const float wGrassNorth = wGrassTotal * (1.0f - medClimate);

        sv.weights[0] = wWater;
        sv.weights[1] = wGrassNorth;
        sv.weights[2] = wGrassMed;
        sv.weights[3] = wForest;
        sv.weights[4] = wRock;

        // Subtle NW hillshading + macro spatial tone variation to eliminate repetition
        const float eL = std::max(0.0f, map_.elevationAt(wx - 2, wy));
        const float eR = std::max(0.0f, map_.elevationAt(wx + 2, wy));
        const float eU = std::max(0.0f, map_.elevationAt(wx, wy - 2));
        const float eD = std::max(0.0f, map_.elevationAt(wx, wy + 2));
        const float dzdx = (eR - eL) * 0.008f;
        const float dzdy = (eD - eU) * 0.008f;
        const float invLen = 1.0f / std::sqrt(dzdx * dzdx + dzdy * dzdy + 1.0f);
        const float hillShade = std::clamp(
            0.82f + 0.30f * ((-dzdx - dzdy + 1.0f) * 0.577f * invLen), 0.68f, 1.12f);

        // Subtle SE canopy drop-shadow where grass sits immediately SE of a forest edge
        const float forestNW = map_.forestDensityAt(wx - 4, wy - 4);
        const float canopyShadow = (wForest < 0.25f && forestNW > 0.57f) ? 0.88f : 1.0f;

        const float macroVar = 0.94f + 0.12f * smoothValueNoise(wx * 0.009f, wy * 0.009f);
        const float landBright = std::clamp(hillShade * canopyShadow * macroVar, 0.64f, 1.12f);
        sv.landTint = {landBright, landBright, landBright * 0.98f, 1.0f};

        // Altitude-dependent mountain tint: warm foothill -> cool slate -> snowy peak
        const float altMid = smoothstep(1150.0f, 1950.0f, elev);
        const float altSnow = smoothstep(2350.0f, 3100.0f, elev);
        const float rr = (0.80f + 0.05f * altMid + 0.15f * altSnow) * hillShade;
        const float rg = (0.76f + 0.09f * altMid + 0.15f * altSnow) * hillShade;
        const float rb = (0.68f + 0.18f * altMid + 0.14f * altSnow) * hillShade;
        sv.rockCol = {
            std::clamp(rr, 0.0f, 1.0f),
            std::clamp(rg, 0.0f, 1.0f),
            std::clamp(rb, 0.0f, 1.0f),
            1.0f
        };
        return sv;
    };

    auto emitQuad = [&](const SampleVertex& s00, const SampleVertex& s10,
                        const SampleVertex& s11, const SampleVertex& s01,
                        float u0, float v0, float u1, float v1) {
        for (int b = 0; b < 5; ++b) {
            if (!meshes[b].tex) continue;
            const float a00 = s00.weights[b];
            const float a10 = s10.weights[b];
            const float a11 = s11.weights[b];
            const float a01 = s01.weights[b];
            if (a00 < 0.01f && a10 < 0.01f && a11 < 0.01f && a01 < 0.01f) {
                continue;
            }
            auto& m = meshes[b];
            const int baseIdx = static_cast<int>(m.verts.size());

            auto vtxCol = [&](const SampleVertex& sv, float w) -> SDL_FColor {
                if (b == 4) {
                    return {sv.rockCol.r, sv.rockCol.g, sv.rockCol.b, w * m.layerAlpha};
                }
                if (b == 0) {
                    return {0.92f, 0.96f, 1.0f, w * m.layerAlpha};
                }
                return {sv.landTint.r, sv.landTint.g, sv.landTint.b, w * m.layerAlpha};
            };

            m.verts.push_back({s00.screenPt, vtxCol(s00, a00), {u0, v0}});
            m.verts.push_back({s10.screenPt, vtxCol(s10, a10), {u1, v0}});
            m.verts.push_back({s11.screenPt, vtxCol(s11, a11), {u1, v1}});
            m.verts.push_back({s01.screenPt, vtxCol(s01, a01), {u0, v1}});

            m.indices.push_back(baseIdx + 0);
            m.indices.push_back(baseIdx + 1);
            m.indices.push_back(baseIdx + 2);
            m.indices.push_back(baseIdx + 0);
            m.indices.push_back(baseIdx + 2);
            m.indices.push_back(baseIdx + 3);
        }
    };

    for (int ty = ty0; ty <= ty1; ++ty) {
        for (int tx = tx0; tx <= tx1; ++tx) {
            SampleVertex grid[kSubDiv + 1][kSubDiv + 1];
            for (int sy = 0; sy <= kSubDiv; ++sy) {
                const int wy = ty * kTileWorld + sy * stepWorld;
                for (int sx = 0; sx <= kSubDiv; ++sx) {
                    const int wx = tx * kTileWorld + sx * stepWorld;
                    grid[sy][sx] = evalSample(wx, wy);
                }
            }

            for (int sy = 0; sy < kSubDiv; ++sy) {
                const float v0 = static_cast<float>(sy) / kSubDiv;
                const float v1 = static_cast<float>(sy + 1) / kSubDiv;
                for (int sx = 0; sx < kSubDiv; ++sx) {
                    const float u0 = static_cast<float>(sx) / kSubDiv;
                    const float u1 = static_cast<float>(sx + 1) / kSubDiv;

                    const auto& c00 = grid[sy][sx];
                    const auto& c10 = grid[sy][sx + 1];
                    const auto& c11 = grid[sy + 1][sx + 1];
                    const auto& c01 = grid[sy + 1][sx];

                    const bool allLand = c00.isLand && c10.isLand && c11.isLand && c01.isLand;
                    const bool allSea = !c00.isLand && !c10.isLand && !c11.isLand && !c01.isLand;

                    if (allLand || allSea) {
                        emitQuad(c00, c10, c11, c01, u0, v0, u1, v1);
                    } else {
                        // Coastal quad: adaptively subdivide 4x4 (down to 4 world-unit cells)
                        // so field textures stop crisply at the exact shoreline and never wash into oceans!
                        constexpr int kCoastSub = 4;
                        const int fineStep = stepWorld / kCoastSub;
                        const int baseWx = tx * kTileWorld + sx * stepWorld;
                        const int baseWy = ty * kTileWorld + sy * stepWorld;
                        SampleVertex fine[kCoastSub + 1][kCoastSub + 1];
                        for (int fy = 0; fy <= kCoastSub; ++fy) {
                            for (int fx = 0; fx <= kCoastSub; ++fx) {
                                fine[fy][fx] = evalSample(baseWx + fx * fineStep, baseWy + fy * fineStep);
                            }
                        }
                        for (int fy = 0; fy < kCoastSub; ++fy) {
                            const float fv0 = v0 + (v1 - v0) * (static_cast<float>(fy) / kCoastSub);
                            const float fv1 = v0 + (v1 - v0) * (static_cast<float>(fy + 1) / kCoastSub);
                            for (int fx = 0; fx < kCoastSub; ++fx) {
                                const float fu0 = u0 + (u1 - u0) * (static_cast<float>(fx) / kCoastSub);
                                const float fu1 = u0 + (u1 - u0) * (static_cast<float>(fx + 1) / kCoastSub);
                                emitQuad(fine[fy][fx], fine[fy][fx + 1],
                                         fine[fy + 1][fx + 1], fine[fy + 1][fx],
                                         fu0, fv0, fu1, fv1);
                            }
                        }
                    }
                }
            }
        }
    }

    for (auto& m : meshes) {
        if (!m.tex || m.indices.empty()) continue;
        SDL_SetTextureAlphaModFloat(m.tex, 1.0f);
        SDL_RenderGeometry(renderer_, m.tex,
                           m.verts.data(), static_cast<int>(m.verts.size()),
                           m.indices.data(), static_cast<int>(m.indices.size()));
    }
}

void MapRenderer::renderRivers(const Camera2D& camera, float alpha) {
    // Render smooth continuous mitered river ribbons at all zoom levels (scaled cleanly)
    const float baseAlpha = std::max(alpha, 0.72f);
    const float zoom = static_cast<float>(camera.zoom());

    std::vector<SDL_Vertex> bankVerts;
    std::vector<int> bankIdx;
    std::vector<SDL_Vertex> waterVerts;
    std::vector<int> waterIdx;

    for (const auto& river : map_.worldRivers()) {
        const std::size_t n = river.points.size();
        if (n < 2) continue;

        // Precompute screen points, continuous miter normals, widths & estuary sea-fade
        struct RibbonPt {
            float sx = 0.0f;
            float sy = 0.0f;
            float nx = 0.0f;
            float ny = 0.0f;
            float halfWater = 1.0f;
            float halfBank = 2.0f;
            float seaFade = 1.0f;
            float bankFade = 1.0f;
            bool visible = false;
        };

        std::vector<RibbonPt> pts(n);
        bool anyVisible = false;
        for (std::size_t i = 0; i < n; ++i) {
            const auto& wp = river.points[i];
            const Vec2 sp = camera.worldToScreen(wp.x, wp.y);
            pts[i].sx = static_cast<float>(sp.x);
            pts[i].sy = static_cast<float>(sp.y);

            const float elev = map_.elevationAtWorld(wp.x, wp.y);
            // Smooth estuary fade: stays 100% solid up to the shoreline, then blends gently into sea shelf
            if (elev >= 0.0f) {
                pts[i].seaFade = 1.0f;
                pts[i].bankFade = 1.0f;
            } else {
                pts[i].seaFade = std::clamp(1.0f + elev / 24.0f, 0.0f, 1.0f);
                pts[i].bankFade = std::clamp(1.0f + elev / 6.0f, 0.0f, 1.0f);
            }

            const float tRiver = static_cast<float>(i) / static_cast<float>(std::max<std::size_t>(1, n - 1));
            const float radWorld = river.baseWidth * (0.55f + 0.78f * tRiver);
            const float widthPx = std::max(1.4f, radWorld * 1.9f * zoom);
            pts[i].halfWater = widthPx * 0.5f;
            pts[i].halfBank = pts[i].halfWater + std::clamp(widthPx * 0.55f, 1.5f, 5.5f);

            if (sp.x >= -80.0 && sp.y >= -80.0 &&
                sp.x <= camera.viewportWidth() + 80.0 &&
                sp.y <= camera.viewportHeight() + 80.0 &&
                pts[i].seaFade > 0.01f) {
                pts[i].visible = true;
                anyVisible = true;
            }
        }
        if (!anyVisible) continue;

        // Compute smooth continuous tangent & normal at every vertex (no disconnected rectangles!)
        for (std::size_t i = 0; i < n; ++i) {
            const std::size_t iPrev = (i > 0) ? (i - 1) : i;
            const std::size_t iNext = (i + 1 < n) ? (i + 1) : i;
            const float dx = pts[iNext].sx - pts[iPrev].sx;
            const float dy = pts[iNext].sy - pts[iPrev].sy;
            const float len = std::max(1e-4f, std::hypot(dx, dy));
            pts[i].nx = -dy / len;
            pts[i].ny = dx / len;
        }

        // Emit soft feathered alluvial bank strip (4 vertices per point: outerL -> innerL -> innerR -> outerR)
        const int bankBase = static_cast<int>(bankVerts.size());
        for (std::size_t i = 0; i < n; ++i) {
            const auto& p = pts[i];
            const float ba = 0.34f * baseAlpha * p.bankFade;
            const SDL_FColor outerCol{0.38f, 0.48f, 0.34f, 0.0f};
            const SDL_FColor innerCol{0.34f, 0.45f, 0.34f, ba};

            bankVerts.push_back({{p.sx + p.nx * p.halfBank,  p.sy + p.ny * p.halfBank},  outerCol, {0.0f, 0.0f}});
            bankVerts.push_back({{p.sx + p.nx * p.halfWater, p.sy + p.ny * p.halfWater}, innerCol, {0.0f, 0.0f}});
            bankVerts.push_back({{p.sx - p.nx * p.halfWater, p.sy - p.ny * p.halfWater}, innerCol, {0.0f, 0.0f}});
            bankVerts.push_back({{p.sx - p.nx * p.halfBank,  p.sy - p.ny * p.halfBank},  outerCol, {0.0f, 0.0f}});

            if (i + 1 < n && (p.seaFade > 0.01f || pts[i + 1].seaFade > 0.01f)) {
                const int r0 = bankBase + static_cast<int>(i) * 4;
                const int r1 = r0 + 4;
                // Left bank feather
                bankIdx.insert(bankIdx.end(), {r0 + 0, r0 + 1, r1 + 1, r0 + 0, r1 + 1, r1 + 0});
                // Right bank feather
                bankIdx.insert(bankIdx.end(), {r0 + 2, r0 + 3, r1 + 3, r0 + 2, r1 + 3, r1 + 2});
            }
        }

        // Emit smooth continuous water core strip (3 vertices per point: edgeL -> centerSheen -> edgeR)
        const int waterBase = static_cast<int>(waterVerts.size());
        for (std::size_t i = 0; i < n; ++i) {
            const auto& p = pts[i];
            const float wa = baseAlpha * p.seaFade;
            const SDL_FColor edgeCol{0.20f, 0.44f, 0.64f, wa * 0.94f};
            const SDL_FColor midCol{0.28f, 0.54f, 0.74f, wa};

            waterVerts.push_back({{p.sx + p.nx * p.halfWater, p.sy + p.ny * p.halfWater}, edgeCol, {0.0f, 0.0f}});
            waterVerts.push_back({{p.sx,                      p.sy},                      midCol,  {0.0f, 0.0f}});
            waterVerts.push_back({{p.sx - p.nx * p.halfWater, p.sy - p.ny * p.halfWater}, edgeCol, {0.0f, 0.0f}});

            if (i + 1 < n && (p.seaFade > 0.01f || pts[i + 1].seaFade > 0.01f)) {
                const int r0 = waterBase + static_cast<int>(i) * 3;
                const int r1 = r0 + 3;
                waterIdx.insert(waterIdx.end(), {r0 + 0, r0 + 1, r1 + 1, r0 + 0, r1 + 1, r1 + 0});
                waterIdx.insert(waterIdx.end(), {r0 + 1, r0 + 2, r1 + 2, r0 + 1, r1 + 2, r1 + 1});
            }
        }
    }

    if (!bankIdx.empty()) {
        SDL_RenderGeometry(renderer_, nullptr,
                           bankVerts.data(), static_cast<int>(bankVerts.size()),
                           bankIdx.data(), static_cast<int>(bankIdx.size()));
    }
    if (!waterIdx.empty()) {
        SDL_RenderGeometry(renderer_, nullptr,
                           waterVerts.data(), static_cast<int>(waterVerts.size()),
                           waterIdx.data(), static_cast<int>(waterIdx.size()));
    }
}

void MapRenderer::renderTradeRoutes(const Camera2D& camera) {
    const float zoom = static_cast<float>(camera.zoom());
    SDL_SetRenderDrawBlendMode(renderer_, SDL_BLENDMODE_BLEND);

    std::vector<SDL_Vertex> washVerts;
    std::vector<int> washIdx;

    for (const auto& route : map_.worldTradeRoutes()) {
        const std::size_t n = route.points.size();
        if (n < 2) continue;

        if (route.isMaritime) {
            // Delicate vintage nautical dashed sea lane (only drawn over open water)
            const float dashLenPx = std::clamp(6.0f + zoom * 2.5f, 6.0f, 14.0f);
            float accumPx = 0.0f;
            const SDL_FColor seaLaneCol{0.84f, 0.90f, 0.94f, 0.30f};
            for (std::size_t i = 0; i + 1 < n; ++i) {
                const auto& wp0 = route.points[i];
                const auto& wp1 = route.points[i + 1];
                const float elevMid = map_.elevationAtWorld(
                    (wp0.x + wp1.x) * 0.5, (wp0.y + wp1.y) * 0.5);
                if (elevMid >= -4.0f) continue;

                const Vec2 s0 = camera.worldToScreen(wp0.x, wp0.y);
                const Vec2 s1 = camera.worldToScreen(wp1.x, wp1.y);
                const float segPx = static_cast<float>(std::hypot(s1.x - s0.x, s1.y - s0.y));
                if (static_cast<int>(accumPx / dashLenPx) % 2 == 0) {
                    drawThickLine(renderer_,
                                  static_cast<float>(s0.x), static_cast<float>(s0.y),
                                  static_cast<float>(s1.x), static_cast<float>(s1.y),
                                  std::clamp(0.9f + zoom * 0.22f, 0.9f, 1.8f), seaLaneCol);
                }
                accumPx += segPx;
            }
        } else {
            // Painterly, feathered watercolor dirt/post road integrated into the terrain
            const float baseHalfW = std::clamp(1.1f + zoom * 0.72f, 1.2f, 4.2f);
            const float baseAlpha = std::clamp(0.24f + (zoom - 0.8f) * 0.09f, 0.22f, 0.42f);

            struct RoadPt {
                float sx = 0.0f;
                float sy = 0.0f;
                float nx = 0.0f;
                float ny = 0.0f;
                float halfInner = 0.5f;
                float halfOuter = 1.5f;
                float alpha = 0.0f;
                SDL_FColor col{};
                bool onLand = false;
            };

            std::vector<RoadPt> rpts(n);
            for (std::size_t i = 0; i < n; ++i) {
                const auto& wp = route.points[i];
                const Vec2 sp = camera.worldToScreen(wp.x, wp.y);
                rpts[i].sx = static_cast<float>(sp.x);
                rpts[i].sy = static_cast<float>(sp.y);

                const float elev = map_.elevationAtWorld(wp.x, wp.y);
                rpts[i].onLand = (elev >= 0.0f);

                // Fade smoothly as road enters city interiors so it doesn't cut across town squares
                float cityFade = 1.0f;
                for (const auto& fp : cityFootprints_) {
                    const float d = static_cast<float>(std::hypot(wp.x - fp.center.x, wp.y - fp.center.y));
                    if (d < fp.radius * 1.15f) {
                        const float t = std::clamp((d - fp.radius * 0.75f) / (fp.radius * 0.40f), 0.0f, 1.0f);
                        cityFade = std::min(cityFade, t);
                    }
                }

                // Organic hand-painted brush width & opacity variation along the road
                const float brushVar = 0.82f + 0.36f * smoothValueNoise(
                    static_cast<float>(wp.x) * 0.08f, static_cast<float>(wp.y) * 0.08f);
                rpts[i].halfOuter = baseHalfW * brushVar;
                rpts[i].halfInner = rpts[i].halfOuter * 0.38f;
                rpts[i].alpha = baseAlpha * cityFade * (0.85f + 0.15f * brushVar);

                // Biome-aware earthy watercolor tint (blends naturally into northern meadows, med hills & alpine passes)
                double lat = 48.0, lon = 8.0;
                EuropeProjection::worldToLatLon(wp.x, wp.y, lat, lon);
                const float medT = std::clamp((46.0f - static_cast<float>(lat)) / 4.0f, 0.0f, 1.0f);
                const float alpineT = std::clamp((elev - 800.0f) / 700.0f, 0.0f, 1.0f);

                float rr = 0.68f + 0.12f * medT + 0.05f * alpineT;
                float rg = 0.60f + 0.08f * medT + 0.07f * alpineT;
                float rb = 0.46f + 0.02f * medT + 0.14f * alpineT;
                rpts[i].col = {rr, rg, rb, rpts[i].alpha};
            }

            for (std::size_t i = 0; i < n; ++i) {
                const std::size_t iPrev = (i > 0) ? (i - 1) : i;
                const std::size_t iNext = (i + 1 < n) ? (i + 1) : i;
                const float dx = rpts[iNext].sx - rpts[iPrev].sx;
                const float dy = rpts[iNext].sy - rpts[iPrev].sy;
                const float len = std::max(1e-4f, std::hypot(dx, dy));
                rpts[i].nx = -dy / len;
                rpts[i].ny = dx / len;
            }

            // 1. Soft 4-vertex feathered watercolor track wash (zero hard CAD edges)
            const int base = static_cast<int>(washVerts.size());
            for (std::size_t i = 0; i < n; ++i) {
                const auto& p = rpts[i];
                const SDL_FColor outerCol{p.col.r * 0.82f, p.col.g * 0.80f, p.col.b * 0.78f, 0.0f};
                const SDL_FColor innerCol = p.col;

                washVerts.push_back({{p.sx + p.nx * p.halfOuter, p.sy + p.ny * p.halfOuter}, outerCol, {0.0f, 0.0f}});
                washVerts.push_back({{p.sx + p.nx * p.halfInner, p.sy + p.ny * p.halfInner}, innerCol, {0.0f, 0.0f}});
                washVerts.push_back({{p.sx - p.nx * p.halfInner, p.sy - p.ny * p.halfInner}, innerCol, {0.0f, 0.0f}});
                washVerts.push_back({{p.sx - p.nx * p.halfOuter, p.sy - p.ny * p.halfOuter}, outerCol, {0.0f, 0.0f}});

                if (i + 1 < n && p.onLand && rpts[i + 1].onLand &&
                    (p.alpha > 0.01f || rpts[i + 1].alpha > 0.01f)) {
                    const int r0 = base + static_cast<int>(i) * 4;
                    const int r1 = r0 + 4;
                    washIdx.insert(washIdx.end(), {r0 + 0, r0 + 1, r1 + 1, r0 + 0, r1 + 1, r1 + 0});
                    washIdx.insert(washIdx.end(), {r0 + 1, r0 + 2, r1 + 2, r0 + 1, r1 + 2, r1 + 1});
                    washIdx.insert(washIdx.end(), {r0 + 2, r0 + 3, r1 + 3, r0 + 2, r1 + 3, r1 + 2});
                }
            }

            // 2. Delicate vintage fine-ink cartographic dashes along the winding path when zoomed in
            if (zoom >= 1.15f) {
                const float inkFade = std::clamp((zoom - 1.15f) / 1.2f, 0.0f, 1.0f);
                const float dashCyclePx = std::clamp(7.0f + zoom * 2.2f, 7.0f, 14.0f);
                float accumPx = 0.0f;
                for (std::size_t i = 0; i + 1 < n; ++i) {
                    const auto& p0 = rpts[i];
                    const auto& p1 = rpts[i + 1];
                    const float segPx = std::hypot(p1.sx - p0.sx, p1.sy - p0.sy);
                    if (p0.onLand && p1.onLand && p0.alpha > 0.04f &&
                        std::fmod(accumPx, dashCyclePx) < dashCyclePx * 0.42f) {
                        const float a = std::min(p0.alpha, p1.alpha) * 0.72f * inkFade;
                        SDL_SetRenderDrawColor(renderer_, 76, 58, 40,
                                               static_cast<std::uint8_t>(std::clamp(a * 255.0f, 0.0f, 255.0f)));
                        SDL_RenderLine(renderer_, p0.sx, p0.sy, p1.sx, p1.sy);
                    }
                    accumPx += segPx;
                }
            }
        }
    }

    if (!washIdx.empty()) {
        SDL_RenderGeometry(renderer_, nullptr,
                           washVerts.data(), static_cast<int>(washVerts.size()),
                           washIdx.data(), static_cast<int>(washIdx.size()));
    }
}

void MapRenderer::renderGraticule(const Camera2D& camera) {
    const double zoom = camera.zoom();
    const double stepDeg = (zoom >= 2.2) ? 1.0 : ((zoom >= 1.1) ? 2.0 : 5.0);

    SDL_SetRenderDrawBlendMode(renderer_, SDL_BLENDMODE_BLEND);
    SDL_SetRenderDrawColor(renderer_, 220, 230, 240, (zoom >= 2.2) ? 24 : 18);

    const Vec2 topLeft = camera.screenToWorld(0.0, 0.0);
    const Vec2 botRight = camera.screenToWorld(camera.viewportWidth(), camera.viewportHeight());

    double latMax = 0.0, lonMin = 0.0, latMin = 0.0, lonMax = 0.0;
    EuropeProjection::worldToLatLon(topLeft.x, topLeft.y, latMax, lonMin);
    EuropeProjection::worldToLatLon(botRight.x, botRight.y, latMin, lonMax);

    const double lonStart = std::floor(std::max(EuropeProjection::kMinLon, lonMin) / stepDeg) * stepDeg;
    const double lonEnd = std::min(EuropeProjection::kMaxLon, lonMax);
    for (double lon = lonStart; lon <= lonEnd; lon += stepDeg) {
        double wx0 = 0.0, wy0 = 0.0, wx1 = 0.0, wy1 = 0.0;
        EuropeProjection::latLonToWorld(EuropeProjection::kMaxLat, lon, wx0, wy0);
        EuropeProjection::latLonToWorld(EuropeProjection::kMinLat, lon, wx1, wy1);
        const Vec2 s0 = camera.worldToScreen(wx0, wy0);
        const Vec2 s1 = camera.worldToScreen(wx1, wy1);
        SDL_RenderLine(renderer_, static_cast<float>(s0.x), 0.0f,
                       static_cast<float>(s1.x), static_cast<float>(camera.viewportHeight()));
    }

    const double latStart = std::floor(std::max(EuropeProjection::kMinLat, latMin) / stepDeg) * stepDeg;
    const double latEnd = std::min(EuropeProjection::kMaxLat, latMax);
    for (double lat = latStart; lat <= latEnd; lat += stepDeg) {
        double wx0 = 0.0, wy0 = 0.0, wx1 = 0.0, wy1 = 0.0;
        EuropeProjection::latLonToWorld(lat, EuropeProjection::kMinLon, wx0, wy0);
        EuropeProjection::latLonToWorld(lat, EuropeProjection::kMaxLon, wx1, wy1);
        const Vec2 s0 = camera.worldToScreen(wx0, wy0);
        const Vec2 s1 = camera.worldToScreen(wx1, wy1);
        SDL_RenderLine(renderer_, 0.0f, static_cast<float>(s0.y),
                       static_cast<float>(camera.viewportWidth()), static_cast<float>(s1.y));
    }
}

void MapRenderer::renderCityFootprints(const Camera2D& camera, int selectedCityIndex, int hoveredCityIndex) {
    const double zoom = camera.zoom();
    if (zoom < 0.65) return;

    SDL_SetRenderDrawBlendMode(renderer_, SDL_BLENDMODE_BLEND);
    const auto& cities = map_.cities();

    for (std::size_t i = 0; i < cityFootprints_.size(); ++i) {
        const auto& fp = cityFootprints_[i];
        const Vec2 centerScreen = camera.worldToScreen(fp.center.x, fp.center.y);
        const float screenRadius = fp.radius * static_cast<float>(zoom);

        if (centerScreen.x + screenRadius * 2.0f < 0.0 ||
            centerScreen.y + screenRadius * 2.0f < 0.0 ||
            centerScreen.x - screenRadius * 2.0f > camera.viewportWidth() ||
            centerScreen.y - screenRadius * 2.0f > camera.viewportHeight()) {
            continue;
        }

        const bool isSelected = static_cast<int>(i) == selectedCityIndex;
        const bool isHovered = static_cast<int>(i) == hoveredCityIndex;
        const bool isMedCity = (i < cities.size() && cities[i].lat < 45.2);

        float cityTexBlend = 0.0f;
        if (detailMode_ == DetailMode::Textured && texCityHistoric_) {
            cityTexBlend = 1.0f;
        } else if (detailMode_ == DetailMode::AutoZoomLOD && texCityHistoric_) {
            // Crisp, tight LOD transition instead of a long ghost-fade
            cityTexBlend = static_cast<float>(std::clamp((zoom - 1.35) / 0.50, 0.0, 1.0));
        }

        // 1. Solid urban ground undercoat (100% opaque when textured so rocks/fields never bleed through)
        if (fp.boundary.size() >= 3) {
            const int n = static_cast<int>(fp.boundary.size());
            std::vector<SDL_Vertex> verts;
            verts.reserve(static_cast<std::size_t>(n + 1));

            const float baseAlpha = (cityTexBlend > 0.02f)
                ? 1.0f
                : (isSelected ? 0.44f : 0.32f);
            const SDL_FColor centerCol = isMedCity
                ? SDL_FColor{0.84f, 0.75f, 0.59f, baseAlpha}
                : SDL_FColor{0.76f, 0.68f, 0.56f, baseAlpha};
            const SDL_FColor edgeCol = isMedCity
                ? SDL_FColor{0.72f, 0.64f, 0.49f, baseAlpha}
                : SDL_FColor{0.62f, 0.57f, 0.46f, baseAlpha};

            verts.push_back({
                {static_cast<float>(centerScreen.x), static_cast<float>(centerScreen.y)},
                centerCol, {0.0f, 0.0f}
            });
            for (const auto& pt : fp.boundary) {
                const Vec2 sp = camera.worldToScreen(pt.x, pt.y);
                verts.push_back({
                    {static_cast<float>(sp.x), static_cast<float>(sp.y)},
                    edgeCol, {0.0f, 0.0f}
                });
            }

            std::vector<int> indices;
            indices.reserve(static_cast<std::size_t>(n * 3));
            for (int v = 0; v < n; ++v) {
                indices.push_back(0);
                indices.push_back(1 + v);
                indices.push_back(1 + ((v + 1) % n));
            }
            SDL_RenderGeometry(renderer_, nullptr,
                               verts.data(), static_cast<int>(verts.size()),
                               indices.data(), static_cast<int>(indices.size()));

            // 1b. Opaque concentric city districts (NO semi-transparent ghost-fading of buildings!)
            if (cityTexBlend > 0.02f) {
                // Per-city UV rotation so neighboring cities look distinct
                const float rotAngle = static_cast<float>((i * 2654435761u) % 360u) * (3.14159265f / 180.0f);
                const float cosR = std::cos(rotAngle);
                const float sinR = std::sin(rotAngle);
                const float uvSpan = fp.radius * 2.15f;

                auto makeCityUV = [&](double wx, double wy, float scale) -> SDL_FPoint {
                    const float dx = static_cast<float>(wx - fp.center.x) / (uvSpan * scale);
                    const float dy = static_cast<float>(wy - fp.center.y) / (uvSpan * scale);
                    const float rx = dx * cosR - dy * sinR;
                    const float ry = dx * sinR + dy * cosR;
                    return {std::clamp(0.5f + rx, 0.01f, 0.99f),
                            std::clamp(0.5f + ry, 0.01f, 0.99f)};
                };

                auto drawOpaqueCityPolygon = [&](SDL_Texture* tex, float radiusFrac,
                                                 bool wobble, float uvScale, float alpha) {
                    if (!tex || alpha <= 0.01f) return;
                    std::vector<SDL_Vertex> cVerts;
                    cVerts.reserve(static_cast<std::size_t>(n + 1));
                    cVerts.push_back({
                        {static_cast<float>(centerScreen.x), static_cast<float>(centerScreen.y)},
                        {1.0f, 1.0f, 1.0f, alpha}, {0.5f, 0.5f}
                    });
                    for (int v = 0; v < n; ++v) {
                        const auto& bp = fp.boundary[static_cast<std::size_t>(v)];
                        float f = radiusFrac;
                        if (wobble) {
                            const float ang = (2.0f * 3.14159265f * v) / static_cast<float>(n);
                            f *= 1.0f + 0.08f * std::sin(3.0f * ang + static_cast<float>(i)) +
                                        0.05f * std::cos(5.0f * ang - static_cast<float>(i));
                        }
                        const double px = fp.center.x + (bp.x - fp.center.x) * f;
                        const double py = fp.center.y + (bp.y - fp.center.y) * f;
                        const Vec2 sp = camera.worldToScreen(px, py);
                        cVerts.push_back({
                            {static_cast<float>(sp.x), static_cast<float>(sp.y)},
                            {1.0f, 1.0f, 1.0f, alpha}, makeCityUV(px, py, uvScale)
                        });
                    }
                    std::vector<int> cIdx;
                    cIdx.reserve(static_cast<std::size_t>(n * 3));
                    for (int v = 0; v < n; ++v) {
                        cIdx.push_back(0);
                        cIdx.push_back(1 + v);
                        cIdx.push_back(1 + ((v + 1) % n));
                    }
                    SDL_SetTextureAlphaModFloat(tex, 1.0f);
                    SDL_RenderGeometry(renderer_, tex,
                                       cVerts.data(), static_cast<int>(cVerts.size()),
                                       cIdx.data(), static_cast<int>(cIdx.size()));
                };

                // Outer suburban/garden ring: fully opaque up to the organic city perimeter
                drawOpaqueCityPolygon(texCityOuter_, 0.98f, false, 1.0f, cityTexBlend);

                // Historic old town core: fully opaque inside a distinct organic inner district
                SDL_Texture* historicTex = (isMedCity && texCityHistoricMed_)
                    ? texCityHistoricMed_ : texCityHistoric_;
                drawOpaqueCityPolygon(historicTex, 0.56f, true, 0.72f, cityTexBlend);

                // Subtle historic ring-road / old city boulevard separating historic core from outer suburbs
                const float ringWidth = std::clamp(static_cast<float>(zoom) * 0.55f, 1.2f, 3.0f);
                const SDL_FColor boulevardCol = isMedCity
                    ? SDL_FColor{0.84f, 0.78f, 0.65f, 0.85f * cityTexBlend}
                    : SDL_FColor{0.76f, 0.73f, 0.66f, 0.82f * cityTexBlend};
                for (int v = 0; v < n; ++v) {
                    const int vNext = (v + 1) % n;
                    auto corePt = [&](int idx) -> Vec2 {
                        const auto& bp = fp.boundary[static_cast<std::size_t>(idx)];
                        const float ang = (2.0f * 3.14159265f * idx) / static_cast<float>(n);
                        const float f = 0.56f * (1.0f + 0.08f * std::sin(3.0f * ang + static_cast<float>(i)) +
                                                        0.05f * std::cos(5.0f * ang - static_cast<float>(i)));
                        return camera.worldToScreen(fp.center.x + (bp.x - fp.center.x) * f,
                                                    fp.center.y + (bp.y - fp.center.y) * f);
                    };
                    const Vec2 p0 = corePt(v);
                    const Vec2 p1 = corePt(vNext);
                    drawThickLine(renderer_,
                                  static_cast<float>(p0.x), static_cast<float>(p0.y),
                                  static_cast<float>(p1.x), static_cast<float>(p1.y),
                                  ringWidth, boulevardCol);
                }
            }

            // 1c. Subtle organic cartographic perimeter rim (replaces unnatural green circles)
            if (isSelected || isHovered) {
                SDL_SetRenderDrawColor(renderer_, 255, 224, 110, 210);
                for (int v = 0; v < n; ++v) {
                    const auto& a = verts[static_cast<std::size_t>(1 + v)].position;
                    const auto& b = verts[static_cast<std::size_t>(1 + ((v + 1) % n))].position;
                    SDL_RenderLine(renderer_, a.x, a.y, b.x, b.y);
                }
            } else {
                // Soft warm earth/stone wall hairline that frames the town cleanly without geometric dots
                const float rimWidth = std::clamp(static_cast<float>(zoom) * 0.45f, 1.0f, 2.2f);
                const SDL_FColor rimCol = isMedCity
                    ? SDL_FColor{0.58f, 0.48f, 0.36f, 0.52f}
                    : SDL_FColor{0.42f, 0.40f, 0.32f, 0.48f};
                for (int v = 0; v < n; ++v) {
                    const auto& a = verts[static_cast<std::size_t>(1 + v)].position;
                    const auto& b = verts[static_cast<std::size_t>(1 + ((v + 1) % n))].position;
                    drawThickLine(renderer_, a.x, a.y, b.x, b.y, rimWidth, rimCol);
                }
            }
        }

        // 2. Station catchment / buildable zone dashed ring when selected or zoomed in
        if (isSelected || (zoom >= 2.5 && isHovered)) {
            SDL_SetRenderDrawColor(renderer_, 255, 232, 130, 145);
            drawDashedCircle(renderer_,
                             static_cast<float>(centerScreen.x),
                             static_cast<float>(centerScreen.y),
                             screenRadius * 1.35f, 44);
        }

        // 3. Synthesized arterial & ring streets at medium-high zoom
        if (zoom >= 1.5) {
            const std::uint8_t streetAlpha = static_cast<std::uint8_t>(
                std::clamp((zoom - 1.5) / 1.5, 0.0, 1.0) * 160.0);
            SDL_SetRenderDrawColor(renderer_, 226, 216, 196, streetAlpha);
            for (const auto& seg : fp.streets) {
                const Vec2 s0 = camera.worldToScreen(seg.first.x, seg.first.y);
                const Vec2 s1 = camera.worldToScreen(seg.second.x, seg.second.y);
                SDL_RenderLine(renderer_,
                               static_cast<float>(s0.x), static_cast<float>(s0.y),
                               static_cast<float>(s1.x), static_cast<float>(s1.y));
            }
        }

        // 4. Synthesized procedural building blocks (fading out as district textures fade in)
        if (zoom >= 2.2) {
            const float blockAlpha = static_cast<float>(
                std::clamp((zoom - 2.2) / 1.4, 0.0, 1.0) * 0.88);
            const float genBlend = 1.0f - cityTexBlend * 0.80f;
            if (genBlend > 0.05f) {
                for (const auto& blk : fp.blocks) {
                    const Vec2 sp = camera.worldToScreen(blk.x, blk.y);
                    const float sw = blk.w * static_cast<float>(zoom);
                    const float sh = blk.h * static_cast<float>(zoom);
                    if (sw < 1.2f && sh < 1.2f) continue;

                    SDL_FColor col{};
                    if (blk.kind == 0) {
                        col = {0.72f, 0.36f, 0.26f, blockAlpha * genBlend};
                    } else if (blk.kind == 1) {
                        col = {0.68f, 0.60f, 0.50f, blockAlpha * genBlend};
                    } else {
                        col = {0.38f, 0.41f, 0.45f, blockAlpha * genBlend};
                    }
                    drawRotatedFilledRect(renderer_,
                                          static_cast<float>(sp.x), static_cast<float>(sp.y),
                                          sw, sh, blk.angle, col);
                }
            }
        }
    }
}

void MapRenderer::renderTracksAndStations(const Camera2D& camera, const TrackGraph& tracks) {
    const double zoom = camera.zoom();
    const float baseWidth = std::clamp(static_cast<float>(zoom) * 0.85f, 1.4f, 2.8f);

    float trackTexBlend = 0.0f;
    if (detailMode_ == DetailMode::Textured && texTrackRail_) {
        trackTexBlend = 1.0f;
    } else if (detailMode_ == DetailMode::AutoZoomLOD && texTrackRail_) {
        trackTexBlend = static_cast<float>(std::clamp((zoom - 2.0) / 1.2, 0.0, 1.0));
    }
    const float vecBlend = 1.0f - trackTexBlend * 0.75f;

    // 1. Track edges
    for (const auto& edge : tracks.edges()) {
        if (edge.sampledPoints.size() < 2) continue;

        const SDL_FColor ballastCol = edge.hasTunnel
            ? SDL_FColor{0.18f, 0.16f, 0.14f, 0.85f * vecBlend}
            : (edge.hasBridge ? SDL_FColor{0.42f, 0.36f, 0.28f, 0.95f * vecBlend}
                              : SDL_FColor{0.20f, 0.18f, 0.16f, 0.90f * vecBlend});
        const SDL_FColor railCol = edge.hasTunnel
            ? SDL_FColor{0.78f, 0.62f, 0.35f, 0.85f * vecBlend}
            : SDL_FColor{0.84f, 0.86f, 0.90f, 0.96f * vecBlend};

        float uAccum = 0.0f;
        for (std::size_t i = 0; i + 1 < edge.sampledPoints.size(); ++i) {
            const auto& wp0 = edge.sampledPoints[i];
            const auto& wp1 = edge.sampledPoints[i + 1];
            const Vec2 s0 = camera.worldToScreen(wp0.x, wp0.y);
            const Vec2 s1 = camera.worldToScreen(wp1.x, wp1.y);
            const float segWorldLen = static_cast<float>(std::hypot(wp1.x - wp0.x, wp1.y - wp0.y));
            const float uNext = uAccum + segWorldLen * 0.55f;

            if ((s0.x < -50 && s1.x < -50) || (s0.y < -50 && s1.y < -50) ||
                (s0.x > camera.viewportWidth() + 50 && s1.x > camera.viewportWidth() + 50) ||
                (s0.y > camera.viewportHeight() + 50 && s1.y > camera.viewportHeight() + 50)) {
                uAccum = uNext;
                continue;
            }

            if (edge.hasTunnel && (i % 2 == 1)) {
                uAccum = uNext;
                continue;  // Dashed appearance for tunnels
            }

            if (vecBlend > 0.05f) {
                drawThickLine(renderer_,
                              static_cast<float>(s0.x), static_cast<float>(s0.y),
                              static_cast<float>(s1.x), static_cast<float>(s1.y),
                              baseWidth + 1.4f, ballastCol);
                drawThickLine(renderer_,
                              static_cast<float>(s0.x), static_cast<float>(s0.y),
                              static_cast<float>(s1.x), static_cast<float>(s1.y),
                              std::max(1.0f, baseWidth * 0.48f), railCol);
            }

            if (trackTexBlend > 0.05f && !edge.hasTunnel) {
                const float texWidth = std::max(3.5f, baseWidth * 2.1f);
                const SDL_FColor texCol = edge.hasBridge
                    ? SDL_FColor{0.96f, 0.88f, 0.74f, trackTexBlend}
                    : SDL_FColor{1.0f, 1.0f, 1.0f, trackTexBlend};
                drawTexturedSegment(renderer_, texTrackRail_,
                                    static_cast<float>(s0.x), static_cast<float>(s0.y),
                                    static_cast<float>(s1.x), static_cast<float>(s1.y),
                                    texWidth, uAccum, uNext, texCol);
            }

            uAccum = uNext;
        }

        // 2. Signals on this edge
        for (const auto& sig : edge.signals) {
            const Vec2 wp = TrackGraph::evalBezier(edge.p0, edge.c1, edge.c2, edge.p1, sig.t);
            const Vec2 tan = TrackGraph::evalBezierTangent(edge.p0, edge.c1, edge.c2, edge.p1, sig.t);
            const Vec2 sp = camera.worldToScreen(wp.x, wp.y);

            const double tLen = std::max(1e-6, std::hypot(tan.x, tan.y));
            const float dx = static_cast<float>(tan.x / tLen) * static_cast<float>(sig.direction);
            const float dy = static_cast<float>(tan.y / tLen) * static_cast<float>(sig.direction);
            // Offset signal slightly to the right of travel direction
            const float rx = -dy * 5.0f;
            const float ry = dx * 5.0f;

            const float sx = static_cast<float>(sp.x) + rx;
            const float sy = static_cast<float>(sp.y) + ry;
            const float rad = std::clamp(static_cast<float>(zoom) * 1.8f, 2.5f, 5.0f);

            SDL_SetRenderDrawColor(renderer_, 20, 22, 24, 255);
            drawFilledCircle(renderer_, sx, sy, rad + 1.2f);
            if (sig.type == SignalType::Chain) {
                SDL_SetRenderDrawColor(renderer_, 90, 185, 255, 255);
            } else if (sig.type == SignalType::OneWay) {
                SDL_SetRenderDrawColor(renderer_, 86, 226, 114, 255);
            } else {
                SDL_SetRenderDrawColor(renderer_, 245, 198, 68, 255);
            }
            drawFilledCircle(renderer_, sx, sy, rad);

            // Tiny direction tick
            SDL_SetRenderDrawColor(renderer_, 255, 255, 255, 220);
            SDL_RenderLine(renderer_, sx, sy, sx + dx * (rad + 4.0f), sy + dy * (rad + 4.0f));
        }
    }

    // 3. Junction / Switch nodes (visible when zoomed in)
    if (zoom >= 1.2) {
        for (const auto& node : tracks.nodes()) {
            if (node.edges.size() < 2 && node.stationId < 0) continue;
            const Vec2 sp = camera.worldToScreen(node.pos.x, node.pos.y);
            SDL_SetRenderDrawColor(renderer_, 235, 210, 120, 220);
            drawFilledCircle(renderer_, static_cast<float>(sp.x), static_cast<float>(sp.y), 3.0f);
        }
    }

    // 4. Stations (vector icon at overview -> 2.5D terminal sprite when zoomed in)
    float stationSpriteBlend = 0.0f;
    if (detailMode_ == DetailMode::Textured && texStation_) {
        stationSpriteBlend = 1.0f;
    } else if (detailMode_ == DetailMode::AutoZoomLOD && texStation_) {
        stationSpriteBlend = static_cast<float>(std::clamp((zoom - 1.8) / 1.4, 0.0, 1.0));
    }

    for (const auto& st : tracks.stations()) {
        const Vec2 sp = camera.worldToScreen(st.pos.x, st.pos.y);
        const float sx = static_cast<float>(sp.x);
        const float sy = static_cast<float>(sp.y);
        const float w = std::clamp(static_cast<float>(zoom) * 4.5f, 8.0f, 24.0f);
        const float h = std::clamp(static_cast<float>(zoom) * 2.6f, 5.0f, 14.0f);

        if (stationSpriteBlend < 0.95f) {
            const float vecA = 1.0f - stationSpriteBlend;
            drawRotatedFilledRect(renderer_, sx, sy, w + 2.5f, h + 2.5f, st.angle,
                                  SDL_FColor{0.10f, 0.11f, 0.14f, 0.95f * vecA});
            drawRotatedFilledRect(renderer_, sx, sy, w, h, st.angle,
                                  SDL_FColor{0.88f, 0.34f, 0.24f, 0.98f * vecA});
            drawRotatedFilledRect(renderer_, sx, sy, w * 0.72f, h * 0.38f, st.angle,
                                  SDL_FColor{0.96f, 0.88f, 0.72f, 0.95f * vecA});
        }

        if (stationSpriteBlend > 0.05f && texStation_) {
            const float sprSize = std::max(w * 1.4f, 18.0f);
            SDL_FRect dst{sx - sprSize * 0.5f, sy - sprSize * 0.5f, sprSize, sprSize};
            SDL_SetTextureAlphaModFloat(texStation_, stationSpriteBlend);
            SDL_RenderTextureRotated(renderer_, texStation_, nullptr, &dst,
                                     static_cast<double>(st.angle) * 180.0 / 3.14159265,
                                     nullptr, SDL_FLIP_NONE);
        }
    }
}

void MapRenderer::renderBuildPreview(const Camera2D& camera, const BuildState& buildState,
                                     float mouseX, float mouseY) {
    if (buildState.tool == ToolMode::BuildStation) {
        const float w = std::clamp(static_cast<float>(camera.zoom()) * 4.5f, 8.0f, 22.0f);
        const float h = std::clamp(static_cast<float>(camera.zoom()) * 2.6f, 5.0f, 12.0f);
        SDL_SetRenderDrawColor(renderer_, 100, 235, 140, 220);
        drawCircleOutline(renderer_, mouseX, mouseY, w * 0.85f, 24);
        drawRotatedFilledRect(renderer_, mouseX, mouseY, w, h, buildState.stationAngle,
                              SDL_FColor{0.35f, 0.90f, 0.50f, 0.72f});
        return;
    }

    if (buildState.tool == ToolMode::BuildTrack) {
        if (buildState.hoverNodeId != 0) {
            // Snap indicator
            SDL_SetRenderDrawColor(renderer_, 255, 225, 95, 240);
            drawCircleOutline(renderer_, mouseX, mouseY, 7.0f, 20);
        }

        auto drawPreviewCurve = [&](const TrackPreview& pv) {
            if (pv.sampledPoints.size() < 2) return;
            const SDL_FColor col = !pv.valid
                ? SDL_FColor{0.95f, 0.28f, 0.28f, 0.85f}
                : (pv.hasTunnel || pv.hasBridge
                    ? SDL_FColor{0.98f, 0.78f, 0.28f, 0.90f}
                    : SDL_FColor{0.32f, 0.92f, 0.52f, 0.90f});

            for (std::size_t i = 0; i + 1 < pv.sampledPoints.size(); ++i) {
                const Vec2 s0 = camera.worldToScreen(pv.sampledPoints[i].x, pv.sampledPoints[i].y);
                const Vec2 s1 = camera.worldToScreen(pv.sampledPoints[i + 1].x, pv.sampledPoints[i + 1].y);
                drawThickLine(renderer_,
                              static_cast<float>(s0.x), static_cast<float>(s0.y),
                              static_cast<float>(s1.x), static_cast<float>(s1.y),
                              2.2f, col);
            }
        };

        if (buildState.livePreview) {
            drawPreviewCurve(*buildState.livePreview);
        }
        if (buildState.livePreview2) {
            drawPreviewCurve(*buildState.livePreview2);
        }
        return;
    }

    if (buildState.tool == ToolMode::PlaceSignal && buildState.hoverEdgeId != 0) {
        SDL_SetRenderDrawColor(renderer_, 100, 235, 255, 240);
        drawCircleOutline(renderer_, mouseX, mouseY, 7.0f, 20);
    }
}

void MapRenderer::renderKeyboardCrosshair(float cursorX, float cursorY) {
    SDL_SetRenderDrawBlendMode(renderer_, SDL_BLENDMODE_BLEND);
    // Subtle dark outer halo for contrast on both sea and parchment terrain
    SDL_SetRenderDrawColor(renderer_, 20, 22, 24, 170);
    SDL_RenderLine(renderer_, cursorX - 11.0f, cursorY, cursorX - 4.0f, cursorY);
    SDL_RenderLine(renderer_, cursorX + 4.0f, cursorY, cursorX + 11.0f, cursorY);
    SDL_RenderLine(renderer_, cursorX, cursorY - 11.0f, cursorX, cursorY - 4.0f);
    SDL_RenderLine(renderer_, cursorX, cursorY + 4.0f, cursorX, cursorY + 11.0f);
    drawCircleOutline(renderer_, cursorX, cursorY, 7.5f, 24);

    // Warm ivory reticle
    SDL_SetRenderDrawColor(renderer_, 252, 238, 195, 235);
    SDL_RenderLine(renderer_, cursorX - 10.0f, cursorY, cursorX - 4.0f, cursorY);
    SDL_RenderLine(renderer_, cursorX + 4.0f, cursorY, cursorX + 10.0f, cursorY);
    SDL_RenderLine(renderer_, cursorX, cursorY - 10.0f, cursorX, cursorY - 4.0f);
    SDL_RenderLine(renderer_, cursorX, cursorY + 4.0f, cursorX, cursorY + 10.0f);
    drawCircleOutline(renderer_, cursorX, cursorY, 6.5f, 24);
}

void MapRenderer::render(const Camera2D& camera, const TrackGraph& tracks,
                         const BuildState& buildState,
                         int selectedCityIndex, int hoveredCityIndex,
                         float cursorX, float cursorY, bool showKeyboardCursor) {
    // 1. Render visible terrain chunks
    for (int cy = 0; cy < EuropeMap::kChunksY; ++cy) {
        for (int cx = 0; cx < EuropeMap::kChunksX; ++cx) {
            const double wx0 = static_cast<double>(cx * EuropeMap::kChunkSize);
            const double wy0 = static_cast<double>(cy * EuropeMap::kChunkSize);
            const double wx1 = wx0 + EuropeMap::kChunkSize;
            const double wy1 = wy0 + EuropeMap::kChunkSize;

            const Vec2 s0 = camera.worldToScreen(wx0, wy0);
            const Vec2 s1 = camera.worldToScreen(wx1, wy1);

            if (s1.x < 0.0 || s1.y < 0.0 ||
                s0.x > camera.viewportWidth() || s0.y > camera.viewportHeight()) {
                continue;
            }

            SDL_FRect dst{
                static_cast<float>(s0.x),
                static_cast<float>(s0.y),
                static_cast<float>(s1.x - s0.x),
                static_cast<float>(s1.y - s0.y)
            };
            SDL_Texture* tex = chunkTextures_[static_cast<std::size_t>(cy) * EuropeMap::kChunksX + cx];
            SDL_RenderTexture(renderer_, tex, nullptr, &dst);
        }
    }

    // 1b. Zoom-dependent tiled landscape texture blending (richer & earlier with 1024px regional textures)
    float terrainTexAlpha = 0.0f;
    if (detailMode_ == DetailMode::Textured) {
        terrainTexAlpha = 0.92f;
    } else if (detailMode_ == DetailMode::AutoZoomLOD) {
        terrainTexAlpha = static_cast<float>(std::clamp((camera.zoom() - 1.15) / 1.15, 0.0, 0.92));
    }
    renderTerrainTextures(camera, terrainTexAlpha);
    renderRivers(camera, terrainTexAlpha);

    // 1c. Historic non-railroad trade routes (overland post roads & maritime shipping lanes)
    renderTradeRoutes(camera);

    // 2. Cartographic lat/lon graticule
    renderGraticule(camera);

    // 3. Organic city footprints, streets & zoom-synthesized buildings
    renderCityFootprints(camera, selectedCityIndex, hoveredCityIndex);

    // 4. Built tracks, bridges, tunnels, signals & stations
    renderTracksAndStations(camera, tracks);

    // 5. Active build preview & optional keyboard navigation crosshair
    renderBuildPreview(camera, buildState, cursorX, cursorY);
    if (showKeyboardCursor) {
        renderKeyboardCrosshair(cursorX, cursorY);
    }

    // 6. Smaller, organic vintage-cartographic city markers & labels
    const auto& cities = map_.cities();
    const double zoom = camera.zoom();
    // Gently shrink the center pin when zoomed in close so it never hides historic rooftops
    const float zoomShrink = 1.0f - 0.35f * static_cast<float>(std::clamp((zoom - 1.5) / 2.0, 0.0, 1.0));

    for (std::size_t i = 0; i < cities.size(); ++i) {
        const auto& city = cities[i];
        double wx = 0.0, wy = 0.0;
        EuropeProjection::latLonToWorld(city.lat, city.lon, wx, wy);
        const Vec2 sp = camera.worldToScreen(wx, wy);

        if (sp.x < -80.0 || sp.y < -80.0 ||
            sp.x > camera.viewportWidth() + 80.0 ||
            sp.y > camera.viewportHeight() + 80.0) {
            continue;
        }

        const float sx = static_cast<float>(sp.x);
        const float sy = static_cast<float>(sp.y);
        const float baseRadius = (1.6f + static_cast<float>(city.tier) * 0.65f) * zoomShrink;
        const bool isSelected = static_cast<int>(i) == selectedCityIndex;
        const bool isHovered = static_cast<int>(i) == hoveredCityIndex;

        SDL_SetRenderDrawBlendMode(renderer_, SDL_BLENDMODE_BLEND);

        if (isSelected || isHovered) {
            SDL_SetRenderDrawColor(renderer_, 255, 224, 118, isSelected ? 225 : 175);
            drawCircleOutline(renderer_, sx, sy, baseRadius + 3.0f, 24);
        }

        // Soft warm-umber drop shadow
        SDL_SetRenderDrawColor(renderer_, 34, 26, 20, 130);
        drawFilledCircle(renderer_, sx + 0.8f, sy + 0.9f, baseRadius + 0.7f);

        if (city.tier == 3) {
            // Metropolis: delicate vintage cartographic rosette (diamond + warm antique gold center)
            drawDiamondFilled(renderer_, sx, sy, baseRadius + 1.5f,
                              SDL_FColor{0.20f, 0.14f, 0.10f, 0.92f});
            drawDiamondFilled(renderer_, sx, sy, baseRadius + 0.4f,
                              SDL_FColor{0.89f, 0.72f, 0.34f, 0.96f});
            SDL_SetRenderDrawColor(renderer_, 252, 244, 222, 240);
            drawFilledCircle(renderer_, sx, sy, std::max(1.1f, baseRadius * 0.38f));
        } else if (city.tier == 2) {
            // City: organic sepia-rimmed parchment ring with terracotta core
            SDL_SetRenderDrawColor(renderer_, 58, 42, 32, 225);
            drawFilledCircle(renderer_, sx, sy, baseRadius + 0.8f);
            SDL_SetRenderDrawColor(renderer_, 242, 232, 208, 240);
            drawFilledCircle(renderer_, sx, sy, baseRadius);
            SDL_SetRenderDrawColor(renderer_, 178, 92, 62, 235);
            drawFilledCircle(renderer_, sx, sy, std::max(1.0f, baseRadius * 0.48f));
        } else {
            // Town: tiny delicate organic ink-and-parchment dot
            SDL_SetRenderDrawColor(renderer_, 62, 48, 38, 210);
            drawFilledCircle(renderer_, sx, sy, baseRadius + 0.6f);
            SDL_SetRenderDrawColor(renderer_, 228, 222, 206, 235);
            drawFilledCircle(renderer_, sx, sy, baseRadius);
        }

        // Label visibility by zoom & tier
        const bool showLabel = (city.tier == 3) ||
                               (city.tier == 2 && zoom >= 0.72) ||
                               (zoom >= 1.35) || isSelected || isHovered;
        if (showLabel && i < cityLabels_.size() && cityLabels_[i].texture) {
            const auto& lbl = cityLabels_[i];
            const float lx = sx + baseRadius + 5.5f;
            const float ly = sy - lbl.height * 0.5f;

            SDL_SetRenderDrawBlendMode(renderer_, SDL_BLENDMODE_BLEND);
            SDL_SetRenderDrawColor(renderer_, 24, 22, 20, isSelected ? 200 : 155);
            SDL_FRect bg{lx - 3.0f, ly - 1.0f, lbl.width + 6.0f, lbl.height + 2.0f};
            SDL_RenderFillRect(renderer_, &bg);
            if (isSelected || isHovered) {
                SDL_SetRenderDrawColor(renderer_, 240, 208, 120, 180);
                SDL_RenderRect(renderer_, &bg);
            }

            SDL_FRect textDst{lx, ly, lbl.width, lbl.height};
            SDL_RenderTexture(renderer_, lbl.texture, nullptr, &textDst);
        }
    }
}

int MapRenderer::pickCityAtScreen(const Camera2D& camera, float screenX, float screenY) const {
    const auto& cities = map_.cities();
    const Vec2 worldPt = camera.screenToWorld(screenX, screenY);

    int bestIdx = -1;
    float bestDistSq = 20.0f * 20.0f;

    for (std::size_t i = 0; i < cities.size(); ++i) {
        // Also allow clicking anywhere inside the city's urban footprint when zoomed in
        if (i < cityFootprints_.size() && cityFootprints_[i].contains(worldPt.x, worldPt.y)) {
            return static_cast<int>(i);
        }

        double wx = 0.0, wy = 0.0;
        EuropeProjection::latLonToWorld(cities[i].lat, cities[i].lon, wx, wy);
        const Vec2 sp = camera.worldToScreen(wx, wy);
        const float dx = static_cast<float>(sp.x) - screenX;
        const float dy = static_cast<float>(sp.y) - screenY;
        const float d2 = dx * dx + dy * dy;
        if (d2 < bestDistSq) {
            bestDistSq = d2;
            bestIdx = static_cast<int>(i);
        }
    }
    return bestIdx;
}

}  // namespace raildev
