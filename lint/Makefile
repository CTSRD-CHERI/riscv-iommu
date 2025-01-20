# Copyright © 2025 Manuel Rodríguez & Zero-Day Labs, Lda.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Author:   Manuel Rodríguez <manuel.cederog@gmail.com>
# Date:     20/01/2025
#
# Description:  Makefile to perform lint checks in the RISC-V IOMMU IP using verilator

COMP_FLAGS :=
# COMP_FLAGS += --cc
COMP_FLAGS += --lint-only
COMP_FLAGS += --error-limit 10 

INC += -I../packages

INC += -I../vendor/axi/include
INC += -I../vendor/common_cells/include
INC += -I../vendor/register_interface/include
INC += -I../include

INC += -I../vendor/axi/src
INC += -I../vendor/axi_slice/src
INC += -I../vendor/common_cells/src
INC += -I../vendor/common_cells/src/deprecated
INC += -I../vendor/modified
INC += -I../vendor/register_interface/src

INC += -I../rtl/ext_interfaces
INC += -I../rtl/software_interface
INC += -I../rtl/software_interface/regmap
INC += -I../rtl/transaction_controller
INC += -I../rtl/translation_logic
INC += -I../rtl

all: lint

lint:
	verilator-5.022 config.vlt rv_iommu_lint_wrap.sv ${COMP_FLAGS} ${INC}

lint2log:
	verilator-5.022 config.vlt rv_iommu_lint_wrap.sv ${COMP_FLAGS} ${INC} 2> verilator.log