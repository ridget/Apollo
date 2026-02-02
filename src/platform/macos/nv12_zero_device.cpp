/**
 * @file src/platform/macos/nv12_zero_device.cpp
 * @brief Definitions for NV12 zero copy device on macOS.
 */
// standard includes
#include <utility>

// local includes
#include "src/platform/macos/av_img_t.h"
#include "src/platform/macos/nv12_zero_device.h"
#include "src/video.h"

extern "C" {
#include "libavutil/imgutils.h"
}

namespace platf {

  void free_frame(AVFrame *frame) {
    av_frame_free(&frame);
  }

  void free_buffer(void *opaque, uint8_t *data) {
    CVPixelBufferRelease((CVPixelBufferRef) data);
  }

  int nv12_zero_device::convert(platf::img_t &img) {
    auto *av_img = (av_img_t *) &img;

    if (!av_img->pixel_buffer || !av_img->pixel_buffer->buf) {
      return -1;
    }

    av_buffer_unref(&frame->buf[0]);

    frame->buf[0] = av_buffer_create((uint8_t *) CFRetain(av_img->pixel_buffer->buf), 0, free_buffer, nullptr, 0);

    frame->data[3] = (uint8_t *) av_img->pixel_buffer->buf;

    return 0;
  }

  int nv12_zero_device::set_frame(AVFrame *frame, AVBufferRef *hw_frames_ctx) {
    this->frame = frame;

    resolution_fn(this->display, frame->width, frame->height);

    return 0;
  }

  int nv12_zero_device::init(void *display, pix_fmt_e pix_fmt, resolution_fn_t resolution_fn, const pixel_format_fn_t &pixel_format_fn) {
    OSType pixel_format;
    switch (pix_fmt) {
      case pix_fmt_e::nv12:
        pixel_format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
        break;
      case pix_fmt_e::p010:
        pixel_format = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
        break;
      default:
        pixel_format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
        break;
    }

    pixel_format_fn(display, pixel_format);

    this->display = display;
    this->resolution_fn = std::move(resolution_fn);

    data = this;

    return 0;
  }

}
