# ACPI tables from a devicetree (D51): the loader makes them when RISC-V
# firmware gives only a DT (the Orange Pi RV2's U-Boot), so the kernel
# stays ACPI-only. It allocates nothing.
add_library(croi-dtacpi STATIC DtAcpi/Fdt.swift DtAcpi/Platform.swift DtAcpi/Tables.swift)
set_target_properties(croi-dtacpi PROPERTIES Swift_MODULE_NAME DtAcpi)
