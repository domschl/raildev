#pragma once

#include <string>
#include <vector>

namespace raildev {

struct GeoPoint {
    double lat;
    double lon;
};

struct CityData {
    std::string name;
    std::string country;
    double lat;
    double lon;
    int population;  // Starting population
    int tier;        // 1=Town, 2=City, 3=Metropolis
};

struct MountainSpine {
    std::string name;
    std::vector<GeoPoint> points;
    double halfWidthDeg;
    double peakMeters;
};

struct RiverPath {
    std::string name;
    std::vector<GeoPoint> points;
    double widthWorld;
};

struct TradeRoute {
    std::string name;
    bool isMaritime = false;
    std::vector<GeoPoint> points;
};

struct RegionPreset {
    std::string name;
    double lat;
    double lon;
    double zoom;
};

struct EuropeProjection {
    static constexpr double kMinLon = -10.5;
    static constexpr double kMaxLon = 26.5;
    static constexpr double kMinLat = 35.5;
    static constexpr double kMaxLat = 59.5;
    static constexpr double kWorldWidth = 2048.0;
    static constexpr double kWorldHeight = 1536.0;

    static void latLonToWorld(double lat, double lon, double& outX, double& outY);
    static void worldToLatLon(double worldX, double worldY, double& outLat, double& outLon);
};

const std::vector<CityData>& getEuropeanCities();
const std::vector<std::vector<GeoPoint>>& getEuropeLandPolygons();
const std::vector<MountainSpine>& getEuropeMountainSpines();
const std::vector<RiverPath>& getEuropeRivers();
const std::vector<TradeRoute>& getEuropeTradeRoutes();
const std::vector<RegionPreset>& getEuropeRegionPresets();

}  // namespace raildev
