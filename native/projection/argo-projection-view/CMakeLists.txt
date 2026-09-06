cmake_minimum_required(VERSION 3.20)
project(argo_projection_view LANGUAGES CXX)

find_package(PkgConfig REQUIRED)
pkg_check_modules(GBM REQUIRED IMPORTED_TARGET gbm egl vulkan)
set(IHS_PREFIX "$ENV{IHS_PREFIX}")

find_path(IHS_INCLUDE_DIR
  NAMES ihs/platform_view.h
  PATHS "${IHS_PREFIX}/include"
  NO_DEFAULT_PATH
  REQUIRED
)

find_library(IHS_SHARED_LIBRARY
  NAMES ihs_shared
  PATHS "${IHS_PREFIX}/lib"
  NO_DEFAULT_PATH
  REQUIRED
)
pkg_check_modules(GSTREAMER REQUIRED IMPORTED_TARGET
  gstreamer-1.0
  gstreamer-app-1.0
  gstreamer-video-1.0
)

add_library(argo_projection_view SHARED
  src/projection_view.cpp
)
target_include_directories(argo_projection_view PRIVATE
  "${IHS_INCLUDE_DIR}"
)
target_compile_features(argo_projection_view PRIVATE cxx_std_20)
target_compile_options(argo_projection_view PRIVATE -Wall -Wextra -Werror)
target_link_libraries(argo_projection_view PRIVATE
  "${IHS_SHARED_LIBRARY}"
  PkgConfig::GSTREAMER
  PkgConfig::GBM
)
set_target_properties(argo_projection_view PROPERTIES
  OUTPUT_NAME argo_projection_view
  CXX_VISIBILITY_PRESET hidden
)
