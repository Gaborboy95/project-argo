#pragma once

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <poll.h>
#include <span>
#include <sys/socket.h>

namespace argo::media {

// Idle sessions may stay connected, including while the view is hidden. Once a
// record begins, its entire header and body must arrive within the same deadline.
// shutdown(fd) interrupts the reader; polling also observes teardown every 100 ms.
class RecordReader {
 public:
  RecordReader(int fd, const std::atomic<bool>& stop,
               std::chrono::milliseconds timeout = std::chrono::seconds(2))
      : fd_(fd), stop_(stop), timeout_(timeout) {}

  void BeginRecord(bool required = false) {
    started_ = required;
    if (required) deadline_ = std::chrono::steady_clock::now() + timeout_;
  }

  bool Read(std::span<std::uint8_t> destination) {
    std::size_t offset = 0;
    while (offset < destination.size() && !stop_.load()) {
      int wait_ms = 100;
      if (started_) {
        const auto left = std::chrono::duration_cast<std::chrono::milliseconds>(
            deadline_ - std::chrono::steady_clock::now()).count();
        if (left <= 0) return false;
        wait_ms = static_cast<int>(std::min<std::int64_t>(left, wait_ms));
      }
      pollfd item{fd_, POLLIN, 0};
      const int ready = poll(&item, 1, wait_ms);
      if (ready < 0) { if (errno == EINTR) continue; return false; }
      if (ready == 0) continue;
      if ((item.revents & (POLLERR | POLLNVAL)) != 0) return false;
      const auto size = recv(fd_, destination.data() + offset,
                             destination.size() - offset, MSG_DONTWAIT);
      if (size < 0) {
        if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) continue;
        return false;
      }
      if (size == 0) return false;
      if (!started_) {
        started_ = true;
        deadline_ = std::chrono::steady_clock::now() + timeout_;
      }
      offset += static_cast<std::size_t>(size);
    }
    return offset == destination.size() && !stop_.load();
  }

 private:
  int fd_;
  const std::atomic<bool>& stop_;
  std::chrono::milliseconds timeout_;
  bool started_ = false;
  std::chrono::steady_clock::time_point deadline_;
};

}  // namespace argo::media
