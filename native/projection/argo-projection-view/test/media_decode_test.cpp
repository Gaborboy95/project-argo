#include "../src/media_gstreamer.h"
#include <gst/app/gstappsrc.h>
#include <gst/app/gstappsink.h>
#include <cstdio>
#include <string>
#include <vector>

using namespace argo::media;

bool Decode(Codec codec, Framing framing) {
  const bool avc = codec == Codec::kH264;
  // Generate public synthetic frames at runtime, with no upstream test vectors.
  // This intentionally tests software codecs only, independent of display/IHS.
  const std::string encoder = avc ?
      "x264enc tune=zerolatency ! h264parse ! video/x-h264,stream-format=avc,alignment=au" :
      "x265enc tune=zerolatency option-string=pools=none:frame-threads=1 ! h265parse ! video/x-h265,stream-format=hvc1,alignment=au";
  const std::string generate = "videotestsrc num-buffers=1 pattern=black ! "
      "video/x-raw,format=I420,width=64,height=64,framerate=30/1 ! " + encoder +
      " ! appsink name=encoded sync=false";
  GstElement* encoding = gst_parse_launch(generate.c_str(), nullptr);
  if (encoding == nullptr) return false;
  GstElement* encoded_sink = gst_bin_get_by_name(GST_BIN(encoding), "encoded");
  gst_element_set_state(encoding, GST_STATE_PLAYING);
  GstSample* sample = gst_app_sink_try_pull_sample(GST_APP_SINK(encoded_sink), 5 * GST_SECOND);
  bool okay = sample != nullptr;
  std::vector<std::uint8_t> configuration, unit;
  if (sample != nullptr) {
    const GstStructure* s = gst_caps_get_structure(gst_sample_get_caps(sample), 0);
    const GValue* value = gst_structure_get_value(s, "codec_data");
    GstBuffer* config = value != nullptr ? gst_value_get_buffer(value) : nullptr;
    if (config == nullptr) okay = false;
    else {
      configuration.resize(gst_buffer_get_size(config));
      gst_buffer_extract(config, 0, configuration.data(), configuration.size());
      GstBuffer* access_unit = gst_sample_get_buffer(sample);
      unit.resize(gst_buffer_get_size(access_unit));
      gst_buffer_extract(access_unit, 0, unit.data(), unit.size());
    }
    gst_sample_unref(sample);
  }
  gst_element_set_state(encoding, GST_STATE_NULL);
  gst_object_unref(encoded_sink);
  gst_object_unref(encoding);
  unsigned length = 0;
  if (!okay || !ParseCodecConfig(configuration, codec, length) ||
      !InspectNals(unit, codec, Framing::kLengthPrefixed, length, false)) return false;

  if (framing == Framing::kAnnexB) {
    std::vector<std::uint8_t> annex_unit, annex_configuration;
    // Reframe the already-validated generated codec record for the Annex-B case.
    std::size_t position = avc ? 6 : 23;
    auto copy_parameters = [&](unsigned count) {
      for (unsigned i = 0; i < count; ++i) {
        const auto size = U16(configuration.data() + position);
        position += 2;
        std::uint8_t type = 0;
        const auto nal = std::span(configuration).subspan(position, size);
        if (NalType(nal, codec, type) && ParameterBit(codec, type) != 0) {
          annex_configuration.insert(annex_configuration.end(), {0, 0, 0, 1});
          annex_configuration.insert(annex_configuration.end(), nal.begin(), nal.end());
        }
        position += size;
      }
    };
    if (avc) {
      copy_parameters(configuration[5] & 31);
      const auto count = configuration[position++];
      copy_parameters(count);
    } else {
      for (unsigned i = 0; i < configuration[22]; ++i) {
        ++position;
        const auto count = U16(configuration.data() + position);
        position += 2;
        copy_parameters(count);
      }
    }
    for (std::size_t offset = 0; offset < unit.size();) {
      std::size_t size = 0;
      for (unsigned i = 0; i < length; ++i) size = (size << 8) | unit[offset++];
      const auto nal = std::span(unit).subspan(offset, size);
      std::uint8_t type = 0;
      if (!NalType(nal, codec, type)) return false;
      if (ParameterBit(codec, type) == 0) {
        annex_unit.insert(annex_unit.end(), {0, 0, 0, 1});
        annex_unit.insert(annex_unit.end(), nal.begin(), nal.end());
      }
      offset += size;
    }
    if (!InspectNals(annex_configuration, codec, framing, 0, true) ||
        !InspectNals(annex_unit, codec, framing, 0, false)) return false;
    configuration = std::move(annex_configuration);
    unit = std::move(annex_unit);
  }
  Description d{Protocol::kCarPlay, Plane::kMain, codec, Color::kBt709, Range::kFull,
                framing, 64, 64, 30, 1, 42};
  const std::string decode = std::string("appsrc name=input format=time ! ") +
      (avc ? "h264parse ! avdec_h264 ! " : "h265parse ! avdec_h265 ! ") +
      "identity name=color ! videoconvert ! video/x-raw,format=BGRx ! appsink name=output sync=false";
  GstElement* pipeline = gst_parse_launch(decode.c_str(), nullptr);
  if (pipeline == nullptr) return false;
  GstElement* input = gst_bin_get_by_name(GST_BIN(pipeline), "input");
  GstElement* output = gst_bin_get_by_name(GST_BIN(pipeline), "output");
  GstElement* color = gst_bin_get_by_name(GST_BIN(pipeline), "color");
  GstPad* pad = gst_element_get_static_pad(color, "sink");
  gst_pad_add_probe(pad, GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM, ApplyDecodedColor, &d, nullptr);
  gst_object_unref(pad);
  gst_object_unref(color);
  GstBuffer* config = gst_buffer_new_allocate(nullptr, configuration.size(), nullptr);
  gst_buffer_fill(config, 0, configuration.data(), configuration.size());
  GstCaps* caps = EncodedCaps(d, framing == Framing::kLengthPrefixed ? config : nullptr);
  gst_app_src_set_caps(GST_APP_SRC(input), caps);
  gst_caps_unref(caps);
  gst_element_set_state(pipeline, GST_STATE_PLAYING);
  gst_buffer_unref(config);
  if (framing == Framing::kAnnexB) unit.insert(unit.begin(), configuration.begin(), configuration.end());
  GstBuffer* frame = gst_buffer_new_allocate(nullptr, unit.size(), nullptr);
  gst_buffer_fill(frame, 0, unit.data(), unit.size());
  GST_BUFFER_PTS(frame) = 0;
  okay = okay && gst_app_src_push_buffer(GST_APP_SRC(input), frame) == GST_FLOW_OK;
  gst_app_src_end_of_stream(GST_APP_SRC(input));
  GstSample* decoded = gst_app_sink_try_pull_sample(GST_APP_SINK(output), 5 * GST_SECOND);
  okay = okay && decoded != nullptr;
  if (decoded != nullptr) {
    GstVideoInfo info{};
    okay = okay && gst_video_info_from_caps(&info, gst_sample_get_caps(decoded)) &&
        GST_VIDEO_INFO_WIDTH(&info) == 64 && GST_VIDEO_INFO_HEIGHT(&info) == 64 &&
        GST_VIDEO_INFO_FORMAT(&info) == GST_VIDEO_FORMAT_BGRx;
    GstMapInfo pixels{};
    if (gst_buffer_map(gst_sample_get_buffer(decoded), &pixels, GST_MAP_READ)) {
      // The synthetic limited black is Y=16; declared full range must preserve
      // its level, proving range propagation reaches the actual decoder path.
      okay = okay && pixels.size >= 3 && pixels.data[0] >= 14 && pixels.data[0] <= 18;
      gst_buffer_unmap(gst_sample_get_buffer(decoded), &pixels);
    } else okay = false;
    gst_sample_unref(decoded);
  }
  gst_element_set_state(pipeline, GST_STATE_NULL);
  gst_object_unref(input);
  gst_object_unref(output);
  gst_object_unref(pipeline);
  return okay;
}

int main(int argc, char** argv) {
  gst_init(&argc, &argv);
  for (const auto* name : {"x264enc", "x265enc", "h264parse", "h265parse", "avdec_h264", "avdec_h265"}) {
    GstElementFactory* factory = gst_element_factory_find(name);
    if (factory == nullptr) { std::fprintf(stderr, "unavailable test codec: %s\n", name); return 77; }
    gst_object_unref(factory);
  }
  for (const auto codec : {Codec::kH264, Codec::kH265}) {
    for (const auto framing : {Framing::kLengthPrefixed, Framing::kAnnexB}) {
      if (!Decode(codec, framing)) {
        std::fprintf(stderr, "decode failed: codec=%d framing=%d\n", static_cast<int>(codec), static_cast<int>(framing));
        return 1;
      }
    }
  }
  gst_deinit();
  return 0;
}
