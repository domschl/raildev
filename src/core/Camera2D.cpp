#include "core/Camera2D.hpp"

#include <algorithm>
#include <cmath>

namespace raildev {

Camera2D::Camera2D(double worldWidth, double worldHeight)
    : worldWidth_(worldWidth),
      worldHeight_(worldHeight),
      x_(worldWidth * 0.5),
      y_(worldHeight * 0.5) {}

double Camera2D::minZoom() const {
    const double minX = static_cast<double>(viewportWidth_) / worldWidth_;
    const double minY = static_cast<double>(viewportHeight_) / worldHeight_;
    return std::max({kMinZoom, minX, minY});
}

void Camera2D::setViewportSize(int width, int height) {
    viewportWidth_ = std::max(1, width);
    viewportHeight_ = std::max(1, height);
    clampToWorld();
}

void Camera2D::setPosition(double worldX, double worldY) {
    x_ = worldX;
    y_ = worldY;
    clampToWorld();
}

void Camera2D::panByScreenDelta(double dx, double dy) {
    x_ -= dx / zoom_;
    y_ -= dy / zoom_;
    clampToWorld();
}

void Camera2D::zoomAtScreenPoint(double screenX, double screenY, double factor) {
    Vec2 before = screenToWorld(screenX, screenY);
    zoom_ = std::clamp(zoom_ * factor, minZoom(), kMaxZoom);
    targetZoom_ = zoom_;
    Vec2 after = screenToWorld(screenX, screenY);
    x_ += (before.x - after.x);
    y_ += (before.y - after.y);
    clampToWorld();
}

void Camera2D::smoothZoomAtScreenPoint(double screenX, double screenY, double factor) {
    zoomAnchorX_ = screenX;
    zoomAnchorY_ = screenY;
    targetZoom_ = std::clamp(targetZoom_ * factor, minZoom(), kMaxZoom);
}

void Camera2D::update(double dt) {
    if (dt <= 0.0) return;
    const double clampedDt = std::min(dt, 0.1);
    if (std::abs(targetZoom_ - zoom_) <= 1e-4 * zoom_) {
        if (zoom_ != targetZoom_) {
            Vec2 before = screenToWorld(zoomAnchorX_, zoomAnchorY_);
            zoom_ = targetZoom_;
            Vec2 after = screenToWorld(zoomAnchorX_, zoomAnchorY_);
            x_ += (before.x - after.x);
            y_ += (before.y - after.y);
            clampToWorld();
        }
        return;
    }

    const double alpha = 1.0 - std::exp(-clampedDt * 12.0);
    const double nextZoom = zoom_ + (targetZoom_ - zoom_) * alpha;
    Vec2 before = screenToWorld(zoomAnchorX_, zoomAnchorY_);
    zoom_ = std::clamp(nextZoom, minZoom(), kMaxZoom);
    Vec2 after = screenToWorld(zoomAnchorX_, zoomAnchorY_);
    x_ += (before.x - after.x);
    y_ += (before.y - after.y);
    clampToWorld();
}

void Camera2D::focusOn(double worldX, double worldY, double zoom) {
    zoom_ = std::clamp(zoom, minZoom(), kMaxZoom);
    targetZoom_ = zoom_;
    x_ = worldX;
    y_ = worldY;
    clampToWorld();
}

void Camera2D::clampToWorld() {
    const double minZ = minZoom();
    zoom_ = std::clamp(zoom_, minZ, kMaxZoom);
    targetZoom_ = std::clamp(targetZoom_, minZ, kMaxZoom);

    const double halfW = (static_cast<double>(viewportWidth_) * 0.5) / zoom_;
    const double halfH = (static_cast<double>(viewportHeight_) * 0.5) / zoom_;

    if (halfW * 2.0 >= worldWidth_) {
        x_ = worldWidth_ * 0.5;
    } else {
        x_ = std::clamp(x_, halfW, worldWidth_ - halfW);
    }

    if (halfH * 2.0 >= worldHeight_) {
        y_ = worldHeight_ * 0.5;
    } else {
        y_ = std::clamp(y_, halfH, worldHeight_ - halfH);
    }
}

Vec2 Camera2D::worldToScreen(double worldX, double worldY) const {
    return {
        (worldX - x_) * zoom_ + viewportWidth_ * 0.5,
        (worldY - y_) * zoom_ + viewportHeight_ * 0.5,
    };
}

Vec2 Camera2D::screenToWorld(double screenX, double screenY) const {
    return {
        (screenX - viewportWidth_ * 0.5) / zoom_ + x_,
        (screenY - viewportHeight_ * 0.5) / zoom_ + y_,
    };
}

}  // namespace raildev
