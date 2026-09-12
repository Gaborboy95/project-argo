#include "../src/contract.h"
#include <cassert>
#include <cmath>
int main() {
  std::uint8_t bytes[12]{'A', 'R', 'C', 'V', 1, 0, 0, 0, 0, 0, 0, 0};
  std::uint32_t role = 99;
  assert(camera::Parse(bytes, 12, role) && role == 0);
  assert(!camera::Parse(bytes, 11, role));
  bytes[8] = 4;
  assert(!camera::Parse(bytes, 12, role));
  assert(camera::Stable(4, 4, 2));
  assert(!camera::Stable(4, 6, 2));
  assert(!camera::Stable(5, 5, 2));
  std::vector<std::uint64_t> storage((camera::kSize + 7) / 8);
  auto *ring = reinterpret_cast<std::uint8_t *>(storage.data());
  auto put = [&](std::size_t off, std::uint32_t v) {
    std::memcpy(ring + off, &v, 4);
  };
  auto put64 = [&](std::size_t off, std::uint64_t v) {
    std::memcpy(ring + off, &v, 8);
  };
  put(0, 0x52435241);
  put(4, 1);
  put(8, 3);
  put(12, camera::kCapacity);
  put64(16, 1);
  put64(24, 1);
  put64(32, 1);
  put64(128, 2);
  put(136, 2);
  put(140, 2);
  put(144, 8);
  put64(160, 100);
  camera::Frame f;
  assert(camera::Latest(ring, 101, f));
  put64(128, 3);
  assert(!camera::Latest(ring, 101, f));
  put64(128, 2);
  assert(!camera::Latest(ring, 100 + camera::kStaleNs, f));
  put64(24, 0);
  assert(!camera::Latest(ring, 101, f));
  for (double w : {800., 1280., 2000.}) {
    const auto fit = camera::AspectFit(w, w * 0.75, 1920, 1080);
    assert(std::abs(fit.width - w) < 1e-9);
    assert(std::abs(fit.height - w * 9 / 16) < 1e-9);
  }
}
