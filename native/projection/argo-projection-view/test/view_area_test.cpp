#include "../src/view_area.h"
#include <array>
#include <cstdlib>
#include <cstring>

int main() {
  // Padded rows catch copying the cropped width as though it were the source stride.
  std::array<std::uint8_t, 5 * 32> decoded{};
  for (std::size_t i = 0; i < decoded.size(); ++i) decoded[i] = i;
  const auto* source = decoded.data();
  std::uint32_t width = 6, height = 5;
  if (!ApplyViewArea(source, 32, width, height, 6, 5, 1, 1, 2, 1)) return EXIT_FAILURE;
  if (width != 3 || height != 3) return EXIT_FAILURE;
  std::array<std::uint8_t, 36> copied{};
  for (std::size_t y = 0; y < height; ++y) std::memcpy(copied.data() + y * 12, source + y * 32, 12);
  for (std::size_t y = 0; y < height; ++y)
    for (std::size_t x = 0; x < 12; ++x)
      if (copied[y * 12 + x] != decoded[(y + 1) * 32 + 4 + x]) return EXIT_FAILURE;
  // Replacement dimensions and malformed margins never produce a buffer.
  source = decoded.data(); width = 6; height = 5;
  if (ApplyViewArea(source, 32, width, height, 8, 5, 1, 0, 0, 0)) return EXIT_FAILURE;
  if (ApplyViewArea(source, 32, width, height, 6, 5, 4, 0, 2, 0)) return EXIT_FAILURE;
  if (ApplyViewArea(source, 12, width, height, 6, 5, 1, 0, 0, 0)) return EXIT_FAILURE;
}
