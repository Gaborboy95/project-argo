#include <gst/app/gstappsink.h>
#include <gst/gst.h>
#include <gst/video/video.h>
#include <ihs/platform_view.h>

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <string>

#include <sys/socket.h>
#include <sys/un.h>
#include <sys/mman.h>
#include <unistd.h>

namespace {

constexpr char kViewType[] = "argo.projection.view";
constexpr std::uint32_t kXrgb8888 = 0x34325258;  // DRM_FORMAT_XRGB8888.

enum class RenderPath : std::uint32_t {
  kNone = IHS_PV_KIND_NONE,
  kDmaBufTexture = IHS_PV_KIND_TEXTURE_DMABUF_IMPORT,
  kDrmPlane = IHS_PV_KIND_DRM_PLANE,
  kSoftware = IHS_PV_KIND_SOFTWARE_SHM,
};

RenderPath SelectRenderPath(const IhsPvCapabilities& capabilities,
                            bool can_export_compatible_dmabuf,
                            bool can_direct_scanout) {
  if (can_export_compatible_dmabuf &&
      (capabilities.kinds & IHS_PV_KIND_TEXTURE_DMABUF_IMPORT) != 0) {
    return RenderPath::kDmaBufTexture;
  }
  if (can_direct_scanout &&
      (capabilities.kinds & IHS_PV_KIND_DRM_PLANE) != 0) {
    return RenderPath::kDrmPlane;
  }
  if ((capabilities.kinds & IHS_PV_KIND_SOFTWARE_SHM) != 0) {
    return RenderPath::kSoftware;
  }
  return RenderPath::kNone;
}

struct ViewState;
GstFlowReturn OnSample(GstAppSink* sink, gpointer user_data);

struct ViewState {
  IhsPlatformView* view = nullptr;
  IhsPvGrant grant{};
  double width = 0;
  double height = 0;
  int shm_fd = -1;
  std::size_t shm_stride = 0;
  void* shm_mapping = MAP_FAILED;
  std::size_t shm_mapping_size = 0;
  GstElement* pipeline = nullptr;
  GstElement* app_sink = nullptr;
  int media_fd = -1;
  std::mutex mutex;
  bool suspended = false;

  ~ViewState() {
    StopPipeline();
    ReleaseMapping();
  }

  void StopPipeline() {
    if (pipeline != nullptr) {
      gst_element_set_state(pipeline, GST_STATE_NULL);
      gst_object_unref(pipeline);
      pipeline = nullptr;
      app_sink = nullptr;
    }
    if (media_fd >= 0) {
      close(media_fd);
      media_fd = -1;
    }
  }

  bool StartPipeline() {
    const char* socket_path = std::getenv("ARGO_PROJECTION_MEDIA_SOCKET");
    if (socket_path == nullptr || socket_path[0] == '\0') {
      return false;
    }
    media_fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (media_fd < 0) {
      return false;
    }
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    if (std::strlen(socket_path) >= sizeof(address.sun_path)) {
      StopPipeline();
      return false;
    }
    std::strncpy(address.sun_path, socket_path, sizeof(address.sun_path) - 1);
    if (connect(media_fd, reinterpret_cast<sockaddr*>(&address),
                sizeof(address)) != 0) {
      StopPipeline();
      return false;
    }

    const std::string description =
        "fdsrc fd=" + std::to_string(media_fd) +
        " do-timestamp=true ! queue max-size-buffers=8 leaky=downstream ! "
        "h264parse ! decodebin ! videoconvert ! "
        "video/x-raw,format=BGRx ! appsink name=projection_sink "
        "sync=false max-buffers=2 drop=true";
    GError* error = nullptr;
    pipeline = gst_parse_launch(description.c_str(), &error);
    if (pipeline == nullptr || error != nullptr) {
      if (error != nullptr) {
        g_error_free(error);
      }
      StopPipeline();
      return false;
    }
    app_sink = gst_bin_get_by_name(GST_BIN(pipeline), "projection_sink");
    if (app_sink == nullptr) {
      StopPipeline();
      return false;
    }
    GstAppSinkCallbacks callbacks{};
    callbacks.new_sample = OnSample;
    gst_app_sink_set_callbacks(GST_APP_SINK(app_sink), &callbacks, this,
                               nullptr);
    gst_object_unref(app_sink);
    app_sink = nullptr;
    return gst_element_set_state(pipeline, GST_STATE_PLAYING) !=
           GST_STATE_CHANGE_FAILURE;
  }

  void ReleaseMapping() {
    if (shm_mapping != MAP_FAILED) {
      munmap(shm_mapping, shm_mapping_size);
      shm_mapping = MAP_FAILED;
      shm_mapping_size = 0;
    }
    shm_fd = -1;  // Registry retains ownership of the fd.
    shm_stride = 0;
  }

  bool Negotiate() {
    ReleaseMapping();
    IhsPvCapabilities capabilities{.struct_size = sizeof(capabilities)};
    if (ihs_pv_query_capabilities(&capabilities) != IHS_PV_OK) {
      return false;
    }

    // The initial GStreamer path produces CPU RGB. A future hardware-decoder
    // path may set these after verifying its dma-buf fourcc/modifier against
    // capabilities.formats; NV12 is never assumed importable as RGB.
    const RenderPath path = SelectRenderPath(capabilities, false, false);
    if (path == RenderPath::kNone) {
      return false;
    }
    const IhsFormatModifier format{
        .fourcc = kXrgb8888,
        .reserved = 0,
        .modifier = 0,
    };
    const IhsPvRequirements requirements{
        .struct_size = sizeof(requirements),
        .kinds = static_cast<std::uint32_t>(path),
        .formats = &format,
        .format_count = 1,
        .needs_alpha = 0,
        .sync = IHS_PV_SYNC_IMPLICIT,
        .z_order = IHS_PV_Z_INLINE,
        .reserved = 0,
    };
    grant = IhsPvGrant{.struct_size = sizeof(grant)};
    if (ihs_pv_negotiate(view, &requirements, &grant) != IHS_PV_OK) {
      return false;
    }
    if (grant.granted_kind != IHS_PV_KIND_SOFTWARE_SHM) {
      return true;
    }
    shm_fd = ihs_pv_grant_shm_fd(view, &shm_stride);
    return Remap();
  }

  bool Remap() {
    ReleaseMapping();
    shm_fd = ihs_pv_grant_shm_fd(view, &shm_stride);
    if (shm_fd < 0 || shm_stride == 0 || height <= 0) {
      return false;
    }
    shm_mapping_size = shm_stride * static_cast<std::size_t>(height);
    shm_mapping =
        mmap(nullptr, shm_mapping_size, PROT_READ | PROT_WRITE, MAP_SHARED,
             shm_fd, 0);
    return shm_mapping != MAP_FAILED;
  }

  void SubmitRgb(const std::uint8_t* pixels, std::size_t stride,
                 std::uint32_t frame_width, std::uint32_t frame_height) {
    std::scoped_lock lock(mutex);
    if (suspended || grant.granted_kind != IHS_PV_KIND_SOFTWARE_SHM ||
        shm_mapping == MAP_FAILED) {
      return;
    }
    const std::size_t rows = std::min<std::size_t>(
        frame_height, static_cast<std::size_t>(height));
    const std::size_t bytes = std::min(stride, shm_stride);
    auto* destination = static_cast<std::uint8_t*>(shm_mapping);
    for (std::size_t row = 0; row < rows; ++row) {
      std::memcpy(destination + row * shm_stride, pixels + row * stride, bytes);
    }
    IhsFrame frame{
        .struct_size = sizeof(frame),
        .format = grant.format,
        .color_space = IHS_COLOR_SPACE_BT709,
        .color_range = IHS_COLOR_RANGE_LIMITED,
        .reserved = {0, 0},
        .width = frame_width,
        .height = frame_height,
        .plane_count = 1,
        .plane_fd = {-1, -1, -1, -1},
        .plane_offset = {0, 0, 0, 0},
        .plane_stride = {static_cast<std::uint32_t>(shm_stride), 0, 0, 0},
        .hdr = nullptr,
        .buffer_id = 0,
    };
    int release_fence = -1;
    ihs_pv_submit(view, &frame, -1, &release_fence);
    if (release_fence >= 0) {
      close(release_fence);
    }
  }
};

GstFlowReturn OnSample(GstAppSink* sink, gpointer user_data) {
  auto* state = static_cast<ViewState*>(user_data);
  GstSample* sample = gst_app_sink_pull_sample(sink);
  if (sample == nullptr) {
    return GST_FLOW_EOS;
  }
  GstBuffer* buffer = gst_sample_get_buffer(sample);
  GstCaps* caps = gst_sample_get_caps(sample);
  GstVideoInfo info{};
  GstMapInfo mapping{};
  if (buffer != nullptr && caps != nullptr &&
      gst_video_info_from_caps(&info, caps) &&
      gst_buffer_map(buffer, &mapping, GST_MAP_READ)) {
    state->SubmitRgb(mapping.data, GST_VIDEO_INFO_PLANE_STRIDE(&info, 0),
                     GST_VIDEO_INFO_WIDTH(&info), GST_VIDEO_INFO_HEIGHT(&info));
    gst_buffer_unmap(buffer, &mapping);
  }
  gst_sample_unref(sample);
  return GST_FLOW_OK;
}

void Resize(void* user_data, double width, double height) {
  auto* state = static_cast<ViewState*>(user_data);
  std::scoped_lock lock(state->mutex);
  state->width = width;
  state->height = height;
  if (state->grant.granted_kind == IHS_PV_KIND_SOFTWARE_SHM) {
    state->Remap();
  }
}

void SetSuspended(void* user_data, std::uint8_t suspended) {
  auto* state = static_cast<ViewState*>(user_data);
  std::scoped_lock lock(state->mutex);
  state->suspended = suspended != 0;
  if (state->pipeline != nullptr) {
    gst_element_set_state(state->pipeline,
                          state->suspended ? GST_STATE_PAUSED
                                           : GST_STATE_PLAYING);
  }
}

void Renegotiate(void* user_data) {
  auto* state = static_cast<ViewState*>(user_data);
  std::scoped_lock lock(state->mutex);
  state->Negotiate();
}

void Dispose(void* user_data) { delete static_cast<ViewState*>(user_data); }

int Create(const IhsPvCreateInfo* info, void*, IhsPlatformView* view,
           IhsPvCallbacks* callbacks, void** user_data) {
  if (info == nullptr || view == nullptr || callbacks == nullptr ||
      user_data == nullptr) {
    return IHS_PV_ERR_INVALID;
  }
  auto state = std::make_unique<ViewState>();
  state->view = view;
  state->width = info->width;
  state->height = info->height;
  if (!state->Negotiate()) {
    return IHS_PV_ERR_UNSUPPORTED;
  }
  state->StartPipeline();
  *callbacks = IhsPvCallbacks{
      .struct_size = sizeof(*callbacks),
      .resize = Resize,
      .on_touch = nullptr,
      .accept_gesture = nullptr,
      .reject_gesture = nullptr,
      .set_suspended = SetSuspended,
      .renegotiate = Renegotiate,
      .dispose = Dispose,
  };
  *user_data = state.release();
  return IHS_PV_OK;
}

}  // namespace

extern "C" __attribute__((visibility("default"))) int
argo_projection_view_register() {
  gst_init(nullptr, nullptr);
  return ihs_pv_register_factory(kViewType, Create, nullptr);
}

extern "C" __attribute__((visibility("default"))) void
argo_projection_view_unregister() {
  ihs_pv_unregister_factory(kViewType);
}
