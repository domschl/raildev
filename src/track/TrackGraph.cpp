#include "track/TrackGraph.hpp"

#include <algorithm>
#include <cmath>

namespace raildev {
namespace {

float distPointToSegSq(const Vec2& p, const Vec2& a, const Vec2& b, float& outT) {
    const double abx = b.x - a.x;
    const double aby = b.y - a.y;
    const double apx = p.x - a.x;
    const double apy = p.y - a.y;
    const double lenSq = abx * abx + aby * aby;
    if (lenSq <= 1e-9) {
        outT = 0.0f;
        return static_cast<float>(apx * apx + apy * apy);
    }
    outT = static_cast<float>(std::clamp((apx * abx + apy * aby) / lenSq, 0.0, 1.0));
    const double cx = a.x + outT * abx - p.x;
    const double cy = a.y + outT * aby - p.y;
    return static_cast<float>(cx * cx + cy * cy);
}

Vec2 normalizeVec(const Vec2& v) {
    const double len = std::hypot(v.x, v.y);
    if (len <= 1e-9) return {1.0, 0.0};
    return {v.x / len, v.y / len};
}

}  // namespace

Vec2 TrackGraph::evalBezier(const Vec2& p0, const Vec2& c1,
                            const Vec2& c2, const Vec2& p1, float t) {
    const double u = 1.0 - static_cast<double>(t);
    const double tt = static_cast<double>(t) * t;
    const double uu = u * u;
    const double uuu = uu * u;
    const double ttt = tt * t;
    return {
        uuu * p0.x + 3.0 * uu * t * c1.x + 3.0 * u * tt * c2.x + ttt * p1.x,
        uuu * p0.y + 3.0 * uu * t * c1.y + 3.0 * u * tt * c2.y + ttt * p1.y
    };
}

Vec2 TrackGraph::evalBezierTangent(const Vec2& p0, const Vec2& c1,
                                   const Vec2& c2, const Vec2& p1, float t) {
    const double u = 1.0 - static_cast<double>(t);
    const double dt = static_cast<double>(t);
    return {
        3.0 * u * u * (c1.x - p0.x) + 6.0 * u * dt * (c2.x - c1.x) + 3.0 * dt * dt * (p1.x - c2.x),
        3.0 * u * u * (c1.y - p0.y) + 6.0 * u * dt * (c2.y - c1.y) + 3.0 * dt * dt * (p1.y - c2.y)
    };
}

bool TrackGraph::getNodeTangent(std::uint32_t nodeId, const Vec2& towardPos, Vec2& outDir) const {
    const TrackNode* node = getNode(nodeId);
    if (!node) return false;

    const Vec2 toTarget = normalizeVec({towardPos.x - node->pos.x, towardPos.y - node->pos.y});

    // If attached to a station throat, depart axially outward from the station
    if (node->stationId >= 0) {
        for (const auto& st : stations_) {
            if (static_cast<int>(st.id) == node->stationId) {
                Vec2 axial{std::cos(st.angle), std::sin(st.angle)};
                if (nodeId == st.nodeId) {
                    // Throat A is at -axial, so outward is -axial
                    outDir = {-axial.x, -axial.y};
                } else {
                    // Throat B is at +axial, so outward is +axial
                    outDir = axial;
                }
                return true;
            }
        }
    }

    if (node->edges.empty()) return false;

    // Pick the connected edge whose tangent aligns best with towardPos
    double bestDot = -2.0;
    Vec2 bestDir{1.0, 0.0};
    for (std::uint32_t eid : node->edges) {
        const TrackEdge* edge = getEdge(eid);
        if (!edge) continue;

        Vec2 tan{};
        if (edge->nodeA == nodeId) {
            // Edge starts at nodeA; continuing through nodeA means -tangent(0)
            tan = evalBezierTangent(edge->p0, edge->c1, edge->c2, edge->p1, 0.0f);
            tan = {-tan.x, -tan.y};
        } else {
            // Edge ends at nodeB; continuing past nodeB means +tangent(1)
            tan = evalBezierTangent(edge->p0, edge->c1, edge->c2, edge->p1, 1.0f);
        }
        const Vec2 unit = normalizeVec(tan);
        const double dot = unit.x * toTarget.x + unit.y * toTarget.y;
        // Also allow branching in the opposite direction if user drags back
        if (std::abs(dot) > bestDot) {
            bestDot = std::abs(dot);
            bestDir = (dot >= 0.0) ? unit : Vec2{-unit.x, -unit.y};
        }
    }

    outDir = bestDir;
    return true;
}

TrackPreview TrackGraph::previewTrack(const EuropeMap& map,
                                      const Vec2& startPos, const Vec2& endPos,
                                      const Vec2* startDir,
                                      const Vec2* endDir) const {
    TrackPreview pv;
    pv.p0 = startPos;
    pv.p1 = endPos;

    const double dx = endPos.x - startPos.x;
    const double dy = endPos.y - startPos.y;
    const double chord = std::hypot(dx, dy);

    if (chord < 1.5) {
        pv.valid = false;
        pv.invalidReason = "Track too short";
        return pv;
    }

    const float startElev = map.elevationAtWorld(startPos.x, startPos.y);
    const float endElev = map.elevationAtWorld(endPos.x, endPos.y);
    if (startElev < 0.0f || endElev < 0.0f) {
        pv.valid = false;
        pv.invalidReason = "Stations & track ends must be on land";
        return pv;
    }

    const double handleLen = std::min(chord * 0.38, 45.0);
    const Vec2 chordDir{dx / chord, dy / chord};

    if (startDir && std::hypot(startDir->x, startDir->y) > 1e-6) {
        const Vec2 sUnit = normalizeVec(*startDir);
        pv.c1 = {startPos.x + sUnit.x * handleLen, startPos.y + sUnit.y * handleLen};
    } else if (endDir && std::hypot(endDir->x, endDir->y) > 1e-6) {
        // Gentle entry curve even if only endDir is constrained
        const Vec2 eUnit = normalizeVec(*endDir);
        const Vec2 autoStart = normalizeVec({chordDir.x * 1.4 - eUnit.x * 0.4,
                                             chordDir.y * 1.4 - eUnit.y * 0.4});
        pv.c1 = {startPos.x + autoStart.x * handleLen, startPos.y + autoStart.y * handleLen};
    } else {
        pv.c1 = {startPos.x + dx * 0.33, startPos.y + dy * 0.33};
    }

    if (endDir && std::hypot(endDir->x, endDir->y) > 1e-6) {
        const Vec2 eUnit = normalizeVec(*endDir);
        pv.c2 = {endPos.x + eUnit.x * handleLen, endPos.y + eUnit.y * handleLen};
    } else if (startDir && std::hypot(startDir->x, startDir->y) > 1e-6) {
        const Vec2 sUnit = normalizeVec(*startDir);
        const Vec2 autoEnd = normalizeVec({chordDir.x * 1.4 - sUnit.x * 0.4,
                                           chordDir.y * 1.4 - sUnit.y * 0.4});
        pv.c2 = {endPos.x - autoEnd.x * handleLen, endPos.y - autoEnd.y * handleLen};
    } else {
        pv.c2 = {startPos.x + dx * 0.67, startPos.y + dy * 0.67};
    }

    const int steps = std::clamp(static_cast<int>(std::ceil(chord * 1.4)), 20, 180);
    pv.sampledPoints.reserve(static_cast<std::size_t>(steps) + 1);

    float prevElev = startElev;
    Vec2 prevPt = startPos;
    pv.sampledPoints.push_back(startPos);

    double totalWorldLen = 0.0;
    double waterWorldLen = 0.0;
    double maxContigWater = 0.0;
    double curContigWater = 0.0;
    double tunnelWorldLen = 0.0;

    for (int i = 1; i <= steps; ++i) {
        const float t = static_cast<float>(i) / static_cast<float>(steps);
        const Vec2 pt = evalBezier(pv.p0, pv.c1, pv.c2, pv.p1, t);
        pv.sampledPoints.push_back(pt);

        const double segWorld = std::hypot(pt.x - prevPt.x, pt.y - prevPt.y);
        totalWorldLen += segWorld;

        const int ix = static_cast<int>(std::round(pt.x));
        const int iy = static_cast<int>(std::round(pt.y));
        const float elev = map.elevationAt(ix, iy);
        const bool isWater = (elev < 0.0f) || map.isRiver(ix, iy);

        if (isWater) {
            pv.hasBridge = true;
            waterWorldLen += segWorld;
            curContigWater += segWorld;
            maxContigWater = std::max(maxContigWater, curContigWater);
        } else {
            curContigWater = 0.0;
        }

        const float effElev = std::max(0.0f, elev);
        const float effPrev = std::max(0.0f, prevElev);
        const double segMeters = std::max(1.0, segWorld * kKmPerWorldUnit * 1000.0);
        const float gradePct = static_cast<float>(std::abs(effElev - effPrev) / segMeters * 100.0);
        pv.maxGradePct = std::max(pv.maxGradePct, gradePct);

        if (effElev > 1350.0f || gradePct > 4.8f) {
            pv.hasTunnel = true;
            tunnelWorldLen += segWorld;
        }

        prevElev = elev;
        prevPt = pt;
    }

    pv.lengthKm = static_cast<float>(totalWorldLen * kKmPerWorldUnit);

    if (maxContigWater > 18.0) {
        pv.valid = false;
        pv.invalidReason = "Water crossing too wide for a bridge";
        return pv;
    }
    if (pv.maxGradePct > kMaxBuildableGradePct && !pv.hasTunnel) {
        pv.valid = false;
        pv.invalidReason = "Grade too steep";
        return pv;
    }

    const double baseCost = pv.lengthKm * 420.0;
    const double bridgeCost = (waterWorldLen * kKmPerWorldUnit) * 2800.0;
    const double tunnelCost = (tunnelWorldLen * kKmPerWorldUnit) * 3200.0;
    const double gradeMultiplier = 1.0 + std::min(1.5, pv.maxGradePct * 0.12);
    pv.cost = static_cast<int>(std::round(baseCost * gradeMultiplier + bridgeCost + tunnelCost));
    pv.valid = true;
    return pv;
}

std::uint32_t TrackGraph::findNodeNear(const Vec2& pos, float worldRadius) const {
    const double rSq = static_cast<double>(worldRadius) * worldRadius;
    std::uint32_t bestId = 0;
    double bestDistSq = rSq;
    for (const auto& node : nodes_) {
        const double dx = node.pos.x - pos.x;
        const double dy = node.pos.y - pos.y;
        const double d2 = dx * dx + dy * dy;
        if (d2 <= bestDistSq) {
            bestDistSq = d2;
            bestId = node.id;
        }
    }
    return bestId;
}

bool TrackGraph::findEdgeNear(const Vec2& pos, float worldRadius,
                              std::uint32_t& outEdgeId, float& outT) const {
    float bestDistSq = worldRadius * worldRadius;
    bool found = false;

    for (const auto& edge : edges_) {
        if (edge.isStationTrack || edge.sampledPoints.size() < 2) continue;
        const std::size_t n = edge.sampledPoints.size();
        for (std::size_t i = 0; i + 1 < n; ++i) {
            float segT = 0.0f;
            const float d2 = distPointToSegSq(
                pos, edge.sampledPoints[i], edge.sampledPoints[i + 1], segT);
            if (d2 < bestDistSq) {
                bestDistSq = d2;
                outEdgeId = edge.id;
                outT = (static_cast<float>(i) + segT) / static_cast<float>(n - 1);
                found = true;
            }
        }
    }
    return found;
}

std::uint32_t TrackGraph::getOrCreateNode(const EuropeMap& map, const Vec2& pos, float snapRadius) {
    if (const std::uint32_t existing = findNodeNear(pos, snapRadius); existing != 0) {
        return existing;
    }
    TrackNode node;
    node.id = nextNodeId_++;
    node.pos = pos;
    node.elevation = map.elevationAtWorld(pos.x, pos.y);
    nodes_.push_back(std::move(node));
    return nodes_.back().id;
}

std::uint32_t TrackGraph::addStation(const EuropeMap& map, const Vec2& worldPos,
                                     int cityIndex, const std::string& name, float angle) {
    const double dx = std::cos(angle) * kStationHalfLengthWorld;
    const double dy = std::sin(angle) * kStationHalfLengthWorld;
    const Vec2 throatAPos{worldPos.x - dx, worldPos.y - dy};
    const Vec2 throatBPos{worldPos.x + dx, worldPos.y + dy};

    const std::uint32_t nodeAId = getOrCreateNode(map, throatAPos, 0.5f);
    const std::uint32_t nodeBId = getOrCreateNode(map, throatBPos, 0.5f);

    Station st;
    st.id = nextStationId_++;
    st.name = name;
    st.pos = worldPos;
    st.angle = angle;
    st.platforms = 2;
    st.cityIndex = cityIndex;
    st.nodeId = nodeAId;
    st.throatBNodeId = nodeBId;

    // Internal station platform edge connecting both throats
    TrackEdge internalEdge;
    internalEdge.id = nextEdgeId_++;
    internalEdge.nodeA = nodeAId;
    internalEdge.nodeB = nodeBId;
    internalEdge.p0 = throatAPos;
    internalEdge.c1 = {throatAPos.x + dx * 0.66, throatAPos.y + dy * 0.66};
    internalEdge.c2 = {throatBPos.x - dx * 0.66, throatBPos.y - dy * 0.66};
    internalEdge.p1 = throatBPos;
    internalEdge.lengthKm = kStationHalfLengthWorld * 2.0f * kKmPerWorldUnit;
    internalEdge.isStationTrack = true;
    internalEdge.sampledPoints = {throatAPos, worldPos, throatBPos};

    for (auto& n : nodes_) {
        if (n.id == nodeAId || n.id == nodeBId) {
            n.stationId = static_cast<int>(st.id);
            n.edges.push_back(internalEdge.id);
        }
    }

    edges_.push_back(std::move(internalEdge));
    stations_.push_back(std::move(st));
    return stations_.back().id;
}

std::uint32_t TrackGraph::addTrackFromPreview(const EuropeMap& map, const TrackPreview& preview,
                                              std::uint32_t snapNodeA, std::uint32_t snapNodeB) {
    if (!preview.valid) return 0;

    const std::uint32_t nA = (snapNodeA != 0) ? snapNodeA : getOrCreateNode(map, preview.p0, 2.0f);
    const std::uint32_t nB = (snapNodeB != 0) ? snapNodeB : getOrCreateNode(map, preview.p1, 2.0f);
    if (nA == nB) return 0;

    TrackEdge edge;
    edge.id = nextEdgeId_++;
    edge.nodeA = nA;
    edge.nodeB = nB;
    edge.p0 = preview.p0;
    edge.c1 = preview.c1;
    edge.c2 = preview.c2;
    edge.p1 = preview.p1;
    edge.lengthKm = preview.lengthKm;
    edge.maxGradePct = preview.maxGradePct;
    edge.hasBridge = preview.hasBridge;
    edge.hasTunnel = preview.hasTunnel;
    edge.cost = preview.cost;
    edge.sampledPoints = preview.sampledPoints;

    for (auto& n : nodes_) {
        if (n.id == nA || n.id == nB) {
            n.edges.push_back(edge.id);
        }
    }

    edges_.push_back(std::move(edge));
    return edges_.back().id;
}

int TrackGraph::addDoubleTrack(const EuropeMap& map, const Vec2& startPos, const Vec2& endPos,
                               std::vector<std::uint32_t>* outEdgeIds,
                               std::uint32_t snapNodeA, std::uint32_t snapNodeB,
                               const Vec2* startDir, const Vec2* endDir) {
    const double dx = endPos.x - startPos.x;
    const double dy = endPos.y - startPos.y;
    const double len = std::hypot(dx, dy);
    if (len < 2.0) return 0;

    const double nx = -dy / len;
    const double ny = dx / len;
    const double halfOff = kDoubleTrackOffsetWorld * 0.5;

    const Vec2 s1 = (snapNodeA != 0) ? startPos : Vec2{startPos.x + nx * halfOff, startPos.y + ny * halfOff};
    const Vec2 e1 = (snapNodeB != 0) ? endPos   : Vec2{endPos.x + nx * halfOff,   endPos.y + ny * halfOff};
    const Vec2 s2 = (snapNodeA != 0) ? startPos : Vec2{startPos.x - nx * halfOff, startPos.y - ny * halfOff};
    const Vec2 e2 = (snapNodeB != 0) ? endPos   : Vec2{endPos.x - nx * halfOff,   endPos.y - ny * halfOff};

    // Slightly fan out control tangents when converging into a snapped station/junction node
    Vec2 sd1 = startDir ? *startDir : Vec2{dx / len, dy / len};
    Vec2 sd2 = sd1;
    Vec2 ed1 = endDir ? *endDir : Vec2{-dx / len, -dy / len};
    Vec2 ed2 = ed1;
    if (snapNodeA != 0) {
        sd1 = {sd1.x + nx * 0.08, sd1.y + ny * 0.08};
        sd2 = {sd2.x - nx * 0.08, sd2.y - ny * 0.08};
    }
    if (snapNodeB != 0) {
        ed1 = {ed1.x + nx * 0.08, ed1.y + ny * 0.08};
        ed2 = {ed2.x - nx * 0.08, ed2.y - ny * 0.08};
    }

    const TrackPreview pv1 = previewTrack(map, s1, e1, &sd1, &ed1);
    const TrackPreview pv2 = previewTrack(map, s2, e2, &sd2, &ed2);
    if (!pv1.valid || !pv2.valid) return 0;

    const std::uint32_t id1 = addTrackFromPreview(map, pv1, snapNodeA, snapNodeB);
    const std::uint32_t id2 = addTrackFromPreview(map, pv2, snapNodeA, snapNodeB);
    if (id1 == 0 || id2 == 0) return 0;

    if (outEdgeIds) {
        outEdgeIds->push_back(id1);
        outEdgeIds->push_back(id2);
    }
    return pv1.cost + pv2.cost;
}

std::uint32_t TrackGraph::addSignal(std::uint32_t edgeId, float t, int direction, SignalType type) {
    for (auto& edge : edges_) {
        if (edge.id == edgeId) {
            Signal sig;
            sig.id = nextSignalId_++;
            sig.edgeId = edgeId;
            sig.t = std::clamp(t, 0.05f, 0.95f);
            sig.direction = (direction >= 0) ? 1 : -1;
            sig.type = type;
            edge.signals.push_back(sig);
            std::sort(edge.signals.begin(), edge.signals.end(),
                      [](const Signal& a, const Signal& b) { return a.t < b.t; });
            return sig.id;
        }
    }
    return 0;
}

int TrackGraph::autoSignalEdge(std::uint32_t edgeId, float spacingKm,
                               int direction, SignalType type) {
    const TrackEdge* edge = getEdge(edgeId);
    if (!edge || edge->isStationTrack || edge->lengthKm < spacingKm) return 0;

    const int count = std::max(1, static_cast<int>(std::floor(edge->lengthKm / spacingKm)));
    int placed = 0;
    for (int i = 1; i <= count; ++i) {
        const float t = static_cast<float>(i) / static_cast<float>(count + 1);
        if (addSignal(edgeId, t, direction, type) != 0) {
            ++placed;
        }
    }
    return placed;
}

const TrackNode* TrackGraph::getNode(std::uint32_t id) const {
    for (const auto& n : nodes_) {
        if (n.id == id) return &n;
    }
    return nullptr;
}

const TrackEdge* TrackGraph::getEdge(std::uint32_t id) const {
    for (const auto& e : edges_) {
        if (e.id == id) return &e;
    }
    return nullptr;
}

}  // namespace raildev
