#pragma once

#include <SDL3/SDL.h>
#include <SDL3_ttf/SDL_ttf.h>

#include <string>
#include <vector>

#include "core/Camera2D.hpp"
#include "map/CityFootprint.hpp"
#include "map/EuropeMap.hpp"
#include "track/TrackGraph.hpp"
#include "ui/BuildState.hpp"

namespace raildev {

enum class DetailMode {
    AutoZoomLOD,
    GenerativeOnly,
    Textured
};

class MapRenderer {
public:
    MapRenderer(SDL_Renderer* renderer, const EuropeMap& map);
    ~MapRenderer();

    MapRenderer(const MapRenderer&) = delete;
    MapRenderer& operator=(const MapRenderer&) = delete;

    void setOverlay(TerrainOverlay overlay);
    [[nodiscard]] TerrainOverlay overlay() const { return overlay_; }

    void setDetailMode(DetailMode mode) { detailMode_ = mode; }
    [[nodiscard]] DetailMode detailMode() const { return detailMode_; }

    void render(const Camera2D& camera, const TrackGraph& tracks,
                const BuildState& buildState,
                int selectedCityIndex, int hoveredCityIndex,
                float cursorX, float cursorY, bool showKeyboardCursor = false);

    /// Returns index of city near screen coordinates, or -1 if none.
    [[nodiscard]] int pickCityAtScreen(const Camera2D& camera, float screenX, float screenY) const;
    [[nodiscard]] const std::vector<CityFootprint>& cityFootprints() const { return cityFootprints_; }

private:
    struct CityLabel {
        SDL_Texture* texture = nullptr;
        float width = 0.0f;
        float height = 0.0f;
    };

    void rebuildChunkTextures();
    void loadFontAndLabels();
    void loadTextures();
    void renderTerrainTextures(const Camera2D& camera, float texAlpha);
    void renderRivers(const Camera2D& camera, float alpha);
    void renderTradeRoutes(const Camera2D& camera);
    void renderGraticule(const Camera2D& camera);
    void renderCityFootprints(const Camera2D& camera, int selectedCityIndex, int hoveredCityIndex);
    void renderTracksAndStations(const Camera2D& camera, const TrackGraph& tracks);
    void renderBuildPreview(const Camera2D& camera, const BuildState& buildState,
                            float cursorX, float cursorY);
    void renderKeyboardCrosshair(float cursorX, float cursorY);

    SDL_Renderer* renderer_;
    const EuropeMap& map_;
    TerrainOverlay overlay_ = TerrainOverlay::Relief;
    DetailMode detailMode_ = DetailMode::AutoZoomLOD;

    std::vector<SDL_Texture*> chunkTextures_;
    TTF_Font* font_ = nullptr;
    std::vector<CityLabel> cityLabels_;
    std::vector<CityFootprint> cityFootprints_;

    SDL_Texture* texGrass_ = nullptr;
    SDL_Texture* texGrassMed_ = nullptr;
    SDL_Texture* texForest_ = nullptr;
    SDL_Texture* texRock_ = nullptr;
    SDL_Texture* texWater_ = nullptr;
    SDL_Texture* texStation_ = nullptr;
    SDL_Texture* texCityHistoric_ = nullptr;
    SDL_Texture* texCityHistoricMed_ = nullptr;
    SDL_Texture* texCityOuter_ = nullptr;
    SDL_Texture* texTrackRail_ = nullptr;
};

}  // namespace raildev
