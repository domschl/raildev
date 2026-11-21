#include "map/EuropeMap.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <queue>

namespace raildev {
namespace {

inline float hash2D(int x, int y) {
    std::uint32_t h = static_cast<std::uint32_t>(x) * 374761393u +
                      static_cast<std::uint32_t>(y) * 668265263u;
    h = (h ^ (h >> 13)) * 1274126177u;
    return static_cast<float>((h ^ (h >> 16)) & 0xFFFFu) / 65535.0f;
}

float valueNoise(float x, float y) {
    const int xi = static_cast<int>(std::floor(x));
    const int yi = static_cast<int>(std::floor(y));
    const float tx = x - static_cast<float>(xi);
    const float ty = y - static_cast<float>(yi);
    const float ux = tx * tx * (3.0f - 2.0f * tx);
    const float uy = ty * ty * (3.0f - 2.0f * ty);

    const float a = hash2D(xi, yi);
    const float b = hash2D(xi + 1, yi);
    const float c = hash2D(xi, yi + 1);
    const float d = hash2D(xi + 1, yi + 1);

    return (a + (b - a) * ux) + ((c + (d - c) * ux) - (a + (b - a) * ux)) * uy;
}

float fbm(float x, float y, int octaves) {
    float sum = 0.0f;
    float amp = 0.5f;
    float freq = 1.0f;
    for (int i = 0; i < octaves; ++i) {
        sum += amp * valueNoise(x * freq, y * freq);
        freq *= 2.05f;
        amp *= 0.5f;
    }
    return sum;
}

float ridgeFbm(float x, float y, int octaves) {
    float sum = 0.0f;
    float amp = 0.55f;
    float freq = 1.0f;
    for (int i = 0; i < octaves; ++i) {
        const float n = valueNoise(x * freq, y * freq);
        const float r = 1.0f - std::abs(2.0f * n - 1.0f);
        sum += amp * r * r;
        freq *= 2.1f;
        amp *= 0.5f;
    }
    return sum;
}

float distSqPointToSegment(float px, float py, float ax, float ay, float bx, float by) {
    const float abx = bx - ax;
    const float aby = by - ay;
    const float apx = px - ax;
    const float apy = py - ay;
    const float lenSq = abx * abx + aby * aby;
    if (lenSq <= 1e-8f) {
        return apx * apx + apy * apy;
    }
    const float t = std::clamp((apx * abx + apy * aby) / lenSq, 0.0f, 1.0f);
    const float cx = ax + t * abx - px;
    const float cy = ay + t * aby - py;
    return cx * cx + cy * cy;
}

/// Chaikin corner-cutting subdivision for closed polygons.
std::vector<std::pair<float, float>> subdivideClosedPolygon(
    const std::vector<std::pair<float, float>>& poly, int iterations) {
    std::vector<std::pair<float, float>> cur = poly;
    for (int it = 0; it < iterations; ++it) {
        if (cur.size() < 3) break;
        std::vector<std::pair<float, float>> next;
        next.reserve(cur.size() * 2);
        const std::size_t n = cur.size();
        for (std::size_t i = 0; i < n; ++i) {
            const auto& p0 = cur[i];
            const auto& p1 = cur[(i + 1) % n];
            next.emplace_back(0.75f * p0.first + 0.25f * p1.first,
                              0.75f * p0.second + 0.25f * p1.second);
            next.emplace_back(0.25f * p0.first + 0.75f * p1.first,
                              0.25f * p0.second + 0.75f * p1.second);
        }
        cur = std::move(next);
    }
    return cur;
}

/// Catmull-Rom spline sampling for open river polylines.
std::vector<std::pair<float, float>> sampleCatmullRom(
    const std::vector<std::pair<float, float>>& pts, int samplesPerSeg) {
    if (pts.size() < 2) return pts;
    std::vector<std::pair<float, float>> out;
    out.reserve(pts.size() * static_cast<std::size_t>(samplesPerSeg));

    const int n = static_cast<int>(pts.size());
    for (int i = 0; i < n - 1; ++i) {
        const auto p0 = pts[static_cast<std::size_t>(std::max(0, i - 1))];
        const auto p1 = pts[static_cast<std::size_t>(i)];
        const auto p2 = pts[static_cast<std::size_t>(i + 1)];
        const auto p3 = pts[static_cast<std::size_t>(std::min(n - 1, i + 2))];

        for (int s = 0; s < samplesPerSeg; ++s) {
            const float t = static_cast<float>(s) / static_cast<float>(samplesPerSeg);
            const float t2 = t * t;
            const float t3 = t2 * t;

            const float x = 0.5f * ((2.0f * p1.first) +
                                    (-p0.first + p2.first) * t +
                                    (2.0f * p0.first - 5.0f * p1.first + 4.0f * p2.first - p3.first) * t2 +
                                    (-p0.first + 3.0f * p1.first - 3.0f * p2.first + p3.first) * t3);
            const float y = 0.5f * ((2.0f * p1.second) +
                                    (-p0.second + p2.second) * t +
                                    (2.0f * p0.second - 5.0f * p1.second + 4.0f * p2.second - p3.second) * t2 +
                                    (-p0.second + 3.0f * p1.second - 3.0f * p2.second + p3.second) * t3);
            out.emplace_back(x, y);
        }
    }
    out.push_back(pts.back());
    return out;
}

struct WorldSpine {
    std::vector<std::pair<float, float>> pts;
    float halfWidthPx;
    float peakMeters;
};

struct ColorRGB {
    float r, g, b;
};

ColorRGB lerpColor(ColorRGB a, ColorRGB b, float t) {
    t = std::clamp(t, 0.0f, 1.0f);
    return {a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t};
}

ColorRGB elevationColor(float elev) {
    // Hypsometric cartographic palette
    constexpr ColorRGB kLowland{126, 174, 110};   // 0m
    constexpr ColorRGB kPlains{164, 194, 122};    // 250m
    constexpr ColorRGB kUpland{202, 190, 130};    // 650m
    constexpr ColorRGB kFoothill{182, 146, 100};  // 1200m
    constexpr ColorRGB kAlpine{142, 120, 108};    // 2000m
    constexpr ColorRGB kPeak{228, 230, 234};      // 2900m+

    if (elev < 250.0f) {
        return lerpColor(kLowland, kPlains, elev / 250.0f);
    }
    if (elev < 650.0f) {
        return lerpColor(kPlains, kUpland, (elev - 250.0f) / 400.0f);
    }
    if (elev < 1200.0f) {
        return lerpColor(kUpland, kFoothill, (elev - 650.0f) / 550.0f);
    }
    if (elev < 2000.0f) {
        return lerpColor(kFoothill, kAlpine, (elev - 1200.0f) / 800.0f);
    }
    return lerpColor(kAlpine, kPeak, (elev - 2000.0f) / 900.0f);
}

ColorRGB oceanDepthColor(float depthMeters) {
    // depthMeters is positive depth below sea level (0m .. 3500m)
    constexpr ColorRGB kShore{88, 152, 178};     // 0m (shallow coastal shelf)
    constexpr ColorRGB kShelf{66, 126, 158};     // 150m
    constexpr ColorRGB kSlope{48, 98, 136};      // 600m
    constexpr ColorRGB kAbyss{32, 68, 104};      // 1800m+

    if (depthMeters < 150.0f) {
        return lerpColor(kShore, kShelf, depthMeters / 150.0f);
    }
    if (depthMeters < 600.0f) {
        return lerpColor(kShelf, kSlope, (depthMeters - 150.0f) / 450.0f);
    }
    return lerpColor(kSlope, kAbyss, (depthMeters - 600.0f) / 1400.0f);
}

}  // namespace

EuropeMap::EuropeMap()
    : elevation_(static_cast<std::size_t>(kWidth) * kHeight, -120.0f),
      coastDist_(static_cast<std::size_t>(kWidth) * kHeight, 0.0f),
      riverDist_(static_cast<std::size_t>(kWidth) * kHeight, 100.0f),
      landMask_(static_cast<std::size_t>(kWidth) * kHeight, 0),
      riverMask_(static_cast<std::size_t>(kWidth) * kHeight, 0),
      cities_(getEuropeanCities()) {
    rasterizeLandmask();
    computeCoastDistance();
    rasterizeRivers();
    generateTerrain();
    buildTradeRoutes();
}

void EuropeMap::rasterizeLandmask() {
    const auto& polygons = getEuropeLandPolygons();

    for (const auto& poly : polygons) {
        if (poly.size() < 3) continue;
        std::vector<std::pair<float, float>> basePts;
        basePts.reserve(poly.size());
        for (const auto& gp : poly) {
            double wx = 0.0, wy = 0.0;
            EuropeProjection::latLonToWorld(gp.lat, gp.lon, wx, wy);
            basePts.emplace_back(static_cast<float>(wx), static_cast<float>(wy));
        }

        // Smooth polygon corners with 3 Chaikin iterations
        const auto wpts = subdivideClosedPolygon(basePts, 3);
        float minY = static_cast<float>(kHeight);
        float maxY = 0.0f;
        for (const auto& p : wpts) {
            minY = std::min(minY, p.second);
            maxY = std::max(maxY, p.second);
        }

        const int yStart = std::max(0, static_cast<int>(std::floor(minY)));
        const int yEnd = std::min(kHeight - 1, static_cast<int>(std::ceil(maxY)));

        std::vector<float> nodes;
        for (int y = yStart; y <= yEnd; ++y) {
            const float fy = static_cast<float>(y) + 0.5f;
            nodes.clear();
            std::size_t j = wpts.size() - 1;
            for (std::size_t i = 0; i < wpts.size(); ++i) {
                const float yi = wpts[i].second;
                const float yj = wpts[j].second;
                if ((yi < fy && yj >= fy) || (yj < fy && yi >= fy)) {
                    const float xi = wpts[i].first;
                    const float xj = wpts[j].first;
                    nodes.push_back(xi + (fy - yi) / (yj - yi) * (xj - xi));
                }
                j = i;
            }
            std::sort(nodes.begin(), nodes.end());
            for (std::size_t k = 0; k + 1 < nodes.size(); k += 2) {
                const int xStart = std::max(0, static_cast<int>(std::ceil(nodes[k])));
                const int xEnd = std::min(kWidth - 1, static_cast<int>(std::floor(nodes[k + 1])));
                for (int x = xStart; x <= xEnd; ++x) {
                    landMask_[static_cast<std::size_t>(y) * kWidth + x] = 1;
                }
            }
        }
    }
}

void EuropeMap::computeCoastDistance() {
    // 2-pass Chamfer distance transform (both inward for land and outward for sea)
    constexpr float kInf = 1e6f;
    constexpr float kDiag = 1.41421356f;
    const std::size_t total = static_cast<std::size_t>(kWidth) * kHeight;

    std::vector<float> distLand(total, kInf);
    std::vector<float> distSea(total, kInf);

    for (std::size_t i = 0; i < total; ++i) {
        if (landMask_[i]) {
            distSea[i] = 0.0f;
        } else {
            distLand[i] = 0.0f;
        }
    }

    auto chamferPass = [&](std::vector<float>& d) {
        // Forward pass
        for (int y = 0; y < kHeight; ++y) {
            for (int x = 0; x < kWidth; ++x) {
                const std::size_t idx = static_cast<std::size_t>(y) * kWidth + x;
                float v = d[idx];
                if (x > 0) v = std::min(v, d[idx - 1] + 1.0f);
                if (y > 0) {
                    v = std::min(v, d[idx - kWidth] + 1.0f);
                    if (x > 0) v = std::min(v, d[idx - kWidth - 1] + kDiag);
                    if (x + 1 < kWidth) v = std::min(v, d[idx - kWidth + 1] + kDiag);
                }
                d[idx] = v;
            }
        }
        // Backward pass
        for (int y = kHeight - 1; y >= 0; --y) {
            for (int x = kWidth - 1; x >= 0; --x) {
                const std::size_t idx = static_cast<std::size_t>(y) * kWidth + x;
                float v = d[idx];
                if (x + 1 < kWidth) v = std::min(v, d[idx + 1] + 1.0f);
                if (y + 1 < kHeight) {
                    v = std::min(v, d[idx + kWidth] + 1.0f);
                    if (x > 0) v = std::min(v, d[idx + kWidth - 1] + kDiag);
                    if (x + 1 < kWidth) v = std::min(v, d[idx + kWidth + 1] + kDiag);
                }
                d[idx] = v;
            }
        }
    };

    chamferPass(distLand);
    chamferPass(distSea);

    // Perturb coast signed distance with multi-octave noise for organic bays/peninsulas
    for (int y = 0; y < kHeight; ++y) {
        for (int x = 0; x < kWidth; ++x) {
            const std::size_t idx = static_cast<std::size_t>(y) * kWidth + x;
            const float signedD = landMask_[idx] ? distLand[idx] : -distSea[idx];
            const float coastNoise = (fbm(x * 0.035f + 13.7f, y * 0.035f + 5.1f, 4) - 0.5f) * 11.0f;
            coastDist_[idx] = signedD + coastNoise;
        }
    }
}

void EuropeMap::rasterizeRivers() {
    for (const auto& river : getEuropeRivers()) {
        std::vector<std::pair<float, float>> basePts;
        basePts.reserve(river.points.size());
        for (const auto& gp : river.points) {
            double wx = 0.0, wy = 0.0;
            EuropeProjection::latLonToWorld(gp.lat, gp.lon, wx, wy);
            basePts.emplace_back(static_cast<float>(wx), static_cast<float>(wy));
        }

        auto pts = sampleCatmullRom(basePts, 10);
        // Add subtle organic river meanders
        const std::size_t nPts = pts.size();
        for (std::size_t i = 1; i + 1 < nPts; ++i) {
            const float dx = pts[i + 1].first - pts[i - 1].first;
            const float dy = pts[i + 1].second - pts[i - 1].second;
            const float len = std::max(1e-4f, std::hypot(dx, dy));
            const float nx = -dy / len;
            const float ny = dx / len;
            const float meander = (fbm(pts[i].first * 0.04f, pts[i].second * 0.04f, 3) - 0.5f) * 8.0f;
            pts[i].first += nx * meander;
            pts[i].second += ny * meander;
        }

        const float baseRad = static_cast<float>(river.widthWorld);
        WorldRiver wr;
        wr.baseWidth = baseRad;
        wr.points.reserve(pts.size());
        for (const auto& p : pts) {
            wr.points.push_back({static_cast<double>(p.first), static_cast<double>(p.second)});
        }
        worldRivers_.push_back(std::move(wr));

        for (std::size_t i = 0; i + 1 < pts.size(); ++i) {
            // Widen river gradually from source to mouth
            const float tRiver = static_cast<float>(i) / static_cast<float>(std::max<std::size_t>(1, pts.size() - 1));
            const float rad = baseRad * (0.55f + 0.70f * tRiver);
            const float valleyRad = rad + 6.0f;

            const float ax = pts[i].first;
            const float ay = pts[i].second;
            const float bx = pts[i + 1].first;
            const float by = pts[i + 1].second;
            const int x0 = std::max(0, static_cast<int>(std::floor(std::min(ax, bx) - valleyRad - 1)));
            const int x1 = std::min(kWidth - 1, static_cast<int>(std::ceil(std::max(ax, bx) + valleyRad + 1)));
            const int y0 = std::max(0, static_cast<int>(std::floor(std::min(ay, by) - valleyRad - 1)));
            const int y1 = std::min(kHeight - 1, static_cast<int>(std::ceil(std::max(ay, by) + valleyRad + 1)));

            for (int y = y0; y <= y1; ++y) {
                for (int x = x0; x <= x1; ++x) {
                    const std::size_t idx = static_cast<std::size_t>(y) * kWidth + x;
                    const float d = std::sqrt(distSqPointToSegment(
                        static_cast<float>(x), static_cast<float>(y), ax, ay, bx, by));
                    riverDist_[idx] = std::min(riverDist_[idx], d);
                    if (d <= rad && coastDist_[idx] >= -2.5f) {
                        riverMask_[idx] = 1;
                    }
                }
            }
        }
    }
}

void EuropeMap::buildTradeRoutes() {
    // Coarse terrain grid for fast, valley-hugging, elevation-aware overland road A*
    constexpr int kCell = 4;  // 4 world units per cell -> 512 x 384 grid
    constexpr int kGW = kWidth / kCell;
    constexpr int kGH = kHeight / kCell;
    constexpr int kTotal = kGW * kGH;

    std::vector<float> cellCost(static_cast<std::size_t>(kTotal), 1.0f);
    for (int gy = 0; gy < kGH; ++gy) {
        const int wy = gy * kCell + kCell / 2;
        for (int gx = 0; gx < kGW; ++gx) {
            const int wx = gx * kCell + kCell / 2;
            const std::size_t idx = static_cast<std::size_t>(gy) * kGW + gx;
            const float elev = elevationAt(wx, wy);
            if (elev < 0.0f) {
                cellCost[idx] = 5000.0f;  // Avoid sea strictly unless unavoidable
                continue;
            }
            const float slope = slopeAt(wx, wy);
            const float rDist = riverDistAt(wx, wy);

            // Height & grade awareness: roads bend around mountains, hug valleys & low passes
            const float elevExcess = std::max(0.0f, elev - 220.0f) / 520.0f;
            const float elevPen = elevExcess * elevExcess * 5.0f;
            const float slopePen = slope * 130.0f + slope * slope * 22000.0f;

            // Gentle bonus for following river valleys (without swimming down the middle of rivers)
            float riverMod = 0.0f;
            if (isRiver(wx, wy)) {
                riverMod = 7.5f;  // Ford/bridge crossing penalty so roads cross cleanly
            } else if (rDist > 2.5f && rDist < 14.0f) {
                riverMod = -0.18f;
            }

            // Low-frequency organic cost ripple so roads meander gracefully even across flat plains
            const float organicNoise = 0.32f * fbm(gx * 0.085f + 17.3f, gy * 0.085f + 41.9f, 2);

            cellCost[idx] = std::max(0.55f, 1.0f + elevPen + slopePen + riverMod + organicNoise);
        }
    }

    std::vector<float> gScore(static_cast<std::size_t>(kTotal), 0.0f);
    std::vector<int> cameFrom(static_cast<std::size_t>(kTotal), -1);
    std::vector<std::uint32_t> stamp(static_cast<std::size_t>(kTotal), 0);
    std::uint32_t curStamp = 0;

    struct PQNode {
        float f;
        int idx;
        bool operator>(const PQNode& o) const { return f > o.f; }
    };

    auto findTerrainPath = [&](std::pair<float, float> a, std::pair<float, float> b)
        -> std::vector<std::pair<float, float>> {
        const int sx = std::clamp(static_cast<int>(std::round(a.first)) / kCell, 0, kGW - 1);
        const int sy = std::clamp(static_cast<int>(std::round(a.second)) / kCell, 0, kGH - 1);
        const int ex = std::clamp(static_cast<int>(std::round(b.first)) / kCell, 0, kGW - 1);
        const int ey = std::clamp(static_cast<int>(std::round(b.second)) / kCell, 0, kGH - 1);
        const int startIdx = sy * kGW + sx;
        const int goalIdx = ey * kGW + ex;

        if (startIdx == goalIdx) {
            return {a, b};
        }

        ++curStamp;
        std::priority_queue<PQNode, std::vector<PQNode>, std::greater<PQNode>> open;
        stamp[static_cast<std::size_t>(startIdx)] = curStamp;
        gScore[static_cast<std::size_t>(startIdx)] = 0.0f;
        cameFrom[static_cast<std::size_t>(startIdx)] = -1;
        open.push({static_cast<float>(std::hypot(ex - sx, ey - sy)), startIdx});

        static constexpr int kDX[8] = {1, -1, 0, 0, 1, 1, -1, -1};
        static constexpr int kDY[8] = {0, 0, 1, -1, 1, -1, 1, -1};
        static constexpr float kStepLen[8] = {1.0f, 1.0f, 1.0f, 1.0f,
                                              1.41421356f, 1.41421356f, 1.41421356f, 1.41421356f};

        int expansions = 0;
        bool found = false;
        while (!open.empty() && expansions < 28000) {
            const PQNode top = open.top();
            open.pop();
            const int u = top.idx;
            if (u == goalIdx) {
                found = true;
                break;
            }
            const float curG = gScore[static_cast<std::size_t>(u)];
            const int ux = u % kGW;
            const int uy = u / kGW;
            if (top.f > curG + static_cast<float>(std::hypot(ex - ux, ey - uy)) * 0.6f + 1e-3f) {
                continue;
            }
            ++expansions;

            const float uElev = elevationAt(ux * kCell + kCell / 2, uy * kCell + kCell / 2);

            for (int d = 0; d < 8; ++d) {
                const int vx = ux + kDX[d];
                const int vy = uy + kDY[d];
                if (vx < 0 || vx >= kGW || vy < 0 || vy >= kGH) continue;
                const int v = vy * kGW + vx;

                const float vElev = elevationAt(vx * kCell + kCell / 2, vy * kCell + kCell / 2);
                // Additional directional climb penalty so roads follow contours rather than climbing head-on
                const float climb = std::abs(vElev - uElev) / 140.0f;
                const float stepC = kStepLen[d] * (cellCost[static_cast<std::size_t>(v)] + climb * climb * 2.2f);
                const float tentG = curG + stepC;

                if (stamp[static_cast<std::size_t>(v)] != curStamp ||
                    tentG < gScore[static_cast<std::size_t>(v)]) {
                    stamp[static_cast<std::size_t>(v)] = curStamp;
                    gScore[static_cast<std::size_t>(v)] = tentG;
                    cameFrom[static_cast<std::size_t>(v)] = u;
                    const float h = static_cast<float>(std::hypot(ex - vx, ey - vy)) * 0.6f;
                    open.push({tentG + h, v});
                }
            }
        }

        std::vector<std::pair<float, float>> out;
        if (!found) {
            out.push_back(a);
            out.push_back(b);
            return out;
        }

        std::vector<int> rev;
        for (int cur = goalIdx; cur != -1; cur = cameFrom[static_cast<std::size_t>(cur)]) {
            rev.push_back(cur);
            if (cur == startIdx) break;
        }
        std::reverse(rev.begin(), rev.end());

        out.reserve(rev.size());
        out.push_back(a);
        for (std::size_t i = 1; i + 1 < rev.size(); ++i) {
            const int gx = rev[i] % kGW;
            const int gy = rev[i] / kGW;
            out.emplace_back(static_cast<float>(gx * kCell + kCell / 2),
                             static_cast<float>(gy * kCell + kCell / 2));
        }
        out.push_back(b);
        return out;
    };

    for (const auto& route : getEuropeTradeRoutes()) {
        std::vector<std::pair<float, float>> basePts;
        basePts.reserve(route.points.size());
        for (const auto& gp : route.points) {
            double wx = 0.0, wy = 0.0;
            EuropeProjection::latLonToWorld(gp.lat, gp.lon, wx, wy);
            basePts.emplace_back(static_cast<float>(wx), static_cast<float>(wy));
        }

        std::vector<std::pair<float, float>> pts;
        if (route.isMaritime) {
            pts = sampleCatmullRom(basePts, 10);
        } else {
            // Build full terrain-aware A* path across all waypoints
            for (std::size_t s = 0; s + 1 < basePts.size(); ++s) {
                auto seg = findTerrainPath(basePts[s], basePts[s + 1]);
                if (s > 0 && !seg.empty()) {
                    seg.erase(seg.begin());
                }
                pts.insert(pts.end(), seg.begin(), seg.end());
            }

            // Multi-pass Laplacian smoothing (keeps endpoints fixed and stays on land)
            for (int pass = 0; pass < 5 && pts.size() >= 3; ++pass) {
                auto next = pts;
                for (std::size_t i = 1; i + 1 < pts.size(); ++i) {
                    const float nx = 0.25f * pts[i - 1].first + 0.50f * pts[i].first + 0.25f * pts[i + 1].first;
                    const float ny = 0.25f * pts[i - 1].second + 0.50f * pts[i].second + 0.25f * pts[i + 1].second;
                    if (isLand(static_cast<int>(std::round(nx)), static_cast<int>(std::round(ny)))) {
                        next[i] = {nx, ny};
                    }
                }
                pts = std::move(next);
            }

            // Keep every 2nd vertex + smooth spline to remove grid-staircase artifacts
            if (pts.size() > 6) {
                std::vector<std::pair<float, float>> thinned;
                thinned.reserve(pts.size() / 2 + 2);
                thinned.push_back(pts.front());
                for (std::size_t i = 2; i + 2 < pts.size(); i += 2) {
                    thinned.push_back(pts[i]);
                }
                thinned.push_back(pts.back());
                pts = sampleCatmullRom(thinned, 3);
            }
        }

        WorldTradeRoute wtr;
        wtr.isMaritime = route.isMaritime;
        wtr.points.reserve(pts.size());
        for (const auto& p : pts) {
            wtr.points.push_back({static_cast<double>(p.first), static_cast<double>(p.second)});
        }
        worldTradeRoutes_.push_back(std::move(wtr));
    }
}

void EuropeMap::generateTerrain() {
    const auto& rawSpines = getEuropeMountainSpines();
    std::vector<WorldSpine> spines;
    spines.reserve(rawSpines.size());
    const float pxPerDeg = static_cast<float>(kHeight) /
                           static_cast<float>(EuropeProjection::kMaxLat - EuropeProjection::kMinLat);

    for (const auto& sp : rawSpines) {
        WorldSpine ws;
        ws.halfWidthPx = static_cast<float>(sp.halfWidthDeg) * pxPerDeg;
        ws.peakMeters = static_cast<float>(sp.peakMeters);
        for (const auto& gp : sp.points) {
            double wx = 0.0, wy = 0.0;
            EuropeProjection::latLonToWorld(gp.lat, gp.lon, wx, wy);
            ws.pts.emplace_back(static_cast<float>(wx), static_cast<float>(wy));
        }
        spines.push_back(std::move(ws));
    }

    for (int y = 0; y < kHeight; ++y) {
        for (int x = 0; x < kWidth; ++x) {
            const std::size_t idx = static_cast<std::size_t>(y) * kWidth + x;
            const float cd = coastDist_[idx];
            const float fx = static_cast<float>(x);
            const float fy = static_cast<float>(y);

            if (cd < 0.0f) {
                // Ocean bathymetry: depth increases away from shore + subtle basin noise
                const float offDist = -cd;
                const float basinNoise = fbm(fx * 0.012f, fy * 0.012f, 3);
                // Continental shelf stays shallow (~0-180m) for first ~22 px, then drops
                float depth = 12.0f + offDist * 6.5f;
                if (offDist > 22.0f) {
                    depth += (offDist - 22.0f) * 14.0f;
                }
                depth *= (0.75f + 0.55f * basinNoise);
                elevation_[idx] = -std::clamp(depth, 5.0f, 3500.0f);
                continue;
            }

            // Land: multi-scale rolling plains & hills + fine micro-relief
            const float macroHills = fbm(fx * 0.008f, fy * 0.008f, 3);
            const float rollingHills = fbm(fx * 0.028f + 41.0f, fy * 0.028f + 19.0f, 3);
            const float microRelief = fbm(fx * 0.09f + 7.3f, fy * 0.09f + 2.9f, 2);
            const float detailNoise = ridgeFbm(fx * 0.025f, fy * 0.025f, 4);

            // Coastal plain ramp so land rises naturally from the sea
            const float coastalRamp = std::min(1.0f, cd / 18.0f);
            float elev = 8.0f + coastalRamp * (18.0f + macroHills * 175.0f +
                                               rollingHills * 65.0f + microRelief * 18.0f);

            // Mountain ranges
            float mtnBoost = 0.0f;
            for (const auto& sp : spines) {
                float minDistSq = 1e12f;
                for (std::size_t i = 0; i + 1 < sp.pts.size(); ++i) {
                    const float d2 = distSqPointToSegment(
                        fx, fy, sp.pts[i].first, sp.pts[i].second,
                        sp.pts[i + 1].first, sp.pts[i + 1].second);
                    minDistSq = std::min(minDistSq, d2);
                }
                const float invSigma2 = 1.0f / (sp.halfWidthPx * sp.halfWidthPx);
                if (minDistSq < sp.halfWidthPx * sp.halfWidthPx * 6.5f) {
                    const float falloff = std::exp(-minDistSq * invSigma2);
                    const float sculpted = falloff * (0.42f + 0.68f * detailNoise);
                    mtnBoost = std::max(mtnBoost, sculpted * sp.peakMeters);
                }
            }

            elev += mtnBoost;

            // Gentle alluvial valley carving near rivers
            const float rd = riverDist_[idx];
            if (rd < 7.0f) {
                const float carve = 1.0f - (rd / 7.0f);
                elev *= (1.0f - 0.35f * carve);
            }

            elevation_[idx] = elev;
        }
    }
}

float EuropeMap::elevationAt(int x, int y) const {
    x = std::clamp(x, 0, kWidth - 1);
    y = std::clamp(y, 0, kHeight - 1);
    return elevation_[static_cast<std::size_t>(y) * kWidth + x];
}

float EuropeMap::elevationAtWorld(double worldX, double worldY) const {
    return elevationAt(static_cast<int>(std::round(worldX)),
                       static_cast<int>(std::round(worldY)));
}

bool EuropeMap::isLand(int x, int y) const {
    return elevationAt(x, y) >= 0.0f;
}

bool EuropeMap::isRiver(int x, int y) const {
    x = std::clamp(x, 0, kWidth - 1);
    y = std::clamp(y, 0, kHeight - 1);
    return riverMask_[static_cast<std::size_t>(y) * kWidth + x] != 0;
}

float EuropeMap::riverDistAt(int x, int y) const {
    x = std::clamp(x, 0, kWidth - 1);
    y = std::clamp(y, 0, kHeight - 1);
    return riverDist_[static_cast<std::size_t>(y) * kWidth + x];
}

float EuropeMap::slopeAt(int x, int y) const {
    const float eL = elevationAt(x - 1, y);
    const float eR = elevationAt(x + 1, y);
    const float eU = elevationAt(x, y - 1);
    const float eD = elevationAt(x, y + 1);
    const float dx = (eR - eL) * 0.5f;
    const float dy = (eD - eU) * 0.5f;
    return std::sqrt(dx * dx + dy * dy) / 1500.0f;
}

float EuropeMap::forestDensityAt(int x, int y) const {
    const float elev = elevationAt(x, y);
    if (elev < 25.0f || elev > 1450.0f) return 0.0f;
    const float fx = static_cast<float>(x);
    const float fy = static_cast<float>(y);
    return fbm(fx * 0.022f + 19.2f, fy * 0.022f + 71.5f, 3);
}

void EuropeMap::renderChunkRGBA(int chunkX, int chunkY, TerrainOverlay overlay,
                                std::vector<std::uint8_t>& outRgba) const {
    outRgba.resize(static_cast<std::size_t>(kChunkSize) * kChunkSize * 4);
    const int baseX = chunkX * kChunkSize;
    const int baseY = chunkY * kChunkSize;

    // NW directional sunlight vector (normalized)
    constexpr float lx = -0.577f;
    constexpr float ly = -0.577f;
    constexpr float lz = 0.577f;

    for (int py = 0; py < kChunkSize; ++py) {
        const int wy = baseY + py;
        for (int px = 0; px < kChunkSize; ++px) {
            const int wx = baseX + px;
            const std::size_t idx = static_cast<std::size_t>(wy) * kWidth + wx;
            const std::size_t outIdx = (static_cast<std::size_t>(py) * kChunkSize + px) * 4;

            const float elev = elevation_[idx];
            if (elev < 0.0f) {
                const float depth = -elev;
                ColorRGB sea = oceanDepthColor(depth);

                // Subtle bathymetric contour lines at 150m, 400m, 900m, 1600m
                const float dR = -elevationAt(wx + 1, wy);
                const float dD = -elevationAt(wx, wy + 1);
                auto depthBand = [](float d) -> int {
                    if (d < 150.0f) return 0;
                    if (d < 400.0f) return 1;
                    if (d < 900.0f) return 2;
                    if (d < 1600.0f) return 3;
                    return 4;
                };
                if (dR > 0.0f && dD > 0.0f) {
                    const int b0 = depthBand(depth);
                    if (b0 != depthBand(dR) || b0 != depthBand(dD)) {
                        sea.r *= 0.90f;
                        sea.g *= 0.92f;
                        sea.b *= 0.95f;
                    }
                }

                // Crisp shoreline highlight
                if (coastDist_[idx] > -1.4f) {
                    sea = lerpColor(sea, {118, 176, 196}, 0.55f);
                }

                outRgba[outIdx + 0] = static_cast<std::uint8_t>(std::clamp(sea.r, 0.0f, 255.0f));
                outRgba[outIdx + 1] = static_cast<std::uint8_t>(std::clamp(sea.g, 0.0f, 255.0f));
                outRgba[outIdx + 2] = static_cast<std::uint8_t>(std::clamp(sea.b, 0.0f, 255.0f));
                outRgba[outIdx + 3] = 255;
                continue;
            }

            // Surface normal for 2.5D hillshading (stronger micro-relief in lowlands)
            const float eL = std::max(0.0f, elevationAt(wx - 1, wy));
            const float eR = std::max(0.0f, elevationAt(wx + 1, wy));
            const float eU = std::max(0.0f, elevationAt(wx, wy - 1));
            const float eD = std::max(0.0f, elevationAt(wx, wy + 1));

            const float reliefScale = (elev < 350.0f) ? 0.022f : 0.014f;
            const float dzdx = (eR - eL) * reliefScale;
            const float dzdy = (eD - eU) * reliefScale;
            const float invLen = 1.0f / std::sqrt(dzdx * dzdx + dzdy * dzdy + 1.0f);
            const float nx = -dzdx * invLen;
            const float ny = -dzdy * invLen;
            const float nz = invLen;
            const float shade = std::clamp(0.56f + 0.65f * (nx * lx + ny * ly + nz * lz), 0.35f, 1.30f);

            ColorRGB col{};
            if (overlay == TerrainOverlay::Relief) {
                col = elevationColor(elev);

                const float fx = static_cast<float>(wx);
                const float fy = static_cast<float>(wy);

                // Latitude climate tint (warmer Mediterranean south vs cooler lush north)
                const float southFactor = std::clamp(
                    (fy - kHeight * 0.55f) / (kHeight * 0.45f), 0.0f, 1.0f);
                if (elev < 750.0f && southFactor > 0.0f) {
                    col = lerpColor(col, {196, 186, 124}, southFactor * 0.38f);
                }

                // Generative farmland / meadow patchwork in lowlands
                if (elev < 550.0f) {
                    const float patch = fbm(fx * 0.045f + 3.1f, fy * 0.045f + 8.4f, 2);
                    const float grain = (hash2D(wx, wy) - 0.5f) * 10.0f;
                    col.r += (patch - 0.5f) * 26.0f + grain;
                    col.g += (patch - 0.5f) * 20.0f + grain * 0.8f;
                    col.b += (patch - 0.5f) * 10.0f;
                }

                // Generative woodland / forest clusters (lowlands & mid-elevation foothills)
                if (elev > 30.0f && elev < 1450.0f) {
                    const float forestField = fbm(fx * 0.022f + 19.2f, fy * 0.022f + 71.5f, 3);
                    const float canopyTex = fbm(fx * 0.18f, fy * 0.18f, 2);
                    if (forestField > 0.54f) {
                        const float density = std::clamp((forestField - 0.54f) / 0.18f, 0.0f, 1.0f);
                        const ColorRGB forestCol{
                            64.0f + canopyTex * 24.0f,
                            112.0f + canopyTex * 28.0f,
                            62.0f + canopyTex * 16.0f
                        };
                        col = lerpColor(col, forestCol, density * 0.62f);
                    }
                }

                // Lush alluvial greening along river valleys
                const float rd = riverDist_[idx];
                if (rd < 7.5f && elev < 900.0f) {
                    const float valleyT = 1.0f - (rd / 7.5f);
                    col = lerpColor(col, {92, 152, 86}, valleyT * 0.42f);
                }

                // Topographic contour lines every 400m
                const int band = static_cast<int>(elev / 400.0f);
                const int bandR = static_cast<int>(eR / 400.0f);
                const int bandD = static_cast<int>(eD / 400.0f);
                if (band != bandR || band != bandD) {
                    col.r *= 0.80f;
                    col.g *= 0.80f;
                    col.b *= 0.80f;
                }
            } else {
                // Engineering Grade / Slope overlay
                const float gradePct = slopeAt(wx, wy) * 100.0f;
                if (gradePct < 1.5f) {
                    col = lerpColor({86, 172, 98}, {190, 204, 88}, gradePct / 1.5f);
                } else if (gradePct < 4.5f) {
                    col = lerpColor({190, 204, 88}, {222, 138, 62}, (gradePct - 1.5f) / 3.0f);
                } else {
                    col = lerpColor({222, 138, 62}, {198, 52, 52}, (gradePct - 4.5f) / 4.5f);
                }
            }

            if (isRiver(wx, wy)) {
                col = {56.0f, 118.0f, 174.0f};
            } else {
                col.r *= shade;
                col.g *= shade;
                col.b *= shade;

                // Subtle warm coastal shoreline rim
                if (coastDist_[idx] < 1.6f) {
                    col = lerpColor(col, {194, 184, 146}, 0.45f);
                }
            }

            outRgba[outIdx + 0] = static_cast<std::uint8_t>(std::clamp(col.r, 0.0f, 255.0f));
            outRgba[outIdx + 1] = static_cast<std::uint8_t>(std::clamp(col.g, 0.0f, 255.0f));
            outRgba[outIdx + 2] = static_cast<std::uint8_t>(std::clamp(col.b, 0.0f, 255.0f));
            outRgba[outIdx + 3] = 255;
        }
    }
}

}  // namespace raildev
