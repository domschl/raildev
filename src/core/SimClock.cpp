#include "core/SimClock.hpp"

#include <algorithm>
#include <array>
#include <cstdio>

namespace raildev {

SimClock::SimClock(int startYear, int startMonth, int startDay)
    : year_(startYear), month_(startMonth), day_(startDay) {}

int SimClock::advance(double dtSeconds) {
    if (speed_ == SimSpeed::Paused) {
        return 0;
    }

    const double clampedDt = std::min(dtSeconds, 0.25);
    accumulator_ += clampedDt * static_cast<double>(static_cast<int>(speed_));

    int ticks = 0;
    while (accumulator_ + 1e-9 >= kTickDurationSec) {
        accumulator_ = std::max(0.0, accumulator_ - kTickDurationSec);
        ++totalTicks_;
        ++dayTicks_;
        if (dayTicks_ >= kTicksPerDay) {
            dayTicks_ = 0;
            advanceOneDay();
        }
        ++ticks;
    }
    return ticks;
}

void SimClock::togglePause() {
    if (speed_ == SimSpeed::Paused) {
        speed_ = lastActiveSpeed_;
    } else {
        lastActiveSpeed_ = speed_;
        speed_ = SimSpeed::Paused;
    }
}

void SimClock::advanceOneDay() {
    static constexpr std::array<int, 12> kDaysInMonth = {
        31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31
    };

    int maxDays = kDaysInMonth[static_cast<std::size_t>(month_ - 1)];
    if (month_ == 2 && ((year_ % 4 == 0 && year_ % 100 != 0) || (year_ % 400 == 0))) {
        maxDays = 29;
    }

    ++day_;
    if (day_ > maxDays) {
        day_ = 1;
        ++month_;
        if (month_ > 12) {
            month_ = 1;
            ++year_;
        }
    }
}

std::string SimClock::formattedDate() const {
    static constexpr std::array<const char*, 12> kMonths = {
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
    };
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%02d %s %d", day_, kMonths[month_ - 1], year_);
    return std::string(buf);
}

}  // namespace raildev
