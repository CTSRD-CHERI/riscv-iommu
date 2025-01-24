# Copyright 2022 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

BENDER:=./bender

library ?= work
top_level ?= rv_iommu_dti_ats_top_tb

pedanticerrors ?= -pedanticerrors

defines ?=
compile_flag += +cover=bcfst+/dut -incr -64 -nologo -quiet -suppress 13262 -suppress 3999 -suppress 3009 -suppress 8386 -suppress 8360 -permissive +define+$(defines)

bender:
	wget "https://github.com/pulp-platform/bender/releases/download/v0.22.0/bender-0.22.0-x86_64-linux-gnu-centos7.8.2003.tar.gz"
	tar -xvzf bender-0.22.0-x86_64-linux-gnu-centos7.8.2003.tar.gz
	rm bender-0.22.0-x86_64-linux-gnu-centos7.8.2003.tar.gz
	./bender --version | grep -q "bender 0.22.0"

update:
	$(BENDER) update

compile.tcl:
	$(BENDER) script vsim \
		--vlog-arg="$(compile_flag)  -work  $(library) -suppress 2583 -suppress 13314 -suppress 8386 +nospecify +notimingchecks" --vcom-arg=" -work $(library)" \
    -t rtl -t test -t tb -t vip > target/sim/vsim/$@

init: bender update compile.tcl
 
