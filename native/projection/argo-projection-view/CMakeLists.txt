cmake_minimum_required(VERSION 3.20)
project(argo_projection_view LANGUAGES CXX)

find_package(PkgConfig REQUIRED)
find_package(Threads REQUIRED)
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
  gstreamer-1.0>=1.20
  gstreamer-app-1.0>=1.20
  gstreamer-video-1.0>=1.20
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
  Threads::Threads
)
set_target_properties(argo_projection_view PROPERTIES
  OUTPUT_NAME argo_projection_view
  CXX_VISIBILITY_PRESET hidden
)

include(CTest)
if(BUILD_TESTING)
  add_executable(view_area_test test/view_area_test.cpp)
  target_compile_features(view_area_test PRIVATE cxx_std_20)
  target_compile_options(view_area_test PRIVATE -Wall -Wextra -Werror)
  add_test(NAME view_area_copy COMMAND view_area_test)
  add_executable(media_contract_test test/media_contract_test.cpp)
  target_compile_features(media_contract_test PRIVATE cxx_std_20)
  target_compile_options(media_contract_test PRIVATE -Wall -Wextra -Werror)
  target_link_libraries(media_contract_test PRIVATE Threads::Threads)
  add_test(NAME projection_media_contract COMMAND media_contract_test
    "${CMAKE_CURRENT_SOURCE_DIR}/test/fixtures/arpm-v1.hex")
  add_executable(media_color_test test/media_color_test.cpp)
  target_compile_features(media_color_test PRIVATE cxx_std_20)
  target_compile_options(media_color_test PRIVATE -Wall -Wextra -Werror)
  target_link_libraries(media_color_test PRIVATE PkgConfig::GSTREAMER)
  add_test(NAME projection_media_color COMMAND media_color_test)
  add_executable(media_decode_test test/media_decode_test.cpp)
  target_compile_features(media_decode_test PRIVATE cxx_std_20)
  target_compile_options(media_decode_test PRIVATE -Wall -Wextra -Werror)
  target_link_libraries(media_decode_test PRIVATE PkgConfig::GSTREAMER)
  add_test(NAME projection_media_decode COMMAND media_decode_test)
  set_tests_properties(projection_media_decode PROPERTIES SKIP_RETURN_CODE 77 TIMEOUT 30)
endif()
