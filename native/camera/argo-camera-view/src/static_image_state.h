#pragma once
#include <atomic>
#include <cstdint>

namespace camera {
// Worker-owned decisions only; pixels remain in the view's single cached frame.
// Submission attempts (including failures) wait for a change/refresh before retry.
class StaticImageState {
public:
  enum class Action { None, Image, Blank };

  bool DecodeRevision(std::uint64_t revision) {
    if (active_ && revision == revision_)
      return false;
    active_ = true;
    revision_ = revision;
    presented_ = Action::None;
    return true; // Remember the attempt even if decoding fails.
  }

  // Caller serializes this with surface lifecycle callbacks. Suspension must
  // neither acknowledge a presentation nor consume the pending redraw event.
  Action Present(bool decoded, bool fresh, bool suspended,
                 std::atomic<bool> &refresh) {
    if (suspended)
      return Action::None;
    const auto desired = decoded && fresh ? Action::Image : Action::Blank;
    if (!refresh.exchange(false) && desired == presented_)
      return Action::None;
    presented_ = desired;
    return desired;
  }

  bool active() const { return active_; }
  void Reset() { *this = {}; }

private:
  bool active_ = false;
  std::uint64_t revision_ = 0;
  Action presented_ = Action::None;
};
} // namespace camera
