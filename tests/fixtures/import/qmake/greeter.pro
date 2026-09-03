TEMPLATE = app
TARGET   = demo
CONFIG  -= qt
CONFIG  += console

SOURCES += src/main.c \
           lib/greet.c
HEADERS += include/greet.h
INCLUDEPATH += include
DEFINES += DEMO=1
