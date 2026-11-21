#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "core/Camera2D.hpp"
#include "map/EuropeMap.hpp"

namespace raildev {

enum class SignalType {
    Block,
    OneWay,
    Chain
};

struct Signal {
    std::uint32_t id = 0;
    std::uint32_t edgeId = 0;
    float t = 0.5f;         // Normalized position along edge [0..1]
    int direction = 1;      // +1: nodeA -> nodeB, -1: nodeB -> nodeA
    SignalType type = SignalType::OneWay;
};

struct TrackNode {
    std::uint32_t id = 0;
    Vec2 pos{};
    float elevation = 0.0f;
    int stationId = -1;     // >= 0 if attached to a station
    std::vector<std::uint32_t> edges;
};

struct TrackEdge {
    std::uint32_t id = 0;
    std::uint32_t nodeA = 0;
    std::uint32_t nodeB = 0;
    Vec2 p0{};
    Vec2 c1{};
    Vec2 c2{};
    Vec2 p1{};

    float lengthKm = 0.0f;
    float maxGradePct = 0.0f;
    bool hasBridge = false;
    bool hasTunnel = false;
    bool isStationTrack = false;
    int cost = 0;
    std::vector<Vec2> sampledPoints;
    std::vector<Signal> signals;
};

struct Station {
    std::uint32_t id = 0;
    std::string name;
    Vec2 pos{};
    float angle = 0.0f;
    int platforms = 2;
    int maxPlatforms = 8;
    int cityIndex = -1;     // Linked European city index, or -1 if rural
    std::uint32_t nodeId = 0;        // Throat A
    std::uint32_t throatBNodeId = 0; // Throat B
};

struct TrackPreview {
    Vec2 p0{};
    Vec2 c1{};
    Vec2 c2{};
    Vec2 p1{};
    std::vector<Vec2> sampledPoints;
    float lengthKm = 0.0f;
    float maxGradePct = 0.0f;
    bool hasBridge = false;
    bool hasTunnel = false;
    bool valid = false;
    int cost = 0;
    std::string invalidReason;
};

class TrackGraph {
public:
    static constexpr float kKmPerWorldUnit = 1.5f;
    static constexpr float kMaxBuildableGradePct = 8.5f;
    static constexpr float kDoubleTrackOffsetWorld = 0.55f;
    static constexpr float kStationHalfLengthWorld = 1.8f;

    /// Evaluates a cubic Bezier curve at parameter t in [0, 1].
    [[nodiscard]] static Vec2 evalBezier(const Vec2& p0, const Vec2& c1,
                                         const Vec2& c2, const Vec2& p1, float t);
    [[nodiscard]] static Vec2 evalBezierTangent(const Vec2& p0, const Vec2& c1,
                                                const Vec2& c2, const Vec2& p1, float t);

    /// Returns a unit departure/arrival tangent at nodeId oriented toward towardPos, if available.
    [[nodiscard]] bool getNodeTangent(std::uint32_t nodeId, const Vec2& towardPos,
                                      Vec2& outDir) const;

    /// Computes a smooth track preview between two world points (with optional start/end tangents).
    [[nodiscard]] TrackPreview previewTrack(const EuropeMap& map,
                                            const Vec2& startPos, const Vec2& endPos,
                                            const Vec2* startDir = nullptr,
                                            const Vec2* endDir = nullptr) const;

    /// Finds an existing TrackNode within worldRadius of pos, or returns 0 if none.
    [[nodiscard]] std::uint32_t findNodeNear(const Vec2& pos, float worldRadius) const;

    /// Finds the closest TrackEdge and parameter t within worldRadius of pos.
    [[nodiscard]] bool findEdgeNear(const Vec2& pos, float worldRadius,
                                    std::uint32_t& outEdgeId, float& outT) const;

    /// Places a station at worldPos with orientation angle; creates two throat nodes.
    std::uint32_t addStation(const EuropeMap& map, const Vec2& worldPos,
                             int cityIndex, const std::string& name, float angle = 0.0f);

    /// Creates or reuses nodes and adds a track edge from preview.
    std::uint32_t addTrackFromPreview(const EuropeMap& map, const TrackPreview& preview,
                                      std::uint32_t snapNodeA = 0, std::uint32_t snapNodeB = 0);

    /// Adds a parallel double-track pair between startPos and endPos (converging to snapped station/junction nodes).
    int addDoubleTrack(const EuropeMap& map, const Vec2& startPos, const Vec2& endPos,
                       std::vector<std::uint32_t>* outEdgeIds = nullptr,
                       std::uint32_t snapNodeA = 0, std::uint32_t snapNodeB = 0,
                       const Vec2* startDir = nullptr, const Vec2* endDir = nullptr);

    /// Places a single signal on an edge.
    std::uint32_t addSignal(std::uint32_t edgeId, float t, int direction, SignalType type);

    /// Automatically places evenly spaced directional signals along an edge.
    int autoSignalEdge(std::uint32_t edgeId, float spacingKm = 25.0f,
                       int direction = 1, SignalType type = SignalType::OneWay);

    [[nodiscard]] const std::vector<TrackNode>& nodes() const { return nodes_; }
    [[nodiscard]] const std::vector<TrackEdge>& edges() const { return edges_; }
    [[nodiscard]] const std::vector<Station>& stations() const { return stations_; }
    [[nodiscard]] const TrackNode* getNode(std::uint32_t id) const;
    [[nodiscard]] const TrackEdge* getEdge(std::uint32_t id) const;

private:
    std::uint32_t getOrCreateNode(const EuropeMap& map, const Vec2& pos, float snapRadius);

    std::vector<TrackNode> nodes_;
    std::vector<TrackEdge> edges_;
    std::vector<Station> stations_;
    std::uint32_t nextNodeId_ = 1;
    std::uint32_t nextEdgeId_ = 1;
    std::uint32_t nextStationId_ = 1;
    std::uint32_t nextSignalId_ = 1;
};

}  // namespace raildev
