#pragma once

// Argo-owned media IPC, independent of AA control IPC7 and AirPlay framing.
// CarPlay framing review informed by f-io / Lasse Heitgres and LIVI,
// a23dc0c5fcdb6d069c679eddfd73298e58f44783: cp/stack/screenStream.ts and
// nalu.ts. No upstream implementation or fixtures are copied. See CREDITS.md
// and docs/carplay-livi-review.md for the protocol review and GPL provenance.

#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <span>

namespace argo::media {

constexpr std::size_t kHeaderSize = 24;
constexpr std::size_t kDescriptionSize = 24;
constexpr std::size_t kConfigLimit = 64 * 1024;
constexpr std::size_t kAccessUnitLimit = 4 * 1024 * 1024;
constexpr std::size_t kNalLimit = 1024;

inline std::uint16_t U16(const std::uint8_t* p) {
  return (static_cast<std::uint16_t>(p[0]) << 8) | p[1];
}
inline std::uint32_t U32(const std::uint8_t* p) {
  return (static_cast<std::uint32_t>(U16(p)) << 16) | U16(p + 2);
}
inline std::uint64_t U64(const std::uint8_t* p) {
  return (static_cast<std::uint64_t>(U32(p)) << 32) | U32(p + 4);
}

enum class Protocol : std::uint8_t { kAndroidAuto = 1, kCarPlay = 2 };
enum class Plane : std::uint8_t { kMain = 1, kCluster = 2 };
enum class Codec : std::uint8_t { kH264 = 1, kH265 = 2 };
enum class Color : std::uint8_t { kBt601 = 1, kBt709 = 2 };
enum class Range : std::uint8_t { kLimited = 1, kFull = 2 };
enum class Framing : std::uint8_t { kAnnexB = 1, kLengthPrefixed = 2 };
enum class Kind : std::uint8_t { kDescription = 1, kConfig = 2, kAccessUnit = 3 };

struct Description {
  Protocol protocol{};
  Plane plane{};
  Codec codec{};
  Color color{};
  Range range{};
  Framing framing{};
  std::uint16_t width = 0, height = 0, fps_num = 0, fps_den = 0;
  std::uint64_t session = 0;
  bool operator==(const Description&) const = default;
};

inline bool ParseDescription(std::span<const std::uint8_t> bytes,
                             Description& out) {
  if (bytes.size() != kDescriptionSize) return false;
  const auto* p = bytes.data();
  // All current enums are closed, explicitly numbered 1 and 2.
  for (std::size_t i = 0; i < 6; ++i) {
    if (p[i] < 1 || p[i] > 2) return false;
  }
  Description d{static_cast<Protocol>(p[0]), static_cast<Plane>(p[1]),
                static_cast<Codec>(p[2]), static_cast<Color>(p[3]),
                static_cast<Range>(p[4]), static_cast<Framing>(p[5]),
                U16(p + 6), U16(p + 8), U16(p + 10), U16(p + 12),
                U64(p + 16)};
  if (U16(p + 14) != 0 || d.session == 0 || d.width == 0 ||
      d.width > 1920 || d.height == 0 || d.height > 1080 || d.fps_den == 0 ||
      d.fps_den > 1001 || d.fps_num < d.fps_den ||
      d.fps_num > 60U * d.fps_den) return false;
  out = d;
  return true;
}

struct ViewParameters {
  Description description;
  std::uint16_t left = 0, top = 0, right = 0, bottom = 0;
};

inline bool ParseViewParameters(std::span<const std::uint8_t> bytes,
                                ViewParameters& out) {
  if (bytes.size() != 40 || bytes[0] != 'A' || bytes[1] != 'R' ||
      bytes[2] != 'V' || bytes[3] != '2' || U32(bytes.data() + 4) != 1) return false;
  ViewParameters p;
  if (!ParseDescription(bytes.subspan(8, kDescriptionSize), p.description) ||
      p.description.plane != Plane::kMain) return false;
  p.left = U16(bytes.data() + 32);
  p.top = U16(bytes.data() + 34);
  p.right = U16(bytes.data() + 36);
  p.bottom = U16(bytes.data() + 38);
  if (p.left + p.right >= p.description.width || p.top + p.bottom >= p.description.height) return false;
  out = p;
  return true;
}

struct Header {
  Kind kind{};
  std::uint8_t flags = 0;
  std::uint32_t size = 0, sequence = 0;
  std::uint64_t timestamp_ns = 0;
};

// Validate allocation limits before any payload allocation/read.
inline bool ParseHeader(std::span<const std::uint8_t> bytes, Header& out) {
  if (bytes.size() != kHeaderSize) return false;
  const auto* p = bytes.data();
  if (p[0] != 'A' || p[1] != 'R' || p[2] != 'P' || p[3] != 'M' ||
      U16(p + 4) != 1 || p[6] < 1 || p[6] > 3) return false;
  Header h{static_cast<Kind>(p[6]), p[7], U32(p + 8), U32(p + 12), U64(p + 16)};
  if (h.kind == Kind::kAccessUnit) {
    if ((h.flags & ~3U) != 0 || h.size == 0 || h.size > kAccessUnitLimit ||
        h.timestamp_ns == std::numeric_limits<std::uint64_t>::max()) return false;
  } else {
    if (h.flags != 0 || h.timestamp_ns != 0) return false;
    if (h.kind == Kind::kDescription && h.size != kDescriptionSize) return false;
    if (h.kind == Kind::kConfig && (h.size == 0 || h.size > kConfigLimit)) return false;
  }
  out = h;
  return true;
}

inline std::size_t StartCode(std::span<const std::uint8_t> bytes,
                             std::size_t i) {
  if (i + 3 > bytes.size() || bytes[i] != 0 || bytes[i + 1] != 0) return 0;
  if (bytes[i + 2] == 1) return 3;
  return i + 4 <= bytes.size() && bytes[i + 2] == 0 && bytes[i + 3] == 1 ? 4 : 0;
}

inline bool NalType(std::span<const std::uint8_t> nal, Codec codec,
                    std::uint8_t& type) {
  if (nal.empty() || (nal[0] & 0x80) != 0) return false;
  if (codec == Codec::kH264) {
    type = nal[0] & 0x1f;
    return type != 0 && type < 24;
  }
  if (nal.size() < 2 || (nal[1] & 7) == 0) return false;
  type = (nal[0] >> 1) & 0x3f;
  return type < 48;
}

inline unsigned ParameterBit(Codec codec, std::uint8_t type) {
  if (codec == Codec::kH264) return type == 7 ? 1 : type == 8 ? 2 : 0;
  return type == 32 ? 1 : type == 33 ? 2 : type == 34 ? 4 : 0;
}

inline bool InspectNals(std::span<const std::uint8_t> bytes, Codec codec,
                        Framing framing, unsigned length_bytes, bool config) {
  unsigned parameters = 0;
  std::size_t offset = 0, count = 0;
  while (offset < bytes.size()) {
    if (++count > kNalLimit) return false;
    std::size_t size = 0;
    if (framing == Framing::kAnnexB) {
      const auto prefix = StartCode(bytes, offset);
      if (prefix == 0) return false;
      offset += prefix;
      std::size_t end = offset;
      while (end < bytes.size() && StartCode(bytes, end) == 0) ++end;
      size = end - offset;
    } else {
      if (length_bytes < 1 || length_bytes > 4 || bytes.size() - offset < length_bytes) return false;
      for (unsigned i = 0; i < length_bytes; ++i) size = (size << 8) | bytes[offset++];
      if (size > bytes.size() - offset) return false;
    }
    std::uint8_t type = 0;
    if (!NalType(bytes.subspan(offset, size), codec, type)) return false;
    const unsigned bit = ParameterBit(codec, type);
    if (config && bit == 0) return false;
    parameters |= bit;
    offset += size;
  }
  return count != 0 && (!config || parameters == (codec == Codec::kH264 ? 3U : 7U));
}

// AVCDecoderConfigurationRecord / HEVCDecoderConfigurationRecord structural
// checks. No pixel or SPS decoding occurs here; GStreamer parses codec syntax.
inline bool ParseCodecConfig(std::span<const std::uint8_t> bytes, Codec codec,
                              unsigned& length_bytes) {
  const std::size_t minimum = codec == Codec::kH264 ? 7 : 23;
  if (bytes.size() < minimum || bytes[0] != 1) return false;
  std::size_t offset = codec == Codec::kH264 ? 6 : 23;
  unsigned parameters = 0;
  std::size_t count = 0;
  auto take = [&](unsigned nals, int expected_type) {
    for (unsigned i = 0; i < nals; ++i) {
      if (++count > kNalLimit || bytes.size() - offset < 2) return false;
      const std::size_t size = U16(bytes.data() + offset);
      offset += 2;
      if (size > bytes.size() - offset) return false;
      std::uint8_t type = 0;
      if (!NalType(bytes.subspan(offset, size), codec, type) || type != expected_type) return false;
      parameters |= ParameterBit(codec, type);
      offset += size;
    }
    return true;
  };
  if (codec == Codec::kH264) {
    if ((bytes[4] & 0xfc) != 0xfc || (bytes[5] & 0xe0) != 0xe0) return false;
    length_bytes = (bytes[4] & 3) + 1;
    if (length_bytes == 3 || !take(bytes[5] & 31, 7) || offset == bytes.size()) return false;
    const unsigned pps_count = bytes[offset++];
    if (!take(pps_count, 8)) return false;
    // High-profile avcC records may include chroma/bit-depth and SPS extensions.
    if (offset < bytes.size()) {
      const auto profile = bytes[1];
      if ((profile != 100 && profile != 110 && profile != 122 && profile != 144) ||
          bytes.size() - offset < 4 || (bytes[offset] & 0xfc) != 0xfc ||
          (bytes[offset + 1] & 0xf8) != 0xf8 || (bytes[offset + 2] & 0xf8) != 0xf8) return false;
      offset += 3;
      const unsigned extension_count = bytes[offset++];
      if (!take(extension_count, 13)) return false;
    }
  } else {
    length_bytes = (bytes[21] & 3) + 1;
    if (length_bytes == 3) return false;
    for (unsigned i = 0; i < bytes[22]; ++i) {
      if (bytes.size() - offset < 3 || (bytes[offset] & 0x40) != 0) return false;
      const auto type = bytes[offset++] & 0x3f;
      const unsigned nals = U16(bytes.data() + offset);
      offset += 2;
      if (!take(nals, type)) return false;
    }
  }
  return offset == bytes.size() && parameters == (codec == Codec::kH264 ? 3U : 7U);
}

class Validator {
 public:
  explicit Validator(Description expected) : expected_(expected) {}

  bool Accept(const Header& h, std::span<const std::uint8_t> payload) {
    if (failed_ || exhausted_ || h.sequence != next_sequence_ || payload.size() != h.size) return Fail();
    if (!described_) {
      Description actual;
      if (h.kind != Kind::kDescription || !ParseDescription(payload, actual) || actual != expected_) return Fail();
      described_ = true;
    } else if (h.kind == Kind::kConfig) {
      if (configured_ || seen_frame_) return Fail();
      if (expected_.framing == Framing::kAnnexB) {
        if (!InspectNals(payload, expected_.codec, expected_.framing, 0, true)) return Fail();
      } else if (!ParseCodecConfig(payload, expected_.codec, length_bytes_)) return Fail();
      configured_ = true;
    } else if (h.kind == Kind::kAccessUnit) {
      if (!configured_ || ((!seen_frame_ || (h.flags & 2) != 0) && (h.flags & 1) == 0) ||
          (seen_frame_ && h.timestamp_ns < last_timestamp_) ||
          !InspectNals(payload, expected_.codec, expected_.framing, length_bytes_, false)) return Fail();
      seen_frame_ = true;
      last_timestamp_ = h.timestamp_ns;
    } else return Fail();
    exhausted_ = next_sequence_ == std::numeric_limits<std::uint32_t>::max();
    ++next_sequence_;
    return true;
  }

 private:
  bool Fail() { failed_ = true; return false; }
  Description expected_;
  std::uint32_t next_sequence_ = 0;
  unsigned length_bytes_ = 0;
  std::uint64_t last_timestamp_ = 0;
  bool described_ = false, configured_ = false, seen_frame_ = false;
  bool exhausted_ = false, failed_ = false;
};

}  // namespace argo::media
