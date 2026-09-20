#pragma once

#include "media_contract.h"
#include <gst/gst.h>
#include <gst/video/video.h>

namespace argo::media {

inline gchar* Colorimetry(const Description& d) {
  GstVideoColorimetry color{};
  color.range = d.range == Range::kFull ? GST_VIDEO_COLOR_RANGE_0_255 : GST_VIDEO_COLOR_RANGE_16_235;
  color.matrix = d.color == Color::kBt709 ? GST_VIDEO_COLOR_MATRIX_BT709 : GST_VIDEO_COLOR_MATRIX_BT601;
  color.transfer = d.color == Color::kBt709 ? GST_VIDEO_TRANSFER_BT709 : GST_VIDEO_TRANSFER_BT601;
  color.primaries = d.color == Color::kBt709 ? GST_VIDEO_COLOR_PRIMARIES_BT709 : GST_VIDEO_COLOR_PRIMARIES_SMPTE170M;
  return gst_video_colorimetry_to_string(&color);
}

inline GstCaps* EncodedCaps(const Description& d, GstBuffer* codec_data = nullptr) {
  const bool avc = d.codec == Codec::kH264;
  GstCaps* caps = gst_caps_new_simple(
      avc ? "video/x-h264" : "video/x-h265",
      "stream-format", G_TYPE_STRING,
      d.framing == Framing::kAnnexB ? "byte-stream" : avc ? "avc" : "hvc1",
      "alignment", G_TYPE_STRING, "au",
      "width", G_TYPE_INT, static_cast<int>(d.width),
      "height", G_TYPE_INT, static_cast<int>(d.height),
      "framerate", GST_TYPE_FRACTION, d.fps_num, d.fps_den, nullptr);
  gchar* color = Colorimetry(d);
  gst_caps_set_simple(caps, "colorimetry", G_TYPE_STRING, color, nullptr);
  g_free(color);
  if (codec_data != nullptr) gst_caps_set_simple(caps, "codec_data", GST_TYPE_BUFFER, codec_data, nullptr);
  return caps;
}

// The stream description is frozen by the native session owner. Explicitly
// propagate its negotiated SDR range before YUV -> RGB conversion; an RGB frame
// must not merely be relabelled full-range after limited-range conversion.
inline GstPadProbeReturn ApplyDecodedColor(GstPad*, GstPadProbeInfo* info,
                                           gpointer user_data) {
  if ((GST_PAD_PROBE_INFO_TYPE(info) & GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM) == 0) return GST_PAD_PROBE_OK;
  GstEvent* event = GST_PAD_PROBE_INFO_EVENT(info);
  if (GST_EVENT_TYPE(event) != GST_EVENT_CAPS) return GST_PAD_PROBE_OK;
  GstCaps* original = nullptr;
  gst_event_parse_caps(event, &original);
  if (original == nullptr || !gst_caps_is_fixed(original)) return GST_PAD_PROBE_DROP;
  GstCaps* caps = gst_caps_copy(original);
  const auto& d = *static_cast<const Description*>(user_data);
  GstVideoInfo video{};
  if (!gst_video_info_from_caps(&video, caps) ||
      GST_VIDEO_INFO_WIDTH(&video) != d.width || GST_VIDEO_INFO_HEIGHT(&video) != d.height ||
      !GST_VIDEO_INFO_IS_YUV(&video)) {
    gst_caps_unref(caps);
    return GST_PAD_PROBE_DROP;
  }
  gchar* color = Colorimetry(d);
  gst_caps_set_simple(caps, "colorimetry", G_TYPE_STRING, color, nullptr);
  g_free(color);
  GstEvent* replacement = gst_event_new_caps(caps);
  gst_event_set_seqnum(replacement, gst_event_get_seqnum(event));
  gst_caps_unref(caps);
  gst_event_unref(event);
  GST_PAD_PROBE_INFO_DATA(info) = replacement;
  return GST_PAD_PROBE_OK;
}

}  // namespace argo::media
