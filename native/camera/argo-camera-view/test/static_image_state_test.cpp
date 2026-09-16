#include "../src/static_image_state.h"
#include <cassert>

using State = camera::StaticImageState;
using Action = State::Action;

int main() {
  State state;
  std::atomic<bool> refresh{true};
  auto present = [&](bool decoded, bool fresh, bool request_refresh) {
    if (request_refresh)
      refresh = true;
    return state.Present(decoded, fresh, false, refresh);
  };
  assert(state.DecodeRevision(1));
  assert(present(true, true, true) == Action::Image);
  // More than 30 seconds of the existing 25 ms worker loop: no GBM submissions.
  for (int i = 0; i < 2000; ++i) {
    assert(!state.DecodeRevision(1));
    assert(present(true, true, false) == Action::None);
  }
  // Resize, renegotiation and resume use the same refresh event, not a decode.
  for (int event = 0; event < 3; ++event) {
    assert(!state.DecodeRevision(1));
    assert(present(true, true, true) == Action::Image);
    assert(present(true, true, false) == Action::None);
  }
  assert(state.DecodeRevision(2));
  assert(present(true, true, false) == Action::Image);

  // Live-timestamped static imagery expires once; repeated black allocations
  // are just as undesirable as repeated image allocations. Replay stays fresh.
  assert(present(true, false, false) == Action::Blank);
  for (int i = 0; i < 2000; ++i)
    assert(present(true, false, false) == Action::None);
  assert(present(true, false, true) == Action::Blank);
  assert(present(true, false, false) == Action::None);

  assert(state.DecodeRevision(3));
  assert(present(false, true, false) == Action::Blank);
  for (int i = 0; i < 2000; ++i) {
    assert(!state.DecodeRevision(3));
    assert(present(false, true, false) == Action::None);
  }
  // A failed decode remains failed on refresh; a new revision may try again.
  assert(!state.DecodeRevision(3));
  assert(present(false, true, true) == Action::Blank);
  assert(state.DecodeRevision(4));
  assert(present(true, true, false) == Action::Image);
  // An unsuccessful IHS submission also waits for an explicit refresh.
  assert(present(true, true, false) == Action::None);
  assert(present(true, true, true) == Action::Image);

  // Suspension (including one arriving during decode) preserves the redraw.
  refresh = true;
  for (int i = 0; i < 2000; ++i) {
    assert(state.Present(true, true, true, refresh) == Action::None);
    assert(refresh.load());
  }
  // On resume the cached image is submitted once without reopening the file.
  assert(!state.DecodeRevision(4));
  assert(present(true, true, true) == Action::Image);
  assert(present(true, true, false) == Action::None);
  state.Reset(); // Return to live: release the cached frame and its decisions.
  assert(!state.active());
  assert(state.DecodeRevision(4));
  assert(present(true, true, false) == Action::Image);
}
