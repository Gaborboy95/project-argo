#pragma once
#include <cstddef>
#include <cstdint>

// Adjust the source of the existing row copy. Keep the decoded row stride;
// only negotiated margin pixels are omitted, with no intermediate resampling.
inline bool ApplyViewArea(const std::uint8_t*& pixels, std::size_t stride,
                          std::uint32_t& width, std::uint32_t& height,
                          std::uint16_t encoded_width, std::uint16_t encoded_height,
                          std::uint16_t left, std::uint16_t top,
                          std::uint16_t right, std::uint16_t bottom) {
  if (width != encoded_width || height != encoded_height ||
      left + right >= width || top + bottom >= height ||
      stride < static_cast<std::size_t>(width) * 4) return false;
  pixels += static_cast<std::size_t>(top) * stride + static_cast<std::size_t>(left) * 4;
  width -= left + right;
  height -= top + bottom;
  return true;
}
