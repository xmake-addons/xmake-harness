project('greeter', 'c')
inc = include_directories('include')
greet = static_library('greet', 'lib/greet.c', include_directories: inc)
executable('demo', 'src/main.c', include_directories: inc, link_with: greet)
