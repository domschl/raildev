#pragma once

#include <cstdint>
#include <utility>
#include <vector>

#include "core/Camera2D.hpp"
#include "map/EuropeData.hpp"
#include "map/EuropeMap.hpp"

namespace raildev {

struct CityBlock {
    float x;
    float y;
    float w;
    float h;
    float angle;
    std::uint8_t kind;  // 0 = historic core, 1 = residential, 2 = industrial/outer
};

struct CityFootprint {
    Vec2 center{};
    float radius = 6.0f;
    std::vector<Vec2> boundary;
    std::vector<std::pair<Vec2, Vec2>> streets;
    std::vector<CityBlock> blocks;

    [[nodiscard]] bool contains(double wx, double wy) const;
};

CityFootprint generateCityFootprint(const CityData& city, const EuropeMap& map);

}  // namespace raildev
