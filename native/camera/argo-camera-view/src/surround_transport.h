#pragma once
#include "contract.h"
#include <rapidjson/document.h>
#include <array>
#include <fcntl.h>
#include <poll.h>
#include <string>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
namespace surround {
constexpr std::size_t kMaxMessage = 65536, kMaxAllocation = 64 * 1024 * 1024;
inline bool Transfer(int fd, void *data, std::size_t size, bool write) {
  auto *bytes = static_cast<std::uint8_t *>(data);
  while (size) {
    const auto count = write ? send(fd, bytes, size, MSG_NOSIGNAL) : recv(fd, bytes, size, 0);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) return false;
    bytes += count; size -= count;
  }
  return true;
}
inline bool Send(int fd, const std::string &body) {
  if (body.empty() || body.size() > kMaxMessage) return false;
  std::array<std::uint8_t, 4> size{
    static_cast<std::uint8_t>(body.size() >> 24), static_cast<std::uint8_t>(body.size() >> 16),
    static_cast<std::uint8_t>(body.size() >> 8), static_cast<std::uint8_t>(body.size())};
  return Transfer(fd, size.data(), size.size(), true) &&
    Transfer(fd, const_cast<char *>(body.data()), body.size(), true);
}
inline bool Receive(int fd, rapidjson::Document &value) {
  std::array<std::uint8_t, 4> prefix{};
  if (!Transfer(fd, prefix.data(), prefix.size(), false)) return false;
  const std::uint32_t size = (prefix[0] << 24) | (prefix[1] << 16) | (prefix[2] << 8) | prefix[3];
  if (size == 0 || size > kMaxMessage) return false;
  std::string body(size, '\0');
  if (!Transfer(fd, body.data(), size, false)) return false;
  value.Parse(body.data(), body.size());
  return !value.HasParseError() && value.IsObject() && value.HasMember("major") &&
    value["major"].IsInt() && value["major"].GetInt() == 1;
}
inline bool Unsigned(const rapidjson::Value &v, const char *key, std::uint64_t &out) {
  if (!v.IsObject() || !v.HasMember(key) || !v[key].IsUint64()) return false;
  out = v[key].GetUint64(); return true;
}
inline bool Layout(const rapidjson::Value &value, camera::Frame &frame,
                   std::uint64_t &generation, std::uint64_t &allocation,
                   std::uint64_t &offset, std::uint64_t now) {
  std::uint64_t width, height, stride, plane_size;
  if (!value.IsObject() || !value.HasMember("format") || !value["format"].IsString() ||
      std::string(value["format"].GetString()) != "BGRx" ||
      !Unsigned(value, "width", width) || !Unsigned(value, "height", height) ||
      !Unsigned(value, "generation", generation) || !Unsigned(value, "sequence", frame.sequence) ||
      !Unsigned(value, "capture_ns", frame.time) || !Unsigned(value, "allocation_size", allocation) ||
      !value.HasMember("planes") || !value["planes"].IsArray() || value["planes"].Size() != 1)
    return false;
  const auto &plane = value["planes"][0];
  if (!Unsigned(plane, "offset", offset) || !Unsigned(plane, "stride", stride) ||
      !Unsigned(plane, "size", plane_size) || width == 0 || height == 0 ||
      width > 8192 || height > 8192 || stride < width * 4 ||
      allocation == 0 || allocation > kMaxAllocation || offset > allocation ||
      plane_size > allocation - offset || stride > plane_size / height ||
      frame.time > now || now - frame.time >= camera::kStaleNs) return false;
  frame.width = width; frame.height = height; frame.stride = stride;
  return true;
}
inline int Descriptor(int fd) {
  char byte = 0;
  iovec iov{&byte, 1};
  alignas(cmsghdr) char control[CMSG_SPACE(8 * sizeof(int))]{};
  msghdr msg{};
  msg.msg_iov = &iov; msg.msg_iovlen = 1;
  msg.msg_control = control; msg.msg_controllen = sizeof(control);
  const auto received = recvmsg(fd, &msg, MSG_CMSG_CLOEXEC);
  std::vector<int> descriptors;
  for (auto *c = CMSG_FIRSTHDR(&msg); c; c = CMSG_NXTHDR(&msg, c)) {
    if (c->cmsg_level != SOL_SOCKET || c->cmsg_type != SCM_RIGHTS || c->cmsg_len < CMSG_LEN(0)) continue;
    const auto count = (c->cmsg_len - CMSG_LEN(0)) / sizeof(int);
    for (std::size_t i = 0; i < count; ++i) {
      int descriptor; std::memcpy(&descriptor, CMSG_DATA(c) + i * sizeof(int), sizeof(int));
      descriptors.push_back(descriptor);
    }
  }
  if (received != 1 || byte != 0x46 || msg.msg_flags & (MSG_CTRUNC | MSG_TRUNC) || descriptors.size() != 1) {
    for (int descriptor : descriptors) close(descriptor);
    return -1;
  }
  return descriptors[0];
}
} // namespace surround
