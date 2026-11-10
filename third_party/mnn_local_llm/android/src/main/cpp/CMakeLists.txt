cmake_minimum_required(VERSION 3.22.1)
project(mnn_local_llm LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(mnn_bridge SHARED mnn_bridge.cpp)

# MNN headers (MNN runtime + llm engine), vendored by tools/build_mnn_android.sh.
target_include_directories(
        mnn_bridge
        PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/mnn/include
)

# Prebuilt runtime: libMNN.so already contains the MNN runtime and LLM engine.
set(LIB_PATH ${CMAKE_SOURCE_DIR}/../jniLibs/${ANDROID_ABI})
add_library(MNN SHARED IMPORTED)
set_target_properties(MNN PROPERTIES
        IMPORTED_LOCATION ${LIB_PATH}/libMNN.so
        IMPORTED_NO_SONAME TRUE)

find_library(log-lib log)

target_link_libraries(mnn_bridge MNN ${log-lib})
