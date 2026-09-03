LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)
LOCAL_MODULE    := greet
LOCAL_SRC_FILES := ../lib/greet.c
LOCAL_C_INCLUDES := $(LOCAL_PATH)/../include
LOCAL_EXPORT_C_INCLUDES := $(LOCAL_PATH)/../include
include $(BUILD_STATIC_LIBRARY)

include $(CLEAR_VARS)
LOCAL_MODULE    := demo
LOCAL_SRC_FILES := ../src/main.c
LOCAL_C_INCLUDES := $(LOCAL_PATH)/../include
LOCAL_CFLAGS    := -DDEMO=1
LOCAL_STATIC_LIBRARIES := greet
LOCAL_LDLIBS    := -llog
include $(BUILD_EXECUTABLE)
