#include "../src/media_gstreamer.h"
#include <gst/app/gstappsrc.h>
#include <gst/app/gstappsink.h>
#include <cmath>
#include <cstdio>
#include <cstring>

using namespace argo::media;

bool Convert(Range range, Color matrix, std::uint8_t luma, int expected) {
  Description d{Protocol::kCarPlay, Plane::kMain, Codec::kH264, matrix, range,
                Framing::kLengthPrefixed, 4, 2, 30, 1, 42};
  GError* error = nullptr;
  GstElement* pipeline = gst_parse_launch(
      "appsrc name=input format=time ! identity name=color ! videoconvert ! "
      "video/x-raw,format=BGRx ! appsink name=output sync=false", &error);
  if (pipeline == nullptr || error != nullptr) {
    if (error != nullptr) { std::fprintf(stderr, "%s\n", error->message); g_error_free(error); }
    if (pipeline != nullptr) gst_object_unref(pipeline);
    return false;
  }
  GstElement* input = gst_bin_get_by_name(GST_BIN(pipeline), "input");
  GstElement* output = gst_bin_get_by_name(GST_BIN(pipeline), "output");
  GstElement* identity = gst_bin_get_by_name(GST_BIN(pipeline), "color");
  GstPad* pad = gst_element_get_static_pad(identity, "sink");
  gst_pad_add_probe(pad, GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM, ApplyDecodedColor, &d, nullptr);
  gst_object_unref(pad);
  gst_object_unref(identity);
  GstVideoInfo video{};
  gst_video_info_set_format(&video, GST_VIDEO_FORMAT_I420, 4, 2);
  video.fps_n = 30; video.fps_d = 1;
  gst_video_colorimetry_from_string(&video.colorimetry, "bt709");
  GstCaps* caps = gst_video_info_to_caps(&video);
  gst_app_src_set_caps(GST_APP_SRC(input), caps);
  gst_caps_unref(caps);
  GstBuffer* buffer = gst_buffer_new_allocate(nullptr, video.size, nullptr);
  GstMapInfo write{};
  gst_buffer_map(buffer, &write, GST_MAP_WRITE);
  std::memset(write.data, 128, write.size);
  for (int row = 0; row < 2; ++row) {
    std::memset(write.data + video.offset[0] + row * video.stride[0], luma, 4);
  }
  gst_buffer_unmap(buffer, &write);
  GST_BUFFER_PTS(buffer) = 0;
  gst_element_set_state(pipeline, GST_STATE_PLAYING);
  bool okay = gst_app_src_push_buffer(GST_APP_SRC(input), buffer) == GST_FLOW_OK;
  gst_app_src_end_of_stream(GST_APP_SRC(input));
  GstSample* sample = gst_app_sink_try_pull_sample(GST_APP_SINK(output), GST_SECOND);
  okay = okay && sample != nullptr;
  if (sample != nullptr) {
    GstMapInfo pixels{};
    GstVideoInfo decoded{};
    okay = okay && gst_video_info_from_caps(&decoded, gst_sample_get_caps(sample));
    if (gst_buffer_map(gst_sample_get_buffer(sample), &pixels, GST_MAP_READ)) {
      for (int row = 0; row < 2; ++row) {
        for (int column = 0; column < 4; ++column) {
          for (int color = 0; color < 3; ++color) {
            const int actual = pixels.data[decoded.offset[0] + row * decoded.stride[0] + column * 4 + color];
            if (std::abs(actual - expected) > 2) {
              std::fprintf(stderr, "range=%d matrix=%d luma=%d actual=%d expected=%d\n",
                           static_cast<int>(range), static_cast<int>(matrix), luma, actual, expected);
              okay = false;
            }
          }
        }
      }
      gst_buffer_unmap(gst_sample_get_buffer(sample), &pixels);
    } else okay = false;
    gst_sample_unref(sample);
  }
  gst_element_set_state(pipeline, GST_STATE_NULL);
  gst_object_unref(input);
  gst_object_unref(output);
  gst_object_unref(pipeline);
  return okay;
}

int main(int argc, char** argv) {
  gst_init(&argc, &argv);
  for (const auto matrix : {Color::kBt601, Color::kBt709}) {
    if (!Convert(Range::kFull, matrix, 16, 16) || !Convert(Range::kFull, matrix, 235, 235) ||
        !Convert(Range::kLimited, matrix, 16, 0) || !Convert(Range::kLimited, matrix, 235, 255)) return 1;
  }
  for (const auto codec : {Codec::kH264, Codec::kH265}) {
    for (const auto framing : {Framing::kAnnexB, Framing::kLengthPrefixed}) {
      Description d{Protocol::kCarPlay, Plane::kMain, codec, Color::kBt709, Range::kFull,
                    framing, 1280, 720, 60, 1, 42};
      GstCaps* caps = EncodedCaps(d);
      const GstStructure* s = gst_caps_get_structure(caps, 0);
      const bool avc = codec == Codec::kH264;
      const bool okay = gst_structure_has_name(s, avc ? "video/x-h264" : "video/x-h265") &&
          std::strcmp(gst_structure_get_string(s, "stream-format"),
                      framing == Framing::kAnnexB ? "byte-stream" : avc ? "avc" : "hvc1") == 0;
      gst_caps_unref(caps);
      if (!okay) return 1;
    }
  }
  gst_deinit();
  return 0;
}
