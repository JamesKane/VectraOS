# The ACPI root (RSDP, XSDT and the checksums), shared by the loader (the
# console's tables) and the kernel (all of them). It allocates nothing.
add_library(croi-acpi STATIC AcpiRoot/AcpiRoot.swift)
set_target_properties(croi-acpi PROPERTIES Swift_MODULE_NAME AcpiRoot)
