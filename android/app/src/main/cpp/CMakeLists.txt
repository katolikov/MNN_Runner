cmake_minimum_required(VERSION 3.10)
project(mnn_runner_jni)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(mnn_runner SHARED mnn_runner.cpp)

find_library(log-lib log)

# Paths for MNN 3.1.0
set(MNN_INCLUDE_DIR ${CMAKE_SOURCE_DIR}/third_party/MNN/include)
set(MNN_SO_PATH ${CMAKE_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libMNN.so)

# Detect presence of headers and shared library
if (EXISTS "${MNN_INCLUDE_DIR}/MNN/Interpreter.hpp" AND EXISTS "${MNN_SO_PATH}")
    message(STATUS "MNN detected at: ${MNN_INCLUDE_DIR} and ${MNN_SO_PATH}")
    add_library(MNN SHARED IMPORTED)
    set_target_properties(MNN PROPERTIES IMPORTED_LOCATION ${MNN_SO_PATH})
    target_include_directories(mnn_runner PRIVATE ${MNN_INCLUDE_DIR})
    target_compile_definitions(mnn_runner PRIVATE HAVE_MNN=1)
    # Link against NDK shared C++ runtime so AGP packages libc++_shared.so
    target_link_libraries(mnn_runner MNN c++_shared ${log-lib})
else()
    message(WARNING "MNN not found. Building without MNN. Place headers in ${MNN_INCLUDE_DIR} and libMNN.so in ${CMAKE_SOURCE_DIR}/../jniLibs/<ABI>/")
    target_compile_definitions(mnn_runner PRIVATE HAVE_MNN=0)
    # Still link c++_shared to ensure consistent STL across builds
    target_link_libraries(mnn_runner c++_shared ${log-lib})
endif()
