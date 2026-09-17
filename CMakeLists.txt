cmake_minimum_required(VERSION 3.16)

# VERSION is the single source of truth for firmware releases. Normal local and
# branch builds carry enough provenance to identify the exact source tree that
# produced them; a release pipeline opts into the clean SemVer with
# FOLO_FIRMWARE_RELEASE=1. ESP-IDF copies PROJECT_VER into esp_app_desc_t.version,
# whose storage is 32 bytes including the trailing NUL.
file(STRINGS "${CMAKE_CURRENT_LIST_DIR}/VERSION" FOLO_BASE_VERSION LIMIT_COUNT 1)
string(STRIP "${FOLO_BASE_VERSION}" FOLO_BASE_VERSION)
if(NOT FOLO_BASE_VERSION MATCHES "^[0-9]+\\.[0-9]+\\.[0-9]+$")
    message(FATAL_ERROR "VERSION must contain one MAJOR.MINOR.PATCH value")
endif()

if("$ENV{FOLO_FIRMWARE_RELEASE}" STREQUAL "1")
    set(PROJECT_VER "${FOLO_BASE_VERSION}")
else()
    execute_process(
        COMMAND git rev-parse --short=7 HEAD
        WORKING_DIRECTORY "${CMAKE_CURRENT_LIST_DIR}"
        OUTPUT_VARIABLE FOLO_GIT_SHA
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET)
    string(LENGTH "${FOLO_GIT_SHA}" FOLO_GIT_SHA_LENGTH)
    if(NOT FOLO_GIT_SHA MATCHES "^[0-9a-fA-F]+$" OR NOT FOLO_GIT_SHA_LENGTH EQUAL 7)
        set(FOLO_GIT_SHA "unknown")
    endif()
    execute_process(
        # catalog.json is a deterministic build output refreshed after CMake
        # configures. Excluding it prevents one successful build from making
        # the next otherwise-clean build identify itself as dirty.
        COMMAND git status --porcelain --untracked-files=normal -- .
                ":(exclude)mac-relay/AppCatalog/catalog.json"
        WORKING_DIRECTORY "${CMAKE_CURRENT_LIST_DIR}"
        OUTPUT_VARIABLE FOLO_GIT_STATUS
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET)
    set(PROJECT_VER "${FOLO_BASE_VERSION}-dev+g${FOLO_GIT_SHA}")
    if(NOT FOLO_GIT_STATUS STREQUAL "")
        string(APPEND PROJECT_VER ".dirty")
    endif()
endif()

string(LENGTH "${PROJECT_VER}" FOLO_PROJECT_VER_LENGTH)
if(FOLO_PROJECT_VER_LENGTH GREATER 31)
    message(FATAL_ERROR
        "Resolved firmware version '${PROJECT_VER}' exceeds esp_app_desc_t's 31-byte limit")
endif()
message(STATUS "FoloToy AI Passport firmware version: ${PROJECT_VER}")

include($ENV{IDF_PATH}/tools/cmake/project.cmake)

# Community firmware replaces the bootloader when installed over USB. Keep the
# factory Recovery entry gesture in every derivative build so USB development
# does not strand the device outside the mini-program BLE install path.
idf_build_set_property(
    BOOTLOADER_EXTRA_COMPONENT_DIRS
    "${CMAKE_CURRENT_LIST_DIR}/bootloader_components/"
    APPEND)

project(FoloToy-AI-Passport)
