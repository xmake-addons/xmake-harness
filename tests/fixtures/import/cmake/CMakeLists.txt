cmake_minimum_required(VERSION 3.15)
project(greeter LANGUAGES C)

add_library(greet STATIC lib/greet.c)
target_include_directories(greet PUBLIC include)

add_executable(demo src/main.c)
target_include_directories(demo PRIVATE include)
target_compile_definitions(demo PRIVATE DEMO=1)
target_link_libraries(demo PRIVATE greet)
