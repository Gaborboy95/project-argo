#include "../src/media_contract.h"
#include "../src/media_io.h"
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <thread>
#include <vector>
#include <unistd.h>

using namespace argo::media;
#define CHECK(value) do { if (!(value)) { std::fprintf(stderr, "line %d: %s\n", __LINE__, #value); return EXIT_FAILURE; } } while (false)

// Synthetic protocol records, not copied codec bitstreams or private phone data.
std::array<std::uint8_t, 24> DescriptionBytes() {
  return {2, 1, 1, 2, 2, 2, 5, 0, 2, 208, 0, 60, 0, 1, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 42};
}

int main(int argc, char** argv) {
  const auto bytes = DescriptionBytes();
  Description d;
  CHECK(ParseDescription(bytes, d));
  CHECK(argc == 2);
  std::ifstream fixture(argv[1]);
  CHECK(fixture.good());
  std::vector<std::uint8_t> wire_fixture;
  unsigned value;
  while (fixture >> std::hex >> value) {
    CHECK(value <= 255);
    wire_fixture.push_back(static_cast<std::uint8_t>(value));
  }
  Validator fixture_validator(d);
  std::size_t fixture_offset = 0, fixture_records = 0;
  while (fixture_offset < wire_fixture.size()) {
    CHECK(wire_fixture.size() - fixture_offset >= kHeaderSize);
    Header record;
    CHECK(ParseHeader(std::span(wire_fixture).subspan(fixture_offset, kHeaderSize), record));
    fixture_offset += kHeaderSize;
    CHECK(record.size <= wire_fixture.size() - fixture_offset);
    CHECK(fixture_validator.Accept(record, std::span(wire_fixture).subspan(fixture_offset, record.size)));
    fixture_offset += record.size;
    ++fixture_records;
  }
  CHECK(fixture_records == 3);
  CHECK(d.width == 1280 && d.height == 720 && d.session == 42 && d.range == Range::kFull);
  for (std::size_t i = 0; i < bytes.size(); ++i) CHECK(!ParseDescription(std::span(bytes).first(i), d));
  for (std::size_t i = 0; i < 6; ++i) {
    auto bad = bytes; bad[i] = 0; CHECK(!ParseDescription(bad, d));
    bad[i] = 3; CHECK(!ParseDescription(bad, d));
  }
  for (const auto index : {6, 8, 14}) {
    auto bad = bytes; bad[index] = 255; CHECK(!ParseDescription(bad, d));
  }
  auto bad = bytes; bad[23] = 0; CHECK(!ParseDescription(bad, d));
  bad = bytes; bad[11] = 61; CHECK(!ParseDescription(bad, d));
  bad = bytes; bad[13] = 0; CHECK(!ParseDescription(bad, d));
  CHECK(ParseDescription(bytes, d));

  std::array<std::uint8_t, 40> create{'A', 'R', 'V', '2', 0, 0, 0, 1};
  std::copy(bytes.begin(), bytes.end(), create.begin() + 8);
  ViewParameters view;
  CHECK(ParseViewParameters(create, view));
  create[9] = 2; CHECK(!ParseViewParameters(create, view)); create[9] = 1;
  create[32] = 5; CHECK(!ParseViewParameters(create, view)); create[32] = 0;
  create[7] = 2; CHECK(!ParseViewParameters(create, view));

  std::array<std::uint8_t, 24> header{'A', 'R', 'P', 'M', 0, 1, 1, 0, 0, 0, 0, 24};
  Header h;
  CHECK(ParseHeader(header, h));
  CHECK(h.kind == Kind::kDescription && h.size == 24 && h.sequence == 0);
  for (std::size_t i = 0; i < header.size(); ++i) CHECK(!ParseHeader(std::span(header).first(i), h));
  auto bad_header = header; bad_header[5] = 2; CHECK(!ParseHeader(bad_header, h));
  bad_header = header; bad_header[7] = 1; CHECK(!ParseHeader(bad_header, h));
  bad_header = header; bad_header[23] = 1; CHECK(!ParseHeader(bad_header, h));
  header[6] = 2; header[9] = 1; header[11] = 1; CHECK(!ParseHeader(header, h));
  header[6] = 3; header[9] = 0x40; header[11] = 0; CHECK(ParseHeader(header, h));
  header[11] = 1; CHECK(!ParseHeader(header, h));
  header[11] = 0; header[7] = 4; CHECK(!ParseHeader(header, h));

  const std::vector<std::uint8_t> avcc{1, 66, 0, 30, 255, 225, 0, 2, 0x67, 1, 1, 0, 2, 0x68, 1};
  const std::vector<std::uint8_t> avc_frame{0, 0, 0, 2, 0x65, 1};
  unsigned length = 0;
  CHECK(ParseCodecConfig(avcc, Codec::kH264, length) && length == 4);
  for (std::size_t i = 0; i < avcc.size(); ++i) CHECK(!ParseCodecConfig(std::span(avcc).first(i), Codec::kH264, length));
  auto bad_config = avcc; bad_config[4] = 254; CHECK(!ParseCodecConfig(bad_config, Codec::kH264, length));
  bad_config = avcc; bad_config[7] = 255; CHECK(!ParseCodecConfig(bad_config, Codec::kH264, length));
  CHECK(!ParseCodecConfig(avcc, Codec::kH265, length));
  CHECK(InspectNals(avc_frame, Codec::kH264, Framing::kLengthPrefixed, 4, false));
  for (std::size_t i = 0; i < avc_frame.size(); ++i) CHECK(!InspectNals(std::span(avc_frame).first(i), Codec::kH264, Framing::kLengthPrefixed, 4, false));
  const std::vector<std::uint8_t> annex_config{0, 0, 0, 1, 0x67, 1, 0, 0, 1, 0x68, 1};
  CHECK(InspectNals(annex_config, Codec::kH264, Framing::kAnnexB, 0, true));
  CHECK(!InspectNals(std::span(annex_config).first(6), Codec::kH264, Framing::kAnnexB, 0, true));
  std::vector<std::uint8_t> too_many;
  for (unsigned i = 0; i <= kNalLimit; ++i) too_many.insert(too_many.end(), {0, 0, 1, 0x65});
  CHECK(!InspectNals(too_many, Codec::kH264, Framing::kAnnexB, 0, false));

  std::vector<std::uint8_t> hvcc(23, 0);
  hvcc[0] = 1; hvcc[21] = 3; hvcc[22] = 3;
  for (std::uint8_t type : {32, 33, 34}) hvcc.insert(hvcc.end(), {type, 0, 1, 0, 2, static_cast<std::uint8_t>(type << 1), 1});
  CHECK(ParseCodecConfig(hvcc, Codec::kH265, length) && length == 4);
  for (std::size_t i = 0; i < hvcc.size(); ++i) CHECK(!ParseCodecConfig(std::span(hvcc).first(i), Codec::kH265, length));
  bad_config = hvcc; bad_config.back() = 0; CHECK(!ParseCodecConfig(bad_config, Codec::kH265, length));

  Validator validator(d);
  CHECK(validator.Accept({Kind::kDescription, 0, 24, 0, 0}, bytes));
  CHECK(validator.Accept({Kind::kConfig, 0, static_cast<std::uint32_t>(avcc.size()), 1, 0}, avcc));
  CHECK(validator.Accept({Kind::kAccessUnit, 1, 6, 2, 100}, avc_frame));
  CHECK(validator.Accept({Kind::kAccessUnit, 0, 6, 3, 200}, avc_frame));
  CHECK(!validator.Accept({Kind::kAccessUnit, 0, 6, 4, 199}, avc_frame));
  CHECK(!validator.Accept({Kind::kAccessUnit, 1, 6, 4, 300}, avc_frame));
  Validator no_config(d);
  CHECK(no_config.Accept({Kind::kDescription, 0, 24, 0, 0}, bytes));
  CHECK(!no_config.Accept({Kind::kAccessUnit, 1, 6, 1, 100}, avc_frame));
  Validator stale(d);
  auto stale_description = bytes; stale_description[23] = 43;
  CHECK(!stale.Accept({Kind::kDescription, 0, 24, 0, 0}, stale_description));
  Validator sequence(d);
  CHECK(!sequence.Accept({Kind::kDescription, 0, 24, 1, 0}, bytes));
  Validator first_delta(d);
  CHECK(first_delta.Accept({Kind::kDescription, 0, 24, 0, 0}, bytes));
  CHECK(first_delta.Accept({Kind::kConfig, 0, static_cast<std::uint32_t>(avcc.size()), 1, 0}, avcc));
  CHECK(!first_delta.Accept({Kind::kAccessUnit, 0, 6, 2, 100}, avc_frame));

  int sockets[2];
  CHECK(socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sockets) == 0);
  std::atomic<bool> stop{false};
  RecordReader reader(sockets[0], stop, std::chrono::milliseconds(50));
  std::array<std::uint8_t, 4> received{};
  const std::array<std::uint8_t, 4> sent{1, 2, 3, 4};
  reader.BeginRecord(true);
  CHECK(!reader.Read(received));  // Silent startup is bounded too.
  std::thread fragmented([&] {
    send(sockets[1], sent.data(), 1, MSG_NOSIGNAL);
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
    send(sockets[1], sent.data() + 1, 3, MSG_NOSIGNAL);
  });
  reader.BeginRecord();
  const bool read_fragmented = reader.Read(received);
  fragmented.join();
  CHECK(read_fragmented && received == sent);
  reader.BeginRecord();
  CHECK(send(sockets[1], sent.data(), 1, MSG_NOSIGNAL) == 1);
  CHECK(!reader.Read(received));  // Partial-record timeout.
  reader.BeginRecord();
  shutdown(sockets[1], SHUT_RDWR);
  CHECK(!reader.Read(received));  // Truncated/closed peer.
  close(sockets[0]); close(sockets[1]);
  CHECK(socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sockets) == 0);
  RecordReader idle(sockets[0], stop);
  std::thread cancel([&] { std::this_thread::sleep_for(std::chrono::milliseconds(5)); stop = true; });
  const bool idle_result = idle.Read(received);
  cancel.join();
  CHECK(!idle_result);
  close(sockets[0]); close(sockets[1]);
  return EXIT_SUCCESS;
}
