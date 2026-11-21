#include "map/CityFootprint.hpp"

#include <algorithm>
#include <cmath>
#include <random>

namespace raildev {
namespace {

std::uint32_t hashString(const std::string& s) {
    std::uint32_t h = 2166136261u;
    for (unsigned char c : s) {
        h ^= c;
        h *= 16777619u;
    }
    return h;
}

}  // namespace

bool CityFootprint::contains(double wx, double wy) const {
    if (boundary.size() < 3) return false;
    bool inside = false;
    std::size_t j = boundary.size() - 1;
    for (std::size_t i = 0; i < boundary.size(); ++i) {
        const double xi = boundary[i].x;
        const double yi = boundary[i].y;
        const double xj = boundary[j].x;
        const double yj = boundary[j].y;
        if (((yi > wy) != (yj > wy)) &&
            (wx < (xj - xi) * (wy - yi) / ((yj - yi) + 1e-12) + xi)) {
            inside = !inside;
        }
        j = i;
    }
    return inside;
}

CityFootprint generateCityFootprint(const CityData& city, const EuropeMap& map) {
    CityFootprint fp;
    EuropeProjection::latLonToWorld(city.lat, city.lon, fp.center.x, fp.center.y);

    std::mt19937 rng(hashString(city.name));
    std::uniform_real_distribution<float> phaseDist(0.0f, 6.2831853f);
    std::uniform_real_distribution<float> uni01(0.0f, 1.0f);

    // Radius scales smoothly with population to visualize city growth
    const float popFactor = std::sqrt(static_cast<float>(std::max(5000, city.population)) / 20000.0f);
    fp.radius = std::clamp(3.0f + popFactor * 2.1f, 4.5f, 26.0f);

    const float p2 = phaseDist(rng);
    const float p3 = phaseDist(rng);
    const float p5 = phaseDist(rng);
    const float a2 = 0.14f + 0.08f * uni01(rng);
    const float a3 = 0.10f + 0.06f * uni01(rng);
    const float a5 = 0.05f + 0.04f * uni01(rng);

    constexpr int kNumVerts = 36;
    std::vector<float> radii(kNumVerts, 1.5f);
    for (int i = 0; i < kNumVerts; ++i) {
        const float theta = (2.0f * 3.14159265f * static_cast<float>(i)) / kNumVerts;
        const float mod = 1.0f +
                          a2 * std::sin(2.0f * theta + p2) +
                          a3 * std::cos(3.0f * theta + p3) +
                          a5 * std::sin(5.0f * theta + p5);
        const float targetR = fp.radius * std::clamp(mod, 0.62f, 1.42f);

        // Ray-march outward so city respects coastlines and steep cliffs
        float actualR = 1.5f;
        const float cosT = std::cos(theta);
        const float sinT = std::sin(theta);
        constexpr int kSteps = 14;
        for (int s = 1; s <= kSteps; ++s) {
            const float r = targetR * (static_cast<float>(s) / kSteps);
            const int wx = static_cast<int>(std::round(fp.center.x + cosT * r));
            const int wy = static_cast<int>(std::round(fp.center.y + sinT * r));
            if (!map.isLand(wx, wy) || map.slopeAt(wx, wy) > 0.11f) {
                break;
            }
            actualR = r;
        }
        radii[static_cast<std::size_t>(i)] = actualR;
    }

    // 1-pass circular smoothing so mountainous/coastal cities stay organic instead of spiky
    fp.boundary.reserve(kNumVerts);
    for (int i = 0; i < kNumVerts; ++i) {
        const float rPrev = radii[static_cast<std::size_t>((i + kNumVerts - 1) % kNumVerts)];
        const float rCur = radii[static_cast<std::size_t>(i)];
        const float rNext = radii[static_cast<std::size_t>((i + 1) % kNumVerts)];
        const float smoothR = 0.25f * rPrev + 0.50f * rCur + 0.25f * rNext;
        const float theta = (2.0f * 3.14159265f * static_cast<float>(i)) / kNumVerts;
        fp.boundary.push_back({
            fp.center.x + static_cast<double>(std::cos(theta) * smoothR),
            fp.center.y + static_cast<double>(std::sin(theta) * smoothR)
        });
    }

    // Radial arterial streets
    const int numRadials = std::clamp(5 + city.tier * 2, 5, 11);
    const float radialOffset = phaseDist(rng);
    for (int i = 0; i < numRadials; ++i) {
        const float theta = radialOffset +
                            (2.0f * 3.14159265f * static_cast<float>(i)) / numRadials +
                            (uni01(rng) - 0.5f) * 0.22f;
        const float cosT = std::cos(theta);
        const float sinT = std::sin(theta);
        // Find edge along ray
        float edgeR = fp.radius * 0.9f;
        for (float r = 1.0f; r <= fp.radius * 1.35f; r += 0.8f) {
            const double px = fp.center.x + cosT * r;
            const double py = fp.center.y + sinT * r;
            if (!fp.contains(px, py)) {
                edgeR = std::max(1.5f, r - 0.8f);
                break;
            }
        }
        fp.streets.push_back({
            fp.center,
            {fp.center.x + cosT * edgeR, fp.center.y + sinT * edgeR}
        });
    }

    // Inner ring road(s)
    const int numRings = (fp.radius > 11.0f) ? 2 : 1;
    for (int ring = 1; ring <= numRings; ++ring) {
        const float ringFrac = (numRings == 2) ? (ring == 1 ? 0.42f : 0.74f) : 0.52f;
        constexpr int kRingSegs = 18;
        for (int i = 0; i < kRingSegs; ++i) {
            const std::size_t idx0 = static_cast<std::size_t>((i * kNumVerts) / kRingSegs);
            const std::size_t idx1 = static_cast<std::size_t>(((i + 1) * kNumVerts) / kRingSegs) % kNumVerts;
            const Vec2 p0{
                fp.center.x + (fp.boundary[idx0].x - fp.center.x) * ringFrac,
                fp.center.y + (fp.boundary[idx0].y - fp.center.y) * ringFrac
            };
            const Vec2 p1{
                fp.center.x + (fp.boundary[idx1].x - fp.center.x) * ringFrac,
                fp.center.y + (fp.boundary[idx1].y - fp.center.y) * ringFrac
            };
            fp.streets.push_back({p0, p1});
        }
    }

    // Synthesize procedural building blocks inside the footprint
    const float cellStep = 1.15f;
    const int gridHalf = static_cast<int>(std::ceil(fp.radius * 1.45f / cellStep));
    for (int gy = -gridHalf; gy <= gridHalf; ++gy) {
        for (int gx = -gridHalf; gx <= gridHalf; ++gx) {
            const float jx = (uni01(rng) - 0.5f) * 0.45f;
            const float jy = (uni01(rng) - 0.5f) * 0.45f;
            const double wx = fp.center.x + (static_cast<float>(gx) + jx) * cellStep;
            const double wy = fp.center.y + (static_cast<float>(gy) + jy) * cellStep;
            if (!fp.contains(wx, wy)) continue;

            const float dist = static_cast<float>(std::hypot(wx - fp.center.x, wy - fp.center.y));
            const float normDist = dist / std::max(1.0f, fp.radius);

            // Slightly sparser towards the urban fringe
            const float spawnProb = (normDist < 0.45f) ? 0.85f : (normDist < 0.80f ? 0.65f : 0.40f);
            if (uni01(rng) > spawnProb) continue;

            std::uint8_t kind = 1;
            if (normDist < 0.38f) {
                kind = 0;  // Historic core
            } else if (normDist > 0.76f && uni01(rng) < 0.45f) {
                kind = 2;  // Industrial / rail yard edge
            }

            const float bw = 0.42f + uni01(rng) * 0.48f;
            const float bh = 0.38f + uni01(rng) * 0.45f;
            const float angle = std::atan2(static_cast<float>(wy - fp.center.y),
                                           static_cast<float>(wx - fp.center.x)) +
                                (uni01(rng) - 0.5f) * 0.35f;

            fp.blocks.push_back({
                static_cast<float>(wx),
                static_cast<float>(wy),
                bw, bh, angle, kind
            });
        }
    }

    return fp;
}

}  // namespace raildev
