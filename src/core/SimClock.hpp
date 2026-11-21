#pragma once

#include <cstdint>
#include <string>

namespace raildev {

enum class SimSpeed {
    Paused = 0,
    Normal = 1,
    Fast = 2,
    Ultra = 4
};

class SimClock {
public:
    static constexpr double kTickDurationSec = 0.05;  // 20 Hz fixed sim step
    static constexpr int kTicksPerDay = 20;           // 1 day = 1s at 1x speed

    explicit SimClock(int startYear = 1835, int startMonth = 5, int startDay = 1);

    /// Advances simulation accumulator by real dtSeconds. Returns number of fixed ticks executed.
    int advance(double dtSeconds);

    void setSpeed(SimSpeed speed) { speed_ = speed; }
    void togglePause();

    [[nodiscard]] SimSpeed speed() const { return speed_; }
    [[nodiscard]] bool isPaused() const { return speed_ == SimSpeed::Paused; }
    [[nodiscard]] std::uint64_t totalTicks() const { return totalTicks_; }
    [[nodiscard]] int year() const { return year_; }
    [[nodiscard]] int month() const { return month_; }
    [[nodiscard]] int day() const { return day_; }
    [[nodiscard]] std::string formattedDate() const;

private:
    void advanceOneDay();

    SimSpeed speed_ = SimSpeed::Normal;
    SimSpeed lastActiveSpeed_ = SimSpeed::Normal;
    double accumulator_ = 0.0;
    std::uint64_t totalTicks_ = 0;
    int dayTicks_ = 0;
    int year_;
    int month_;
    int day_;
};

}  // namespace raildev
