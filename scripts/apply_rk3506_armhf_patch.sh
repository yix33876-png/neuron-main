#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT_DIR"

patch -p1 <<'PATCH'
diff --git a/cmake/arm-linux-gnueabihf.cmake b/cmake/arm-linux-gnueabihf.cmake
index 3f87699..50ffaf9 100644
--- a/cmake/arm-linux-gnueabihf.cmake
+++ b/cmake/arm-linux-gnueabihf.cmake
@@ -1,21 +1,25 @@
 set(CMAKE_SYSTEM_NAME Linux)
 set(COMPILER_PREFIX arm-linux-gnueabihf)
 set(CMAKE_SYSTEM_PROCESSOR armv7l)
-set(LIBRARY_DIR /home/neuron/main/libs)
+
+if(DEFINED ENV{STAGING} AND NOT "$ENV{STAGING}" STREQUAL "")
+  set(CMAKE_STAGING_PREFIX "$ENV{STAGING}")
+elseif(NOT DEFINED CMAKE_STAGING_PREFIX)
+  message(FATAL_ERROR "STAGING is not set. Export STAGING or pass -DCMAKE_STAGING_PREFIX=<path>.")
+endif()
 
 set(CMAKE_C_COMPILER ${COMPILER_PREFIX}-gcc)
 set(CMAKE_CXX_COMPILER ${COMPILER_PREFIX}-g++)
 set(CMAKE_AR ${COMPILER_PREFIX}-ar)
 set(CMAKE_LINKER ${COMPILER_PREFIX}-ld)
 set(CMAKE_NM ${COMPILER_PREFIX}-nm)
 set(CMAKE_OBJDUMP ${COMPILER_PREFIX}-objdump)
 set(CMAKE_RANLIB ${COMPILER_PREFIX}-ranlib)
-set(CMAKE_STAGING_PREFIX ${LIBRARY_DIR}/${COMPILER_PREFIX})
 set(CMAKE_PREFIX_PATH ${CMAKE_STAGING_PREFIX})
+set(OPENSSL_ROOT_DIR ${CMAKE_STAGING_PREFIX})
 
 include_directories(SYSTEM ${CMAKE_STAGING_PREFIX}/include)
-include_directories(SYSTEM ${CMAKE_STAGING_PREFIX}/openssl/include)
+include_directories(SYSTEM ${CMAKE_STAGING_PREFIX}/include/libxml2)
 set(CMAKE_FIND_ROOT_PATH ${CMAKE_STAGING_PREFIX})
 set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
 set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
 set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
-link_directories(${CMAKE_STAGING_PREFIX})
-
-file(COPY ${CMAKE_STAGING_PREFIX}/lib/libzlog.so.1.2 DESTINATION /usr/local/lib)
+set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
+link_directories(${CMAKE_STAGING_PREFIX}/lib)
diff --git a/CMakeLists.txt b/CMakeLists.txt
index 44c57e6..52015af 100644
--- a/CMakeLists.txt
+++ b/CMakeLists.txt
@@ -1,5 +1,7 @@
 cmake_minimum_required(VERSION 3.12)
 project(neuron)
+
+option(ENABLE_DATALAYERS "Build the datalayers plugin" ON)
 
 enable_testing()
 
@@ -54,10 +56,24 @@ set(OPENSSL_USE_STATIC_LIBS TRUE)
 find_package(OpenSSL REQUIRED)
 
 if (CMAKE_STAGING_PREFIX)
   include_directories(${CMAKE_STAGING_PREFIX}/include)
   link_directories(${CMAKE_STAGING_PREFIX}/lib)
   include_directories(${CMAKE_STAGING_PREFIX}/include/libxml2)
+  set(NEURON_LIB_SEARCH_PATHS ${CMAKE_STAGING_PREFIX}/lib)
 else()
   include_directories(/usr/local/include)
   link_directories(/usr/local/lib)
   include_directories(/usr/local/include/libxml2)
+  set(NEURON_LIB_SEARCH_PATHS /usr/local/lib)
 endif()
+
+find_library(NEURON_LIB_NNG nng PATHS ${NEURON_LIB_SEARCH_PATHS} REQUIRED NO_DEFAULT_PATH)
+find_library(NEURON_LIB_ZLOG zlog PATHS ${NEURON_LIB_SEARCH_PATHS} REQUIRED NO_DEFAULT_PATH)
+find_library(NEURON_LIB_JANSSON jansson PATHS ${NEURON_LIB_SEARCH_PATHS} REQUIRED NO_DEFAULT_PATH)
+find_library(NEURON_LIB_JWT jwt PATHS ${NEURON_LIB_SEARCH_PATHS} REQUIRED NO_DEFAULT_PATH)
+find_library(NEURON_LIB_XML2 xml2 PATHS ${NEURON_LIB_SEARCH_PATHS} REQUIRED NO_DEFAULT_PATH)
+find_library(NEURON_LIB_PROTOBUF_C protobuf-c PATHS ${NEURON_LIB_SEARCH_PATHS} REQUIRED NO_DEFAULT_PATH)
+find_library(NEURON_LIB_MBEDTLS mbedtls PATHS ${NEURON_LIB_SEARCH_PATHS} REQUIRED NO_DEFAULT_PATH)
+find_library(NEURON_LIB_MBEDX509 mbedx509 PATHS ${NEURON_LIB_SEARCH_PATHS} REQUIRED NO_DEFAULT_PATH)
+find_library(NEURON_LIB_MBEDCRYPTO mbedcrypto PATHS ${NEURON_LIB_SEARCH_PATHS} REQUIRED NO_DEFAULT_PATH)
+find_library(NEURON_LIB_SQLITE3 sqlite3 PATHS ${NEURON_LIB_SEARCH_PATHS} REQUIRED NO_DEFAULT_PATH)
 
 set(PERSIST_SOURCES
     src/persist/persist.c
@@ -119,12 +135,25 @@ if(CMAKE_BUILD_TYPE STREQUAL "Release")
 add_library(neuron-base SHARED)
 target_sources(neuron-base PRIVATE ${NEURON_BASE_SOURCES} ${NEURON_SRC_PARSE} ${NEURON_SRC_OTEL}) 
 target_include_directories(neuron-base
                            PRIVATE include/neuron src)
 target_link_libraries(neuron-base OpenSSL::SSL OpenSSL::Crypto)
-target_link_libraries(neuron-base nng libzlog.so jansson jwt xml2
-                      ${CMAKE_THREAD_LIBS_INIT} -lm protobuf-c)
+target_link_libraries(neuron-base
+                      ${NEURON_LIB_NNG}
+                      ${NEURON_LIB_ZLOG}
+                      ${NEURON_LIB_JANSSON}
+                      ${NEURON_LIB_JWT}
+                      ${NEURON_LIB_XML2}
+                      ${CMAKE_THREAD_LIBS_INIT}
+                      -lm
+                      ${NEURON_LIB_PROTOBUF_C})
 add_dependencies(neuron-base neuron-version)
 
 # dependency imposed by nng
 #find_package(MbedTLS)
-target_link_libraries(neuron-base mbedtls mbedx509 mbedcrypto)
+target_link_libraries(neuron-base
+                      ${NEURON_LIB_MBEDTLS}
+                      ${NEURON_LIB_MBEDX509}
+                      ${NEURON_LIB_MBEDCRYPTO})
 
 set(NEURON_SOURCES
     src/main.c
@@ -171,7 +200,12 @@ set(CMAKE_BUILD_RPATH ./)
 add_executable(neuron)
 target_sources(neuron PRIVATE ${NEURON_SOURCES}) 
 target_include_directories(neuron PRIVATE include/neuron src plugins)
-target_link_libraries(neuron dl neuron-base sqlite3 -lm xml2)
+target_link_libraries(neuron
+                      dl
+                      neuron-base
+                      ${NEURON_LIB_SQLITE3}
+                      -lm
+                      ${NEURON_LIB_XML2})
 target_link_options(neuron PRIVATE "LINKER:--dynamic-list-data")
 
 #copy file for run
@@ -188,7 +222,9 @@ add_subdirectory(plugins/modbus)
 add_subdirectory(plugins/mqtt)
 add_subdirectory(plugins/ekuiper)
 add_subdirectory(plugins/file)
 add_subdirectory(plugins/monitor)
-add_subdirectory(plugins/datalayers)
+if(ENABLE_DATALAYERS)
+  add_subdirectory(plugins/datalayers)
+endif()
 
 add_subdirectory(simulator)
diff --git a/plugins/ekuiper/CMakeLists.txt b/plugins/ekuiper/CMakeLists.txt
index e95780d..f48a5f6 100644
--- a/plugins/ekuiper/CMakeLists.txt
+++ b/plugins/ekuiper/CMakeLists.txt
@@ -11,5 +11,5 @@ add_library(plugin-ekuiper SHARED ${src})
 target_include_directories(plugin-ekuiper PRIVATE 
   ${CMAKE_SOURCE_DIR}/include/neuron)
 
-target_link_libraries(plugin-ekuiper neuron-base nng)
+target_link_libraries(plugin-ekuiper neuron-base ${NEURON_LIB_NNG})
 target_link_libraries(plugin-ekuiper ${CMAKE_THREAD_LIBS_INIT})
diff --git a/plugins/monitor/CMakeLists.txt b/plugins/monitor/CMakeLists.txt
index e5783ff..14f4e8d 100644
--- a/plugins/monitor/CMakeLists.txt
+++ b/plugins/monitor/CMakeLists.txt
@@ -15,5 +15,5 @@ target_include_directories(plugin-monitor PRIVATE
   ${CMAKE_SOURCE_DIR}/include/neuron
   ${CMAKE_SOURCE_DIR}/src
 )
 
-target_link_libraries(plugin-monitor neuron-base nng)
+target_link_libraries(plugin-monitor neuron-base ${NEURON_LIB_NNG})
 target_link_libraries(plugin-monitor ${CMAKE_THREAD_LIBS_INIT})
PATCH

echo "RK3506 ARMHF patch applied."
echo "Repo root: $ROOT_DIR"
