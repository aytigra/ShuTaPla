//
//  shim.h
//  Cmpv — Clang module exposing the libmpv C API to Swift.
//
//  The mpv headers themselves are found via HEADER_SEARCH_PATHS (the Homebrew mpv keg's
//  include directory); this shim is the module's single umbrella header.
//

#include <mpv/client.h>
#include <mpv/render.h>
#include <mpv/render_gl.h>
