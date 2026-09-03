CC      = gcc
CFLAGS  = -Wall -Iinclude -DDEMO=1
SRCS    = src/main.c lib/greet.c
OBJS    = $(SRCS:.c=.o)
TARGET  = demo

$(TARGET): $(OBJS)
	$(CC) -o $@ $^ $(LDFLAGS)

clean:
	rm -f $(OBJS) $(TARGET)
