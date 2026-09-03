noinst_LIBRARIES = libgreet.a
bin_PROGRAMS = demo

libgreet_a_SOURCES = lib/greet.c
libgreet_a_CPPFLAGS = -I$(top_srcdir)/include

demo_SOURCES = src/main.c
demo_CPPFLAGS = -I$(top_srcdir)/include -DDEMO=1
demo_LDADD = libgreet.a
