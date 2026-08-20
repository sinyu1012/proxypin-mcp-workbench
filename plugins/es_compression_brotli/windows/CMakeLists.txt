cmake_minimum_required(VERSION 3.14)
project(es_compression_brotli_plugin)

set(PLUGIN_NAME "es_compression_brotli_plugin")

# Copy brotli DLL to plugin build output
file(GLOB BROTLI_DLLS "${CMAKE_CURRENT_SOURCE_DIR}/blobs/*.dll")
if(BROTLI_DLLS)
    add_custom_command(TARGET ${PLUGIN_NAME} POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            ${BROTLI_DLLS}
            "$<TARGET_FILE_DIR:${PLUGIN_NAME}>"
        COMMENT "Copying es_compression brotli DLLs"
    )
endif()
