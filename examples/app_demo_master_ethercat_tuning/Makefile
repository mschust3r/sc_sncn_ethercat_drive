PREFIX = /usr/local

CC = gcc
LD = gcc

INCLUDE = -I/opt/etherlab/include
INCLUDE += -I../libreadsdoconfig/include
INCLUDE += -Iinclude
INCLUDE += -I
INCLUDE += -I.
INCLUDE += -Isdo_config
LIB_PATH = -L/opt/etherlab/lib
LIB_PATH += -L../libreadsdoconfig/lib

LIBRARY =  -lethercat_wrapper -lethercat -lm -lreadsdoconfig

CFLAGS += $(FLAGS)
CFLAGS += -Wall --std=c99 -g -O2 $(INCLUDE) -D_XOPEN_SOURCE
LDFLAGS = -g -Wall -Wextra $(LIB_PATH) $(LIBRARY)
LIBS_D += -g -Wall -Wextra -lncurses

TARGET = bin/app_demo_master_ethercat_tuning

SRCDIR=src
ODIR=.obj
_OBJ = main.o ecat_sdo_config.o cyclic_task.o display.o ecat_master.o ecat_debug.o tuning.o profile_position.o
OBJ = $(patsubst %,$(ODIR)/%,$(_OBJ))

all: libreadsdoconfig $(TARGET)

$(ODIR):
	mkdir $(ODIR)
	
bin:
	mkdir bin

$(ODIR)/%.o: $(SRCDIR)/%.c $(ODIR) bin
	$(CC) -c -o $@ $< $(CFLAGS)


$(TARGET): $(OBJ)
	$(LD) -o $@ $^ -Wl,-Bstatic $(LDFLAGS) -Wl,-Bdynamic $(LIBS_D)

.PHONY: libreadsdoconfig clean install

libreadsdoconfig:
	make -C ../libreadsdoconfig all

install:
	install $(TARGET) $(PREFIX)/bin

clean:
	rm -rf $(ODIR) bin
