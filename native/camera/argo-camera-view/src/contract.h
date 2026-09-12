#pragma once
#include <algorithm>
#include <atomic>
#include <bit>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>
namespace camera {
static_assert(std::endian::native == std::endian::little,
              "ARCR v1 requires little-endian Linux");
constexpr std::size_t kCapacity = 1920 * 1080 * 4, kHeader = 128,
                      kSlot = 64 + kCapacity, kSize = kHeader + 3 * kSlot;
constexpr std::uint64_t kStaleNs = 750000000;
inline bool Parse(const std::uint8_t *bytes, std::size_t size,
                  std::uint32_t &role) {
  if (!bytes || size != 12 || std::memcmp(bytes, "ARCV", 4) != 0)
    return false;
  std::uint32_t version;
  std::memcpy(&version, bytes + 4, 4);
  std::memcpy(&role, bytes + 8, 4);
  return version == 1 && role < 4;
}
inline std::uint32_t U32(const std::uint8_t *p) {
  std::uint32_t v;
  std::memcpy(&v, p, 4);
  return v;
}
inline std::uint64_t Load(const std::uint8_t *p) {
  return __atomic_load_n(reinterpret_cast<const std::uint64_t *>(p),
                         __ATOMIC_ACQUIRE);
}
inline bool Header(const std::uint8_t *p) {
  return U32(p) == 0x52435241 && U32(p + 4) == 1 && U32(p + 8) == 3 &&
         U32(p + 12) == kCapacity;
}
inline bool Stable(std::uint64_t before, std::uint64_t after,
                   std::uint64_t sequence) {
  return before == after && before == sequence * 2 && !(before & 1);
}
struct Frame {
  std::uint32_t width = 0, height = 0, stride = 0;
  std::uint64_t sequence = 0, time = 0;
  std::vector<std::uint8_t> pixels;
};
inline bool Latest(const std::uint8_t *ring, std::uint64_t now, Frame &frame,
                   std::uint32_t role = 0) {
  if (!Header(ring) || Load(ring + 24) != 1 || Load(ring + 32) != role + 1)
    return false;
  const auto seq = Load(ring + 16);
  if (seq == 0)
    return false;
  const auto *slot = ring + kHeader + ((seq - 1) % 3) * kSlot;
  const auto guard = Load(slot);
  if (guard != seq * 2)
    return false;
  const auto w = U32(slot + 8), h = U32(slot + 12), stride = U32(slot + 16);
  const auto timestamp = Load(slot + 32);
  if (w == 0 || h == 0 || w > 1920 || h > 1080 || stride < w * 4 ||
      stride > kCapacity / h || timestamp > now || now - timestamp >= kStaleNs)
    return false;
  frame.pixels.resize(static_cast<std::size_t>(stride) * h);
  std::memcpy(frame.pixels.data(), slot + 64, frame.pixels.size());
  __atomic_thread_fence(__ATOMIC_ACQUIRE);
  if (!Stable(guard, Load(slot), seq) || Load(ring + 24) != 1)
    return false;
  frame.width = w;
  frame.height = h;
  frame.stride = stride;
  frame.sequence = seq;
  frame.time = timestamp;
  return true;
}
struct Fit {
  double width, height;
};
inline Fit AspectFit(double width, double height, double source_width,
                     double source_height) {
  if (width <= 0 || height <= 0 || source_width <= 0 || source_height <= 0)
    return {0, 0};
  const double scale = std::min(width / source_width, height / source_height);
  return {source_width * scale, source_height * scale};
}
} // namespace camera
