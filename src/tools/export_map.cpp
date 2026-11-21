#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

#include "map/CityFootprint.hpp"
#include "map/EuropeData.hpp"
#include "map/EuropeMap.hpp"

namespace {

void writeBinary(const std::filesystem::path& path, const void* data, std::size_t bytes) {
    std::ofstream out(path, std::ios::binary);
    if (!out) {
        std::cerr << "Failed to open " << path << " for writing\n";
        std::exit(1);
    }
    out.write(reinterpret_cast<const char*>(data), static_cast<std::streamsize>(bytes));
}

void rasterizeSegment(std::vector<std::uint8_t>& mask, int w, int h,
                      double x0, double y0, double x1, double y1,
                      float radius, std::uint8_t val) {
    const int minX = std::max(0, static_cast<int>(std::floor(std::min(x0, x1) - radius - 1.0)));
    const int maxX = std::min(w - 1, static_cast<int>(std::ceil(std::max(x0, x1) + radius + 1.0)));
    const int minY = std::max(0, static_cast<int>(std::floor(std::min(y0, y1) - radius - 1.0)));
    const int maxY = std::min(h - 1, static_cast<int>(std::ceil(std::max(y0, y1) + radius + 1.0)));

    const double dx = x1 - x0;
    const double dy = y1 - y0;
    const double lenSq = dx * dx + dy * dy;

    for (int y = minY; y <= maxY; ++y) {
        for (int x = minX; x <= maxX; ++x) {
            double t = 0.0;
            if (lenSq > 1e-8) {
                t = std::clamp(((x - x0) * dx + (y - y0) * dy) / lenSq, 0.0, 1.0);
            }
            const double px = x0 + t * dx;
            const double py = y0 + t * dy;
            const float d = static_cast<float>(std::hypot(x - px, y - py));
            if (d <= radius) {
                const float falloff = std::clamp(1.0f - d / radius, 0.0f, 1.0f);
                const std::uint8_t v = static_cast<std::uint8_t>(std::round(falloff * val));
                auto& dst = mask[static_cast<std::size_t>(y) * w + x];
                dst = std::max(dst, v);
            }
        }
    }
}

}  // namespace

int main(int argc, char* argv[]) {
    std::filesystem::path outDir = (argc > 1) ? argv[1] : "godot/data";
    std::filesystem::create_directories(outDir);

    std::cout << "Generating EuropeMap...\n";
    raildev::EuropeMap map;
    constexpr int W = raildev::EuropeMap::kWidth;
    constexpr int H = raildev::EuropeMap::kHeight;
    constexpr std::size_t N = static_cast<std::size_t>(W) * H;

    // 1. Float32 raw heightmap in meters (negative = ocean depth, positive = land elevation)
    std::vector<float> heightF32(N);
    for (int y = 0; y < H; ++y) {
        for (int x = 0; x < W; ++x) {
            heightF32[static_cast<std::size_t>(y) * W + x] = map.elevationAt(x, y);
        }
    }
    writeBinary(outDir / "europe_height.f32", heightF32.data(), heightF32.size() * sizeof(float));

    // Precompute trade road mask (overland + maritime)
    std::vector<std::uint8_t> roadMask(N, 0);
    std::vector<std::uint8_t> seaLaneMask(N, 0);
    for (const auto& route : map.worldTradeRoutes()) {
        for (std::size_t i = 0; i + 1 < route.points.size(); ++i) {
            const auto& p0 = route.points[i];
            const auto& p1 = route.points[i + 1];
            if (route.isMaritime) {
                if (i % 2 == 0) {
                    rasterizeSegment(seaLaneMask, W, H, p0.x, p0.y, p1.x, p1.y, 1.5f, 255);
                }
            } else {
                rasterizeSegment(roadMask, W, H, p0.x, p0.y, p1.x, p1.y, 2.2f, 255);
            }
        }
    }

    // Precompute city valley clearance mask so forest/rock don't cover cities
    const auto& cities = map.cities();
    std::vector<raildev::CityFootprint> footprints;
    footprints.reserve(cities.size());
    for (const auto& c : cities) {
        footprints.push_back(raildev::generateCityFootprint(c, map));
    }

    // 2. RGBA8 terrain control/splat texture:
    //    R = forest density [0..255]
    //    G = river proximity / water core [0..255]
    //    B = overland road [0..255]
    //    A = Mediterranean climate factor [0..255]
    std::vector<std::uint8_t> splatRGBA(N * 4, 0);
    for (int y = 0; y < H; ++y) {
        for (int x = 0; x < W; ++x) {
            const std::size_t idx = static_cast<std::size_t>(y) * W + x;
            const float elev = map.elevationAt(x, y);
            const float forest = map.forestDensityAt(x, y);
            const float riverDist = map.riverDistAt(x, y);

            double lat = 48.0, lon = 8.0;
            raildev::EuropeProjection::worldToLatLon(x, y, lat, lon);
            const float medT = std::clamp((46.0f - static_cast<float>(lat)) / 3.5f, 0.0f, 1.0f);

            // Soft river channel value (255 at center, tapering smoothly over 3.5 px)
            const float riverVal = (elev >= -6.0f)
                ? std::clamp(1.0f - riverDist / 3.4f, 0.0f, 1.0f)
                : 0.0f;

            // Suppress forest inside city footprints
            float cityMask = 0.0f;
            for (const auto& fp : footprints) {
                const float d = static_cast<float>(std::hypot(x - fp.center.x, y - fp.center.y));
                if (d < fp.radius * 1.25f) {
                    cityMask = std::max(cityMask,
                        std::clamp(1.0f - (d - fp.radius * 0.8f) / (fp.radius * 0.45f), 0.0f, 1.0f));
                }
            }

            const float cleanForest = std::clamp(forest * (1.0f - cityMask), 0.0f, 1.0f);
            const float cleanRoad = (elev >= 0.0f)
                ? (static_cast<float>(roadMask[idx]) / 255.0f) * (1.0f - cityMask * 0.85f)
                : (static_cast<float>(seaLaneMask[idx]) / 255.0f) * 0.5f;

            splatRGBA[idx * 4 + 0] = static_cast<std::uint8_t>(std::round(cleanForest * 255.0f));
            splatRGBA[idx * 4 + 1] = static_cast<std::uint8_t>(std::round(riverVal * 255.0f));
            splatRGBA[idx * 4 + 2] = static_cast<std::uint8_t>(std::round(std::clamp(cleanRoad, 0.0f, 1.0f) * 255.0f));
            splatRGBA[idx * 4 + 3] = static_cast<std::uint8_t>(std::round(medT * 255.0f));
        }
    }
    writeBinary(outDir / "europe_splat.rgba", splatRGBA.data(), splatRGBA.size());

    // 3. Cities & Region Presets JSON
    std::ofstream jf(outDir / "europe_meta.json");
    jf << "{\n";
    jf << "  \"width\": " << W << ",\n";
    jf << "  \"height\": " << H << ",\n";
    jf << "  \"cities\": [\n";
    for (std::size_t i = 0; i < cities.size(); ++i) {
        const auto& c = cities[i];
        const auto& fp = footprints[i];
        const float elev = std::max(0.0f, map.elevationAtWorld(fp.center.x, fp.center.y));
        jf << "    {\"name\": \"" << c.name << "\", \"country\": \"" << c.country
           << "\", \"lat\": " << c.lat << ", \"lon\": " << c.lon
           << ", \"population\": " << c.population << ", \"tier\": " << c.tier
           << ", \"x\": " << fp.center.x << ", \"y\": " << fp.center.y
           << ", \"elev\": " << elev << ", \"radius\": " << fp.radius
           << ", \"blocks\": [";
        for (std::size_t b = 0; b < fp.blocks.size(); ++b) {
            const auto& blk = fp.blocks[b];
            jf << "[" << blk.x << "," << blk.y << "," << blk.angle << "," << static_cast<int>(blk.kind) << "]";
            if (b + 1 < fp.blocks.size()) jf << ",";
        }
        jf << "]}";
        if (i + 1 < cities.size()) jf << ",";
        jf << "\n";
    }
    jf << "  ],\n";
    jf << "  \"regions\": [\n";
    const auto& regions = raildev::getEuropeRegionPresets();
    for (std::size_t i = 0; i < regions.size(); ++i) {
        const auto& r = regions[i];
        double wx = 0.0, wy = 0.0;
        raildev::EuropeProjection::latLonToWorld(r.lat, r.lon, wx, wy);
        jf << "    {\"name\": \"" << r.name << "\", \"x\": " << wx
           << ", \"y\": " << wy << ", \"zoom\": " << r.zoom << "}";
        if (i + 1 < regions.size()) jf << ",";
        jf << "\n";
    }
    jf << "  ]\n";
    jf << "}\n";

    std::cout << "Exported Europe 3D map data to " << outDir << "\n";
    return 0;
}
