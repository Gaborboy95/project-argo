#include "contract.h"
#include "surround_transport.h"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <gbm.h>
#include <gst/app/gstappsink.h>
#include <gst/video/video.h>
#include <ihs/platform_view.h>
#include <mutex>
#include <poll.h>
#include <string>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <thread>
#include <time.h>
#include <unistd.h>
#include <vulkan/vulkan.h>
namespace {
constexpr const char *kType = "argo.camera.view";
constexpr const char *kSurroundType = "argo.surround.view";
std::atomic<std::uint32_t> selected_role{0};
struct PresentedImage { std::string path; std::uint64_t capture_ns = 0, revision = 0; bool replay = false; };
std::mutex image_mutex;
PresentedImage selected_image;
bool DecodeImage(const std::string &path, camera::Frame &frame) {
  GError *error = nullptr;
  GstElement *pipeline = gst_parse_launch("filesrc name=source ! decodebin ! videoconvert ! video/x-raw,format=BGRx ! appsink name=sink sync=false max-buffers=1 drop=true", &error);
  if (!pipeline || error) { if (error) g_error_free(error); if (pipeline) gst_object_unref(pipeline); return false; }
  GstElement *source = gst_bin_get_by_name(GST_BIN(pipeline), "source");
  GstElement *sink = gst_bin_get_by_name(GST_BIN(pipeline), "sink");
  g_object_set(source, "location", path.c_str(), nullptr);
  gst_element_set_state(pipeline, GST_STATE_PLAYING);
  GstSample *sample = gst_app_sink_try_pull_sample(GST_APP_SINK(sink), 500 * GST_MSECOND);
  GstVideoInfo info{}; GstVideoFrame mapped{};
  bool success = false;
  if (sample && gst_video_info_from_caps(&info, gst_sample_get_caps(sample)) &&
      info.width > 0 && info.height > 0 && info.width <= 8192 && info.height <= 8192 &&
      info.stride[0] >= info.width * 4 && info.size <= surround::kMaxAllocation &&
      gst_video_frame_map(&mapped, &info, gst_sample_get_buffer(sample), GST_MAP_READ)) {
    frame.width = info.width; frame.height = info.height; frame.stride = info.width * 4;
    frame.pixels.resize(static_cast<std::size_t>(frame.stride) * frame.height);
    const auto *data = static_cast<const std::uint8_t *>(GST_VIDEO_FRAME_PLANE_DATA(&mapped, 0));
    for (std::uint32_t row = 0; row < frame.height; ++row)
      std::memcpy(frame.pixels.data() + row * frame.stride, data + row * info.stride[0], frame.stride);
    gst_video_frame_unmap(&mapped); success = true;
  }
  if (sample) gst_sample_unref(sample);
  gst_element_set_state(pipeline, GST_STATE_NULL);
  gst_object_unref(source); gst_object_unref(sink); gst_object_unref(pipeline);
  return success;
}
std::uint64_t Now() {
  timespec t{};
  clock_gettime(CLOCK_MONOTONIC, &t);
  return static_cast<std::uint64_t>(t.tv_sec) * 1000000000 + t.tv_nsec;
}
struct View {
  double width = 0, height = 0;
  std::uint32_t role = 0;
  bool external = false;
  IhsPlatformView *view = nullptr;
  IhsPvGrant grant{};
  gbm_device *allocator = nullptr;
  int allocator_fd = -1;
  bool owns_allocator = false;
  std::mutex mutex;
  bool suspended = false;
  std::atomic<bool> stopping{false}, refresh{true};
  std::thread worker;
  bool submit_failed = false;
  ~View() {
    stopping = true;
    if (worker.joinable())
      worker.join();
    if (owns_allocator && allocator)
      gbm_device_destroy(allocator);
    if (allocator_fd >= 0)
      close(allocator_fd);
  }
  bool FindAllocator() {
    if (allocator != nullptr)
      return true;

    IhsEglContext context{};
    context.struct_size = sizeof(context);
    if (ihs_pv_egl_context(&context) != IHS_PV_OK)
      return FindVulkanAllocator();
    if (context.gbm_device != nullptr) {
      allocator = static_cast<gbm_device *>(context.gbm_device);
      return true;
    }
    // Resolve the render node belonging to the advertised EGL display. No
    // backend-name switch, guessed /dev/dri/cardN, or private IHS object.
    auto query_display = reinterpret_cast<PFNEGLQUERYDISPLAYATTRIBEXTPROC>(
        eglGetProcAddress("eglQueryDisplayAttribEXT"));
    auto query_device = reinterpret_cast<PFNEGLQUERYDEVICESTRINGEXTPROC>(
        eglGetProcAddress("eglQueryDeviceStringEXT"));
    EGLAttrib device = 0;
    if (!query_display || !query_device ||
        !query_display(context.egl_display, EGL_DEVICE_EXT, &device))
      return false;
    const char *node = query_device(reinterpret_cast<EGLDeviceEXT>(device),
                                    EGL_DRM_RENDER_NODE_FILE_EXT);
    if (node == nullptr)
      return false;
    allocator_fd = open(node, O_RDWR | O_CLOEXEC);
    if (allocator_fd < 0)
      return false;
    allocator = gbm_create_device(allocator_fd);
    owns_allocator = allocator != nullptr;
    return owns_allocator;
  }

  bool FindVulkanAllocator() {
    IhsVulkanContext context{};
    context.struct_size = sizeof(context);
    if (ihs_pv_vulkan_context(&context) != IHS_PV_OK ||
        context.get_instance_proc_addr == nullptr)
      return false;
    auto get = reinterpret_cast<PFN_vkGetInstanceProcAddr>(
        context.get_instance_proc_addr);
    auto instance = static_cast<VkInstance>(context.instance);
    auto physical = static_cast<VkPhysicalDevice>(context.physical_device);
    auto enumerate = reinterpret_cast<PFN_vkEnumerateDeviceExtensionProperties>(
        get(instance, "vkEnumerateDeviceExtensionProperties"));
    auto properties = reinterpret_cast<PFN_vkGetPhysicalDeviceProperties2>(
        get(instance, "vkGetPhysicalDeviceProperties2"));
    if (!enumerate || !properties)
      return false;
    std::uint32_t count = 0;
    if (enumerate(physical, nullptr, &count, nullptr) != VK_SUCCESS ||
        count > 4096)
      return false;
    std::vector<VkExtensionProperties> extensions(count);
    if (enumerate(physical, nullptr, &count, extensions.data()) != VK_SUCCESS)
      return false;
    bool supported = false;
    for (const auto &extension : extensions)
      supported |= std::strcmp(extension.extensionName,
                               VK_EXT_PHYSICAL_DEVICE_DRM_EXTENSION_NAME) == 0;
    if (!supported)
      return false;
    VkPhysicalDeviceDrmPropertiesEXT drm{};
    drm.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRM_PROPERTIES_EXT;
    VkPhysicalDeviceProperties2 info{};
    info.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2;
    info.pNext = &drm;
    properties(physical, &info);
    if (!drm.hasRender)
      return false;
    const std::string node = "/dev/char/" + std::to_string(drm.renderMajor) +
                             ":" + std::to_string(drm.renderMinor);
    allocator_fd = open(node.c_str(), O_RDWR | O_CLOEXEC);
    if (allocator_fd < 0)
      return false;
    allocator = gbm_create_device(allocator_fd);
    owns_allocator = allocator != nullptr;
    return owns_allocator;
  }

  bool Negotiate() {
    if (!FindAllocator())
      return false;
    IhsPvCapabilities caps{};
    caps.struct_size = sizeof(caps);
    if (ihs_pv_query_capabilities(&caps) != IHS_PV_OK)
      return false;
    bool format_ok = false;
    for (std::size_t i = 0; i < caps.format_count; ++i)
      format_ok |= caps.formats[i].fourcc == GBM_FORMAT_XRGB8888 &&
                   caps.formats[i].modifier == 0;
    if (!format_ok)
      return false;
    const auto kind =
        (caps.kinds & IHS_PV_KIND_TEXTURE_DMABUF_IMPORT)
            ? IHS_PV_KIND_TEXTURE_DMABUF_IMPORT
            : ((caps.kinds & IHS_PV_KIND_DRM_PLANE) ? IHS_PV_KIND_DRM_PLANE
                                                    : 0);
    if (!kind)
      return false;
    IhsFormatModifier format{GBM_FORMAT_XRGB8888, 0, 0};
    IhsPvRequirements req{};
    req.struct_size = sizeof(req);
    req.kinds = kind;
    req.formats = &format;
    req.format_count = 1;
    req.sync = IHS_PV_SYNC_IMPLICIT;
    req.z_order = IHS_PV_Z_INLINE;
    grant = {};
    grant.struct_size = sizeof(grant);
    return ihs_pv_negotiate(view, &req, &grant) == IHS_PV_OK;
  }
  bool Submit(const camera::Frame &f, bool blank = false) {
    std::lock_guard lock(mutex);
    if (suspended)
      return true;
    // Metadata and resize notifications can trail a new native frame. Blank
    // until Flutter has fitted its viewport; never briefly stretch a new mode.
    const auto fit = camera::AspectFit(width, height, f.width, f.height);
    if (!blank &&
        (std::abs(fit.width - width) > 1 || std::abs(fit.height - height) > 1))
      return false;
    gbm_bo *bo = gbm_bo_create(allocator, f.width, f.height,
                               GBM_FORMAT_XRGB8888, GBM_BO_USE_LINEAR);
    if (!bo)
      return false;
    std::uint32_t stride = 0;
    void *token = nullptr;
    void *mapped = gbm_bo_map(bo, 0, 0, f.width, f.height,
                              GBM_BO_TRANSFER_WRITE, &stride, &token);
    const auto modifier = gbm_bo_get_modifier(bo);
    if (!mapped || stride < f.width * 4 ||
        (modifier != 0 && modifier != 0x00ffffffffffffffULL)) {
      if (mapped)
        gbm_bo_unmap(bo, token);
      gbm_bo_destroy(bo);
      return false;
    }
    for (std::uint32_t y = 0; y < f.height; ++y)
      std::memcpy(static_cast<std::uint8_t *>(mapped) + y * stride,
                  f.pixels.data() + y * f.stride, f.width * 4);
    gbm_bo_unmap(bo, token);
    int fd = gbm_bo_get_fd(bo);
    if (fd < 0) {
      gbm_bo_destroy(bo);
      return false;
    }
    IhsFrame frame{};
    frame.struct_size = offsetof(IhsFrame, buffer_id);
    frame.format = grant.format;
    frame.format.modifier = modifier;
    frame.width = f.width;
    frame.height = f.height;
    frame.plane_count = 1;
    frame.plane_fd[0] = fd;
    frame.plane_stride[0] = gbm_bo_get_stride(bo);
    int release = -1;
    const int result = ihs_pv_submit(view, &frame, -1, &release);
    if (release >= 0)
      close(release);
    gbm_bo_destroy(bo);
    if (result != IHS_PV_OK && !submit_failed) {
      std::fprintf(stderr, "Camera native submission failed: %d\n", result);
      submit_failed = true;
    }
    return result == IHS_PV_OK;
  }
  void RunExternal() {
    int socket = -1;
    bool black = false;
    std::uint64_t presented = 0;
    std::uint32_t subscribed_role = 99;
    std::uint64_t image_revision = 0;
    camera::Frame cached_image;
    camera::Frame blank;
    blank.width = 16; blank.height = 9; blank.stride = 64; blank.pixels.resize(576);
    auto disconnect = [&] { if (socket >= 0) close(socket); socket = -1; };
    while (!stopping) {
      PresentedImage image;
      { std::lock_guard lock(image_mutex); image = selected_image; }
      if (!image.path.empty()) {
        disconnect();
        if (image.revision != image_revision) {
          if (DecodeImage(image.path, cached_image)) { image_revision = image.revision; black = false; }
          else cached_image.pixels.clear();
        }
        const bool fresh = image.replay || (Now() >= image.capture_ns && Now() - image.capture_ns < camera::kStaleNs);
        if (!cached_image.pixels.empty() && fresh) { if (Submit(cached_image)) black = false; }
        else if (!black) black = Submit(blank, true);
        poll(nullptr, 0, 25);
        continue;
      }
      const auto wanted = selected_role.load();
      if (wanted != subscribed_role) { disconnect(); black = false; presented = 0; }
      if (socket < 0) {
        const char *explicit_runtime = std::getenv("SURROUND_RUNTIME_DIR");
        const char *runtime = std::getenv("XDG_RUNTIME_DIR");
        const std::string path = explicit_runtime ? std::string(explicit_runtime) + "/media.sock" :
          runtime ? std::string(runtime) + "/surround-camera/media.sock" : "";
        sockaddr_un address{}; address.sun_family = AF_UNIX;
        if (!path.empty() && path.size() < sizeof(address.sun_path)) {
          std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
          socket = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
          if (socket >= 0 && connect(socket, reinterpret_cast<sockaddr *>(&address), sizeof(address)) == 0) {
            ucred peer{}; socklen_t length = sizeof(peer);
            if (getsockopt(socket, SOL_SOCKET, SO_PEERCRED, &peer, &length) != 0 || peer.uid != getuid()) {
              disconnect();
            } else {
              fcntl(socket, F_SETFL, fcntl(socket, F_GETFL) & ~O_NONBLOCK);
              timeval timeout{0, 150000};
              setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
              setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
              const char *roles[]{"rear", "front", "left", "right"};
              rapidjson::Document reply;
              const std::string request = "{\"major\":1,\"minor\":0,\"id\":1,\"op\":\"subscribe\",\"args\":{\"role\":\"" +
                std::string(roles[wanted < 4 ? wanted : 0]) + "\",\"formats\":[\"BGRx\"],\"consumer\":\"display\",\"delivery\":\"latest\",\"max_outstanding\":2}}";
              if (!surround::Send(socket, request) || !surround::Receive(socket, reply) ||
                  !reply.HasMember("ok") || !reply["ok"].IsBool() || !reply["ok"].GetBool()) disconnect();
              else subscribed_role = wanted;
            }
          } else disconnect();
        }
      }
      if (socket >= 0) {
        pollfd event{socket, POLLIN | POLLHUP, 0};
        poll(&event, 1, 25);
        if (event.revents & POLLIN) {
          rapidjson::Document message;
          if (!surround::Receive(socket, message) || !message.HasMember("frame")) { disconnect(); }
          else {
            const int memory = surround::Descriptor(socket);
            camera::Frame frame;
            std::uint64_t generation = 0, allocation = 0, offset = 0;
            struct stat info{};
            constexpr int seals = F_SEAL_WRITE | F_SEAL_GROW | F_SEAL_SHRINK | F_SEAL_SEAL;
            const bool valid = memory >= 0 && surround::Layout(message["frame"], frame, generation, allocation, offset, Now()) &&
              fstat(memory, &info) == 0 && info.st_size == static_cast<off_t>(allocation) &&
              (fcntl(memory, F_GET_SEALS) >= 0 && (fcntl(memory, F_GET_SEALS) & seals) == seals);
            if (valid) {
              void *map = mmap(nullptr, allocation, PROT_READ, MAP_SHARED, memory, 0);
              if (map != MAP_FAILED) {
                frame.pixels.resize(static_cast<std::size_t>(frame.stride) * frame.height);
                std::memcpy(frame.pixels.data(), static_cast<const std::uint8_t *>(map) + offset, frame.pixels.size());
                munmap(map, allocation);
                if (Submit(frame)) { presented = frame.time; black = false; }
              }
            }
            if (memory >= 0) close(memory);
            if (!valid) disconnect();
            else if (!surround::Send(socket, "{\"major\":1,\"minor\":0,\"id\":2,\"op\":\"release\",\"args\":{\"generation\":" +
              std::to_string(generation) + ",\"sequence\":" + std::to_string(frame.sequence) + "}}")) disconnect();
          }
        }
        if (event.revents & (POLLHUP | POLLERR | POLLNVAL)) disconnect();
      } else { poll(nullptr, 0, 50); }
      if (!black && (socket < 0 || presented == 0 || Now() < presented || Now() - presented >= camera::kStaleNs)) {
        black = Submit(blank, true);
      }
    }
    disconnect();
  }
  void Run() {
    int socket = -1, event = -1, memory = -1;
    const std::uint8_t *ring = nullptr;
    bool black = false, warned = false;
    std::uint64_t sequence = 0, displayed_time = 0;
    camera::Frame blank;
    blank.width = 16;
    blank.height = 9;
    blank.stride = 64;
    blank.pixels.resize(576);
    auto disconnect = [&] {
      if (ring)
        munmap(const_cast<std::uint8_t *>(ring), camera::kSize);
      ring = nullptr;
      for (int fd : {socket, event, memory})
        if (fd >= 0)
          close(fd);
      socket = event = memory = -1;
    };
    while (!stopping) {
      if (refresh.exchange(false)) {
        black = false;
        sequence = 0;
      }
      if (socket < 0) {
        const char *runtime = std::getenv("XDG_RUNTIME_DIR");
        const std::string path =
            runtime ? std::string(runtime) + "/project-argo/camera-" +
                          std::to_string(getpid()) + "/media.sock"
                    : "";
        sockaddr_un address{};
        address.sun_family = AF_UNIX;
        if (!path.empty() && path.size() < sizeof(address.sun_path)) {
          std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
          socket =
              ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
          if (socket >= 0 &&
              connect(socket, reinterpret_cast<sockaddr *>(&address),
                      sizeof(address)) == 0) {
            // A full Unix listen backlog must never block stale-frame blanking.
            // Local connect has completed; only the bounded FD handshake may
            // wait.
            fcntl(socket, F_SETFL, fcntl(socket, F_GETFL) & ~O_NONBLOCK);
            timeval timeout{0, 300000};
            setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                       sizeof(timeout));
            char byte = 0;
            iovec iov{&byte, 1};
            alignas(cmsghdr) char control[CMSG_SPACE(2 * sizeof(int))]{};
            msghdr msg{};
            msg.msg_iov = &iov;
            msg.msg_iovlen = 1;
            msg.msg_control = control;
            msg.msg_controllen = sizeof(control);
            if (recvmsg(socket, &msg, MSG_CMSG_CLOEXEC) == 1 && byte == 1 &&
                !(msg.msg_flags & MSG_CTRUNC)) {
              auto *c = CMSG_FIRSTHDR(&msg);
              if (c && c->cmsg_level == SOL_SOCKET &&
                  c->cmsg_type == SCM_RIGHTS &&
                  c->cmsg_len == CMSG_LEN(2 * sizeof(int))) {
                int fds[2];
                std::memcpy(fds, CMSG_DATA(c), sizeof(fds));
                memory = fds[0];
                event = fds[1];
                struct stat info{};
                if (fstat(memory, &info) == 0 &&
                    info.st_size == static_cast<off_t>(camera::kSize)) {
                  void *map = mmap(nullptr, camera::kSize, PROT_READ,
                                   MAP_SHARED, memory, 0);
                  if (map != MAP_FAILED)
                    ring = static_cast<const std::uint8_t *>(map);
                }
              }
            }
          }
          if (!ring)
            disconnect();
        }
      }
      camera::Frame frame;
      const bool fresh = ring && camera::Latest(ring, Now(), frame, role);
      if (fresh) {
        if (frame.sequence != sequence || black) {
          if (Submit(frame)) {
            sequence = frame.sequence;
            displayed_time = frame.time;
            black = false;
            warned = false;
          } else if (!black) {
            black = Submit(blank, true);
          }
        }
      } else if (!black && !(ring && camera::Header(ring) &&
                             camera::Load(ring + 24) == 1 &&
                             camera::Load(ring + 32) == role + 1 &&
                             sequence != 0 && Now() >= displayed_time &&
                             Now() - displayed_time < camera::kStaleNs)) {
        // A slot overwritten during copy is dropped, not flashed black. Only
        // the timestamp of an actually submitted frame permits bounded
        // retention.
        black = Submit(blank, true);
        if (sequence && !warned) {
          std::fprintf(stderr, "Camera native view blanked: frame unavailable "
                               "or older than 750 ms\n");
          warned = true;
        }
      }
      pollfd fds[2]{{event, POLLIN, 0},
                    {socket, POLLIN | POLLHUP | POLLRDHUP, 0}};
      poll(fds, 2, 50);
      if (fds[0].revents & POLLIN) {
        std::uint64_t count;
        static_cast<void>(read(event, &count, 8));
      }
      if (fds[1].revents & (POLLHUP | POLLRDHUP | POLLERR)) {
        disconnect();
        black = false;
      }
    }
    disconnect();
  }
};
void Resize(void *data, double width, double height) {
  auto *v = static_cast<View *>(data);
  std::lock_guard lock(v->mutex);
  v->width = width;
  v->height = height;
  v->refresh = true;
}
void Suspend(void *data, std::uint8_t suspended) {
  auto *v = static_cast<View *>(data);
  std::lock_guard lock(v->mutex);
  v->suspended = suspended != 0;
  v->refresh = true;
}
void Renegotiate(void *data) {
  auto *v = static_cast<View *>(data);
  std::lock_guard lock(v->mutex);
  v->refresh = true;
  if (!v->Negotiate())
    std::fprintf(stderr, "Camera renegotiation failed\n");
}
void Dispose(void *data) { delete static_cast<View *>(data); }
int Create(const IhsPvCreateInfo *args, void *factory_data, IhsPlatformView *view,
           IhsPvCallbacks *callbacks, void **user_data) {
  std::uint32_t role = 0;
  if (!args || !callbacks || !user_data ||
      !camera::Parse(static_cast<const std::uint8_t *>(args->params),
                     args->params_size, role))
    return IHS_PV_ERR_INVALID;
  auto *v = new View;
  v->width = args->width;
  v->height = args->height;
  v->role = role;
  v->external = factory_data != nullptr;
  v->view = view;
  if (!v->Negotiate()) {
    std::fprintf(stderr, "Camera native view: no compatible GBM/IHS grant\n");
    delete v;
    return IHS_PV_ERR_UNSUPPORTED;
  }
  *callbacks = {};
  callbacks->struct_size = sizeof(*callbacks);
  callbacks->resize = Resize;
  callbacks->set_suspended = Suspend;
  callbacks->renegotiate = Renegotiate;
  callbacks->dispose = Dispose;
  *user_data = v;
  v->worker = std::thread([v] { if (v->external) v->RunExternal(); else v->Run(); });
  return IHS_PV_OK;
}
} // namespace
extern "C" __attribute__((visibility("default"))) int
argo_camera_view_register() {
  return ihs_pv_register_factory(kType, Create, nullptr);
}
extern "C" __attribute__((visibility("default"))) void
argo_camera_view_unregister() {
  ihs_pv_unregister_factory(kType);
}

extern "C" __attribute__((visibility("default"))) int
argo_surround_camera_view_register() {
  gst_init(nullptr, nullptr);
  return ihs_pv_register_factory(kSurroundType, Create, reinterpret_cast<void *>(1));
}
extern "C" __attribute__((visibility("default"))) void
argo_surround_camera_view_set_role(std::uint32_t role) {
  if (role < 4) selected_role.store(role);
  std::lock_guard lock(image_mutex); selected_image.path.clear();
}

extern "C" __attribute__((visibility("default"))) int
argo_surround_camera_view_set_image(const char *path, std::uint64_t capture_ns, std::uint32_t replay) {
  if (!path || strnlen(path, 4097) > 4096 || (path[0] != '/' && path[0] != '\0')) return -1;
  std::lock_guard lock(image_mutex);
  selected_image.path = path; selected_image.capture_ns = capture_ns;
  selected_image.replay = replay == 1; ++selected_image.revision;
  return 0;
}

extern "C" __attribute__((visibility("default"))) int
argo_surround_camera_runtime_check(const char *path) {
  struct stat info{};
  return path && lstat(path, &info) == 0 && S_ISDIR(info.st_mode) && info.st_uid == getuid() && (info.st_mode & 0077) == 0 ? 0 : -1;
}
