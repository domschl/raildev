#pragma once

#include <cstdint>
#include <vector>

#include "core/Camera2D.hpp"
#include "map/EuropeData.hpp"

namespace raildev {

struct WorldRiver {
    std::vector<Vec2> points;
    float baseWidth = 1.6f;
};

struct WorldTradeRoute {
    std::vector<Vec2> points;
    bool isMaritime = false;
};

enum class TerrainOverlay {
    Relief,
    Grade
};

class EuropeMap {
public:
    static constexpr int kWidth = 2048;
    static constexpr int kHeight = 1536;
    static constexpr int kChunkSize = 256;
    static constexpr int kChunksX = kWidth / kChunkSize;   // 8
    static constexpr int kChunksY = kHeight / kChunkSize;  // 6

    EuropeMap();

    [[nodiscard]] float elevationAt(int x, int y) const;
    [[nodiscard]] float elevationAtWorld(double worldX, double worldY) const;
    [[nodiscard]] bool isLand(int x, int y) const;
    [[nodiscard]] bool isRiver(int x, int y) const;
    [[nodiscard]] float riverDistAt(int x, int y) const;
    [[nodiscard]] float slopeAt(int x, int y) const;  // Rise/run magnitude
    [[nodiscard]] float forestDensityAt(int x, int y) const;  // [0..1]

    /// Renders a 256x256 chunk into RGBA8888 (row-major, 4 bytes per pixel).
    void renderChunkRGBA(int chunkX, int chunkY, TerrainOverlay overlay,
                         std::vector<std::uint8_t>& outRgba) const;

    [[nodiscard]] const std::vector<CityData>& cities() const { return cities_; }
    [[nodiscard]] const std::vector<WorldRiver>& worldRivers() const { return worldRivers_; }
    [[nodiscard]] const std::vector<WorldTradeRoute>& worldTradeRoutes() const { return worldTradeRoutes_; }

private:
    void generateTerrain();
    void rasterizeLandmask();
    void computeCoastDistance();
    void rasterizeRivers();
    void buildTradeRoutes();

    std::vector<float> elevation_;   // kWidth * kHeight, meters (< 0 = sea/depth)
    std::vector<float> coastDist_;   // signed distance to coast in px (>0 land, <0 sea)
    std::vector<float> riverDist_;   // distance to nearest river in px
    std::vector<std::uint8_t> landMask_;
    std::vector<std::uint8_t> riverMask_;
    std::vector<CityData> cities_;
    std::vector<WorldRiver> worldRivers_;
    std::vector<WorldTradeRoute> worldTradeRoutes_;
};

}  // namespace raildev
