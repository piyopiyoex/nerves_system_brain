DTC ?= dtc
DTC_FLAGS ?= -q

DTBS = \
	imx28-pwsh6-peripheral.dtb \
	imx28-pwsh6-buzzer.dtb

.PHONY: all
all: $(DTBS)

%.dtb: %.dts
	$(DTC) $(DTC_FLAGS) -I dts -O dtb -o $@ $<
