#pragma once

namespace raildev {

struct Vec2 {
    double x = 0.0;
    double y = 0.0;
};

class Camera2D {
public:
    Camera2D(double worldWidth, double worldHeight);

    void setViewportSize(int width, int height);
    void setPosition(double worldX, double worldY);
    void panByScreenDelta(double dx, double dy);
    void zoomAtScreenPoint(double screenX, double screenY, double factor);
    void smoothZoomAtScreenPoint(double screenX, double screenY, double factor);
    void update(double dt);
    void focusOn(double worldX, double worldY, double zoom);
    void clampToWorld();

    [[nodiscard]] Vec2 worldToScreen(double worldX, double worldY) const;
    [[nodiscard]] Vec2 screenToWorld(double screenX, double screenY) const;

    [[nodiscard]] double x() const { return x_; }
    [[nodiscard]] double y() const { return y_; }
    [[nodiscard]] double zoom() const { return zoom_; }
    [[nodiscard]] double minZoom() const;
    [[nodiscard]] int viewportWidth() const { return viewportWidth_; }
    [[nodiscard]] int viewportHeight() const { return viewportHeight_; }

    static constexpr double kMinZoom = 0.25;
    static constexpr double kMaxZoom = 12.0;

private:
    double worldWidth_;
    double worldHeight_;
    int viewportWidth_ = 1280;
    int viewportHeight_ = 720;
    double x_ = 0.0;
    double y_ = 0.0;
    double zoom_ = 0.75;
    double targetZoom_ = 0.75;
    double zoomAnchorX_ = 640.0;
    double zoomAnchorY_ = 360.0;
};

}  // namespace raildev
