cmake_minimum_required(VERSION 3.20)
project(argo_projection_view LANGUAGES CXX)

find_package(PkgConfig REQUIRED)
pkg_check_modules(IHS_SHARED REQUIRED IMPORTED_TARGET ihs_shared)
pkg_check_modules(GSTREAMER REQUIRED IMPORTED_TARGET
  gstreamer-1.0
  gstreamer-app-1.0
  gstreamer-video-1.0
)

add_library(argo_projection_view SHARED
  src/projection_view.cpp
)
target_compile_features(argo_projection_view PRIVATE cxx_std_20)
target_compile_options(argo_projection_view PRIVATE -Wall -Wextra -Werror)
target_link_libraries(argo_projection_view PRIVATE
  PkgConfig::IHS_SHARED
  PkgConfig::GSTREAMER
)
set_target_properties(argo_projection_view PROPERTIES
  OUTPUT_NAME argo_projection_view
  CXX_VISIBILITY_PRESET hidden
)
