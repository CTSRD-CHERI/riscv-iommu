# Copyright 2025 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

vsim rv_iommu_top_tb -t 1ps -coverage  -voptargs=+acc -classdebug -suppress 3999 -suppress 8360 \
    -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; log -r /*; run -a "
