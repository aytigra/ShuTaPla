//
//  shim.h
//  Cffmpeg — Clang module exposing the FFmpeg C API to Swift.
//
//  The FFmpeg headers themselves are found via HEADER_SEARCH_PATHS (the Homebrew ffmpeg keg's
//  include directory); this shim is the module's single umbrella header. Only the demux/mux
//  and packet APIs the remux needs are pulled in.
//

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/error.h>
