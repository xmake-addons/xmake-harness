cc_library(
    name = "greet",
    srcs = ["lib/greet.c"],
    hdrs = ["include/greet.h"],
    includes = ["include"],
)

cc_binary(
    name = "demo",
    srcs = ["src/main.c"],
    includes = ["include"],
    defines = ["DEMO=1"],
    deps = [":greet"],
)
