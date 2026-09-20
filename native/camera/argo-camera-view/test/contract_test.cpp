#include "../src/contract.h"
#ifdef ARGO_WITH_SURROUND
#include "../src/surround_transport.h"
#endif
#include <cassert>
#include <cmath>
int main() {
  assert(!camera::ClockDiscontinuity(100, 1000));
  assert(camera::ClockDiscontinuity(100, 200000001));
  assert(camera::ClockDiscontinuity(200000001, 100));

#ifdef ARGO_WITH_SURROUND
  rapidjson::Document descriptor;
  descriptor.Parse(R"({"format":"BGRx","width":640,"height":480,"generation":1,"sequence":2,"capture_ns":100,"allocation_size":1228800,"planes":[{"offset":0,"stride":2560,"size":1228800}]})");
  camera::Frame immutable;
  std::uint64_t generation, allocation, offset;
  assert(surround::Layout(descriptor, immutable, generation, allocation, offset, 101));
  descriptor["planes"][0]["offset"].SetUint64(1228800);
  assert(!surround::Layout(descriptor, immutable, generation, allocation, offset, 101));
  descriptor["planes"][0]["offset"].SetUint64(0);
  descriptor["planes"][0]["stride"].SetUint64(UINT64_MAX);
  assert(!surround::Layout(descriptor, immutable, generation, allocation, offset, 101));

#endif
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
  put(136, 1080); put(140, 1920); put(144, 1080 * 4);
  assert(camera::Latest(ring, 101, f));
  put(136, 1920); put(140, 1920); put(144, 1920 * 4);
  assert(!camera::Latest(ring, 101, f));
  put(136, 2); put(140, 2); put(144, 8);
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
